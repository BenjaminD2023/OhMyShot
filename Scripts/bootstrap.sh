#!/bin/sh
# Generates OhMyShot.xcodeproj from project.yml. Run after cloning and after editing project.yml.
set -eu
cd "$(dirname "$0")/.."

if ! command -v xcodegen >/dev/null 2>&1; then
  echo "XcodeGen is not installed. Install it with: brew install xcodegen" >&2
  exit 1
fi

xcodegen generate --quiet
echo "Generated OhMyShot.xcodeproj"
