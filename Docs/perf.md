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

### Background, combine, and project files (2026-10-09)

Same machine. Exports were timed in a Release build of the package (`swift test -c release`) on a
synthetic 6880×2880 capture with a background (inset, Auto Balance, deepest shadow); the editor in the
Debug app on a capture read back from the history (1520×1120 px).

| Measurement | Result | Target |
| --- | --- | --- |
| Reading the capture's edge (edge color, content bounds) on 6880×2880 | 65 ms | once per canvas |
| 6880×2880 export on a background (7940×3940 out): gradient / blurred capture | 0.44 / 0.28 s | off the main actor |
| Footprint with a background on / 30 s after closing (no background: 46 MB after) | 64–66 / 50 MB | back to where it was |
| Footprint growth over repeated open–edit–close rounds | none | none |

- **The card shadow is the card's shape blurred small and drawn back up.** Core Graphics' own shadow
  blurred the whole 7940×3940 picture; a mask a few hundred pixels across, box-blurred three times,
  looks the same at that blur width and took the export from 0.56 to 0.44 s.
- **The background layer draws at one pixel per point.** It is the size of the whole view, so at two
  pixels per point its backing store alone was about 12 MB; gradients, blurs, and shadows are soft, and
  exports still draw them at full size.
- **The edge is read in bands from each side inward**, never the whole capture at once, and stops at the
  first line that is not the edge color.
- **The drawn demo page is not a fair test of memory here.** It is made with Core Image, so the
  background's reads of its pixels (edge, blur) render it again on the CPU; the editor then closed at
  80–86 MB instead of about 50. Captures read from files do not do this.

### In-place annotation (2026-10-09)

Debug build, the capture overlay on drawn screens (the built-in display at 2056×1329 points, 2×, and
the ultrawide), a selection around the drawn page, one rectangle drawn, then cancelled.

| Measurement | Result | Target |
| --- | --- | --- |
| Footprint before / annotating / 15 s after (two rounds) | 97 / 202 / 118 MB, the same both rounds | back to where it was |
| Live resources after it ends | none | none when idle |

- **The canvas does not draw the capture again.** In place, the frozen screen under the canvas is the
  capture, so the canvas's own picture layer is hidden: a second copy of a whole display's pixels
  (44 MB on the built-in display, 79 MB on the ultrawide) is never uploaded.
- **The annotating figure is mostly the frozen screens**: both displays' frames are held while the
  overlay is up, as in freeze mode. The delivered selection is copied out of the frame, so the frame is
  released when the overlay ends even while the copy is on the clipboard.

### Frozen screen by default (2026-10-09)

Freeze the screen is now on by default, and it finally keeps what it shows: before, the frozen screen
was only shown, and the area was captured again after the overlay closed and the previous app took the
keyboard back, by which time a hover card or an open menu had gone.

- **The frames come first.** The overlay's frames are captured on the shortcut, before its panels are
  ordered in or the app activates, and the overlay appears once the pointer's display is in. With the
  screen frozen, `overlay.visible` therefore equals `overlay.frozen` (M1: p50 43.3 / p95 47.7 ms) rather
  than about 7–10 ms. The first real shortcut presses after the change (three, the ultrawide under the
  pointer) measured `overlay.frozen` 78–111 ms and `overlay.visible` 88–126 ms: about twice M1's frozen
  p50 and over the 50 ms target. The likeliest cause is that the frame is now requested while the app is
  still in the background, without the foreground app's scheduling boost; not yet investigated, and not
  measured over 50 runs (`bench-overlay?n=50&freeze=1` shows the overlay 50 times on the screen). The
  same presses logged `app active true, keyboard true`: the activation requested after the frame is
  granted. A live overlay is unchanged: it appears at once and the frames follow.
- **A frozen area is cut, not captured again.** The kept area is copied out of the display's frame
  already in memory: one ScreenCaptureKit screenshot fewer per capture (31–43 ms for a region in M1), and
  the display's frame is still released when the overlay ends. Windows are still captured on their own.

### Self-Timer (2026-10-09)

- **Nothing runs until it is started, and nothing after.** The countdown holds a timer lease and a
  window lease only while it counts down; it ticks on absolute `ContinuousClock` deadlines with 100 ms
  tolerance, so the seconds do not drift and the wakeups can coalesce. Its panels are released at zero
  or on cancel.
- **The capture at zero is a plain live capture** (one ScreenCaptureKit screenshot of the area, per
  display it crosses), delivered like any other.

### The frozen overlay shows at once again (2026-10-09, evening)

The frozen design above waited for the pointer's display before showing anything. Over the day's 23
real presses that put `overlay.frozen` at 54–106 ms (median about 73) and `overlay.visible` at 59–120 ms
(median about 84), over the 50 ms target. Where the time went:

- **The capture itself is about twice M1's.** A bare capture of the built-in display (4112×2658),
  timed with nothing shown (`capture-timing`, the app in the background), took 41–71 ms; M1 measured
  24.2 ms. Holding a user-initiated activity (no App Nap) made no difference (45–68 ms against 41–62
  ms), so App Nap is not the cause. Not resolved: M1's benchmark may have run with the app active, the
  built-in display has EDR headroom (HDR content on screen may force tone mapping), and the ultrawide
  was not connected to compare.
- **Waiting to show the overlay cost the rest**: the reveal and the work before the capture, about 20 ms
  on top of the capture, all of it in front of the first visible frame.

