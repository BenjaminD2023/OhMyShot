# Performance log

Every milestone ends with a power gate. Numbers here are measured, never estimated. Reproduce them with
`Scripts/power-sample.sh` (CPU, idle wakeups, footprint) and `Scripts/latency.sh` (latency probes).

Targets: idle CPU 0.0% (60 s average), fewer than 1 idle wakeup per second, footprint under 30 MB after
launch and under 60 MB after use.

## M0 — foundations (2026-10-07)

Debug build (`-Onone`), MacBook Pro M3 Max, macOS 27.2 beta, two displays (3440×1440 at 2× HiDPI as
primary, built-in XDR in a scaled mode). The app sat in the menu bar with no window open.

| Measurement | Result | Target |
| --- | --- | --- |
| Idle CPU, 60 s | 0.00% average, 0.0% peak | 0.0% |
| Idle wakeups, 60 s | 0 | < 60 |
| Footprint after launch | 14 MB | < 30 MB |
| CPU time to launch | 0.13 s | — |
| Footprint after opening and closing Settings and onboarding | 35 MB, 0 leaks, no live resources | < 60 MB |
| App size | 2.2 MB Debug, 1.3 MB Release | < 30 MB |

### Findings

- **Never touch `AVCaptureDevice` at launch.** Reading the microphone or camera permission status
  initializes AVFoundation's capture stack, which loads every camera plug-in on the Mac. On this machine
  that cost 2.8 s of CPU and about 30 MB of memory before any window appeared (launch CPU 2.93 s and
  footprint 44–49 MB, versus 0.13 s and 14 MB without it). `PermissionCenter` now reads statuses only on
  request; launch reads Screen Recording alone.
- **SwiftUI windows leave about 20 MB of framework caches behind.** After the first settings window closes,
  the controllers are released (verified with `heap`) and `leaks` reports nothing, but SwiftUI, AppKit,
  and font caches stay resident. Returning freed pages with `malloc_zone_pressure_relief` changes little.
  This is within the after-use budget; surfaces that are always on (status item, overlay) stay AppKit.
- **Signposts are not persisted** unless a tool records them, so latency is logged by `LatencyProbe` as
  persisted `latency <name> <ms> ms` notices, which `Scripts/latency.sh` reads.

## M1 — capture core, Quick Access, Capture History (2026-10-07)

Same machine and build type as M0. Latencies come from `LatencyProbe` notices; the overlay numbers are
50 scripted runs (`ohmyshot-dev://debug/bench-overlay?n=50`, then `Scripts/latency.sh overlay.visible 2m
io.github.fzlzjerry.ohmyshot.dev`).

| Measurement | Result | Target |
| --- | --- | --- |
| Hotkey → overlay visible (`overlay.visible`) | p50 6.9 ms, p95 9.8 ms, max 13.2 ms | p95 < 50 ms |
| Hotkey → frozen frame under the pointer (`overlay.frozen`) | p50 43.3 ms, p95 47.7 ms, max 61.9 ms | p95 < 150 ms |
| Full-display capture, 6880×2880 | p50 26.8 ms, p95 41.8 ms | — |
| Full-display capture, XDR 4112×2658 | p50 24.2 ms, p95 26.3 ms | — |
| Region capture, 400×300 pt → 800×600 px (`capture.region`) | 31–43 ms | — |
| Encode PNG, write to history, make the card thumbnail (`capture.deliver`) | 23–25 ms | — |
| Idle after captures, Quick Access cards, and Capture History opened and closed | 0.00% CPU, 0 wakeups in 60 s, 40 MB | 0.0%, < 60, < 60 MB |
| Live resources while a card and the history window are open / after closing them | `window=2` / none | none when idle |

### Findings

- **Commit the overlay's reset before ordering its panels in.** The panels are reused between sessions;
  ordering them in before the reset layers were committed could show a frame of the previous selection.
  With that flush and the native redesign together, `overlay.visible` went from p50 4.6 / p95 7.4 ms to
  p50 6.9 / p95 9.8 ms. The two changes were not measured apart; the flush is the likelier cost, since it
  commits every display's layers before the first panel appears.
- **ScreenCaptureKit leaks about 290 bytes per screenshot** (176 + 112 bytes allocated by
  `CGRectCreateDictionaryRepresentation` inside `SCScreenshotManager`). The allocations are in the
  framework, not in OhMyShot; at dozens of captures a day this is negligible, and it is tracked here in
  case a later macOS fixes or worsens it.
