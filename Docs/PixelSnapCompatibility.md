# PixelSnap snapping compatibility

Investigation date: 2026-10-19. The recovered PixelSnap rules below establish a reference baseline.
OhMyShot now uses the adaptive detector described under Current implementation to improve weak-edge
and noise handling. The evidence is static arm64 analysis and synthetic fixtures; PixelSnap measurements were not
run or compared. The reference launch reached its first-run agreement and activation screen, which
were not completed by this investigation. No licensed measurement runtime is available.

## Reference and reproducibility

The reference is **PixelSnap 2.6.4**, internal build `0b739e0`, a universal arm64/x86_64 application.
Only its arm64 measurement paths were traced. Addresses below are unslid virtual addresses for this
specific executable; descriptive function names are analysis labels unless retained in metadata.

| Artifact | Source or verification |
| --- | --- |
| Publisher download | <https://updates.getpixelsnap.com/v2/PixelSnap-2-2.6.4.dmg> |
| Download discovery | [Homebrew cask](https://github.com/Homebrew/homebrew-cask/blob/HEAD/Casks/p/pixelsnap.rb) |
| Installed reference | `/Applications/PixelSnap 2.app` |
| Publisher signature | Make The Web Oślizło & Magiera s.c.; team `AFJU4P8ZV4` |
| Signature check | `codesign --verify --deep --strict` passed; acquisition recorded a stapled ticket |
| DMG SHA-256, acquisition record | `0a3b1f964891900a2f7f7e6bd319651a1ed379275e7532bc32109a649fb6312d` |
| Executable SHA-256, rechecked | `61c21675c5f0221a075fb122884876a980a68c036b69c83b939567e54f79755c` |

Local evidence is intentionally outside version control in `build/review/pixelsnap/`: `analysis.json`,
`evidence/disassembly-arm64.txt`, comparator/default/scanline slices, and runtime metadata. Detailed
area notes and isolated assembly are in `deep/area-snap-research.json` and `deep/*.asm`. Tutorial frames
and bundled labels establish depicted interactions, not current runtime behavior. No proprietary
binary, disassembly, or bundled resource is added to the repository by this implementation.

## Comparator and tolerance

At `0x10003bcdc`, the comparator requires component 0 of each sample array to be nonnegative. It then
accepts the pair only when **each** absolute difference for components 1, 2, and 3 is at most the current
integer threshold. Equality is accepted; there is no sum, Euclidean distance, or perceptual metric.
The `getPixel:atX:y:` thunk is `0x10016d5c0`. The exact array channel order and bitmap alpha treatment
have not been established, so this is not evidence that PixelSnap always ignores alpha.

An isolated AppKit probe on synthetic images confirms `NSBitmapImageRep(cgImage:)` preserves the
input's sample order: alpha-first input yields `[A,R,G,B]`, while alpha-last input yields `[R,G,B,A]`.
PixelSnap stores the compositor image directly (`0x10003621c..0x100036224`) and does not normalize it
before wrapping it. Components 1–3 are therefore RGB for alpha-first captures. The compositor's
actual format remains the unresolved part; probe sources/results are in `deep/channel-order-research.json`
and `deep/probe-bitmap-layout.*`.

| Preset | Zero | Low | Medium | High |
| --- | --- | --- | --- | --- |
| Factory threshold | 0 | 7 | 13 | 26 |

The fallback presets are constructed at `0x10004eb18`; saved `toleranceModes` JSON can override them.
The selected-ID getter falls back to 2, corresponding to Medium (`0x10004e010`, fallback near
`0x10004e0e4`). Although the field is named `percent`, these are raw sample differences.

OhMyShot's `MeasureTolerance` uses those four thresholds, defaults to Medium, and persists the choice.
`PixelGrid.matches` explicitly compares RGB bytes in its own `AARRGGBB` buffer and ignores alpha.
This is a documented screenshot policy, not a verified reconstruction of PixelSnap's sample layout.
RGB capture color spaces are retained where possible; fallback conversion uses sRGB.

## Current implementation

`OMSPixels.MeasurementEdges` runs optimized pixel work independently of the overlay. Strong RGB
transitions keep their exact pixel boundary. Faint transitions require local prominence over the
surrounding gradient; pointer measurements also require support from at least three distinct nearby
scanlines. A signed, capped contrast probe recovers localized antialiased edges while cancelling
linear background slopes. Its sampling radius follows display scale. Zero tolerance remains exact.

Area selection builds connected edge contours inside the drawn rectangle. Endpoints live on pixel
boundaries, avoiding a one-pixel halo. Long closed weak contours can identify low-contrast cards and
thin separators. Disconnected substantive objects are combined. Isolated one-point specks far from a
substantial closed strong outline can be rejected; nearby punctuation and connected details remain.
Tiny weak contours and smooth, ambiguous patches abstain, preserving the manually drawn rectangle.
The reference scanner's original-bottom-row quirk is deliberately omitted.

A plain click inside the completed selection captures its frozen pixels through the normal screenshot
pipeline. A small pointer movement is tolerated; dragging starts a new selection. Outside releases,
modifier clicks, and stale sessions do not capture. The selected reading says “Click to capture”.
The capture excludes overlay chrome and follows the existing clipboard, History, save, and Quick
Access settings. Drawn-screen debug sessions disable capture delivery.

Selections above 250,000 physical pixels are detected on a background task while the box reads
“Finding edges…”. A quick click waits for the final bounds. New selections, tolerance changes,
replacement frames, and cancellation invalidate both old results and queued capture intent. The
pixel engine checks cancellation during graph construction and traversal. Pointer measurements
scan short strips and never allocate a full-frame graph.

The initial nine controlled quality fixtures matched their intended geometry in 5 cases with the
baseline scanner and all 9 with the adaptive detector, including correct abstentions. These are
targeted synthetic regressions, not a general accuracy estimate. Independent adversarial fixtures
preserve disconnected objects, thin details, nearby diacritics, and axis symmetry. Three gray
border/shadow cases still choose an inner edge one raster pixel away when the outer edge blends into
the shadow. Raw fixture results and timing probes are in `build/review/pixelsnap/optimization/`.

The weak-edge and connectivity approach is informed by [OpenCV's Canny explanation](https://docs.opencv.org/4.13.0/da/d22/tutorial_py_canny.html).
It uses explicit RGB contrast and contour rules rather than applying a generic Canny filter or
blanket morphology, which could erase thin screenshot content.

## Distance measurement

`DistanceTool` scans in four directions from the pointer at `0x100036d80`. Every comparison is between
**neighboring pixels**, rather than between a candidate and the pointer's starting color. The left
path reads `(n-1,0)` and `(n,0)` at `0x100036f88`/`0x100036fa0`, then compares at `0x100036fc4`.
The other paths use the same rule. Scanning stops at the first failing pair or image boundary.
The returned span contains both interior endpoints; its width is `high - low + 1`
(`0x100037bb4..0x100037c00`). A single-pixel object therefore measures one pixel.

The cached-image path produces a one-physical-pixel row and column through the pointer at
`0x1000384b4` (crop calls `0x1000385f4` and `0x100038658`). A separate compositor-capture fallback
uses strips with thickness 4.0. OhMyShot scans its cached full-frame pixel buffer instead.

These loops imply that gradual gradients and shadows can be traversed when every local change is
within tolerance, even when their endpoints differ greatly. A sharp border remains a boundary.
That conclusion follows from the instructions; it is not an observed PixelSnap fixture result.

## Area selection

The area engine at `0x100007504` is called by `Area` recomputation (`0x10002af8c`) and finalization
(`0x10002c188`). It crops the selected image through `0x100067a38`, scales the rectangle to physical
pixels, and adds the following trim deltas. Here `W,H` describe the original crop, `B,T,L,R` are counts
removed, and raster rows run from top to bottom.

| Pass | Helper | Sampling and resulting rectangle delta |
| --- | --- | --- |
| Raster bottom | `0x10000ae10` | Start at `H-1`; return `(0,B,0,-B)` in AppKit coordinates |
| Raster top | `0x10000b174` | Start at 0; return `(0,0,0,-T)` |
| Raster left | `0x10000b4a4` | Start at 0; return `(L,0,-L,0)` |
| Raster right | `0x10000b83c` | Start at `pixelsWide-1`; return `(0,0,-R,0)` |

Each vertical pass verifies every horizontal neighboring pair in its current row. If all match, it
moves inward and compares the first-column pixels across that row transition. It stops at either
kind of mismatch, retaining the first discontinuous row. Both passes inspect the original crop and
original `H`; the top pass does not receive `H-B`. An entirely similar crop with ordinary dimensions
returns `B=H`; the engine rejects its zero height and returns nil before the later passes.

The two lateral passes then compare vertical neighbors in each column and adjacent columns at the
first retained row. They run independently and their deltas are combined. A notable compatibility
detail is preserved: their row range is `T..<H`, **including bottom-trimmed rows**, rather than the
conventional retained interval `T..<(H-B)`. The register math at `0x10000b4fc..0x10000b590` and
`0x10000b8bc..0x10000b950` establishes this. It can widen the result on asymmetric gradients.

There is no seed-background choice, majority-corner heuristic, flood fill, or semantic object model
in this path. OhMyShot's initial `contentBounds` followed these ordinary-dimension rules; the current
implementation uses connected contours instead. A nil result keeps the originally drawn box.
Selections are clipped safely to the image, and tiny dimensions use safe
bounds checks rather than reproducing the reference's unverified out-of-range sample attempts.

PixelSnap's `0x10002af18` normalizes and reuses `Area.originRectangle` when recomputing. OhMyShot
similarly retains `originalBox`, so lowering tolerance can recover an edge previously trimmed away.
Finalization at `0x10002c058` bypasses snapping for Command, Shift, or Option, and for a boolean whose
mouse-up path includes Control. OhMyShot preserves the drawn selection when any of those modifiers
is held on release. PixelSnap's additional click-count branch has not been reproduced.

## Coordinates and scale

PixelSnap multiplies point coordinates by `factor` and truncates to integer raster coordinates
(`0x100036dc8..0x100036e60`), then divides returned endpoints by that factor
(`0x100037c6c..0x100037cb8`). `Session.factor` is at offset `+0x38`; `DistanceTool.factor` is `+0x48`.
The area crop converts AppKit Y using `(screenHeight-y-height)*factor`, then divides all final
rectangle components by the factor. Metadata retains screen-pixel, point, and rounded-point modes.

OhMyShot uses `CapturedFrame.pixelsPerPoint`, top-left raster storage, inclusive span counts, and
exclusive upper boundaries when drawing lines. For example, pixels `30...69` at 2× cover points
`15..<35`: 40 px or 20 pt. Fractional selection rectangles expand to integral pixel bounds.
Reference crop integralization, clipping, mixed-display transitions, and formatter rounding remain
unverified; OhMyShot's clipping and point formatting are explicit local policies.

## Guides and document zoom: research only

Guide helpers `0x100026fd0`, `0x100027110`, `0x100027258`, and `0x100027388` reuse the trim routines
on one-sided 20-point-deep probes. The first probe spans 40 perpendicular points; a zero result
triggers a 20-point-span retry. Accepted offsets lie strictly inside the `20*factor-1` pixel limit.
Positive and negative return adjustments differ; the caller chooses the smaller absolute candidate.
This is distinct from area trimming and is not implemented as a guide tool in this change.

The Sketch path builds an `NSTask` invoking `sketchtool run`, `zoomLevel`, and
`--without-activating=YES` (`0x10003d110..0x10003d1f0`). The Figma path finds a window whose owner
contains Figma, captures it, crops a top-right region, and invokes Vision text recognition
(`0x10003e594`, `0x10003e830`, `0x10003e86c`, `0x10003e980`, `0x10003dffc`, `0x10003e0c4`).
Those call sites establish integration mechanisms, not their runtime accuracy. Document zoom
correction, held distances, multiple areas, guides, and measurement screenshot export are not added.

## Fixtures and coverage

Expected values below describe the recovered reference model, before adaptive optimization.
They are not output collected from PixelSnap. Distance examples use scalar grayscale values, with
threshold 13 unless stated otherwise; spans are inclusive.

| Fixture | Expected result |
| --- | --- |
| `[0,13,26,40,53]`, pointer 1 | Span `0...2`; difference 13 matches, 14 stops |
| Ramp `80,90,...,160`, pointer 4 | Span `0...8`, despite cumulative difference 80 |
| `[255,250,245,240,235,230,10,10,10]`, pointer 3 | Span `0...5` |
| White 9×7 field; level-245 line at x4, y2...4 | Medium: nil; Low: rectangle `(4,2,1,3)` |
| Uniform ordinary-size selected area | nil; overlay keeps the original selection |
| 8×8 field 100; black x4...5,y2...3; final row `100,110,...,170` | `(2,2,6,2)`, exposing the original-bottom lateral limit |

| Coverage | Status |
| --- | --- |
| Adjacent scans, inclusive thresholds/endpoints, four presets | Implemented; synthetic tests added |
| Area pass order and lateral bottom quirk | Recorded baseline; superseded by adaptive contours |
| Original-selection recomputation and modifier bypass | Implemented; local overlay behavior |
| Persistence, keyboard controls, per-frame scale conversion | Implemented; focused regression coverage |
| PixelSnap bitmap channel/alpha layout and formatter rounding | Unverified; explicit OhMyShot policies |
| Guide probes and Sketch/Figma zoom paths | Researched statically; not implemented |
| Live snapping equivalence, latency, shadows on real apps | Unverified; no PixelSnap measurement runtime |

Relevant implementation: `MeasurementEdges.swift`, `PixelGrid.swift`, `MeasureOverlay.swift`,
`MeasureTolerance.swift`, `OverlayView.swift`, and `MeasureCoordinator.swift`. Tests are in
`PixelGridTests`, `PixelGridQualityTests`, `OverlayKeyTests`, `MeasureOverlayTests`,
`MeasureCaptureTests`, and `MeasureToleranceSettingTests`.

Validation on macOS 27 with Xcode 27: the package Debug build and all **41 focused tests passed**
across those six suites, including 1×/2×/3× edge cases, frozen screenshot crops, tolerance
recomputation, manual-box bypass, initial-grid preparation, and asynchronous cancellation/replacement.
Synthetic light/dark CALayer renders also verified the pointer and area readings at 2×, the capture
hint, and a click producing the exact frozen 96×96-pixel crop. The final Release build passed and
was installed in `/Applications/OhMyShot.app`; the previous bundle is backed up under the local
`optimization/app-backups.noindex/` directory. Signature and installation checks are recorded in
`optimization/install-verification.json`.
Reproduce the focused checks with:

```sh
Scripts/test.sh --filter 'PixelGridTests|PixelGridQualityTests|OverlayKeyTests|MeasureOverlayTests|MeasureCaptureTests|MeasureToleranceSettingTests'
```

Before claiming runtime parity, compare identical rendered fixtures at 1×, 2×, and fractional capture
scales; exact-threshold and colored-channel edges; asymmetric shadows, antialiasing, and gradients;
partially clipped and tiny selections; original-selection tolerance changes; and modifier releases.
Then compare real Figma, browser, and native-app screens with known dimensions on mixed-scale
displays. Performance and perceptual equivalence require separate measurement with an authorized
reference runtime; passing OhMyShot fixtures alone does not establish either.
