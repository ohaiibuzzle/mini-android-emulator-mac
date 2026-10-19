#!/bin/sh
# Builds libshadertranslator.dylib into build/shadertranslator: ANGLE's GLSL translator behind the ST* C API that gfxstream's
# host GLES decoder dlopens (devices set to "Host translator"). From AOSP's emulator ANGLE branch, BSD-3-Clause.
# CI runs it (.github/workflows/build.yml); locally, download that artifact into build/shadertranslator instead.
# `build-shadertranslator.sh header` only fetches ShaderTranslator.h, which build-qemu.sh compiles gfxstream against.
set -eu
root=$(cd "$(dirname "$0")/.." && pwd)
rev=901e32aa9923b05c3a2af846f8a28fc79c93d0be  # platform/external/angle, emu-master-dev (2024-06-27); header and dylib must match
repo=https://android.googlesource.com/platform/external/angle
file() { curl -sfL "$repo/+/$rev/$1?format=TEXT" | base64 -d; }  # gitiles serves raw files base64-encoded

if [ "${1:-}" = header ]; then
  inc=$root/third_party/angle-st
  [ -f "$inc/ShaderTranslator.h" ] && exit 0
  mkdir -p "$inc"
  file src/libShaderTranslator/ShaderTranslator.h > "$inc/.ShaderTranslator.h"
  mv "$inc/.ShaderTranslator.h" "$inc/ShaderTranslator.h"
  exit 0
fi

out=$root/build/shadertranslator
[ -f "$out/libshadertranslator.dylib" ] && exit 0
src=$out/angle
rm -rf "$src" "$out/build"
mkdir -p "$src"
# Only the translator's subtrees, as gitiles tarballs: a full ANGLE checkout is gigabytes.
for d in include src/common src/compiler src/third_party/compiler src/libShaderTranslator; do
  mkdir -p "$src/$d"
  curl -sfL "$repo/+archive/$rev/$d.tar.gz" | tar -xzf - -C "$src/$d"
done
file CMakeLists.txt > "$src/CMakeLists.txt"  # the emulator's: targets only, no project()
file LICENSE > "$out/LICENSE"

cat > "$out/CMakeLists.txt" <<'EOF'
cmake_minimum_required(VERSION 3.20)
project(shadertranslator C CXX)
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)
set(CMAKE_OSX_ARCHITECTURES arm64)
add_subdirectory(angle)
EOF
cmake -S "$out" -B "$out/build" -DCMAKE_BUILD_TYPE=Release
cmake --build "$out/build" --target angle_shader_translator --parallel
# The emulator links these two static targets into its shared library the same way.
c++ -dynamiclib -arch arm64 -o "$out/libshadertranslator.dylib" -install_name @rpath/libshadertranslator.dylib \
  -Wl,-force_load,"$out/build/angle/libangle_shader_translator.a" "$out/build/angle/libangle_common.a" \
  -framework CoreFoundation -framework Foundation
for s in STInitialize STFinalize STGenerateResources STCompileAndResolve STFreeShaderResolveState STCopyVariable \
  STCopyInterfaceBlock STDestroyVariable STDestroyInterfaceBlock; do
  nm -gU "$out/libshadertranslator.dylib" | grep -q " _$s\$" || { echo "libshadertranslator: $s not exported" >&2; exit 1; }
done
echo "built $out/libshadertranslator.dylib"
