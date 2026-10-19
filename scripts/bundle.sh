#!/bin/sh
# Builds build/Mini.app. The Android Emulator is not bundled (its SDK license forbids that); Mini downloads it on first run.
# Bundles Mini's own QEMU engine (scripts/build-qemu.sh: GPL-2.0 QEMU, Apache-2.0 gfxstream, BSD rutabaga, and the
# Homebrew libraries they link) under Contents/Resources/qemu, and a MoltenVK built with private Metal APIs (Apache-2.0, redistributable): it adds VK_EXT_provoking_vertex,
# which guest ANGLE needs for GLES 3.x.
set -eu
root=$(cd "$(dirname "$0")/.." && pwd)
app=$root/build/Mini.app
mvk=$root/build/moltenvk
dylib=$mvk/Package/Release/MoltenVK/dynamic/dylib/macOS/libMoltenVK.dylib

# Command Line Tools' Swift 6.2 can't load its own SWBBuildService (dyld error), and the Metal shaders need Xcode anyway.
case ${DEVELOPER_DIR:-$(xcode-select -p 2>/dev/null)} in
  *CommandLineTools*) echo "bundle: needs Xcode's toolchain: sudo xcode-select -s /Applications/Xcode.app (or unset DEVELOPER_DIR)" >&2; exit 1 ;;
esac
"$root/scripts/build-moltenvk.sh"
"$root/scripts/build-qemu.sh"
swift build -c release --package-path "$root/frontend"

rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$root/frontend/.build/release/Mini" "$app/Contents/MacOS/Mini"
cp "$dylib" "$app/Contents/Resources/libMoltenVK.dylib"
cp "$mvk/LICENSE" "$app/Contents/Resources/MoltenVK-LICENSE.txt"
cp "$root/scripts/gsi-image.py" "$app/Contents/Resources/gsi-image.py"  # Devices → Import GSI runs it

# QEMU plus every non-system library it pulls in, pointed at qemu/lib.
q=$app/Contents/Resources/qemu
mkdir -p "$q/lib" "$q/licenses"
cp -R "$root/third_party/install/bin" "$q/bin"
chmod -R u+w "$q"
find "$q/bin" -type f ! -name qemu-system-aarch64 ! -name qemu-img ! -path "*/lib64/*" -delete  # Mini makes qcow2 overlays with qemu-img
relocate() {
  for dep in $(otool -L "$1" | tail -n +2 | awk '{print $1}' | grep -E '^/(opt|Users)/'); do
    name=${dep##*/}
    install_name_tool -change "$dep" "@executable_path/../lib/$name" "$1" 2>/dev/null
    [ -f "$q/lib/$name" ] && continue
    cp "$dep" "$q/lib/$name"
    chmod u+w "$q/lib/$name"
    install_name_tool -id "@executable_path/../lib/$name" "$q/lib/$name" 2>/dev/null
    relocate "$q/lib/$name"
  done
}
relocate "$q/bin/qemu-system-aarch64"
relocate "$q/bin/qemu-img"
cp "$root/third_party/qemu/COPYING" "$q/licenses/QEMU-COPYING.txt"
cp "$root/third_party/gfxstream/LICENSE" "$q/licenses/gfxstream-LICENSE.txt"
cp "$root/third_party/rutabaga_gfx/LICENSE" "$q/licenses/rutabaga_gfx-LICENSE.txt"
# shortcut: the Homebrew libraries' own license texts (glib/gettext LGPL, pixman MIT, slirp & pcre2 BSD) aren't copied;
# add them before handing Mini.app to anyone, along with where to get QEMU's source (GPL).

cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>Mini</string>
  <key>CFBundleIdentifier</key><string>dev.local.goldfish-mini</string>
  <key>CFBundleName</key><string>Mini</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSMicrophoneUsageDescription</key><string>Android apps on your devices can use the microphone.</string>
</dict></plist>
PLIST
codesign --force -s - "$app/Contents/Resources/libMoltenVK.dylib"
for f in "$q"/lib/* "$q"/bin/lib64/vulkan/*.dylib "$q/bin/qemu-img"; do codesign --force -s - "$f"; done
# HVF refuses processes without the hypervisor entitlement.
codesign --force -s - --entitlements "$root/third_party/qemu/accel/hvf/entitlements.plist" "$q/bin/qemu-system-aarch64"
codesign --force -s - "$app"
echo "built $app (private-API MoltenVK, QEMU engine)"