So a frozen session shows its panels again at once, but they let the pointer through and the app does
not take the keyboard: what is under the pointer keeps its hover state and its menus until the frame
is in, and only then does the overlay take input (activate, hide the cursor, show the crosshair). The
capture request is queued before the panels' first flush. `overlay.begin` (the synchronous part of
the shortcut) and `overlay.capture` (the pointer display's capture alone) now break `overlay.frozen`
down. The first real press after the change (built-in display under the pointer): `overlay.begin`
4.5 ms, `overlay.visible` 18.9 ms, `overlay.capture` 55.5 ms, `overlay.frozen` 74.3 ms, activation
granted; one press, not a distribution. The user tried it and reported no problems. Not separately
confirmed: that a window letting the pointer through, ordered in above an app, closes none of its
hover cards or menus.

### Pins (2026-10-09)

Debug build, the drawn demo page (1520×1120 px) pinned at 1:1 on the built-in display.

| Measurement | Result | Target |
| --- | --- | --- |
| Footprint before / with two pins / 5 s after closing them | 74 / 100 / 74 MB | back to where it was |
| Live resources after closing | none | none when idle |

- **A pin costs about its picture twice over** (13 MB for a 6 MB picture: the bitmap and the window's
  backing). A pin of a whole 6K display would hold about 80–160 MB while it is open; pins are the first
  windows that stay open with a full-resolution picture, so they are the first thing to look at if the
  footprint stays high. They hold nothing else: no timers, no observers beyond the accessibility display
  options, and their window lease goes with the last pin.
- **Captures take pins in through the filter**, as `exceptingWindows`; a pin opened since the last fetch
  of the capturable content triggers one refetch in the next capture, and the content is fetched again
  in the background as soon as a pin opens, so that capture rarely pays for it.


## M4 — recording spike (2026-10-10)

Same machine, one display attached (the built-in XDR, 4112×2658 framebuffer); the ultrawide was not
connected, so the stream from a real 6880×2880 display is still to be measured. Two halves:

- **The encoders alone**, with no screen involved: `Tools/recording-spike/encode-bench.swift` feeds
  synthetic 4:2:0 frames (glyph blocks, or real text drawn with Core Text at 2×, scrolling 8 px a frame)
  through AVAssetWriter with the settings the recorder uses (hardware only, real time, constant quality
  0.6, no B-frames, a key frame every 2 s). CPU is this process plus VideoToolbox's encoder service.
- **The stream in the app**, Debug build: `ohmyshot-dev://debug/record-demo` records a window the app
  draws behind the desktop picture (a page of text scrolling 240 pt/s, animated by Core Animation)
  through the real `ScreenRecorder`, so nothing of the user's is read. CPU is per process over the run.

| Measurement | Result | Target |
| --- | --- | --- |
| Largest frame the H.264 hardware encoder takes | 4096 on either side (4096×4096 encodes; 4098 or 4112 wide fails) | — |
| Largest frame the HEVC hardware encoder takes | 8192×4320 and beyond | — |
| Encoding as fast as accepted, H.264 1920×1080 / 4096×2304 | 191 / 94 fps | — |
| Encoding as fast as accepted, HEVC 4112×2658 / 6880×2880 | 139 / 79 fps | 60 |
| Encoding paced at 60 fps, CPU, 1920×1080 H.264 / 6880×2880 HEVC | 5.8–8.7% / 8.1–9.2% of a core, no frame dropped | — |
| Bitrate at quality 0.6, text scrolling 8 px a frame at 60 fps, 1080p H.264 / 4112×2658 HEVC / 6K HEVC | 2.2 / 6.5 / 12.5 Mb/s | — |
| Recording a still window, 60 fps (frames sent / idle notices) | 1 / 292 in 5 s; app 2.1%, encoder 0.3%, replayd 1.6% | — |
| Recording 1920×1080 scrolling, 60 fps: frames written / dropped | 291 / 0 | — |
| CPU for that: app, encoder service, replayd | 8.4%, 4.4%, 2.9% (15.7% together; the window server could not be read) | < 15% |
| The same at 30 fps | 4.5%, 2.2%, 1.7% | — |
| Recording 4112×2658 HEVC scrolling, 60 fps / 30 fps | 8.1 + 5.2 + 2.8% / 4.8 + 2.5 + 1.9% | — |
| Finishing the movie into an MP4 (5 s at 2560×1440, video copied) | 6–13 ms | — |

### Findings

- **H.264 cannot record the built-in display's whole framebuffer.** Its scaled mode is 4112 pixels wide,
  16 over the hardware encoder's limit, and AVAssetWriter has no software fallback that accepts the
  settings. So the format is chosen per recording: H.264 while both sides fit (the default, for players
  and sites without HEVC), HEVC beyond, or always when asked for. 4096×4096 encodes but only at 37–53
  fps; no display or area that size is expected.
- **The encoders are not the cost; the frames are.** Per frame, the app spends most of its time in the
  frameworks: handing each pixel buffer back to ScreenCaptureKit (an XPC message per buffer) and the
  VideoToolbox client. The writer's own work is small. CPU therefore follows the frame rate far more
  than the size: 4112×2658 at 60 fps costs what 1920×1080 does, and 30 fps halves both.
- **A still screen sends no frames, but the stream still wakes at the frame rate** with "idle" notices,
  about 2% of a core in the app and 1.6% in replayd at 60 fps. Fine while recording; never left
  running otherwise.
- **Quality 0.6 keeps 2× text sharp while it scrolls** (stills at 0.4–0.9 look alike at 1:1; 0.6 is the
  middle of the bitrate range). Frames are tagged BT.709 by the stream, as the system's own recordings
  are.
- **A movie cut short is readable**: the writer flushes a fragment every 2 s, and a copy taken while it
  was still writing (as a crash would leave it) read back at least 2 s and finished into an MP4
  (`RecordingRecoveryTests`).
- **Ending the session alone does not stretch the last frame when there is audio**: the video track ended
  at the last change while the audio ran on. The writer writes the last frame once more a frame before
  the end, so the video always lasts as long as the recording.
- Still to measure: a real 6880×2880 display stream (the ultrawide), the window server's share, and a
  Release build.

### The recording flow (2026-10-10)

Debug build, the whole flow on the demo window (`ohmyshot-dev://debug/record-flow`): countdown, recording
with the control bar and the menu bar's time, Stop, kept in the history with a card.

| Measurement | Result | Target |
| --- | --- | --- |
| Record pressed (after the countdown) to the stream running (`recording.start`) | 235–268 ms | — |
| Stop to the MP4 in the history with its thumbnail (`recording.keep`), 3–8 s at 1600×1000 | 36–119 ms | — |
| Frames dropped over four runs (3.5–8 s each, 60 fps) | 0 | 0 |
| Live resources once the card is closed | none | none when idle |

- **A crash keeps everything but the last fragment.** The app was killed with `kill -9` about 8 s into a
  recording; the next launch finished the draft into an 8.0 s MP4 and gave it a card, and a launch after
  that found nothing left. Fragments are cut on the movie's own time every 2 s, so up to the last two
  seconds can be lost, and a still screen at the end of them with them.
- **Quitting keeps the recording first.** A quit Apple event in the middle of a recording stopped it, kept
  it (3.7 s), and only then let the app exit; nothing was left in the drafts folder.
- **Pausing costs the stream, not the file**: frames keep arriving while paused (they are counted and
  dropped, the newest written when recording resumes), so a paused recording still costs what a recording
  of a still screen does.

### GIF (2026-10-10)

The plan left the GIF route open (ImageIO first, gifski if needed). Measured on the demo movie
(`ohmyshot-dev://debug/record-demo`, 10.2 s of a page of text scrolling 240 pt/s, 2000×1280 at 60 fps,
3.3 MB as an MP4), made into a GIF at half its pixels (1000×640, as large as it was on screen) and 15 fps:
the worst case for a GIF, since every frame changes everywhere.

| Measurement | Result | Target |
| --- | --- | --- |
| ImageIO writing all frames into one GIF: size / time / peak memory (prototype, -O) | 31.8 MB / 2.7 s / 1.17 GB | — |
| ImageIO encoding each frame alone, written as it comes (`GIFMaker`): size / time / memory added | 27.3 MB / 1.8 s / 32 MB (Debug build, in the app) | memory flat with length |
| The same frames written whole, never transparent (prototype) | 27.1 MB | — |
| Every frame's unchanged pixels transparent (prototype) | 34.4 MB | — |
| A still page with a small square moving over it, 150 frames vs 1 (ImageIO) | 204 KB vs 182 KB | — |
| At 10 fps / at 0.4× (800×512) | 21.9 MB / 22.3 MB | — |
| Total of the frame delays vs the recording (rounded per frame / per frame start) | 10.57 s / 10.07 s for 10.06 s | as long |

- **ImageIO's GIF writer keeps every frame until it finalizes**, about 7 MB per second of a 1000×640
  GIF, so a minute would need gigabytes. `GIFMaker` has ImageIO encode each frame alone (it picks the
  palette and compresses), then copies that frame's palette and data into the file it writes itself. One
  frame is held at a time, whatever the length.
- **ImageIO's quality is good enough; gifski is not needed now.** Text stays sharp with no visible
  dithering at 1:1, and ImageIO already writes only the part of a frame that changed. Size is the cost of
  GIF itself: a scrolling page changes everywhere in every frame.
- **Transparency pays only for scattered changes.** Marking unchanged pixels transparent made the
  scrolling page 27% larger (its runs broke up), so a frame is transparent only when fewer than half of
  its changed box's 32-pixel runs changed: a pointer and a clock in opposite corners, not a scroll.
- **Delays are rounded where each frame begins**, not per frame: GIF counts hundredths of a second, so
  15 fps frames rounded one by one (7 cs each) played 5% slow.
- **A Debug build was 10× slower until the pixel loops used `memcmp` and `memcpy`**: comparing and copying
  pixel by pixel in Swift without optimization took 18 s for the same GIF; comparing 32-pixel runs and
  copying rows brought it to 1.8 s, about what the optimized prototype took.
- **The whole GIF flow** (`ohmyshot-dev://debug/record-flow?gif=1`, Debug build, on screen with the user's
  OK): 4.36 s of the demo window at 1600×1000, 60 fps, 250 frames written, none dropped; stopping to the GIF
  made took 0.58 s (`recording.gif`: 66 frames at 15 fps, 800×500, 7.5 MB for scrolling text), and to the card
  0.61 s (`recording.keep`). The menu bar went from the time to the GIF's progress to the icon; the clipboard
  was left alone.

### Studio (2026-10-11)

Debug build, in the app, through `ohmyshot-dev://debug/studio-demo` (a Studio recording of the demo window
behind the desktop picture), `studio-render` (filmed as the export would, from a made-up pointer, with
automatic zooms over the sky gradient), and `studio-window` (the Studio window behind the desktop picture).
Footprints are `footprint -p`; the app is 22 MB idle.

| Measurement | Result | Target |
| --- | --- | --- |
| Export, 4.03 s of 1600×1000 at 60 fps → 1760×1160 H.264 | 0.74–0.87 s (4.6–5.5× real time), 5.3 MB | faster than real time |
| Export, 8.02 s of 6400×2600 HEVC at 60 fps (a window as wide as the ultrawide) → 3840×1698 H.264 | 4.0 s (2.0× real time), 88 MB | faster than real time |
| Peak footprint during that export: BGRA in and out / 4:2:0 in / 4:2:0 in and out | 1.09 GB / 910 MB / 575 MB (41 MB after) | — |
| The Studio window playing that recording: preview filmed at the export's 3840 / at the view's pixels (1792×792) | 620–670 MB / 330–610 MB; 80–100 MB paused | — |
| A gray of 111 and an orange (233, 131, 45) through the export, untagged / tagged as the recording | 121 and (239, 141, 51) / 111 and (233, 131, 45) | as recorded |
| The timeline's 24 pictures of the 6400×2600 recording, each from its own stretch / from the nearest key frames | 3.71 s / 0.80 s (5 different frames) | — |

- **A custom compositor asking for BGRA source frames gets every decoded frame converted first**: 66 MB a
  frame at 6400×2600, with a dozen read ahead. Asking for 4:2:0 (what the decoder makes, which Core Image
  reads as it is) took the export from 1.09 GB to 910 MB; drawing the movie's frames in 4:2:0 too (a third
  of BGRA, and nothing left for the encoder to convert) took it to 575 MB, with the colors still exact and
  the speed unchanged. `alwaysCopiesSampleData = false` on the reader's output saves a copy of each frame.
