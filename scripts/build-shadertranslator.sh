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
mkdir -p "$src/src"
# Only the translator's subtrees, as gitiles tarballs: a full ANGLE checkout is gigabytes.
for d in include src/common src/compiler src/libShaderTranslator; do
  mkdir -p "$src/$d"
  curl -sfL "$repo/+archive/$rev/$d.tar.gz" | tar -xzf - -C "$src/$d"
done
for f in src/compiler.gni src/libGLESv2.gni; do file $f > "$src/$f"; done
file LICENSE > "$out/LICENSE"

# The emulator builds GN's "shadertranslator" target; this tree's CMakeLists.txt is years stale. So the sources come from
# ANGLE's own .gni lists: the same pieces as its translator_aemu (ESSL + GLSL output, Apple workarounds), minus the
# Vulkan/Metal/HLSL backends, which only add SPIR-V and glslang.
python3 -I - "$src" > "$out/sources.cmake" <<'EOF'
import os, re, sys
src = sys.argv[1]
lists = {}
for gni in ("src/compiler.gni", "src/libGLESv2.gni"):
    lists |= dict(re.findall(r'^(\w+) = \[([^\]]*)\]', open(os.path.join(src, gni)).read(), re.M))
files = [f for k in ("angle_translator_sources", "angle_translator_glsl_symbol_table_sources", "angle_translator_essl_sources",
                     "angle_translator_glsl_sources", "angle_translator_apple_sources", "angle_translator_glsl_base_sources",
                     "angle_translator_glsl_and_vulkan_base_sources", "angle_preprocessor_sources", "libangle_common_sources",
                     "xxhash_sources")
         for f in re.findall(r'"([^"]+)"', lists[k])]
# libGLESv2.gni adds these to libangle_common_sources inside `if (is_apple)` / `if (is_mac)`, which the regex skips.
files += ["src/common/gl/cgl/FunctionsCGL.cpp", "src/common/system_utils_apple.cpp", "src/common/system_utils_posix.cpp",
          "src/common/system_utils_mac.cpp", "src/libShaderTranslator/libShaderTranslator.cpp"]
missing = [f for f in files if not os.path.exists(os.path.join(src, f))]
assert not missing, f"not in the tarballs: {missing}"
print("set(ANGLE_SOURCES", *(f"angle/{f}" for f in files if f.endswith((".cpp", ".c"))), ")")
EOF

cat > "$out/CMakeLists.txt" <<'EOF'
cmake_minimum_required(VERSION 3.20)
project(shadertranslator C CXX)
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_OSX_ARCHITECTURES arm64)
include(sources.cmake)
add_library(shadertranslator SHARED ${ANGLE_SOURCES})
target_include_directories(shadertranslator PRIVATE angle/include angle/src angle/src/common/third_party/base)
# GN's translator_lib defines for this configuration, plus the shared library's own.
target_compile_definitions(shadertranslator PRIVATE ANGLE_ENABLE_ESSL ANGLE_ENABLE_GLSL ANGLE_ENABLE_APPLE_WORKAROUNDS
  AEMU_TRANSLATOR LIBANGLE_IMPLEMENTATION)
target_link_libraries(shadertranslator PRIVATE "-framework CoreFoundation" "-framework Foundation" "-framework IOKit"
  "-framework OpenGL")
set_target_properties(shadertranslator PROPERTIES INSTALL_NAME_DIR @rpath)
EOF
cmake -S "$out" -B "$out/build" -DCMAKE_BUILD_TYPE=Release
cmake --build "$out/build" --parallel
cp "$out/build/libshadertranslator.dylib" "$out/libshadertranslator.dylib"
for s in STInitialize STFinalize STGenerateResources STCompileAndResolve STFreeShaderResolveState STCopyVariable \
  STCopyInterfaceBlock STDestroyVariable STDestroyInterfaceBlock; do
  nm -gU "$out/libshadertranslator.dylib" | grep -q " _$s\$" || { echo "libshadertranslator: $s not exported" >&2; exit 1; }
done
echo "built $out/libshadertranslator.dylib"
