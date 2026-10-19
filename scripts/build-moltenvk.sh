#!/bin/sh
# Builds MoltenVK with private Metal APIs into build/moltenvk (skips if already built). Used by bundle.sh and CI.
# The private-API build adds VK_EXT_provoking_vertex, which guest ANGLE needs for GLES 3.x.
set -eu
root=$(cd "$(dirname "$0")/.." && pwd)
mvk=$root/build/moltenvk
version=${MVK_VERSION:-v1.4.2}
[ -f "$mvk/Package/Release/MoltenVK/dynamic/dylib/macOS/libMoltenVK.dylib" ] && exit 0
echo "building MoltenVK $version with MVK_USE_METAL_PRIVATE_API (takes a while)…"
[ -d "$mvk" ] || git clone -q --depth 1 --branch "$version" https://github.com/KhronosGroup/MoltenVK.git "$mvk"
cd "$mvk" && ./fetchDependencies --macos && make macos MVK_USE_METAL_PRIVATE_API=1
