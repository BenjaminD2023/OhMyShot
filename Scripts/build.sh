#!/bin/sh
# Builds the app into ./build. Usage: Scripts/build.sh [Debug|Release]
set -eu
cd "$(dirname "$0")/.."

CONFIGURATION=${1:-Debug}

# The project is generated from project.yml: make it when it is missing and again when project.yml has changed
# since, or a checkout that was generated before (before the Share extension target, say) would build without
# the targets added since.
if [ ! -d OhMyShot.xcodeproj ] || [ project.yml -nt OhMyShot.xcodeproj/project.pbxproj ]; then
  Scripts/bootstrap.sh
fi

# The repository can live in a file-provider folder (iCloud Desktop & Documents), which tags existing
# bundles with Finder info that codesign then rejects ("resource fork, Finder information, or similar
# detritus not allowed"); clear it from earlier builds first.
for app in "build/Build/Products/$CONFIGURATION"/*.app; do
  if [ -d "$app" ]; then xattr -cr "$app"; fi
done

xcodebuild \
  -project OhMyShot.xcodeproj \
  -scheme OhMyShot \
  -configuration "$CONFIGURATION" \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath build \
  -quiet \
  build

find "build/Build/Products/$CONFIGURATION" -maxdepth 1 -name '*.app' -print
