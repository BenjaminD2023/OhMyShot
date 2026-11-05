#!/bin/sh
# Runs the packages' unit tests: OhMyShotKit's, then OhMyShotVLM's (they need no GPU; the first run compiles MLX, its
# Metal kernels too, which takes Xcode's Metal Toolchain: xcodebuild -downloadComponent MetalToolchain). They need a Mac,
# not a virtual one: on GitHub's macOS runners (2026-11-05) Vision's text recognition, Live Text, and a studio export's
# colors failed, and the recording tests hung (Docs/release.md, Releasing from CI).
# Usage: Scripts/test.sh [swift test arguments], given to both.
set -eu
cd "$(dirname "$0")/.."

# The repository can live in a file-provider folder (iCloud Desktop & Documents), which tags existing
# bundles with Finder info that codesign then rejects; clear it from earlier builds first.
for PRODUCTS in Packages/OhMyShotKit/.build/out/Products Packages/OhMyShotVLM/.build/out/Products; do
  if [ -d "$PRODUCTS" ]; then
    find "$PRODUCTS" -maxdepth 2 \( -name '*.xctest' -o -name '*.bundle' \) -exec xattr -cr {} +
  fi
done

swift test --package-path Packages/OhMyShotKit "$@"
swift test --package-path Packages/OhMyShotVLM "$@"
