#!/bin/sh
# Builds build/Mini.app. The Android Emulator is not bundled (its SDK license forbids that); Mini downloads it on first run.
# Bundles a MoltenVK built with private Metal APIs (Apache-2.0, redistributable): it adds VK_EXT_provoking_vertex,
# which guest ANGLE needs for GLES 3.x.
set -eu
root=$(cd "$(dirname "$0")/.." && pwd)
app=$root/build/Mini.app
mvk=$root/build/moltenvk
dylib=$mvk/Package/Release/MoltenVK/dynamic/dylib/macOS/libMoltenVK.dylib

"$root/scripts/build-moltenvk.sh"
swift build -c release --package-path "$root/frontend"

rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$root/frontend/.build/release/Mini" "$app/Contents/MacOS/Mini"
cp "$dylib" "$app/Contents/Resources/libMoltenVK.dylib"
cp "$mvk/LICENSE" "$app/Contents/Resources/MoltenVK-LICENSE.txt"
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
</dict></plist>
PLIST
codesign --force -s - "$app/Contents/Resources/libMoltenVK.dylib"
codesign --force -s - "$app"
echo "built $app (private-API MoltenVK)"