- **The preview is filmed no larger than it shows.** At the export's 4K, the frames AVPlayer plays ahead
  (14–16 of them) held some 400 MB; at the view's backing pixels, rounded up in steps of 128 so a small
  resize films nothing again, they hold 30 MB. The export makes its own composition at full size. What
  remains while a full-screen recording plays is AVPlayer's 19 decoded source frames (24 MB each at
  6400×2600), which no API bounds; paused, it drops to 80–100 MB.
- **An untagged video composition played lighter than the recording**: the compositor drew in sRGB into
  frames the writer tagged Rec. 709's transfer, and left the YCbCr matrix out. The composition now takes the
  recording's primaries, transfer function, and matrix, draws in the color space they make, and the writer
  tags the movie the same way (`StudioExportTests.theRecordingsColorsComeThroughAsTheyWere`).
- **Reading the timeline's pictures exactly is slow on a short, large recording**: with key frames every
  2 s, each picture decoded up to two seconds of 6400×2600 frames. The pictures come from the nearest key
  frames first (0.8 s) and, where those repeat, are read again from each stretch.
- **The recording Studio films never moves.** It is cloned into the project (`source.mp4`, no extra room on
  APFS) when the window first opens it; an exported movie takes its place in the history beside it. Before
  this, the first export moved the recording into the project while the window still filmed its old path,
  and the next edit would have filmed the exported movie again.

