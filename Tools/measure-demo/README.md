# Measure snapping demo

This tool renders a deterministic synthetic fixture with the real `MeasureOverlay`, `PixelGrid`, and pixel-edge engine from the linked Debug package products. It produces an explanatory GIF, not a screen recording. The cursor and captions are annotations; selection paths, measurements, tolerance changes, and snapping behavior come from the production overlay methods. The fixture contains only generated pixels.

Build the intended source revision first, using the project's Debug build or package tests, then run from the repository:

```sh
Tools/measure-demo/render.sh
```

The default products directory is `Packages/OhMyShotKit/.build/out/Products/Debug`, and output goes to `build/measure-demo`. Both paths can be supplied explicitly:

```sh
Tools/measure-demo/render.sh /path/to/Debug /path/to/output
```

`DEVELOPER_DIR` can select the Xcode installation. The script uses `xcrun`, the host architecture, and this project's macOS 26 deployment target. It compiles only the renderer and links the existing `OMSCapture.o`, `OMSCore.o`, and `OMSPixels.o` objects. The Debug `OMSCapture.swiftmodule` must support testable imports and match those objects.

The 760 × 480 animation shows a loose drag around a low-contrast card, Medium tolerance snapping to the supported edges, High tolerance retaining the drawn area, and snapping disabled/enabled for subsequent drags. The card is 300 × 160 points; the loose selection is 360 × 220 points. Re-enabling snapping intentionally takes effect on the next drag.

The renderer checks exact geometry and measurements, then decodes every GIF frame to verify frame count, dimensions, and delays. Outputs include:

- `measurement-snapping.gif`
- `frame-00.png` and subsequent exact render frames
- `measurement-snapping-validation.json`
- `build-input-sha256.txt`, containing hashes of the linked package objects

Review the frames and animation before updating `Docs/assets/measurement-snapping.gif`. Rebuild and rerender after changing the measurement implementation. Native input handling and the Settings toggle require their own application checks.
