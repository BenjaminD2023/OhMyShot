#!/bin/sh
# Generates OhMyShot.xcodeproj from project.yml. Run after cloning and after editing project.yml.
set -eu
cd "$(dirname "$0")/.."

if ! command -v xcodegen >/dev/null 2>&1; then
  echo "XcodeGen is not installed. Install it with: brew install xcodegen" >&2
  exit 1
fi

xcodegen generate --quiet
# The package versions the app is built with, which the generated project would otherwise resolve afresh: only into a
# project that has none yet, so versions Xcode has resolved since stay until they're copied back (Docs/release.md).
PINS=OhMyShot.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved
if [ ! -f "$PINS" ]; then
  mkdir -p "$(dirname "$PINS")"
  cp Config/Package.resolved "$PINS"
fi
echo "Generated OhMyShot.xcodeproj"
