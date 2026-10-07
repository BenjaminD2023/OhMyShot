#!/bin/sh
# Reports p50/p95/max of a latency the app measured with LatencyProbe, e.g. hotkey to overlay.
#
# Usage: Scripts/latency.sh <probe name> [time window, default 10m] [subsystem]
#   Scripts/latency.sh overlay.visible
#   Scripts/latency.sh overlay.frozen 30m
set -eu

NAME=${1:?"usage: Scripts/latency.sh <probe name> [window] [subsystem]"}
WINDOW=${2:-10m}
SUBSYSTEM=${3:-io.github.fzlzjerry.ohmyshot.dev}

/usr/bin/log show --style compact --last "$WINDOW" \
  --predicate "subsystem == \"$SUBSYSTEM\" AND eventMessage BEGINSWITH \"latency $NAME \"" 2>/dev/null \
  | awk -v name="$NAME" '{ for (i = 1; i < NF; i++) if ($i == "latency" && $(i + 1) == name) print $(i + 2) }' \
  | sort -n \
  | awk -v name="$NAME" '
      { v[NR] = $1 }
      END {
        if (NR == 0) { print "No \"" name "\" measurements found."; exit 1 }
        p50 = v[int((NR - 1) * 0.50) + 1]
        p95 = v[int((NR - 1) * 0.95) + 1]
        printf "%s: n=%d  p50=%.1f ms  p95=%.1f ms  max=%.1f ms\n", name, NR, p50, p95, v[NR]
      }'
