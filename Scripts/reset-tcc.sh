#!/bin/sh
# Clears the privacy permissions of the Debug build so the first-run flow can be tested again.
# Usage: Scripts/reset-tcc.sh [service]   (default: All; e.g. ScreenCapture, Microphone, Camera)
set -eu
cd "$(dirname "$0")/.."

SERVICE=${1:-All}
PLIST="build/Build/Products/Debug/OhMyShot Dev.app/Contents/Info.plist"

if [ -f "$PLIST" ]; then
  BUNDLE_ID=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$PLIST")
else
  BUNDLE_ID=io.github.fzlzjerry.ohmyshot.dev
fi

tccutil reset "$SERVICE" "$BUNDLE_ID"
# Forget that the app has asked, so onboarding leads to macOS's prompt again.
defaults delete "$BUNDLE_ID" AskedPermissions 2>/dev/null || true