Camera, motion blur, and the cursor hidden while typing (2026-10-11, same build and hooks; the camera is a
made-up 640×480 movie from `studio-window?camera=1` / `studio-render?camera=1`, never a real one):

| Measurement | Result | Target |
| --- | --- | --- |
| Export, 8.04 s of 6400×2600 → 3840×1698: no blur / motion blur / motion blur and a camera | 3.87–3.94 s (2.0–2.1×) / 3.79–4.96 s (1.6–2.1×) / 4.74 s (1.7×) | faster than real time |
| Peak footprint during that export: no blur / blur, every exposure drawn from the recording / blur from one drawing | 570–826 MB / 2.95–3.34 GB / 776–786 MB | — |
| The Studio window playing that recording with blur and a camera (preview 1792×792) | 319–432 MB; 85 MB paused; 423 of 423 frames drawn | — |

- **A composition a 6000th of a second longer than its instruction draws nothing in a player, while an
  export reads it.** `CMTime(seconds:preferredTimescale:)` rounds down (1.78 s came out as 10679/6000), so
  a camera track inserted at 0.3 s for 3.72 s ended at 24120 while the movie's instruction ended at 24119;
  `AVVideoComposition.isValid` says no, AVPlayer asks the compositor for no frame at all (the preview stayed
  empty, `isReadyForDisplay` false even after playing to the end), and `AVAssetReader` exports it without a
  word. Times are now rounded to the nearest, each part goes in where the one before ended, the camera is
  cut to the screen's end, and the one instruction runs to the composition's own end
  (`StudioExportTests.aMovieWithTheCameraIsOneAPlayerCanDraw`). Where the camera's movie has nothing (before
  it began, after it ended) its nearest frame is held, so its track has no empty stretch either.
- **Motion blur drawn from the recording for every exposure took the export to 3 GB.** Each of up to 32
  exposures turned the 6400×2600 4:2:0 frame into color again (130 MB apiece), and `insertingIntermediate`
  on the source did not stop it. The frame is now drawn once as the middle exposure sees it, with room
  around the frame for what the others reach, and each exposure is that drawing moved: +200 MB at 4K.
- **CIColorMatrix works on colors unpremultiplied**: weighting an exposure's color and alpha both squared
  its weight (32 exposures came out black); weighting the alpha alone, as a fade does, weighs the
  premultiplied color with it (`StudioMotionTests.motionBlurOnlyWhileTheCameraMoves` checks the average).

### Replay spike (macOS 27, 2026-10-11)

`SCClipBufferingOutput` keeps a rolling buffer of a stream's last 15 seconds in replayd and exports any part
of it as a movie. Measured through `ohmyshot-dev://debug/replay-demo` on the scrolling demo window behind the
desktop picture (nothing of the user's read), Debug build, the screen awake and unlocked (a locked screen
composites nothing: every stream delivered one frame).

| Measurement | Result |
| --- | --- |
| Buffering 1600×1000 at 60 fps, the page scrolling at 240 pt/s (1200 frames in 20 s): CPU of the app / encoder service / replayd | 2.9–3.2% / 3.1–3.3% / 4.9–5.2% |
| The same with nothing changing | 0.3% / 0.0% / 0.1% |
| Footprint while buffering: the app / replayd | unchanged (60 MB) / 10–11 MB |
| Exporting 15 s | 0.03–0.05 s: 15.00 s of 1600×1000 H.264, 15 MB (8 Mb/s) |

- **The stream must deliver its frames to the app too**: with no screen output added, the buffer held no
  video and the export failed ("failure to process first sample buffer", -5822). The app's 3% is those frames
  arriving and being dropped.
- **No frame wider than 4096**: the buffer encodes H.264 at the stream's size with no choice of codec; at
  6272×2550 (a window as wide as the ultrawide) it held no video. A display has to be buffered at 1× or
  otherwise within 4096 (the ultrawide is 6880 wide at 2×, the built-in display 4112).
- **Only what changed in the last 15 seconds is there**: ScreenCaptureKit sends a frame only when something
  changes, and the buffer keeps samples by time, so after 15 still seconds it holds nothing and the export
  fails (replayd: "No video samples found").
- **The export refuses a file that is already there** (AVFoundation -11823, "file already exists"), though
  its header says it overwrites.
- **In the App target, a stream's or the buffer's delegate must be `nonisolated`**: the target's default
  main-actor isolation made the sample callback assert off the main thread ("Block was expected to execute
  on queue [com.apple.main-thread]") and the app crashed on the first frame.
- **Sound needs no output of the app's own**: with sound asked for but no `.audio` output added, the clip
  still had its audio track. The system's sound comes as silence when nothing plays (an 8 s clip, its track
  at −∞ dBFS); a stream that hears nothing at all (one of this app's own windows with this app's sound left
  out) made a clip a few frames long, so the replay's own check hears the app's sound.
- **The microphone is a track of its own, after the system's** (two 3 s runs on the demo window with the
  user's word, the clips deleted at once, only their levels read): track 2 at −∞ dBFS (the silence this app
  played, so the system's sound), track 3 at −26.7 dBFS (the room, so the microphone), both 44.1 kHz stereo
  AAC. A saved clip keeps either, both mixed into one track, or neither.

The replay as built (`ReplayBuffer`, `ReplayCoordinator`), through `debug/replay` on the demo window: saving
takes 110–120 ms for 15 s of 1600×1000 (export and finishing to MP4), and the capture lease is released when
the replay is turned off (`debug/resources` idle).

### M4 power gate (2026-10-11)

Debug build, the same machine and displays, a fresh launch, nothing of the user's read: every step ran on
the app's own demo windows behind the desktop picture. The tour after launch was a 5 s recording
(`debug/record-demo`), a GIF of it (`debug/gif-demo`), a Studio film of it with motion blur
(`debug/studio-render`), and the replay turned on, saved, and turned off (`debug/replay`); then 30 s of
nothing before a 60 s `Scripts/power-sample.sh`.

| Measurement | Result | Target |
| --- | --- | --- |
| Idle after launch, 60 s | 0.00% CPU, 0 wakeups, 23 MB | 0.0%, < 60, < 30 MB |
| Footprint after each step: recording / GIF / Studio film / replay | 28 / 46 / 61 / 57 MB | — |
| Idle after the tour, 60 s | 0.01% CPU (one 0.1% second), 0 wakeups, 57 MB | 0.0%, < 60, < 60 MB |
| Live resources after the tour | none | none when idle |

