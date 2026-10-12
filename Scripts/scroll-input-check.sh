#!/bin/sh
# Run after Scripts/run.sh. Shows a temporary synthetic scroll view away from the pointer.
set -eu
cd "$(dirname "$0")/.."

PROBE=build/scroll-input-probe/OhMyShot\ Input\ Probe.app
DEV_APP="$(pwd)/build/Build/Products/Debug/OhMyShot Dev.app"
STATE=/tmp/ohmyshot-input-receiver.json
MARKER=build/scroll-input-probe/started
mkdir -p "$PROBE/Contents/MacOS"
cp Tools/scroll-input-probe/Info.plist "$PROBE/Contents/Info.plist"
xcrun swiftc Tools/scroll-input-probe/Receiver.swift -o "$PROBE/Contents/MacOS/Receiver"
codesign --force --sign - "$PROBE"
touch "$MARKER"
open -g -n "$PROBE"
for attempt in 1 2 3 4 5 6 7 8 9 10; do
  if [ "$STATE" -nt "$MARKER" ]; then break; fi
  sleep 0.2
done
[ "$STATE" -nt "$MARKER" ] || { echo "Input probe did not start." >&2; exit 1; }
CHECK_START=$(date '+%Y-%m-%d %H:%M:%S')
open -g -a "$DEV_APP" 'ohmyshot-dev://debug/scroll-input-check'
sleep 2
REPORT=build/scroll-input-probe/report.log
/usr/bin/log show --start "$CHECK_START" --style compact --predicate \
  'process == "OhMyShot Dev" AND eventMessage CONTAINS "debug.scroll-input-external"' > "$REPORT"
cat "$REPORT"
rg -q 'debug.scroll-input-external PASS:' "$REPORT"
