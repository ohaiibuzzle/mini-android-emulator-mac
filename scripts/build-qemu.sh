#!/bin/sh
# Builds Mini's QEMU engine from source into third_party/install: the gfxstream host (macOS work from google/gfxstream#168),
# rutabaga_gfx's C FFI and upstream QEMU, each with patches/<tree>/*.patch. No Google prebuilt binaries.
# Needs: brew install meson ninja rust pkg-config glib pixman libslirp vulkan-loader. bundle.sh copies the result into Mini.app.
set -eu
root=$(cd "$(dirname "$0")/.." && pwd)
tp=$root/third_party
install=$tp/install
export PKG_CONFIG_PATH=$install/lib/pkgconfig

# fetch <tree> <url> <commit>: clones at the pin, then applies patches/<tree>/*.patch unless they already are.
fetch() {
  [ -d "$tp/$1/.git" ] || { git clone -q --filter=blob:none "$2" "$tp/$1" && git -C "$tp/$1" checkout -q "$3"; }
  for p in "$root/patches/$1"/*.patch; do
    [ -f "$p" ] || continue
    git -C "$tp/$1" apply --reverse --check "$p" 2>/dev/null || git -C "$tp/$1" apply "$p"
  done
}

fetch gfxstream https://github.com/utzcoz/gfxstream.git e9eed53d
fetch rutabaga_gfx https://github.com/magma-gpu/rutabaga_gfx.git 60603af
fetch qemu https://gitlab.com/qemu-project/qemu.git v11.1.2

cd "$tp/gfxstream"
[ -d build ] || meson setup build --buildtype=release --prefix="$install" -Dgfxstream-build=host -Ddecoders=gles,vulkan,composer
meson install -C build --quiet

cd "$tp/rutabaga_gfx"
[ -d build ] || meson setup build --buildtype=release --prefix="$install" -Dffi=true -Dfeatures=gfxstream
meson install -C build --quiet

# Only what Mini uses, so the binary links just glib, pixman, slirp, rutabaga and CoreAudio.
# --disable-pvg: hw/display/apple-gfx.m doesn't build against the macOS 27 SDK.
cd "$tp/qemu"
[ -d build-mini ] || (mkdir build-mini && cd build-mini && ../configure --target-list=aarch64-softmmu --without-default-features \
  --enable-hvf --enable-rutabaga-gfx --enable-slirp --enable-coreaudio --audio-drv-list=coreaudio --enable-fdt=internal --enable-pixman --enable-tools --disable-pvg \
  --disable-docs --disable-werror --disable-debug-info)
ninja -C build-mini qemu-system-aarch64 qemu-img
mkdir -p "$install/bin/lib64/vulkan"
cp build-mini/qemu-system-aarch64 build-mini/qemu-img "$install/bin/"

# gfxstream loads the Vulkan loader and ICD from <qemu dir>/lib64/vulkan: Mini's private-API MoltenVK behind Khronos' loader.
"$root/scripts/build-moltenvk.sh"
vk=$install/bin/lib64/vulkan
install -m 755 /opt/homebrew/opt/vulkan-loader/lib/libvulkan.1.dylib "$vk/libvulkan.dylib"
cp "$root/build/moltenvk/Package/Release/MoltenVK/dynamic/dylib/macOS/libMoltenVK.dylib" "$vk/"
printf '{\n  "file_format_version": "1.0.0",\n  "ICD": { "library_path": "./libMoltenVK.dylib", "api_version": "1.4.0", "is_portability_driver": true }\n}\n' \
  > "$vk/MoltenVK_icd.json"
echo "built $install/bin/qemu-system-aarch64"
