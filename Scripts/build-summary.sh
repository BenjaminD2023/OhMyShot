#!/bin/sh
# Sums up a build log of Scripts/release.sh in Markdown, as CI's and the release's job summaries show it: how many
# compilations the compilation cache replayed, and the tasks that took the most time.
# Usage: Scripts/build-summary.sh <build.log>
set -eu

LOG=$1
if [ ! -f "$LOG" ]; then
  echo "No build log at $LOG."
  exit 0
fi

HITS=$(grep -c '^Cache hit' "$LOG" || true)
MISSES=$(grep -c '^Cache miss' "$LOG" || true)
echo "### The app's build"
echo
if [ $((HITS + MISSES)) -gt 0 ]; then
  echo "The compilation cache replayed $HITS of $((HITS + MISSES)) compilations; $MISSES were compiled."
else
  echo "No compilation went through the compilation cache."
fi
echo
# The times are the tasks' own, added up across the cores that ran them.
echo "| Task | Count | Seconds, all cores |"
echo "| --- | ---: | ---: |"
sed -n 's/^\([A-Za-z]*\) (\([0-9]*\) tasks*) | \([0-9.]*\) seconds$/| \1 | \2 | \3 |/p' "$LOG" | head -6
