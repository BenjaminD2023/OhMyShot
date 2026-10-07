#!/bin/sh
# Builds the Debug app ("OhMyShot Dev"), quits any running copy, and launches the new build.
set -eu
cd "$(dirname "$0")/.."

APP=$(Scripts/build.sh Debug | tail -1)
NAME=$(basename "$APP" .app)

if pgrep -x "$NAME" >/dev/null; then
  pkill -x "$NAME" || true
  while pgrep -x "$NAME" >/dev/null; do sleep 0.1; done
fi

# LaunchServices can lag a moment behind a process that just exited (error -600), so retry briefly.
for attempt in 1 2 3 4 5; do
  if open "$APP" 2>/dev/null; then
    echo "Launched $APP"
    exit 0
  fi
  sleep 0.5
done
echo "Could not launch $APP" >&2
exit 1
