#!/bin/sh
# Rebuilds Mini.app and relaunches it. Usage: scripts/build-mini.sh [device]   (boots it via --start; none: opens Devices)
set -eu
root=$(cd "$(dirname "$0")/.." && pwd)
"$root/scripts/bundle.sh"
# Quit gracefully so Android shuts down, then wait for Mini to exit.
osascript -e 'quit app "Mini"' 2> /dev/null || true
while pgrep -f "$root/build/Mini.app/Contents/MacOS/Mini" > /dev/null; do sleep 1; done
open "$root/build/Mini.app" --args ${1:+--start "$1"}
