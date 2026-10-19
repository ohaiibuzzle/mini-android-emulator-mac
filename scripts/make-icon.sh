#!/bin/sh
# Renders assets/icon.svg into assets/Mini.icns (committed, so builds don't need librsvg). Needs: brew install librsvg
set -eu
root=$(cd "$(dirname "$0")/.." && pwd)
set_dir=$(mktemp -d)/Mini.iconset
mkdir "$set_dir"
for s in 16 32 128 256 512; do
  rsvg-convert -w $s -h $s "$root/assets/icon.svg" -o "$set_dir/icon_${s}x${s}.png"
  rsvg-convert -w $((s * 2)) -h $((s * 2)) "$root/assets/icon.svg" -o "$set_dir/icon_${s}x${s}@2x.png"
done
iconutil -c icns "$set_dir" -o "$root/assets/Mini.icns"
rm -r "$(dirname "$set_dir")"
echo "wrote $root/assets/Mini.icns"
