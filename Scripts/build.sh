#!/bin/sh
# Builds the app into ./build. Usage: Scripts/build.sh [Debug|Release]
set -eu
cd "$(dirname "$0")/.."

CONFIGURATION=${1:-Debug}

[ -d OhMyShot.xcodeproj ] || Scripts/bootstrap.sh

xcodebuild \
  -project OhMyShot.xcodeproj \
  -scheme OhMyShot \
  -configuration "$CONFIGURATION" \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath build \
  -quiet \
  build

find "build/Build/Products/$CONFIGURATION" -maxdepth 1 -name '*.app' -print
