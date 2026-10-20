#!/bin/sh
# Runs the packages' unit tests: OhMyShotKit's, then OhMyShotVLM's (they need no GPU; the first run compiles MLX).
# Usage: Scripts/test.sh [swift test arguments], given to both.
# Vision fixtures and timing checks share process/system resources; run serially by default.
# Pass --parallel explicitly to opt into concurrent execution.
set -eu
cd "$(dirname "$0")/.."

# The repository can live in a file-provider folder (iCloud Desktop & Documents), which tags existing
# bundles with Finder info that codesign then rejects; clear it from earlier builds first.
for PRODUCTS in Packages/OhMyShotKit/.build/out/Products Packages/OhMyShotVLM/.build/out/Products; do
  if [ -d "$PRODUCTS" ]; then
    find "$PRODUCTS" -maxdepth 2 \( -name '*.xctest' -o -name '*.bundle' \) -exec xattr -cr {} +
  fi
done

swift test --no-parallel --package-path Packages/OhMyShotKit "$@"
swift test --no-parallel --package-path Packages/OhMyShotVLM "$@"
