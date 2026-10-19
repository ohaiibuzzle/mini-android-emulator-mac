#!/bin/sh
# Compares guest GLES paths: host translator (desktop GL) vs guest ANGLE (Vulkan -> MoltenVK).
# Usage: bench/run.sh [avd] [runs]. Cold-boots the AVD headless once per mode; nothing else may be using adb.
set -eu
avd=${1:-goldfish37}
runs=${2:-3}
sdk=${ANDROID_HOME:-$HOME/Library/Android/sdk}
ndk=$(ls -d "$sdk"/ndk/* | sort -V | tail -1)
here=$(cd "$(dirname "$0")" && pwd)
out=$here/out
mkdir -p "$out"
# Never leave a headless emulator behind if a step fails.
trap 'adb emu kill > /dev/null 2>&1 || true' EXIT

"$ndk"/toolchains/llvm/prebuilt/darwin-x86_64/bin/aarch64-linux-android34-clang \
  -O2 -Wall -o "$out/glbench" "$here/glbench.c" -lEGL -lGLESv2 -lm

for mode in translator angle; do
  feature=""
  [ "$mode" = angle ] && feature="-feature GuestUsesAngle"
  # shellcheck disable=SC2086 # $feature is intentionally word-split
  "$sdk/emulator/emulator" -avd "$avd" -no-window -gpu host $feature -no-snapshot -no-audio -no-boot-anim \
    > "$out/emulator-$mode.log" 2>&1 &
  adb wait-for-device
  until [ "$(adb shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = 1 ]; do sleep 2; done
  sleep 20 # let boot-time jobs settle
  adb push -q "$out/glbench" /data/local/tmp/glbench
  for i in $(seq "$runs"); do
    adb shell /data/local/tmp/glbench > "$out/$mode-$i.tsv"
  done
  adb emu kill > /dev/null
  while pgrep -f qemu-system-aarch64 > /dev/null; do sleep 1; done
done

# Median per metric across runs, side by side.
for mode in translator angle; do
  echo "== $mode: $(sed -n 's/^renderer\t//p' "$out/$mode-1.tsv" | tr -d '\r')"
done
printf '%-12s %14s %14s  %s\n' metric translator angle unit
for metric in draw_calls fill shader_alu tex_upload readback roundtrip; do
  med() { cat "$out/$1"-*.tsv | tr -d '\r' | awk -F'\t' -v m="$metric" '$1==m {print $2}' | sort -g | awk '{a[NR]=$1} END {print a[int((NR+1)/2)]}'; }
  unit=$(tr -d '\r' < "$out/angle-1.tsv" | awk -F'\t' -v m="$metric" '$1==m {print $3}')
  printf '%-12s %14s %14s  %s\n' "$metric" "$(med translator)" "$(med angle)" "$unit"
done
