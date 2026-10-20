#!/bin/zsh
# Render the real measurement overlay over public synthetic pixels. No app window is shown.
set -eu
if (( $# > 2 )); then
    print -u2 'Usage: Tools/measure-demo/render.sh [DEBUG_PRODUCTS_DIRECTORY] [OUTPUT_DIRECTORY]'
    exit 2
fi
DEMO_TOOL_DIR=$(cd -- "$(dirname -- "$0")" && pwd)
DEMO_REPO_ROOT=$(cd -- "$DEMO_TOOL_DIR/../.." && pwd)
DEMO_PRODUCTS=${1:-"$DEMO_REPO_ROOT/Packages/OhMyShotKit/.build/out/Products/Debug"}
DEMO_OUTPUT=${2:-"$DEMO_REPO_ROOT/build/measure-demo"}
DEMO_ARCH=$(uname -m)
for DEMO_PRODUCT in OMSCapture.o OMSCore.o OMSPixels.o OMSCapture.swiftmodule; do
    if [[ ! -e "$DEMO_PRODUCTS/$DEMO_PRODUCT" ]]; then
        print -u2 "Missing $DEMO_PRODUCT in $DEMO_PRODUCTS. Build the Debug package products first."
        exit 2
    fi
done
mkdir -p "$DEMO_OUTPUT"
xcrun swiftc -parse-as-library -target "$DEMO_ARCH-apple-macos26.0" -I "$DEMO_PRODUCTS" \
    "$DEMO_TOOL_DIR/render.swift" "$DEMO_PRODUCTS/OMSCapture.o" "$DEMO_PRODUCTS/OMSCore.o" "$DEMO_PRODUCTS/OMSPixels.o" \
    -o "$DEMO_OUTPUT/render-measure-demo" \
    -framework AppKit -framework CoreGraphics -framework Foundation -framework QuartzCore \
    -framework ImageIO -framework UniformTypeIdentifiers -framework ScreenCaptureKit \
    -framework AVFoundation -framework CoreMedia -framework CoreVideo -framework Vision \
    -framework Metal -framework MetalKit -framework IOKit -framework ApplicationServices \
    -framework Security -framework ServiceManagement -framework Carbon
PACKAGE_RESOURCE_BUNDLE_PATH="$DEMO_PRODUCTS" "$DEMO_OUTPUT/render-measure-demo" "$DEMO_OUTPUT" > "$DEMO_OUTPUT/render.log"
(
    cd -- "$DEMO_PRODUCTS"
    /usr/bin/shasum -a 256 OMSCapture.o OMSCore.o OMSPixels.o
) > "$DEMO_OUTPUT/build-input-sha256.txt"
print "Rendered $DEMO_OUTPUT/measurement-snapping.gif"