A 20 s `sample` of the idle app after the tour found every thread waiting, so the 0.1% second is `top`'s
rounding of a single wake, not something that repeats.

- **The allocator keeps the large blocks it frees, dirty.** Before this gate, one GIF left the footprint 33 MB
  higher for good (28 → 61 MB; a 1920×1080 GIF another 30 MB), and the tour ended at 72 MB. None of it was
  live: `vmmap` showed 44 MB of empty large-block regions and 14 MB of empty small ones still dirty, and
  `malloc_zone_pressure_relief` returned none of it. Launched with `MallocLargeCache=0`, the same GIF left
  nothing (27 → 27 MB). The GIF's frame buffers were Swift arrays and vImage's per-frame scratch room; they
  now come from `PageBuffer` (OMSCore: pages from `mmap`, unmapped when let go), and the scratch room is made
  once per GIF: 46 MB after the GIF. What is left after it is ImageIO's own encoding, which the app cannot
  steer. Core Graphics' bitmaps were never part of it: they are mapped pages already.
- **A Studio film keeps about 15 MB** (46 → 61 MB, then 57 after the replay), most of it small heap blocks
  still dirty after the film (`vmmap`: 32 MB of small-block regions dirty after the tour). Two more films
  and another GIF took it to 63 and then 65 MB, the second film adding nothing: it settles a little over the
  budget after heavy use. Not chased further for now; the small-block regions are where to look next.

## M5 — Scrolling capture (2026-10-11)

Debug build. Stitching was timed with a test probe on made-up pages (views 60 px apart), the whole path
with `ohmyshot-dev://debug/scroll-demo` and `debug/scroll-flow`: a window of made-up text the app draws
behind the desktop picture, scrolled 37 pt every 40 ms while the real stream (60 fps at most, frames only
on change) and stitcher take it in, nothing of the user's read. The picture came out the same as the
window's own drawing of the page, line for line (the largest difference 3–4 levels, color conversion), in
every variation: down, down and back up, a jump too far and back, sideways, larger windows, other steps.

| Measurement | Result |
| --- | --- |
| Taking in a view, median (most): 1600×1200 / 2560×1440 / 3440×2000 px | 5.7 (10.7) / 7.9 (13.8) / 12.7 (23.7) ms |
| Putting the picture together: 1600×4740 / 2560×5700 / 3440×7940 px | 7.5 / 5.1 / 10.4 ms |
| A preview (312 px across) | 5–10 ms |
| In the app, a 640×480 pt window (1280×960 px): views / time each | 77 / 11–13 ms |
| CPU while scrolling: the app / replayd | 35–38% / 1.3–1.6% |
| Live resources after it | none |

- **An Objective-C exception inside a Swift task breaks the main thread's executor checks later.** The
  first progress came before the panel had an area to stand beside, so its frame was infinite, and AppKit's
  assertion in `-[NSWindow _reallySetFrame:]` was thrown inside the main-actor task that delivered the
  progress and caught by AppKit. The task never restored the thread's record of the executor it ran on, and
  seconds later the next `@objc` override with a main-actor check (the card's `layout()`) crashed in
  `swift_task_isMainExecutorImpl` reading an executor of 0x0 or 0x40. The crash names an innocent method;
  the log has the assertion two seconds earlier. The panel now waits until it is shown.
- **A window behind the desktop picture draws nothing that scrolls into view.** AppKit leaves an occluded
  window's newly exposed parts undrawn, so the demo's page showed blank stretches in the stream and the
  first runs read the wrong direction; the page is now one picture in its layer.
- **Dithered fills repeat every 64 rows.** The capture of a plain blue bar holds a dither pattern, the same
  every 64 rows, so at a scroll of exactly 64 pixels the bar's lines agreed with themselves further down and
  were taken for content (the bar once more in the middle of the picture). A line that says something and
  is also where it was in the last view now never counts as scrolling.
- **Overlay scroll bars never fade in a window behind the desktop picture**, so the demo shows its knob and
  track in every view; the made-up tests show the knob is left out when, as on screen, it comes and goes.
- **The picture's own memory goes with it**: the stitcher's pages are mapped and unmapped (`PageBuffer`),
  and nothing of it is left once the picture is kept. Encoding a 1280×6548 PNG leaves about 31 MB in the
  allocator's cache of large blocks, as encoding a GIF did.

### Forums: sidebars, timelines, sticky avatars (2026-10-11, second cut)

Two live tests on a LINUX DO (Discourse) topic broke the first cut. The first smeared the sidebar, the
timeline, and the posts' avatars down the picture. The fix for that decided per column of 8 pixels whether
it stays put, and grounded those columns; the second test then showed the banner's top and the first
avatar's top half white in 8-pixel notches, and faint pieces of the avatar down the post. Discourse avatars
stick below the header while their post scrolls, so the avatar column was still most of the time and yet
every post's avatar moved through it: the column flipped between staying and not, and each flip grounded
what was written meanwhile. Auto-scroll stopped about 20 ms after every start: macOS hands scroll events
posted at the HID level back as a gesture's (phase began, the source's state 0, the user data gone), so the
scroller took its own first step for the user's.

Now each line is held in 8-pixel segments, each with how much the views back it: a view backs what moved
there with the page by about an eighth of how far it moved, and a view that shows a segment otherwise wears
that down and replaces it when nothing backs it more. Only a column never seen moving and seen still over at
least a quarter of the view's height (a sidebar, a timeline) is left out and keeps its ground below the first
view. Auto-scroll tells its own steps by size and time.

The demo gained a forum (`scroll-demo?forum=1&timeline=<percent>`): a sidebar, a banner, six posts whose
avatars (pictures and letter discs) move with the post, stick below the header and are pushed out, and a
timeline whose handle creeps as the page scrolls. Every run below came out the same as the window's own
drawing of the page, avatars where their posts begin, line for line (largest difference 2–4 levels).

| Measurement (Debug) | Result |
| --- | --- |
| Forum, 640×480 pt (1280×960 px), timeline 20% / 35% of the view | 0 / 0 lines off, 11.0–11.3 ms a view, CPU 40% |
| Forum, 1750×1200 pt (3500×2400 px), timeline 30% | 0 lines off, 28.0 ms a view, CPU 87% |
| Sidebar demo, 3500×2400 px (24 ms a view before this cut) | 0 lines off, 28.4 ms a view, CPU 89% |
| Made-up 3500×2400 views, `OMS_STITCH_SPEED=1` test | 27.7 ms a view |
| The earlier demos (plain, scroll bars with a jump and back) | 0 lines off, 12.7–14.3 ms a view |
| 120 walks going back four times in ten, `OMS_STITCH_SWEEP=1` | 6 leave 1–25 rows off |

