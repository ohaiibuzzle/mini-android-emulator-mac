#!/bin/bash
# Builds a LineageOS arm64 emulator system image that Mini can boot.
# Run on Linux x86_64 (AOSP doesn't build on macOS): ~32 GB RAM, ~300 GB disk, a few hours cold.
# Deps (Ubuntu 22.04+):
#   sudo apt install bc bison build-essential ccache curl flex git git-lfs gnupg gperf libelf-dev \
#     liblz4-tool libssl-dev libxml2-utils lz4 python3 rsync squashfs-tools xsltproc zip zlib1g-dev repo
# Usage: scripts/build-lineage.sh   (env: LINEAGE_BRANCH, WORK, DEST, JOBS)
set -euo pipefail
[ "$(uname -s)" = Linux ] || { echo "build-lineage: needs a Linux host" >&2; exit 1; }
branch=${LINEAGE_BRANCH:-lineage-24.0}  # android-17.0.0_r1 = API 37, same as Mini's AVD
work=${WORK:-$HOME/lineage}
dest=${DEST:-$PWD/build/lineage}
jobs=${JOBS:-$(nproc)}

for tool in repo git-lfs ccache python3; do
  command -v "$tool" > /dev/null || { echo "build-lineage: missing $tool (see the apt line at the top)" >&2; exit 1; }
done
mkdir -p "$work" "$dest"
dest=$(cd "$dest" && pwd)
cd "$work"

# Shallow clones save disk; re-running only syncs and rebuilds what changed (ccache).
repo init -u https://github.com/LineageOS/android.git -b "$branch" --git-lfs --depth=1 --no-clone-bundle
repo sync -c -j"$jobs" --no-tags --no-clone-bundle --optimized-fetch --force-sync

CCACHE_EXEC=$(command -v ccache)
export USE_CCACHE=1 CCACHE_EXEC
ccache -M "${CCACHE_SIZE:-50G}" > /dev/null

# envsetup/breakfast reference unset variables, so relax -u around them.
set +u
# shellcheck disable=SC1091 # exists after repo sync
source build/envsetup.sh
breakfast sdk_phone_arm64 userdebug
set -u
m -j"$jobs"
m -j"$jobs" emu_img_zip

zip=$(find "$OUT" -maxdepth 1 -name 'sdk-repo-*system-images*.zip' | head -1)
[ -n "$zip" ] || { echo "build-lineage: no system-image zip in $OUT" >&2; exit 1; }
name="$branch-sdk_phone_arm64-$(date +%Y%m%d).zip"
cp "$zip" "$dest/$name"
(cd "$dest" && sha256sum "$name" > "$name.sha256")
echo "built $dest/$name"
echo "install: unzip into ~/Library/Application Support/Mini/system-images/android-37/lineage/ (the zip holds arm64-v8a/)"