- **Quick Access motion leaves nothing running.** Card fades and stack reflows use Core Animation plus one
  one-shot sleep per change to finish the motion; no timer repeats, and idle wakeups stay at zero.

## M2 — Capture Text (2026-10-08)

Same machine, one display (the built-in XDR) attached. A 400×300 pt region of text recognized by the L1
pipeline inside the app, read with `Scripts/latency.sh ocr.recognize` and `Scripts/power-sample.sh`.

| Measurement | Result | Target |
| --- | --- | --- |
| Recognition (`ocr.recognize`), warm | 290–365 ms | < 300 ms for a region of about 1000×600 px |
| First recognition after a relaunch | 315 ms | — |
| First recognition the app ever made | over 10 s (the system prepares the model once) | — |
| Memory during recognition / one second after | 223 MB / 61–70 MB | < 60 MB after use |
| Idle after Capture Text, its highlight faded | 0.00% CPU, 0 wakeups in 30 s, no live resources | 0.0%, < 30 |

### Findings

- **Recognition leaves the footprint at 61–70 MB**, against 40–43 MB after screenshots alone (M1), just
  over the 60 MB target: Vision keeps its models loaded and has no public way to unload them.
- **The first recognition after launch was followed by a burst of CPU** (2.7 s over the next 30 s,
  footprint 126 MB) that settled to 0% and 70 MB; later recognitions add none. It looks like one-time
  model preparation and is worth measuring again with Instruments.

## M2 — OCR panel (2026-10-08)

Same machine and display. The panel opened on its drawn demo page (`ohmyshot-dev://debug/panel-demo`;
1520×1120 px with a table and a QR code), read with `Scripts/latency.sh ocr.analyze`, `footprint`, and
`Scripts/power-sample.sh`.

| Measurement | Result | Target |
| --- | --- | --- |
| Full analysis (`ocr.analyze`: L1, barcodes, document request), warm | 618–675 ms | — |
| The same for a 800×600 px screen region (Option at the end of a Capture Text drag) | 500 ms | — |
| Footprint with the panel open / 27 s after closing it | 145–163 MB / 109–126 MB | < 60 MB after use |
| Live heap 27 s after closing (`heap`) | 28 MB | — |
| Idle after closing the panel | 0.00% CPU, 0 wakeups in 30 s, no live resources | 0.0%, < 30 |

### Findings

- **Most of what stays after the panel closes is freed memory the allocator keeps.** The live heap is
  28 MB; the footprint is about 110–125 MB, almost all dirty "Malloc Small" pages. Recognition peaks at
  about 410 MB and leaves its small allocations scattered, and `malloc_zone_pressure_relief` returns
  next to nothing (139 → 119 MB over 25 s, mostly Vision freeing late). The table request accounts for
  only about 15 MB of it. Running recognition in a helper process that exits when idle, as planned for
  the model packs (M6), would return all of it; until then the panel misses the after-use target.

## M2 — English lines on Chinese pages (2026-10-08)

L1 now reads the whole page with the Latin model alongside the first pass (Docs/ocr.md, L1 steps 1, 2,
and 5). Benchmark per image, L1 alone, before → after: English pages 85–126 ms faster (`en-ui` 311 →
185 ms, `code-yaml` 312 → 200 ms), Chinese and mixed pages 0–32 ms slower, p50 178 → 183–189 ms and p95
388 → 379–399 ms across runs.

| Measurement | Result | Target |
| --- | --- | --- |
| Capture Text recognition (`ocr.recognize`), five runs on a fresh launch | 177–309 ms | < 300 ms for about 1000×600 px |
| Footprint after those five, settling | 91 MB right after, 73 MB after 40 s, 64 MB after 100 s (live heap 16 MB) | < 60 MB after use |
| Idle once settled | 0.01% CPU, 0 wakeups in 30 s, no live resources | 0.0%, < 30 |

### Findings

- **Both models resident cost little once settled**: 64 MB, against 61–70 MB with the Chinese model
  alone (M2 Capture Text). Right after a launch's first recognitions both models prepare once more
  (1.6% CPU over the next 30 s, peaking at 19%), then settle.
- **A deliberate energy trade**: every recognition now runs the Latin model too, including on pages of
  Chinese alone that never use its reading: about half again as much neural-engine work per recognition
  (the Latin pass alone takes about 95 ms), for 0–32 ms of latency, correct English on mixed pages, and
  English pages that no longer wait for a second pass. Recognition only ever runs when asked for.
- **The strip fallback works end to end**: with every line forced through it, `zh-en-lines` and the
  panel's demo page still read without an error. On the corpus the page reading matched every line, so
  the strip is not used there.