- **Debug Swift loops cost what the stitching does.** The first version of the segment weighing took 43 ms
  a view at 3500×2400 px: taking in a line that just came into view went segment by segment through
  `Range` iteration, closures, and a one-element array made for every line. Loops over byte runs with one
  `memcmp` a segment and `update(repeating:count:)` brought it to 28 ms; matching the views (hashing and
  voting, as before) is now most of what is left.
- **Evenly spaced sample rows fall in step with a sidebar.** The ground of each column was the color most
  of 24 evenly spaced rows of the first view showed; in the 35% forum their spacing matched the sidebar's
  36-point items, every sample hit an icon, and the icon's color became the sidebar's ground down the whole
  picture. Sample rows now go a golden ratio of the range apart.
- **Something alike top to bottom matches wherever it is.** The timeline's handle, creeping down by itself,
  matched "where the page moved" along its bar, so its column counted as moving and the timeline was never
  left out; its track line, still, then outvoted the first view's blank rows passing under it. A match the
  view itself also shows as far on no longer counts as moving, and such alike-both-ways observations only fill
  segments nothing backs.
- **Where an avatar sticks, plain says nothing.** Right below the header the post's blank margin shows where a
  stuck avatar would be, and the avatar is pushed out moving with the page: plain observations there neither
  back nor wear down what a segment holds, and nothing there replaces what something else backs.
- **What is left:** going back and forth a lot right where an avatar sticks and comes loose, a few walks
  leave some rows of it a little off (its edge, or a piece where it was pushed out). Views narrower than about
  550 px (275 pt on a Retina display) have only two bands to line up by, and a sidebar filling one of them
  stops them lining up, as before.
- **The 256 MB cap was about seven screens at full width.** 3346 px wide, a picture reached 256 MB at about
  16,800 px: the first live test stopped there. The user chose a larger cap over half resolution: see below.

### A longer picture: 1 GB (2026-10-12)

The cap is now 1 GB, and the content may be as long as 50,000 px less a view's worth for the header and
footer, counted along the way it scrolls. `ohmyshot-dev://debug/scroll-long?mb=&length=` stitches a page made
up in memory (3346×2404 px views beside a sidebar, nothing shown or read), then makes the picture, its PNG and
the card's thumbnail as a capture's delivery does, and logs the time and the app's highest footprint for each.

| 3346×2404 px views, Debug | 256 MB, before | 1 GB, now |
| --- | --- | --- |
| Picture | 3346×16,600 (128 views) | 3346×47,530 (404 views) |
| Stitching: a view / footprint at most | 33.8 ms / 396 MB | 29.5 ms / 807 MB |
| Making the picture: time / footprint at most | 23 ms / 608 MB | 79 ms / 808 MB |
| PNG / card thumbnail: footprint at most | 338 / 342 MB | 755 / 753 MB |
| Footprint before / after it all | 24 / 129 MB | 23 / 57 MB |

- **Making the picture no longer needs its memory twice.** `picture()` copied the content into a picture of
  its own while the stitcher still held it: at 1 GB that would have been 1.3 GB at once. Captures now take
  the picture with `takePicture()`, which moves the content's lines into it a 256-line chunk at a time and
  unmaps each chunk as it empties; nothing is taken in after it.
- **The picture has to be in one piece.** A picture read straight from the stitcher's chunks through a direct
  data provider cost no copy to make, but ImageIO's PNG encoder then copied all of it (1,344 MB at the peak)
  into memory the allocator kept dirty after: 745 MB footprint once it was all let go. From one mapped buffer
  it streams (12 MB more), and unmapping it gives everything back.
- **The card's thumbnail of a long picture was its whole length shrunk to 560 px, then its top cropped**: 37
  by 29 pixels for a 50,000 px picture, blown up to fill the card. Card thumbnails are now made from the part
  the card shows (`HistoryStore.cardThumbnail`), from the picture itself when it is in memory, and from a file
  decoded only as large as that part needs. 7 ms for the 47,530 px picture.
- The "after" figures count the check's own buffers out (they are mapped and unmapped too); the earlier
  129 MB was mostly them, kept by the allocator.

### Direct Auto-scroll and stitching repairs (2026-10-12)

Auto-scroll starts after the first captured frame. Its panel has a native 0.25×–2× speed slider,
initially 1×, and explicit Pause/Resume. Speed remains set while paused. There is no pointer marker or
arming step. At 1× the rate is 35% of the viewport per second, bounded to 60–320 pt/s; the final rate
never exceeds 80% of the viewport per second. Fractional motion accumulates, and delayed timer ticks
never send a catch-up jump. A page boundary keeps the capture open. Two unmatched views or the length
limit pause the driver for recovery or Done.

The transport resolves the original window, sends phased pixel-wheel events to its process, and never
posts pointer movement or warps the cursor. This machine's Droppy smoother had rewritten unphased
scrolls and removed their source markers. Hardware cancellation now observes wheel input before that
transformation. Window-directed delivery uses a small dynamically resolved SkyLight shim; unavailable
symbols or an unrecognized event layout cause Auto-scroll to remain off with a manual-scroll hint.
Private field numbers are not interchangeable with CGEventField values, so the window field is found
from two unposted AppKit event templates. No Droppy settings were changed.

The production transport was exercised against a separate synthetic NSScrollView process with the
pointer outside its window. Eighteen steps delivered exactly 18 wheel events and moved the view
0 → 192 → 96 pt. The pointer was not snapped to the target. A 6.33 pt displacement coincided with six
hardware mouse movements. This is an input-delivery check, separate from image stitching. The probe is
reproducible with `Scripts/scroll-input-check.sh` after `Scripts/run.sh`; it closes itself after the check.
Hardware wheel input during the probe makes the check inconclusive.

Stitching repairs:

- A moving image inside stationary text must not move the inferred position of the entire page.
- Partly repainted browser tiles must agree before becoming the next scroll reference.
- Per-segment quality favors confirmed observations farther inside the viewport. It prevents repeated
  passes over sticky avatars from overwriting their correct position with a less clear edge view.
- The first view's scrolling content can now be repaired by clearer later observations. Fixed columns
  retain a separate coherent first snapshot. This removes transient shadows captured at the initial edge.
