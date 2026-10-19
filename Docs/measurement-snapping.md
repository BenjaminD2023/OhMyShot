# Measurement snapping

Measure finds pixel boundaries on the frozen screen. Drag a box around content to fit its bounds;
click to clear the box. Normal screenshot capture is unchanged.

![Measurement snapping demonstration](assets/measurement-snapping.gif)

## Controls

Settings → Tools provides **Measurement snapping** and **Edge tolerance**. Snapping starts enabled;
turning it off keeps boxes exactly as drawn while pointer measurements remain available. Hold Command
when releasing a drag to skip snapping once.

The tolerance presets are Zero, Low, Medium (default), and High. Lower tolerance finds finer edges;
higher tolerance ignores small color changes. **T** cycles presets and **+/−** adjusts them while
measuring. The setting persists and applies across displays. **Tab** switches pixels and points.

## Detection and responsiveness

Strong RGB transitions keep precise pixel endpoints. Faint edges need local contrast above the
surrounding gradient and spatial support. Area detection joins supported boundary contours, preserves
thin details, and rejects isolated distant specks only when a strong closed outline provides context.
It abstains on smooth patches with no clear border, preserving the user's drawn box.

Pointer measurements scan rows and columns without allocating a full-screen edge map. Selections
above 250,000 physical pixels find their edges in the background and show “Finding edges…”. New
selections, tolerance changes, replacement frames, and closing the overlay cancel stale work.

Pixel evidence cannot always distinguish a faint border from its shadow. Some ambiguous border/shadow
fixtures differ by one physical pixel. Results on photographs and busy backgrounds depend on the
selected content and tolerance; this feature does not infer semantic objects.

## Validation

Synthetic tests cover 1×/2× geometry, RGB thresholds, antialiasing, low-contrast cards, gradients,
thin lines, narrow opposite-polarity edges, noise, persistence, reused overlay sessions, and background
result invalidation. The GIF is a deterministic render of the real measurement overlay on generated content, not a screen recording. Each selection and tolerance result is checked before its frame is written. See [the reproducible renderer](../Tools/measure-demo/README.md).

Run the focused package checks from the repository root:

```sh
Scripts/test.sh --filter 'PixelGridTests|PixelGridQualityTests|MeasureOverlayTests|OverlayKeyTests|MeasureToleranceSettingTests'
```

The tests validate explicit local geometry and behavior. They are not a broad accuracy benchmark or a
runtime comparison against another application.
