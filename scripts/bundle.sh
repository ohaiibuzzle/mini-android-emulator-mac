#!/bin/sh
# Builds build/Mini.app with a pinned copy of the SDK emulator inside it.
# Local use only: the Android SDK license restricts redistributing the emulator.
set -eu
root=$(cd "$(dirname "$0")/.." && pwd)
sdk=${ANDROID_HOME:-$HOME/Library/Android/sdk}
app=$root/build/Mini.app

[ -x "$sdk/emulator/emulator" ] || { echo "no emulator in $sdk (install with sdkmanager \"emulator\")" >&2; exit 1; }

swift build -c release --package-path "$root/frontend"

rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$root/frontend/.build/release/Mini" "$app/Contents/MacOS/Mini"
ditto "$sdk/emulator" "$app/Contents/Resources/emulator"  # ditto keeps qemu's signature + hypervisor entitlement

version=$(sed -n 's/^Pkg.Revision=//p' "$sdk/emulator/source.properties")
cat > "$app/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>Mini</string>
  <key>CFBundleIdentifier</key><string>dev.local.goldfish-mini</string>
  <key>CFBundleName</key><string>Mini</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>MiniEmulatorVersion</key><string>$version</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
EOF
codesign --force -s - "$app/Contents/MacOS/Mini"  # ad-hoc; leaves the bundled emulator's own signatures intact
echo "built $app (emulator $version)"