- Thin, flat borders surrounded by the column background count as fixed features; large white images
  on dark pages do not. This removes repeated sidebar rules without cutting black notches into images.

The new shadow and image-loading regressions reproduced 45 and 24 incorrect rows before the repair,
and zero afterward. The fixed-sidebar-border case also passes. The 120 randomized forum walks now
require zero differing content rows; all pass, including six formerly failing seeds.

Final verification of this implementation:

| Check | Result |
| --- | --- |
| Optimized targeted tests, including the speed check | 39 tests in 3 suites passed |
| 120 randomized forum walks with reversals | 0 walks with differing rows |
| 3500×2400 synthetic views, optimized | 90 views, 10.7 ms per view, no gaps |
| Real ScreenCaptureKit forum demo, forward and backward | 3500×6488 output; page/sidebar and timeline both had 0 rows beyond the 24-level tolerance (largest differences 8 and 4); no lost frames |
| Same real-stream demo, Debug build | 80 views, 42.6 ms per view; finish 49 ms |
| Final light and dark panel renders | Speed slider and Pause/Resume fit without clipping |
| Final cross-process input probe | Exactly 18 delivered steps, 0 → 192 → 96 pt; 0 hardware wheel events; 68 real mouse movements during the check |
| Debug app | Built and relaunched successfully |

Validation commands: `OMS_STITCH_SWEEP=1 OMS_STITCH_SPEED=1 Scripts/test.sh -c release -Xswiftc -DDEBUG
--filter 'ScrollStitcher|AutoScrollerTests'` and
`ohmyshot-dev://debug/scroll-demo?forum=1&back=1&timeline=35&w=1750&h=1200`.
The DEBUG define exposes existing UI test helpers while retaining optimization. The real stream demo
uses synthetic content. Light and dark panel renders verify the direct controls. The user's existing X
capture was inspected to shape the regressions; a fresh capture of the live X page was not verified.

### Complex pages and Auto-scroll (2026-10-12, later)

A hunt on real pages found 31 problems, most of them Auto-scroll pasting over one view or never stopping.
It replayed frames of real and made-up pages (headless Chrome) through the stitcher, and ran the app itself
driving a throwaway Chrome window, the panel behind the desktop picture, nothing kept but under
debug-snapshots. Debug build unless said.

| Check | Before | After |
| --- | --- | --- |
| 206 replayed frame sets: real pages, made-up pages, live recordings | — | 52 closer to the page's true length, 2 further (near-duplicate cards; ten carousels switching at once), the rest the same |
| X-like timeline replayed at 3534×2394 px | 8290 rows of 11612 | 11612 |
| bbc.com, live recording replayed | 11 views lost | 0 |
| A page that cannot scroll, live | Auto-scroll never stopped; 329 views of 1 px, the picture growing blank | stopped in 1.5 s; one view |
| A code block under Auto-scroll's gesture, live | 113 px too long: text above the block twice, blank below the end | 13927 px, the page's own length |
| bbc.com/news, live | — | 600 scrolls, 0 lost, stopped by itself at the end in 20.5 s |
| 120 randomized forum walks | 0 rows off | 0 rows off |
| A view taken in, live, 2200×1626 px | — | 13–15 ms |

- **Chrome pulls the page past its end while it is pushed**, about a pixel a frame, fixed bars staying and
  the rest moving with the pull, then springs back once the push ends. Each pulled view lines up, its
  arrivals blank, so the picture grew blank for as long as Auto-scroll pushed. Two such views in a row while
  driven now start an overscroll: what comes past the end is kept provisionally and goes when the content
  springs back or Auto-scroll stops. Once trimmed it is springing back, never pulled again: a view lagging
  behind the pull (the reference held while a sticky header moved) once brought 135 px of the background
  back.
- **Auto-scroll watches what it gets.** Every quarter second: once it has pushed four tenths of the area
  since a moment at least 750 ms back and the capture got less than 15% of that, it stops (the content was
  pulled: the end) or moves its gesture, at most twice, then stops and says so.
- **A wheel gesture belongs to whatever was under it first.** On a code block, the block scrolled alone and
  each of its steps was taken for the page's, so once the gesture moved off it the text above it came twice.
  Such a part (under three quarters of the space between the bars, around the gesture, beside content that
  stays put) is now left out and the gesture moves beside it; the block's last steps after the move, and
  its seeming to move further than the page against the view before it scrolled, are left out too; the
  picture starts from the block as it was left. The bars do not count as content around it: on bbc.com the
  sticky header beside a blank advertisement made the page look like a scroller inside itself.
- **What changes in place (video, fading images, ads loading) no longer votes against an offset**, and
  offsets are chosen from several candidates by the rows that testify, not by raw votes; a view found again
  is placed near where it is expected, by what scrolls, never by sidebars.
- **Long pictures and memory:** a scrolling capture is never framed by the automatic background (3534 ×
  47000 px framed took about 1 GB more, 5–16 GB with an aspect preset); the clipboard gets the PNG, TIFF
  only when an app asks, and none past 24 million pixels.

Left as they are: an image whose rows are all alike (a sideways gradient) gets dark dashes where segments
were taken for something fixed on screen, a little more than before (5999 dark pixels where the earlier
stitcher had 5154 on one image); fixed floating buttons bite into the last rows; pages that re-render as
they scroll (apple.com) lose track; a fixed page background, content that changes after it was taken
(skeletons), and the very end of a page showing something new still behave as before.

### Complex pages, a second round (2026-10-13)

The rest of the hunt's problems that lie in the stitcher. Each change was replayed over the same 206 frame
sets (heights, and pixels against pictures rebuilt from the frames' true offsets, every changed picture
looked at) and the 120 forum walks. Debug build unless said.

| Check | Before | After |
| --- | --- | --- |
| A news page whose section list is a sticky card, three live recordings replayed | a white strip beside the list down the picture | the page's gray |
| A fixed panel over a scrolling column (made up), 1400 rows | 414 rows off | 0 |
| A README ending in a GIF, apple.com, a page whose last screen starts playing, a carousel | each ended short (84 rows of the GIF missing) | each ends where the page does |
| A lazy hero and a lazy illustration | their placeholders, notched where the line ends updated alone | what loaded |
| Shop grids with blank stretches, row numbers down the edge | the numbers jumped back and forth by 1800 px, 14 times | in order, but for the blank stretch left out |
| The 206 frame sets replayed twice, in two processes | a picture could come out either of two ways (136 pixels of a news page) | byte for byte the same |
| 3500 × 2400 px views, a video playing and nothing scrolling, optimized build | 5.2 ms | 2.0 ms |
| The same views scrolling, optimized build | 10.2 ms | 9.4–9.6 ms |
| 120 randomized forum walks | 0 rows off | 0 rows off |

