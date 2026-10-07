#!/bin/sh
# Runs the package's unit tests. Usage: Scripts/test.sh [swift test arguments]
set -eu
cd "$(dirname "$0")/.."

# The repository can live in a file-provider folder (iCloud Desktop & Documents), which tags existing
# bundles with Finder info that codesign then rejects; clear it from earlier builds first.
PRODUCTS=Packages/OhMyShotKit/.build/out/Products
if [ -d "$PRODUCTS" ]; then
  find "$PRODUCTS" -maxdepth 2 \( -name '*.xctest' -o -name '*.bundle' \) -exec xattr -cr {} +
fi

swift test --package-path Packages/OhMyShotKit "$@"
