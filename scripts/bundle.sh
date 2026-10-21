#!/bin/sh
# Builds build/Mini.app. Bundles Mini's QEMU engine (scripts/build-qemu.sh: GPL-2.0 QEMU, Apache-2.0 gfxstream, BSD
# rutabaga, a MoltenVK built with private Metal APIs for VK_EXT_provoking_vertex, and the Homebrew libraries they link)
# under Contents/Resources/qemu. Google's adb and system images are not bundled (SDK license); Mini downloads them.
set -eu
root=$(cd "$(dirname "$0")/.." && pwd)
app=$root/build/Mini.app

# Command Line Tools' Swift 6.2 can't load its own SWBBuildService (dyld error), and the Metal shaders need Xcode anyway.
case ${DEVELOPER_DIR:-$(xcode-select -p 2>/dev/null)} in
  *CommandLineTools*) echo "bundle: needs Xcode's toolchain: sudo xcode-select -s /Applications/Xcode.app (or unset DEVELOPER_DIR)" >&2; exit 1 ;;
esac
"$root/scripts/build-qemu.sh"  # builds MoltenVK too
swift build -c release --package-path "$root/frontend"

rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$root/frontend/.build/release/Mini" "$app/Contents/MacOS/Mini"
cp "$root/scripts/gsi-image.py" "$app/Contents/Resources/gsi-image.py"  # Devices → Import GSI runs it
cp "$root/assets/Mini.icns" "$app/Contents/Resources/Mini.icns"  # from assets/icon.svg via scripts/make-icon.sh

# QEMU plus every non-system library it pulls in, pointed at qemu/lib.
q=$app/Contents/Resources/qemu
mkdir -p "$q/lib" "$q/licenses"
cp -R "$root/third_party/install/bin" "$q/bin"
chmod -R u+w "$q"
find "$q/bin" -type f ! -name qemu-system-aarch64 ! -name qemu-img ! -path "*/lib64/*" -delete  # Mini makes qcow2 overlays with qemu-img
kegs=$(mktemp)
relocate() {
  for dep in $(otool -L "$1" | tail -n +2 | awk '{print $1}' | grep -E '^/(opt|Users)/'); do
    name=${dep##*/}
    install_name_tool -change "$dep" "@executable_path/../lib/$name" "$1" 2>/dev/null
    [ -f "$q/lib/$name" ] && continue
    cp "$dep" "$q/lib/$name"
    dirname "$(dirname "$(realpath "$dep")")" >> "$kegs"  # /opt/homebrew/Cellar/<formula>/<version> for Homebrew's
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
cp "$root/build/moltenvk/LICENSE" "$q/licenses/MoltenVK-LICENSE.txt"
# ANGLE's shader translator, for "Host translator" devices. CI builds it; it isn't built here (build-shadertranslator.sh).
st=$root/build/shadertranslator
if [ -f "$st/libshadertranslator.dylib" ]; then
  cp "$st/libshadertranslator.dylib" "$q/lib/"
  cp "$st/LICENSE" "$q/licenses/ANGLE-LICENSE.txt"
else
  echo "bundle: no build/shadertranslator (the CI artifact), so Mini.app can't run GLES on the host" >&2
fi
# The Homebrew libraries' license texts, and where every bundled part's source is (GPL/LGPL). CI's release job reads the
# "homebrew" lines to attach those sources to the release.
{
  echo "Mini's source, with patches/ and the scripts that build all of this: https://github.com/ohaiibuzzle/mini-android-emulator-mac"
  echo "Each GitHub release of Mini also attaches the QEMU and Homebrew sources below."
  for t in qemu gfxstream rutabaga_gfx; do
    echo "$t $(git -C "$root/third_party/$t" remote get-url origin) $(git -C "$root/third_party/$t" rev-parse HEAD) + patches/$t"
  done
  grep /Cellar/ "$kegs" | sort -u | while read -r keg; do
    formula=${keg%/*}; formula=${formula##*/}
    echo "homebrew $formula ${keg##*/}"
    find "$keg" -maxdepth 1 -type f \( -iname 'COPYING*' -o -iname 'COPYRIGHT*' -o -iname 'LICEN[CS]E*' -o -iname '*GPL*.txt' \) \
      -exec sh -c 'cp "$1" "$2-${1##*/}"' _ {} "$q/licenses/$formula" \;
  done
} > "$q/licenses/SOURCES.txt"
rm "$kegs"

cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>Mini</string>
  <key>CFBundleIconFile</key><string>Mini</string>
  <key>CFBundleIdentifier</key><string>dev.local.goldfish-mini</string>
  <key>CFBundleName</key><string>Mini</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <!-- Game Mode, in full screen: Mini's own process gets the priority, QEMU's may not; controllers poll faster either way. -->
  <key>LSApplicationCategoryType</key><string>public.app-category.games</string>
  <key>LSSupportsGameMode</key><true/>
  <key>GCSupportsGameMode</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSMicrophoneUsageDescription</key><string>Android apps on your devices can use the microphone.</string>
</dict></plist>
PLIST
for f in "$q"/lib/* "$q"/bin/lib64/vulkan/*.dylib "$q/bin/qemu-img"; do codesign --force -s - "$f"; done
# HVF refuses processes without the hypervisor entitlement.
codesign --force -s - --entitlements "$root/third_party/qemu/accel/hvf/entitlements.plist" "$q/bin/qemu-system-aarch64"
codesign --force -s - "$app"
echo "built $app"