- **A sticky card's blank inside** (right of its labels) said nothing either way and, wider than three
  segments, was taken as content: below the first view it showed the card's white down the whole picture.
  A gap between columns that stay put now stays put however wide when views told it stayed put at least
  four times as often as moved, or told nothing; the page's color past the card is found column by column,
  since a pixel a shade off at the view's edge made no line of the whole run one color.
- **What the page shows after the first view** (a picture loading once scrolling starts, a skeleton filled
  in) takes the first view's place where three views in a row show it alike, at least three margins of lines
  together, away from the bars. Something that keeps changing (a video, a scroll-driven animation) keeps the
  frame first taken.
- **The page's end** is kept from any view that reaches as far as the picture does, its part that scrolls
  cut short by something playing there or not.
- **A view taken while nothing scrolls counts for the line ends** only where a line between the ends is
  unique and where it was: over rows alike at any offset, a view that scrolled looked still and wrote other
  rows' numbers.
- **The same frames make the same picture.** A column's background and the order of offsets tried when no
  line was unique were left to Swift's per-process hash seed; ties now go to whichever got there first.
- **A view where only a little changed** (a video, a spinner) costs a comparison per line rather than a copy
  and a hash: a line the same as the buffer held keeps its hashes, so every picture is byte for byte what it
  was.

Of what the last round left: content changing after it was taken and the end of a page showing something new
are handled; dark dashes on an image whose rows are all alike now allow for dither (3 levels), though the live
dashes did not reproduce offline. Left as they are: fixed floating buttons (back to top, a chat bubble) still
bite into the last rows, and moving them out of the picture needs tracking what stays put on screen rather
than in the page; carousels that slide while in view can still come out in strips; a fixed page background
and pages that re-render as they scroll (apple.com) still lose track; a blank stretch taller than the view
cannot be measured, so it is left out.

Then a live run in the app, with the user's OK: a throwaway Chrome window, Auto-scroll on six pages (a made-up
news page with a sticky section list, an X-like timeline, a sparse sheet, bbc.com/news, theverge.com,
apple.com/iphone), the picture kept under debug-snapshots only. 417 to 853 scrolls a page, none lost;
Auto-scroll stopped by itself at bbc.com's end, the others ran to the 25–30 s limit. apple.com, which lost track
before, went 795 scrolls without losing it. The X-like timeline showed a sidebar held by its foot at the view's
never staying put (its last entries in fragments down the whole picture): fixed in the stitcher, its counts of
what moved now fading away once it stays still; the six captures replay to their live pictures but for the
last few dozen rows, and the fix changes only the timeline among them.

Still visible on real pages: what changes while in view is taken 8 px at a time, so a headline whose hover
style comes and goes under the pointer (theverge.com), links sliding in as they appear (apple.com's footer) and
animated advertisements (bbc.com) come out as a mosaic of their states; and between a sidebar sticking and being
taken to stay put, flat parts of it still overwrite a few lines below it.

### What sticks over the content (2026-10-13, later)

What a column shows while it does not move with the content, chiefly a sidebar held by its foot at the view's.
Replayed over the six live captures, the 206 frame sets and the 120 forum walks. 76 frame sets came out
otherwise; each was looked at where it changed most, one run of a page standing for its other runs where they
changed alike. Debug build unless said.

| Check | Before | After |
| --- | --- | --- |
| The live X-like timeline, its sidebar's foot (the last card, its footer) | the last avatar in slices down some 290 rows, the name twice, the footer missing | once, as it scrolled, the footer whole |
| The 206 frame sets, pixels against pictures rebuilt from the frames' offsets | 191,604 rows off | 192,403 rows off (8 sets better, 35 worse; see below) |
| A sidebar held by its foot (made up), the sidebar's own rows | 86 rows off | 0 |
| 3500 × 2400 px views scrolling, optimized build (two runs each) | 8.73–8.89 ms | 8.84 ms |
| Frame sets with a video or a carousel in view, replayed one at a time, optimized | 0.73–4.63 ms a frame | within 3% of before (a carousel scrolled 200 px a step: 4.63 → 4.76 ms) |
| 120 randomized forum walks | 0 rows off | 0 rows off |

- **A view that saw a column mostly not move with the content** (its sampled lines showing it stay put, or move
  part of the way: a sidebar held by its foot stops partway through a scroll, then stays put for a dozen views
  before the counts say it stays put) shows what is over the lines there, not the lines. Each line now keeps,
  segment by segment, whether what it holds came from a view that saw the column move; such a view's picture
  there gives way only to another such view's. Before, the clearer-view rule wrote the stuck sidebar's flat
  avatar into every line passing under it, and the view that stopped partway wrote its name a little low.
- **Moving part of the way** is told from changing by finding the segment in the view before at a smaller offset
  than the content's. What moves part of the way moves as one, so the distances found are tried first and others
  16,384 times a view at most: unbounded, a carousel scrolled 200 px a step took 42% longer a frame. A video
  playing changes in place, so it keeps the earlier behavior (a mosaic of its frames where it was taken a little
  at a time).
- **The first view's lines** under something the second view showed staying put (a floating button at its foot,
  an avatar stuck below the header) can still be replaced, as before.
- **What it costs:** a byte for every 8 pixels of each line, a 32nd of the picture (32 MB at the gigabyte limit).
- **The 35 sets that score worse** are sticky sidebars and navigation: the rebuilt reference has no sidebar as it
  scrolled (it repeats one line of it down the picture), and the pictures that now differ from it show the
  sidebar whole where they showed fragments: GitHub's file tree and an issue's participants, MDN's and Apple
  Developer's contents, X-like timelines' follow lists and footers, a made-up forum's avatars. A bun.sh docs
  list repeats three entries, as it repeated three others before.

Still visible: where a view that stopped partway wrote nothing, two views' halves of a name or a footer can meet a
pixel or two apart; GitHub's file tree shows one entry twice where the rest of it was fragments; a fixed button
on a made-up page comes out twice rather than three times; a line cut off at the foot of a card on theverge.com
now has a smear over part of it; a navigation's button stuck from the first view can come out cut (as before);
videos and animated advertisements still come out as a mosaic of their frames.
