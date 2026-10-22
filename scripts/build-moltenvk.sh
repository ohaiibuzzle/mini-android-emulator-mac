#!/bin/sh
# Builds MoltenVK with private Metal APIs and patches/moltenvk/*.patch into build/moltenvk (skips if already built). Used by
# bundle.sh and CI. The private-API build adds VK_EXT_provoking_vertex, which guest ANGLE needs for GLES 3.x.
set -eu
root=$(cd "$(dirname "$0")/.." && pwd)
mvk=$root/build/moltenvk
dylib=$mvk/Package/Release/MoltenVK/dynamic/dylib/macOS/libMoltenVK.dylib
version=${MVK_VERSION:-v1.4.2}
[ -d "$mvk/.git" ] || [ -f "$dylib" ] || git clone -q --depth 1 --branch "$version" https://github.com/KhronosGroup/MoltenVK.git "$mvk"
# CI's cache restores only the dylib, already patched (its key hashes the patches). A patch applied now means the dylib predates it.
if [ -d "$mvk/.git" ]; then
  for p in "$root/patches/moltenvk"/*.patch; do
    [ -f "$p" ] || continue
    git -C "$mvk" apply --reverse --check "$p" 2>/dev/null || { git -C "$mvk" apply "$p"; rm -f "$dylib"; }
  done
fi
[ -f "$dylib" ] && exit 0
echo "building MoltenVK $version with MVK_USE_METAL_PRIVATE_API (takes a while)…"
cd "$mvk" && ./fetchDependencies --macos && make macos MVK_USE_METAL_PRIVATE_API=1