## M2 — Translation (2026-10-08)

Same machine and display. The OCR panel translating its drawn demo page (`ohmyshot-dev://debug/panel-demo`, then `panel-state?translate=1`), Translate Area on the same page (`translate-demo`), read with `Scripts/latency.sh`, `footprint`, and `top`.

| Measurement | Result | Target |
| --- | --- | --- |
| Panel translation (`ocr.translate`: units, the system's model, drawing), first after launch / again | 455–528 ms / 240–330 ms | — |
| Translate Area from the image to the lens (`ocr.translate-area`: recognition, translation, drawing) | 659–684 ms | — |
| Footprint 30 s after closing a translated panel, sessions released / kept | 136–141 MB / 139 MB (131 MB without translating) | < 60 MB after use |
| Idle after closing the lens and the panel | 0.0% CPU, 0 wakeups in 30 s, no live resources | 0.0%, < 30 |

### Findings

- **Translation adds little that stays.** The models load in the system's translation service, not in OhMyShot: releasing the sessions when the panel closes changes the footprint by no more than the noise between runs, and the next panel's first translation is no slower. They are released anyway. What stays after the panel closes is the recognition's freed memory (M2 — OCR panel).
- **Batching labels is faster as well as better**: on the real screenshots translating took 0.1–0.7 s once code, figures, and names were left out and short labels went in batches, against 1.2–2.4 s before.

## M2 — OCR p95 (2026-10-08)

Same machine. `swift run -c release --package-path Tools/ocr-bench ocr-bench --engine l1 [--real …]`,
with `--trace` for the steps (Docs/ocr.md › Speed).

Two runs each, before and after, back to back:

| Measurement | Before | After | Target |
| --- | --- | --- | --- |
| Synthetic cases (27), p50 / p95 | 198–203 / 415–428 ms | 187–188 / 366–373 ms | < 300 ms for about 1000×600 px |
| Real regions (12), p50 / p95 | 269–289 / 854–865 ms | 268–281 / 697–716 ms | — |
| Content CER, synthetic / real | 0.78% / 5.22% | 0.78% / 5.22% | no regression |

### Findings

- **The p95 that is left is the primary pass on dense text** (a terminal region: 690 ms of its 696) and
  the steps that must follow it: code with CJK comments read again (about 130 ms), and Korean gaps
  when Korean is a preferred language. The primary pass cannot be skipped safely (Docs/ocr.md › Speed).
- **Requests side by side cost no more energy**: the same requests run, only together; the English gap
  fallback now runs none.
- **The target is met at p50, not at p95**: the synthetic p95 is the three cases above, each a primary
  pass followed by one request that cannot start sooner.

## M2 — L2 runtime spike (2026-10-09)

PP-OCRv6 small, measured with `Tools/l2-spike/` (details in Docs/ocr.md › L2 runtime).

| Measurement | ONNX Runtime (CPU) | Core ML (enumerated sizes, CPU and Neural Engine) |
| --- | --- | --- |
| Runtime added to the app | 33.2 MB | 0 |
| Models | 31.1 MB (fp32) | 15.8 MB (fp16) |
| 34 cases through the harness, p50 / p95 | 129 / 346 ms | 91 / 238 ms |
| CPU time for those 34 cases | 47.6 s | 3.3 s |
| All 39 (the five largest included), p95 / CPU time | 727 ms / 66.4 s | 499 ms / 7.6 s (any size, CPU) |
| Detection, 736×1280, native | — | 10 ms |
| Recognition, one line 320 / 1280 px wide, native | — | 2 / 8 ms |
| First load / later loads | 50 ms / 50 ms | 21 s once (Neural Engine compile) / 40 ms |

## M3 — annotation editor (2026-10-09)

Same machine, Debug build, one display. The editor opened on the drawn demo page (1520×1120 px) with
13 marks (`ohmyshot-dev://debug/editor-demo`), then closed.

| Measurement | Result | Target |
| --- | --- | --- |
| Footprint before opening / with the editor open / 30 s after closing | 62 / 88 / 63 MB | back to where it was |
| Live resources after closing | none | none when idle |
| Keeping the marks on close (render, encode, write to the history) | after the window has gone, off the main actor | never per edit |

### Findings

- **Marks are layers; the capture is one layer the GPU scales.** Each mark redraws only when it changes
  or the zoom does, through the same renderer exports use, so the screen and the export agree.
- **Edits are written when the capture leaves the editor** (closed, copied, saved, dragged out), never
  per change: a 6880×2880 PNG takes about 100 ms to encode.
