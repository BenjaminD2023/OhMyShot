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

### A navigation's button (2026-10-13, later still)

The X-like timelines' navigation column has a flat, pill-shaped Post button that every view shows whole, yet the
picture showed it cut, square at one end or missing a stretch of its middle, before the last change and after. The
first view's lines where the next view showed something stay put were loosened, so that a floating button over them
gives way to the page, and the button's rounded end counted as such; the views that followed, the navigation
stuck, then wrote its dark gaps over the button's lines. Now only what does not move with the content (stays put or
moves part of the way) within less than half the view is loosened: a floating button at the view's foot, an avatar
stuck below a header. It is taken together across what the column shows between (a button's flat middle), but not
across columns showing nothing but the ground (the dark margin between a sidebar and a floating button), and what
moved part of the way counts (a docs sidebar stopping partway through the one scroll of its capture).

| Check | Before | After |
| --- | --- | --- |
| The live X-like timeline's Post button | cut square at its right end | whole |
| The same button in 18 X-like frame sets (made up, light and dark) | cut, or missing a stretch of its middle | whole |
| A navigation column with a pill-shaped button (made up) | 32 rows of the button off | 0 |
| Floating buttons at the foot of the X-like frame sets | left out | left out |
| The 206 frame sets, pixels against pictures rebuilt from the frames' offsets | 192,403 rows off | 192,409 (the rebuilt pictures show no button there) |
| 120 randomized forum walks | 0 rows off | 0 rows off |

25 frame sets came out otherwise, each looked at: besides the button, a line of Apple Developer's contents and the
last number of a docs list come out whole, and a chat's channel names no longer stop short.

### Seams where a sidebar stopped partway (2026-10-13, later still)

Two places where a view looks at too few lines of a column (32 a view) and leaves one of it out.

- **The ragged edge of what stopped partway.** In the view where a sidebar stops partway through a scroll, a
  column at the right end of its names, with one line that moved with the content by chance and two that moved
  part of the way, was not adrift (that takes two to one), and was not between columns that were: the last letters
  of a name came from that view, a few pixels off. Now a column beside adrift ones that the view saw not move with
  the content at least once, and no less often than move, is adrift too.
- **A letter's gap in small print.** A column coming to stay put takes the ground on the lines no view saw it move
  over. A view whose line looked at in one column fell between two letters, while the columns either side saw the
  small print move, left that column's lines out: 8 px of "Accessibility" at a sidebar's foot went dark. Now a gap of
  up to three columns between ones a view saw move, where it saw nothing at all, moved with them.

| Check | Before | After |
| --- | --- | --- |
| A made-up X-like timeline, the last name in its follow list | "Dana Ose" and an "i" a few pixels off | whole |
| A made-up dark X-like sidebar's footer | "Acce ssibility", the separators and the card's bottom border broken | whole |
| GitHub's file tree, nature.com's and Apple Developer's contents | a name's end, a link's last letter, a highlight's end off | whole |
| The 206 frame sets, pixels against pictures rebuilt from the frames' offsets | 192,409 rows off | 192,399 |
| 3500 × 2400 px views scrolling, optimized build (two runs each) | 8.88–9.19 ms | 8.85–9.09 ms |
| 120 randomized forum walks | 0 rows off | 0 rows off |

30 frame sets came out otherwise, each looked at; two specks appear on a dark MDN page. Still visible: the X-like
timelines' footers keep a seam where two views' halves of a line meet a few pixels apart, moved along it rather
than gone.

### A block that keeps changing (2026-10-13, evening)

What keeps changing where it is (a video, an animated advertisement, a carousel) came out as a mosaic of its frames:
each line kept its clearest view, and each line's clearest view was another frame (bbc.com's advertisements,
cnn.com's clips, apple.com's chip cards).

Each view now counts, segment by segment, where its lines show otherwise than the last view did at the same place in
the page, unless something stuck over the line says why: three times and the segment keeps changing, until eight views
in a row see it hold still. Before any line is written, what keeps changing is held together into blocks, with the
lines come into view under it since. A block that fills at least half of its bounds, at least two margins tall and 8
segments wide, shown whole and well inside the view with the lines around it holding still, is taken whole from one
view: the first that shows it changing where the last view showed a block too (a video, not a shape turning or sliding
across), then any view where nothing in it changed (a slide held), or one at least as clear as the block was taken.
From then on no line by line rule writes it. What keeps changing otherwise (a heading's letters sliding in, a turning
shape) is left to the line by line rules, as before: every picture without such a block comes out byte for byte as it
did. Lines the last view showed as they are, by their bands' hashes, are skipped; a band that differs is compared in
one memcmp before segment by segment.

| Check | Before | After |
| --- | --- | --- |
| The six live captures | bbc.com's three playing advertisements a mosaic, white blocks in two | one frame each; the other five byte for byte as before |
| The 206 frame sets, pixels against pictures rebuilt from the frames' offsets | 192,399 rows off | 191,580 (20 sets changed, all with something playing or sliding in place, each looked at; 11 better, 3 worse) |
| A video playing in a made-up page | the video from three frames, in bands (152 of 240 rows from other frames) | one frame |
| 3500 × 2400 px views scrolling, optimized build, two runs each (a busy machine) | 10.1–10.2 ms | 11.0–11.1 ms |
| The same views, a video playing and nothing scrolling | 2.34 ms | 2.35–2.43 ms |
| Frame sets with a video or a carousel in view, one at a time | 0.9–5.4 ms a frame | 0.1–1.1 ms more |
| 120 randomized forum walks | 0 rows off | 0 rows off |

The busy machine (a load average of 4 to 8) measured the committed version at 10.1 ms where a quiet one had 8.8. What
it costs besides: a byte for every 8 pixels of each line (32 MB at the gigabyte limit), and for the view being taken in
5 bytes a segment (5 MB for a 3500 × 2400 view).

Still visible: a carousel caught mid-slide shows parts of two slides; a made-up page's diagonal streak sliding across
leaves a few more fragments; a stray glyph by a logo in a sliding row of logos (vimeo.com); a faint bar under a button
fading in at a page's end; a video taller than the view still comes out line by line, as before.

### Buttons fixed over the page (2026-10-13, night)

A button fixed over the page (a back-to-top button, an X-like Post button, the pills floating over theverge.com's
feed) was stamped down the picture: where a line passes under it nearer the view's middle than any view shows the line
again, the clearer-view rule took the button's flat inside for the line, as it left out only what stays put and says
something, not one color. Where the last view's lines were seen only under such a button, its edges and mark took the
ground and its flat inside stayed, a blocky blob at the picture's end.

- **The clearer view.** One color where it was on screen that the line did not show in the last view, other than the
  column's own ground, is over the content: no clearer view of the line. Nor is a segment the button's edge crosses:
  two of its pixels at least as the last view showed them on screen, unlike the column's ground and unlike the line as
  the last view showed it but for the display's dither, beside such a flat segment or a mark that stays put.
- **A line come into view.** One color where it was on screen, unlike the line as many lines further in as the content
  moved, takes the ground beside what stays put there (the button's edge or mark), as that does.

| Check | Before | After |
| --- | --- | --- |
| The six live captures | two specks at the foot of the X-like timeline's sidebar | gone; the other five byte for byte |
| The 206 frame sets, each picture's size and steps | as committed | the same |
| The 206 frame sets, pixels against pictures rebuilt from the frames' offsets | 191,580 rows off | 186,830 (51 sets changed, each looked at; 11 better, 8 worse, see below) |
| A flat button fixed mid-view over made-up text, its edges on the 8 px grid or across it | 219 rows show it | none |
| Its white mark, the page's own color | stamped | stamped (33 rows) |
| A round button at a made-up page's foot, over text | 47–48 rows show it | 39–40 |
| 3500 × 2400 px views scrolling, optimized build, alternating, two runs each (a load average of 4 to 9) | 11.4–11.7 ms | 10.5–10.7 ms |
| The same views, a video playing and nothing scrolling | 2.20–2.35 ms | 2.26–2.33 ms |
| 120 randomized forum walks | 0 rows off | 0 rows off |

What changed, looked at: on made-up pages, a chat's highlighted channel stamped down its sidebar, a flat button
stamped 16 times down a margin, the X-like timelines' Post button (light, dark, loading late) and the last avatars of
sidebars that stick, stamped down their columns, now show once; theverge.com's two floating pills are gone from its
feed, and its pinned feature card, whose title was stamped six times down its column, leaves faint fragments there;
small stamps on Apple Developer, Wikipedia and the dark made-up sequences (a gray box, ticks along a rule, short bars)
are gone; the back-to-top button at a made-up feed's foot and a late-sticking sidebar's last avatar leave the page's
background. Of the 8 sets that score worse, the rebuilt references of the two sticky sidebars repeat them and that of
the feed has its button at the foot, which the pictures now leave out; bun.sh's Ask AI button leaves a stretch of its
border where it left its outline; vimeo.com and the VHS terminal recorder's page are within a row of before; the X-like
timelines' footers are below.

Still visible: the X-like timelines' sidebar footer, where two views' halves of its small print met a few pixels apart,
now shows them over each other: the flat card a view shows there, the sidebar stopping partway, is taken for something
over the line and no longer written over what an earlier view left; apple.com's MacBook Pro page keeps the pause glyph
of the media control at its foot in pieces, for the same reason; samsung.com's cookie dialog, garbled before, is
garbled otherwise; a mark of the page's own color inside a button fixed mid-view is still stamped; a round button over
text at a page's foot leaves its flat inside in the last lines; a page whose background stays put while the text
scrolls (a made-up landing page) is as broken as before, as long and in the same steps, its fragments elsewhere; a short
white line under a dark panel on atlassian.com and a notch in a glyph of a made-up sequence are new.

### A sidebar's small print stopping partway (2026-10-13, night, later)

Since the change above, the X-like timelines' sidebar footer came out with its two lines of small print over each
other, where before it had a seam. In the view where the sidebar stops partway (the content moved 22 px, the sidebar
8), the 32 lines a view looks at mostly missed the footer, so its column was not found adrift, and the view wrote its
footer 14 px low over the one the views before wrote as it scrolled; before, the same view also wrote the flat card
over the upper one, which left a seam instead.

Now a view in which those lines found something moving part of the way looks at every line, at the distances found,
before any is written: a segment that says something, shown neither where the content moved nor where it was on screen
but where the view before showed it one of those distances on, is over the line, as in a column found adrift, and so is
the one color beside it in the same column, as near to it as it moved short of the content (the blank between the
lines of small print), not across into another color. Only bands that differ from the last view's line are looked at,
and nothing that keeps changing where it is (a video, which matches somewhere by chance). A view that finds nothing
moving part of the way does nothing more.

| Check | Before | After |
| --- | --- | --- |
| The X-like timelines' sidebar footer, made up, stepped 11 px and auto-scrolled | two lines of small print over each other | once, whole, where it scrolled (stepped: a speck under two letters) |
| The same, auto-scrolled fast | both lines doubled | the first line whole; the second still doubled (below) |
| The six live captures | as committed | the X-like timeline: 14 px of a card's edge; the other five byte for byte |
| The 206 frame sets, each picture's size and steps | as committed | the same |
| The 206 frame sets, pixels against pictures rebuilt from the frames' offsets | 186,830 rows off | 186,817 (13 sets changed, each looked at; 3 better, 0 worse) |
| Frame sets with a video, a carousel or the timelines' footer, one at a time, optimized, alternating, five runs each | 1.3–7.0 ms a frame | 2–6% more (cnn.com's videos 1.27–1.30 → 1.34–1.35 ms; a carousel 6.84–6.96 → 7.01–7.19 ms) |
| 3500 × 2400 px views scrolling, optimized build, alternating, two runs each (a load average of 5 to 7) | 11.3–11.5 ms | 11.5–11.6 ms |
| 120 randomized forum walks | 0 rows off | 0 rows off |

Besides the footers, what changed is within a video, an advertisement or an animation (a few segments a frame earlier
or later), a speck on a made-up page, and a page whose background stays put (as broken as before).

Still visible: in the fast auto-scrolled timeline the footer's second line, which comes into the part of the view that
scrolls only once the sidebar has stopped (the bar at the view's foot goes then), still comes out doubled; apple.com's
MacBook Pro page keeps the pause glyph of the media control at its foot in pieces (the change above), as the lines there
are only ever seen under it.

### The page's background below a sidebar held by its foot (2026-10-13, night, later still)

On X-like timelines the picture showed, below the sidebar's foot, a column in its cards' color down to the end of the
picture (on the live capture some 13,000 rows of light gray down the right of the page), where the page is white. Two
causes:

- A column that comes to stay put took as its ground what the first view showed in it most: under a sticky card shorter
  than the view, the page's background past it; but a sidebar taller than the view shows nothing past it in the first
  view, and its cards' color outnumbers the white between them. What came in under it once it stayed put took that.
- Where its columns were found adrift but not to stay put (by the view's edge, seen moving as it scrolled), the lines
  below its foot came in white and then took its cards' gray from clearer views that showed it stuck over them, as
  what is loose may.

Now a column that comes to stay put, when the first view showed nothing past it, takes for what comes in past it, and
for the lines past the last one any view saw it move over, the color the view it came to stay put in shows across it
past what was seen still: the page's white below the sidebar's foot, when the first view showed that color across it
too (between its cards), not something else at the view's foot. What was not seen moving inside the sidebar keeps its
cards' color. And a run of columns adrift that nothing in moves any more takes from no view what it shows past the last
line any view saw the run move over, loose or not (what stayed put there may still give way to the ground); text
moving over a background that stays put keeps the earlier rules.

| Check | Before | After |
| --- | --- | --- |
| The made-up X-like timelines (light and dark, stepped and auto-scrolled), below the sidebar's foot | its cards' color down to the end | the page's white (black) |
| The live X-like timeline, the same | light gray down some 13,000 rows | white, but for a 14 px strip by the scroll bar and faint streaks |
| A sidebar of gray cards held by its foot (made up) | 1,945 rows below it not the page's white | none |
| theverge.com, the column of its pinned feature card | faint fragments of the card's title | its gray |
| The other five live captures | as committed | byte for byte |
| The 206 frame sets, each picture's size and steps | as committed | the same |
| The 206 frame sets, pixels against pictures rebuilt from the frames' offsets | 186,817 rows off | 186,818 (16 sets changed, each looked at; the rebuilt pictures repeat the stuck sidebar below its foot) |
| Frame sets with the timelines, a video or a carousel, one at a time, optimized, alternating, five runs each | 1.3–9.5 ms a frame | within 2.5% either way |
| 3500 × 2400 px views scrolling, optimized build, alternating, two runs each (a load average of 5 to 7) | 11.4–11.5 ms | 11.4 ms |
| 120 randomized forum walks | 0 rows off | 0 rows off |

Besides the timelines and theverge.com, what changed is a highlight stamped on MDN pages, smaller or gone, and a few
pixels on Wikipedia pages.

Still visible: a strip 14 px wide by the scroll bar, at the line's end, which is counted rather than weighed, keeps the
cards' color; faint streaks of it where a card's edge came in under the stuck sidebar; a sidebar whose first view
shows no line of the page's color across it between its cards keeps its cards' color below.

### A picture that loads after the first view, to its ends (2026-10-14)

A hero that showed a placeholder in the first view and its picture in the views after came out loaded between the
ends but with the placeholder in a strip 18 pt wide down each side. The ends of a line are counted, not weighed, and
the first view, taken while nothing scrolled, counts eight times: a row seen loaded in fewer than nine views after it
kept the first view's ends, though a clearer view had replaced what was between them.

Now when what the first view showed of a line gives way, in half its segments or more, to something unlike it by more
than a shade (24 levels in a channel), the first view's ends count once, and the ends two views agree on follow. A shade
a little off (a gradient that shifts as the page scrolls) or something changing in part of the line leaves the ends as
they were: tried without that, the ends took a scroll bar's knob on bbc.com and a progress bar's dark track on a made-up
landing page from the views after.

| Check | Before | After |
| --- | --- | --- |
| A hero loading after the first view (made up, scrolled in long steps) | 130 rows loaded but at their ends | none |
| The same on a made-up page scrolled 40 px a step | 80 rows with the placeholder at the ends | none |
| The six live captures | as committed | byte for byte |
| The 206 frame sets, each picture's size and steps | as committed | the same |
| The 206 frame sets, pixels against pictures rebuilt from the frames' offsets | 186,818 rows off | 186,669 (5 sets changed, each looked at; 3 better, 0 worse) |
| Frame sets with the hero, a landing page, a carousel, a video or the timelines, one at a time, optimized, alternating, five runs each | 1.3–7.1 ms a frame | within 2% |
| 3500 × 2400 px views scrolling, optimized build, alternating, two runs each (a load average of 5 to 6) | 11.5 ms | 11.5–11.6 ms |
| 120 randomized forum walks | 0 rows off | 0 rows off |

Besides the hero, a white block on two made-up landing pages now reaches the picture's edges instead of stopping short
of them, and two carousels lose small blocks of another color at their ends.

Still visible: a row seen only in the first view, or loaded only right below a header that sticks (where the hero's top
stays hidden after the first view), keeps what the first view showed, ends and all.

### A blank stretch taller than the view (2026-10-14, later)

Between a shop's grids, a blank stretch taller than the view went by as views of nothing but the page's color: nothing
to line up, so as far as the stitcher could tell nothing scrolled. The next grid then came in from below and lined up
with nothing either; with cards alike the views soon lined up with the grid before the stretch instead. The second grid
was laid over the end of the first, and after the second stretch the views never lined up again: the third grid was
missing, or, where the prices differed, its rows were written over the first grid's.

Now a view comes in past the stretch when all of this holds:

- the view last taken in reached the picture's end, and the picture ends in one color;
- a view since showed nothing but that color between the bars (unchanged under a header that stays put, lost without
  one);
- this view shows the stretch for at least a tenth of the view, down to something that came in below it with 16 lines
  that say something.

It follows as much of the stretch as the picture or the view showed, and every line from the old end is written. It is
tried before the view is looked for elsewhere in the picture, where the cards alike are found.

What something fixed on screen shows (a chat button) counts as blank only on the lines where the picture's end was
blank too. Above them the view last taken in showed the content before the stretch, and a pause shows that content
where it was. It never comes in past something a view since showed that could not be placed (a section that plays as
it is scrolled): that is not a blank stretch going by, and the capture stays lost as before.

| Check | Before | After |
| --- | --- | --- |
| A shop of three grids of cards alike, blank stretches of 2400 px between, 120 px steps | 20 views lost, the third grid missing (9674 rows of 22960) | none lost, all three in order (15684 rows), the stretches 570 and 592 px |
| The same, the prices differing | 13 jumps back: the third grid's rows written over the first's | all three in order |
| A made-up page of three blocks, stretches of 700 rows in a view of 300, 20 rows a step: with a header, without, with a button fixed in the corner | the second block not in the picture whole | each block whole and in order |
| The other 204 frame sets, and the six live captures | as committed | byte for byte |
| Frame sets heavy in views where nothing scrolled (the live sheet and verge captures; cnn and a made-up timeline under Auto-scroll), optimized, alternating, five runs each | 0.82–2.63 ms a frame | from 0.3% faster to 4.3% slower, the runs overlapping |
| 3500 × 2400 px views, optimized build, alternating, two runs each (a load average of 7 to 9) | 10.6–11.0 ms scrolling, 2.2–2.5 ms with only a video playing | 10.6–10.8 ms, 2.2 ms |
| 120 randomized forum walks | 0 rows off | 0 rows off |

Left as they are:

- The stretch comes out only as long as a view showed it, since no view can measure it.
- Auto-scroll stops once the capture stops growing, so it will likely stop inside a stretch taller than the view. It
  did, live, in a stretch of 1344 pt (below); its watch now pushes on through such a stretch first ("Auto-scroll's
  watch: a blank stretch, a capture behind").
- On a page without a bar that stays put, the views of the blank are still reported lost, so the panel asks to scroll
  back while they go by.
- A grid of cards alike with no blank between (made up) still skips 371 px where it lines up a row off.

### Views further on than the view reaches (2026-10-14, later still)

Made-up frame sets of a docs page and a thread jump further than a view between two views, as following an anchor,
pressing End, or dropping frames would. The stitcher took each jump at an offset where something the page repeats lined
up, with blank lines around it, while most of the view said otherwise or nothing: a sentence the docs page has twice, a
thread's reply links. Three things went wrong:

- what followed was written over what had been taken in;
- or it was added after it, with the jump's content missing;
- or, on the docs page with sidebars, the views were taken as unchanged and the picture stopped growing for good.

To find a rule, every verified candidate offset over the 183 frame sets with true offsets was labelled by the true move
since the reference view: 25,734 candidates, 24,395 picked, 980 of those wrong. Most of the wrong ones are pages whose
frames' offsets do not tell the content's move: an inner scroller, parallax, a fixed background.

No share of agreeing lines separates right from wrong on its own: a full-view video or a carousel leaves as little
agreeing as a jump does. What does separate them is the votes. A view where the best offset gets under an eighth of the
votes the last offset taken got (from at least 64) shows mostly something else. Among such views, right offsets had at
most a fifth as many lines against them as agreeing and saying something; wrong ones had at least as many.

Now two rules apply:

- In such a view, an offset with at least half as many lines against it as agreeing and saying something does not
  hold.
- A view found again in the picture, after lining up with nothing, needs at least half of its lines that say something
  to agree there. This does not apply where it was found where it was, or where it would have scrolled to.

| Check | Before | After |
| --- | --- | --- |
| A docs page with sidebars (MDN), jumps of 761, 899, 1036 and 1243 px in an 800 px view | taken at 14 and 152 px, written over at −1291, then views alike taken in at the wrong place | the picture as it was before the jump; the views after it lost, or unchanged where the sidebars outweigh the rest |
| A thread (Hacker News), a jump of 1064 px | taken at −465 px, what followed written over the picture: 340 rows off before the jump | 34 views lost, then picked up 6 px on, the jump's content missing, and what followed laid over the last rows before the jump: 241 rows off |
| Made up: down, on past the view, a few views, back up into what was taken in (two sets) | rows from far down the page among the first (1518 rows out of order) | the page in order |
| A made-up page with a heading it repeats, a jump of 1000 rows in a view of 300 (new tests) | written over what was taken in | lost, the picture byte for byte as before the jump |
| spacex.com under Auto-scroll | a view taken as 14 px on while the page stood still | left out, 14 rows shorter |
| The other frame sets | as committed | byte for byte, but a landing page's two sets (2 levels at most) and Atlassian's (14 rows at an animation's edge, no better or worse) |
| The six live captures | as committed | byte for byte |
| The live sheet and verge captures, cnn and a made-up timeline under Auto-scroll, a shop grid, optimized, alternating, five runs each | 0.84–5.43 ms a frame | within 1% |
| 120 randomized forum walks | 0 rows off | 0 rows off |

Tried and left out:

- Taking views as still only by the bands that moved with the content, between the bars, so sidebars could not keep a
  jumped view unchanged. It turned the views of blank stretches under a header, and of two made-up pages with sidebars,
  from unchanged into lost, the pictures the same: the panel would have asked to scroll back where nothing was wrong.
- Choosing among offsets that hold by how consistently their lines agree rather than by score. It picked worse on grids
  of cards alike: 113 of 150 right, against 130.

Left as they are:

- A jump with a small overlap, on a page that repeats a block, is still taken at the repeat: 385 px for a jump of 624
  in 800, both offsets lining up about as well, so what follows lies over 239 rows taken in before it.
- Views that line up again a few pixels from where the content would have scrolled to are taken there. After the
  thread's jump, the place where the repeated reply links line up drifted to 6 px from it, 34 views on. A landing page
  recovers the same way from its parallax hero, there exactly where expected and with as little of its view agreeing
  (a sixth), so the two cannot be told apart.
- On a page with sidebars, views after a jump are mostly taken as unchanged, so the panel does not say the views no
  longer line up; the picture keeps what came before the jump.
- A page whose background, a texture repeating every 480 px, stays fixed under its text still comes out wrong: now
  5400 px too long rather than 1080.

### The first scroll past a banner (2026-10-14, later still)

On MDN captured in steps of 200 CSS px (400 pixels at 2x), a promo banner sat above a header that sticks, with sidebars
that stick below it. The first step scrolled the banner away. The header and both sidebars moved only the banner's
height (182 pixels) and stuck, while the article moved the whole step.

Both offsets held. The sticky ones span five of the six bands the lines are hashed in: the header runs across all of
them, and a band counts as moving when a fifth of what testifies in it agrees. So 182 pixels outscored the article's
400, and the picture came out 218 pixels short of what the article had scrolled by (118 in the set with steps of 150
CSS px).

Now, with no last offset to go by (the first scroll), an offset that moved further the same way and holds at least half
as well wins. What sticks once a banner has gone moves only partway on the scroll that starts it, and a parallax picture
moves less than the page; the page itself moves furthest. After the first scroll the last offset decides, as before.

The rule was checked against the calibration rows of the jump work. Among first scrolls with two offsets holding (8
views), it changes only the three MDN ones, each to the true offset. The four grids' second offsets go the other way and
are left alone.

| Check | Before | After |
| --- | --- | --- |
| MDN, MDN dark and MDN with animations, steps of 200 / 200 / 150 CSS px | 18,982 / 16,982 / 13,182 rows; rows off against pictures rebuilt from the true offsets 13,849 / 12,263 / 9,753 | 19,200 / 17,200 / 13,300 rows, each the true length; 7,823 / 7,046 / 6,215 off (the rest is the rebuilt pictures not knowing what sticks) |
| A made-up docs page: a banner, a header, sparse columns either side of a dense article, 24 sizes and first steps | the sticky offset taken on 10 | taken on 1, where the article's offset was not voted for enough to be verified |
| The other 203 frame sets and the six live captures | as committed | byte for byte |
| 120 randomized forum walks | 0 rows off | 0 rows off |

The rule runs once a capture, on its first scroll, so the time a view takes is unchanged and was not measured.

Left as it is: on a page that repeats itself (a grid of cards alike), a first scroll could be taken a period further,
where the cards line up as well, if that offset gets half the votes. In the frame sets the grids' second offsets were
all the other way, so nothing here tried it.

Tried and left out: preferring, at any scroll, an offset better told every way (more lines agreeing, fewer against it,
and a share agreeing a tenth higher). It set five views right in the calibration rows, among them the MDN ones. On the
made-up docs page it took the sticky offset where the committed stitcher had the article's: the sidebars, dense there,
told better than the article.

### Views of a blank stretch, not lost (2026-10-14, later still)

On a page without a bar that stays put, views of nothing but a blank stretch taller than the view came out lost.
Nothing in them stayed where the view before had it, and nothing moved. After two of them the panel asked to scroll
back, and Auto-scroll stopped, though nothing was wrong. Under a header that stays put the same views were unchanged.

Now a view of nothing but the stretch, the one color the picture ends in, is unchanged wherever the stretch continues
after the view last taken in. Only the view where what comes next has begun to come in, too little of it to line up
with, is lost and waited out: one view, never two in a row.

| Check | Before | After |
| --- | --- | --- |
| The made-up page of two blank stretches, no header, scrolled 20 rows at a time | 22 views lost in a row, twice | unchanged, then one view lost each time |
| A made-up page of near-duplicate sections with blank stretches | 8 views lost | 8 unchanged, the picture byte for byte |
| The other 205 frame sets and the six live captures | as committed | byte for byte |

Auto-scroll now goes on through such a stretch as under a header, until its watch on how much the picture grows stops
it or moves its gesture.

### A carousel changing slide once while in view: tried, left as it is (2026-10-14, later still)

A made-up carousel 180 rows tall, its slide changing once while the views go past it 20 rows at a time, comes out the
first slide above the second (40 to 80 rows of the first). The views after the change show the carousel's upper lines
nearer the view's top, never clearer than the views before the change did. A line's out-of-date picture gives way to
what three views in a row show only where the first view took it. A new test keeps this as a known issue.

Two ways were tried and left out:

- Taking a block whole from the view where all of it changed at once, as what keeps changing is taken. It took the
  carousel whole only where the change was caught well inside the view, and left a segment at each end of the old
  slide. Caught near the view's foot, the carousel was no part of the lines compared, which end where the change
  begins.
- Letting any line's out-of-date picture give way, not only the first view's. Lines did give way, but never three
  margins of lines together in one view, as the rule asks: the upper lines turn out of date one view at a time as they
  near the top.

### A live run, and a pull beside columns that stick (2026-10-14, evening)

The Debug app, built at 01d2017, captured ten pages in a throwaway Chrome window (1100 × 813 pt in view, at 2×)
through the real coordinator and Auto-scroll:

| Page | Views | Picture |
| --- | --- | --- |
| A made-up article with a blank stretch of 894 pt, no header | none lost | the stretch kept as 1616 rows, what follows in order; stopped by itself at the end |
| The same, its header sticking | none lost | the stretch 1504 rows |
| The same, a stretch of 1344 pt | 37 lost at the end | ends inside the stretch: Auto-scroll's watch stopped it, as recorded above; the lost views came from the window's corners (below) |
| A made-up docs page, a banner above a header that sticks, columns either side | none lost; ruler.js continuous from 0 to 6129 pt | 12307 rows for a page of 12266: the pull at its end (below) |
| MDN, BBC News, The Verge | none lost | continuous to the eye |
| apple.com/iphone | none lost | stopped at 4680 rows of 33782 (below) |

Apple's page: Auto-scroll stopped after 5.4 s in both runs ("738 px pushed, 100 px got"). The page kept moving: its
scroll position, read in the page, followed every event, and the views summed to where it ended. As the lineup's large
pictures came into view the Debug build's stitcher took 235–464 ms a view for five views (9–15 ms optimized, the slowest
of the run), the stream dropped the frames between, and the picture did not grow while the watch looked, so it took the
page's end as reached. A Release build is some forty times faster on those views; left as it is.

A window streamed on its own, as these checks capture it, has its corners clear: a radius of 24 pt (48 px), more than
the 18 pt at each side left out of the hashes. Its frames' PNGs no longer replay byte for byte (the corners' pixels
change on the way, premultiplied), so replays are compared with those pixels left out. The corners also reach the
picture: a column that stays put at the area's edge keeps the first view's corner, a notch at that view's foot, and
corners changing while the views show nothing but a blank stretch make those views lost (the 37 above). Choosing a
window with Space passes its frame as the area, where the corners show what is behind the window. Left as it is then;
see "A window's rounded corners, and a contents list by the edge".

At the docs page's end Auto-scroll pushed on, and the browser pulled the whole view along a pixel or two a view, header
and columns too, then let it spring back. Past the article's end the views showed white, the columns' rules and a
button fixed on screen, which look the same moved or not: the part that scrolls ended where the article did, drawing
back from the view's end as far as the pull went, and never reached past the picture's end. The pull was not
recognized:

- the pulled views were taken in as scrolling, the header and columns where the pull moved them: a second header,
  navigation and contents column near the picture's end, and the navigation's thin strokes dashed;
- springing back, the views were taken in down to the view's end, 39 rows past the article's.

Now:

- A view creeping a few rows while driven is a pull also when its part that scrolls draws back from the view's end to
  within 18 pt of the picture's end, if what stayed put before the creep goes along: the part that scrolls starts nearer
  the view's start, or more of the line moves with the content. Slowly scrolling on through blank rows beside a rule
  looks just the same but for that (a news page did, halfway down).
- Such a view, or one springing back from such a pull, is only placed, for the next to line up with: nothing but what it
  shows past the picture's end is taken in, and the ends of the lines it shows as the content has them count as a still
  view's (an overlay knob gone as the pull began would stay otherwise).
- The spring back ends where the view was when the pull began, give or take 18 pt, rather than where the part that
  scrolls ends: beside the columns that is the content's end long before the content is back, and the last views,
  pulled a pixel still, wrote the columns a pixel off.

| Check | Before | After |
| --- | --- | --- |
| The live docs page, replayed | 12307 rows, a second header and navigation near the end, strokes dashed | 12268 rows, the columns once, as the first view showed them |
| The live docs page captured again with the new build | | the pull recognized ("pulled true"), Auto-scroll stopped by it; 12268 rows |
| A made-up page, columns with rules either side of the article and a button fixed near the foot, pulled 12 rows and sprung back | not taken as a pull; 9 rows past the end | a pull; the picture as before it |
| The live BBC capture, replayed | an overlay knob in its last rows | the knob left out; an animated advertisement's frame differs |
| The other nine live captures | as committed | byte for byte, but for 34 pixels of a window's corner in one last row |
| 206 frame sets | as committed | byte for byte but two: 872 pixels at a block's edge; a header seen near a news page's end, alike to the eye |
| Stitcher tests | 64, 7 known issues | 65, 7 known issues |
| 120 randomized forum walks | 0 rows off | 0 rows off |

Not timed: only views creeping while driven do more than before (they count their lines' ends).

Left as they are:

- With a header taken for a bar (three views alike), a pull is taken as nothing scrolled until a view has crept 4 rows
  past the one taken in, which is then taken in, 4 rows past the end (made up; as before).
- A first view taken while the page is still drawing (scrolled just before the capture began) left every later view
  lost, once, live.

### Telling the capture while frames keep coming (2026-10-14, night)

On MDN, scrolled to near its end just before the capture began, the page was still moving (a smooth scroll) when the
first frames came, and the Debug app took about 33 ms a view. The capture was told that Auto-scroll drives it right
after the first frame, but the stitcher only heard it once the frames stopped coming: after about 250 views with every
view dumped to disk, after about 50 without. Until then it took the views as scrolled by hand, so the pull at the page's
end went unrecognized (the views replayed with the message where it took effect give the live picture), and the
columns were taken in where the pull moved them. What the capture is told (the way Auto-scroll goes, whether it drives,
the pull let go of) went to the stream's queue as work behind the frames; how the stream schedules its frames on that
queue is not known here, only that the message waited for them.

Now each message goes into a list, in order, and the list is applied before the next frame is taken in, as well as when
the queue is free and before the picture and the summary are made. When nothing waits, this is as before.

| Check | Result |
| --- | --- |
| Capture tests (OMSCapture, 107) | pass, 7 known issues |
| The app | builds |
| MDN again, live | not run: the throwaway browser window was closed meanwhile |

Not seen in a Release build: there it would take views that take longer to take in than frames come (a busy machine,
very large views).

### Studio's cursor follows the pointer's speed (2026-10-14, night)

The cursor's spring had one time constant per project (0.02 + 0.13 × Smoothing s). Its time constant now falls
from that toward 0.02 s as the pointer's speed (its velocity averaged over 0.16 s) rises past 700 pt/s. Measured
on made-up telemetry (60 readings a second, the cursor drawn at 120 frames a second), against the old spring
computed alongside with the same step; nothing recorded or on screen. The flick's trail at its end and the two
jitter rows are the values `StudioMotionTests` asserts on (`aFastFlickTrailsHalfAsFarAsAFixedSpringWould`,
`slowShakyMotionIsCalmedAsMuchAsByAFixedSpring`); the rest were read from a throwaway test run once, built the
same way (the sweeps lasting 3 s, the jump a single 300 pt step at 1 s), and are not kept.

| Measurement (Smoothing 100%) | Fixed spring, 0.15 s | By speed |
| --- | --- | --- |
| A flick at 2500 pt/s for 0.4 s: how far the cursor trails the pointer at its end | 621 pt | 254 pt |
| The same, until the cursor is within 5 pt of where the pointer rests | 0.95 s after the flick | 0.31 s after |
| A steady sweep at 100 / 300 / 600 / 1200 pt/s: the trail | 30 / 89 / 177 / 355 pt | 26 / 65 / 106 / 158 pt |
| A drift at 40 pt/s, each reading 3 pt off by turns above and below: the cursor's frame-to-frame jitter (raw 3.000 pt) | 0.0033 pt | 0.0038 pt (1.15×) |
| The same, readings off by amounts scattered from −3 to 3 pt (raw 1.220 pt) | 0.0126 pt | 0.0139 pt (1.11×) |

- **A critically damped spring trails a steady sweep by twice its time constant of travel**, not once: the
  fixed 0.15 s spring is 0.3 s behind a pointer at constant speed (739 pt at 2500 pt/s). By speed it is 0.09 s
  behind at 2500 pt/s and 0.13 s at 1200.
- **The speed is read from the velocity as a vector, not as a number**: readings 3 pt off by turns above and
  below, in x and in y, move 6 pt in each between readings 1/60 s apart, which as a speed is about 510 pt/s,
  thirteen times the drift, and tried once that way left the jitter at 2.5× the fixed spring's (1.4× for the
  scattered readings); averaged as a velocity they cancel, and the 40 pt/s drift keeps about 95% of its
  smoothing.
- **The time constant grows again as the speed estimate decays after a stop**, so the spring is no longer
  exactly critically damped over the whole stop and the cursor passes where the pointer rests, by 0.36 pt
  after the 2500 pt/s flick at 100% and 0.01 pt at the default 50%. The fixed spring never passes it.
- **A jump in the pointer counts as speed**: a 300 pt step in one reading (a gap in the readings) leaves the
  cursor 141 pt short after 0.1 s and 19 pt after 0.3 s at 100%, where the fixed spring had 251 pt and 117 pt.

### Studio movie quality (2026-10-14, night)

Debug build, in `swift test` (`StudioExportTests`, and a sweep run by hand with the encoder's quality set to each
value), on made-up media and the real `StudioExporter`: a page of text (Helvetica 22 pt, 64 characters a line)
scrolling 480 px a second, written as the recorder writes (H.264, constant quality 0.6, real time, no
B-frames, a key frame every 2 s), 4 s of it; exported white around it, once with no frame (no padding, shadow, or
corners) and once with the default one. H.264 through VideoToolbox on this Mac, a rerun giving the same bytes. Nothing of the
user's was read, and real recordings will differ.

| Measurement | Result |
| --- | --- |
| Recording: 640×400 at 30 fps / 1280×800 at 60 fps | 253 KB / 416 KB |
| Export, no frame, 640×400 at 0.3 / 0.45 / 0.6 / 0.8 / 0.9 / 1.0 | 119 / 172 / 261 / 462 / 977 / 1,205 KB |
| Export, no frame, 1280×800 at 0.3 / 0.45 / 0.6 / 0.8 / 0.9 / 1.0 | 218 / 303 / 472 / 789 / 1,804 / 2,252 KB |
| Export, default frame (704×464), 640×400 at 0.45 / 0.6 / 0.8 | 204 / 285 / 496 KB |
| Against 0.6: 0.45 / 0.8 (both recordings) | 0.64–0.66× / 1.67–1.77× |
| Ten exports at 0.6 (five canvases at both sizes), against the estimate's model with Standard's factor at 1 | 1.00× on average (0.72–1.30×) |
| Exports at once at 0.6, default frame: one / two / three | 285 KB / 285 KB each / 687, 858, and 756 KB |

- **Quality is cheap to lose and dear to gain.** Smaller File (0.45) weighs two thirds of Standard (0.6) and Best
  Quality (0.8) seven tenths more; past 0.8 each step costs more than the last (0.9 is 3.7–3.8× Standard, 1.0 is
  4.6–4.8×), so 0.8 is where Best stops. `StudioExporter.sizeFactor` is these ratios: 0.65, 1, and 1.7.
- **The estimate is the recording's bytes times the share kept times the square root of the pixels the movie has
  for each of the recording's** (`StudioExporter.estimatedByteCount`). At the default frame it is 1.00× the movie
  at Standard, 0.91× at Smaller File, and 0.98× at Best Quality (`theEstimateIsCloseToTheMovieMadeAtEveryQuality`
  holds it within 25%). The square root over-estimates tall and square canvases (9:16 came out at 0.72–0.94× of it,
  1:1 at 0.88–0.97×) and under-estimates a 25% padding at 1280×800 (1.30×): the background costs less than a
  recording's pixels, though not nothing.
- **A short movie saves less than the share cut.** Two seconds of four cut away left 62% of the recording's bytes,
  not 50%: each kept stretch brings its own key frame. For recordings of minutes the share is what counts.
- **Noisy video and HEVC recordings are off, both ways.** A noisy 640×400 picture weighed 0.48× its recording at
  Standard, since the recorder's real-time encoder spends more on noise than the export's, and an H.264 export of
  an HEVC recording (any side past 4096, such as the built-in display) 1.48× against 1.14× for H.264 to H.264, so
  the estimate runs about twice high for the first and a quarter low for the second. The document knows neither
  the recording's codec nor what is in it, so neither is corrected.
- **A third encoder session at once makes far larger movies.** Alone or two at a time the same settings gave the
  same bytes every time; three at once (the test recording's own writer counts) gave 2.4–3× as many. It looks like
  the hardware encoder's two sessions running out and a software encoder taking over; that is not confirmed.
  `StudioExportTests` runs one test at a time for that.

### Auto-scroll's watch: a blank stretch, a capture behind (2026-10-14, night)

Auto-scroll's watch stopped it twice when nothing was at an end. In a blank stretch of 1344 pt, live, the view was all
blank, the stream sent nothing, and the picture could not grow until what follows came in. On apple.com in the Debug
app the capture fell behind the page ("738 px pushed, 100 px got"): views took 235–464 ms each, and the picture grew
later. Both look like the page's end on what the watch looked at: pushed on, and the picture not growing.

The watch is now `AutoScrollWatch` in OMSCapture, a value the coordinator tells how things stand four times a second,
and tests tell made-up looks. Its rule is as before: since it last pushed four tenths of the area (and at least 0.75 s
ago), the capture got less than 15% of that. Two exceptions:

- **A blank stretch.** The stitcher says when a view since the picture last grew showed nothing but the stretch
  (`isInBlank`), and the capture now reports that view. Before, it went unreported, as a view that changed nothing,
  though it is often the last frame the stream sends until the stretch ends. The watch then waits until three of the
  area's lengths were pushed since, and moves no gesture: the page itself was scrolling. That costs about 8.6 s at 1×
  on a page that ends in a blank margin taller than the view, where no pull shows either, the view being all blank.
  The elastic pull still stops it at once.
- **A capture behind.** The capture keeps how many views it took in, how long that took, and since when it has been
  taking in the one now. A look where the views took 50 ms or more each, or the one now has taken 150 ms so far, is not
  counted, three looks in a row at most. Release builds took 9–15 ms for the heaviest views seen, so this should come
  into play only in Debug builds, or for very large areas on a busy machine.

Left out: slowing Auto-scroll down while the capture is behind, as the design suggested. Even a view of 400 ms at the
top speed (2×, about 1140 px a second at 2×) lets the page move about 450 px between views, well inside a view of
1626 px, so the views still overlap. The panel's speed slider stays as the user set it.

| Check | Result |
| --- | --- |
| `AutoScrollWatchTests` (9): a page that keeps coming, one that stops, a stretch of 2.5 areas, one without end, a pull, a capture behind for 2 s and for good, a view under way, the gesture moved | pass |
| The same with the blank patience at 0, then no looks let off for being behind | 2, then 5 issues |
| The blank-stretch test, with and without a header and with a fixed button: `isInBlank` on from the first view of nothing but the stretch until the view past it, twice | pass |
| Capture tests (OMSCapture, 116) | pass, 7 known issues |
| The app | builds |
| Live | not run: it needs a browser window on screen |

The numbers (three areas, 50 ms, 150 ms, three looks) are first guesses: the slow capture was seen only in a Debug
build, and the blank stretch once.

### A window's rounded corners, and a contents list by the edge (2026-10-14, night)

A window chosen with Space is captured as its frame, and past its rounded corners shows what is behind it: the desktop,
still while the page scrolls (a window streamed on its own, as the checks stream it, has them clear). The picture keeps
the first view as it showed the columns that stay put, so the first view's lower corners stayed in it where that view
ended. The live frames of the docs page and MDN, laid over a still desktop and replayed, left one and two such notches
(rows 1579 to 1625 of the 1626-row view), and MDN a piece more near its end.

Now `ScreenCapturer.windowCorners` finds the window under the area's middle and, for each corner of the area within a
point of one of the window's, takes the corner's shape from the window captured on its own without its shadow: row by
row in from the edge, the pixels not wholly opaque, up to 64 pt. A corner that is square, or see-through further than
that (a translucent sidebar), is left out. The stitcher (`ScrollStitcher.corners`) fills each view's pixels past the
shape from the first pixel inside it in the same column, in its own copy of the view, after the copy and before the
hashes; the stream's buffers are never written to. Filling along the column, not the row: a column that stays put is
the same all the way down, so there the fill is exact, while along the row it would have written the page's color
over a scroll bar's track. The capture's steps record the shape (`corners …`), so replays fill as the capture did.

The fill changed one thing besides: on MDN, "Browser compatibility" in the contents list that sticks at the right came
out as "Browser compatib". The fill was not the cause. The same frames cut 48 rows short, as an area that misses the
corners is, came out the same. The clear corners had made the last 8 px column look still far enough down the view
(past a sixth of it) to count as staying put. That made the blank between the list and the view's edge stay put, and
the list's short words with it. Now a run of columns on to the line's end, past one that stays put, stays put too
when no view saw any of it move and what views saw still in it spans a sixth of the view. A first version without the
span stamped a round button fixed by the edge twice down the picture (9 of the 206 frame sets changed, 6 a little
worse against their pages); with it, all 206 come out byte for byte.

| Check | Result |
| --- | --- |
| The docs page and MDN over a still desktop, as committed | 1 and 2 notches of the desktop down the picture |
| The same with the corners filled | none; the same steps; byte for byte the pictures of the window-alone frames filled |
| The stitcher's fill against a prototype that filled the frames' PNGs, replayed by the same build | byte for byte, both pages, the window alone and over the desktop |
| MDN's contents list (dark pixels where "compatibility" is): as it was, the corners filled, the frames cut short | 782, 310, 310 before; 782 in all three now |
| The other 206 frame sets | byte for byte |
| 120 randomized forum walks | 0 rows off |
| `ViewCornersTests` (4): the shape from a window's alpha, a see-through edge, the shape read back, a view turned filled as it is straight | pass |
| A made-up page with a track at its edge, the desktop in each view's corners | rows of the desktop in the picture without the fill; none with it |
| Capture tests (OMSCapture, 121) | pass, 7 known issues |
| The app | builds |
| Starting a capture whose area shares a corner with a window | one more look at the shareable content and one screenshot of the window alone: not timed |
| Live | not run: measuring the window's corners is the one part nothing offline runs |

The 37 views lost in the blank stretch of 1344 pt (above) came from the corners changing while the views showed nothing
but the stretch; filled, they should no longer be. Expected, not checked: that run's frames were not kept.

### Live runs with the corners, and Auto-scroll's watch again (2026-10-14, late night)

The Debug app at 8887453 and after, through the whole flow (`scroll-e2e-flow`: the real coordinator, Auto-scroll and
panel) on a throwaway Chrome window, 1100 × 813 pt in view at 2×. Every run measured the window's corners from its own
picture, the call a window chosen with Space makes (bottom corners 48 rows, as the frames' alpha has them), and every
picture came out without a clear pixel.

| Run | What happened | Cause, and what changed |
| --- | --- | --- |
| The 1344 pt blank stretch, first | stopped inside the stretch, 8064 rows | two views in a row lost where the next block began: a line of it at the view's foot, the page standing still a frame while the scroll bar's knob was redrawn. Now a view of the stretch and a line or two of what follows is unchanged, as one of the stretch alone is (`aLineOrTwoOfWhatFollowsTheStretchIsWaitedOutHoweverManyViewsShowIt`; the run's frames replay with none lost) |
| The same, second | stopped by the watch before the stretch, 6736 rows | no frame for 1.1 s, then the page 676 px on at once: the page stood still drawing (the Debug app writing every view as PNG beside it). Now the first look that sees little is only quiet, and the watch looks once more afresh before it stops; the pull still stops it at once |
| The same, third | stopped by the watch twice over, 6464 rows | the capture had taken views 20 px apart all along (its replay grows steadily), but the watch read how far it got from the reports on the main actor, and saw nothing come for 1.3 s. Why those came late is not established. Now the watch reads the capture as it stands (`ScrollingCapture.Load`: how far it got, pulled, in a blank stretch), and a report more than 0.5 s late is logged |
| The same, fourth | through to the end: 15817 rows, the stretch kept as 1618 rows, what follows in order, stopped by the pull | no report came late; one quiet look as the stretch ended moved the gesture once, to no harm |
| The docs page with a banner | 12062 rows for a page of 12062, its ruler unbroken from 0 to 6022, stopped by the pull | |
| MDN, scrolled 2500 px from its end before the capture | "driven" told before the second view (after about 250 before the mailbox), the pull seen and stopped by, 6627 rows, the contents list whole; the run's frames replay to the live picture pixel for pixel | |

A review of the two commits by three agents (two reading, one trying to refute) found two things, both checked: a
capture behind was let off though the pull already showed the end (now the pull wins:
`pulledPastTheEndStopsAtOnceThoughTheCaptureIsBehind`), and the end-to-end check measured the corners on the area
before it was cut to its display.

The checks themselves: the flow's steps now carry when each view was taken in, and how long writing the views held
the capture up. The end-to-end check over the screen (not the window alone), and its real Auto-scroll, which addresses
whatever is under the area's middle, now run only with the check's own window in front there: a run with the user's
own browser in front started nothing only because no frame came.

Not run: a window chosen with Space over the real desktop. The user's own windows were in front of the check's.

Left as it is: on MDN the contents list's heading ("In this article") loses its lowest 7 rows, as the stitcher before
this round did too. The heading sits just under the header that sticks; its upper rows are the first view's, and the
rows below are written from the second view as lines it agrees on, which there show the blank above the list where it
stuck.

| Check | Result |
| --- | --- |
| The 206 frame sets | byte for byte |
| 120 randomized forum walks | 0 rows off |
| Capture tests (OMSCapture, 124), Studio (55) | pass, 7 known issues |

### Into a blank stretch, and out of it (2026-10-15)

Run again with the commit above, the blank stretch page stopped short once more: the two views as the stretch began
showed only the last 4 rows of the picture before it, at the top, and the stretch below, the page standing still a
frame between them. Those rows line up with the view before 20 px on, but 4 rows are too few to trust (a match needs
162 in a view of 1626), so both views were lost, and two lost in a row stop Auto-scroll. Now a view whose part that
scrolls shows a few of the reference's own lines at its start, fewer than a match needs, and the color the picture
ends in from there on is unchanged, the stretch begun (`theLastLinesOfTheBlockBeforeTheStretchLeavingAreNothingLost`;
the run's frames replay with none lost).

And as the stretch ended, Auto-scroll's watch moved the gesture once in every run: the first views placed past the
stretch ended "in a blank stretch", so its patience ended, but the look still reached back over the push through the
stretch, where nothing could grow. Out of a blank stretch the watch now looks afresh (`outOfABlankStretchTheWatchLooksAfresh`).

| Run | Result |
| --- | --- |
| The blank stretch page, twice with the first change | through to the end, stopped by the pull, none lost; the gesture moved once each as the stretch ended |
| The same with both | through to the end (15817 rows), stopped by the pull, none lost, no gesture moved |
| BBC News | 12520 rows, stopped by the pull at its foot, none lost, no clear pixel |
| The 206 frame sets | byte for byte |
| 120 randomized forum walks | 0 rows off |
| Capture tests (OMSCapture, 126) | pass, 7 known issues |


## M5 — Capture History search (2026-10-15)

Same machine and displays. Every screenshot's text is read for the history's search by the text reader, a tool
inside the app (`OhMyShot Text Reader`, Contents/MacOS) that the app runs while there is something to read and
that exits when it is done, so that what Vision keeps after a recognition (M2: 61–70 MB after Capture Text, 110–125
after the OCR panel) is never the menu bar app's. The app's own numbers are a Debug build's, fresh launch; the
reader's are the Release reader over the 130 screenshots then in the Debug app's history (timings and sizes only:
nothing they show was read out).

| Measurement | Result | Target |
| --- | --- | --- |
| Idle after launch | 23 MB | < 30 MB |
| A capture read for search, a few seconds after it is kept (background priority) | 0.7 s; the app 23 MB before and after | the app unchanged |
| Idle 60 s after it | 0.00% CPU (one 0.1% second), 0 wakeups, 23 MB, no live resources | 0.0%, < 60, < 60 MB |
| Reading the whole history, 130 screenshots, at utility priority (History open) | 76.5 s: median 394 ms, p90 1.2 s, slowest 3.2 s (a scrolling capture 3346 × 16811) | — |
| The same at background priority (after captures) | 253 s: median 1.27 s, p90 4.4 s | — |
| The reader's footprint while it reads | 340–720 MB through the run, never climbing; all of it gone when it exits | gone after use |
| The OCR panel (`ocr.analyze`, warm) while the reader runs | 749–776 ms (618–675 alone); nothing stalls with four accurate requests in two processes | no stall |
| The history's text, all 133 captures / the largest | 95,779 characters (129 KB) / 3606 | — |
| Searching | instant: a unit test searches 300 texts of 23,000 characters in well under its 0.5 s bound (Debug) | as typed |
| History window open, 133 captures, no search / 15 s after closing it | 104 / 103 MB (live heap 22 MB) | < 60 MB after use |

### Findings

- **Reading in the app would have cost the app's footprint for good; reading beside it costs nothing that stays.**
  The app stays at 23 MB across a capture read for search, with no wakeup after. The reader is a 1.7 MB tool with
  the L1 pipeline linked in, signed with the app's team and hardened runtime, embedded by XcodeGen.
- **One Vision request over a large picture loses text** (Docs/ocr.md › Large pictures, in bands): bands 2048 tall
  across the width read up to sixty times more of a tall capture (the 8–14% first counted for a 4K screen was
  mostly lines read twice; placed and merged, 0.1–0.6%), and the slowest pictures went from 10–15 s to about 2 s.
  The reader reads in bands, and so do Capture Text, the OCR panel, and Translate Area since the next section.
- **Background priority is three times slower** than utility for the same reading (E cores); a capture or two is
  read in a second or so either way. Only the first History window after many captures waits on a backfill, and it
  says how many are left; opening it stops a reading going at background priority and goes on at utility, keeping
  what was read. Re-read with bands, the history's text went from 95,779 to 109,172 characters (some of the gain is
  lines read twice where bands overlap).
- **The History window leaves the allocator's freed pages dirty** (found here, not new): with 133 captures its
  thumbnails take the app from 23 to 104 MB, and 103 MB stays after it closes, though only 22 MB is live (`vmmap`:
  the default zone 50 MB resident for 22 MB allocated, 20 MB of empty large blocks). Searching adds about 1 MB
  while the window is open. Decoding the thumbnails off the heap (as GIFMaker's `PageBuffer` did for M4) was the
  next thing to try; what it came to, and a second cause, are in M5 — Capture History memory, next.

## M5 — Capture History memory (2026-10-15)

Same machine and displays, Debug build. Measured in an isolated build of the same code, with a bundle identifier
of its own so that another session's Dev app could be neither quit nor driven by these runs, over a clone of the
Dev history: 133 captures, 120 of them screenshots (PNGs up to 3346 × 16811, ten of them over 12 million pixels).
Each round opens the window, steps down through every card with the arrow keys (the grid is lazy: only the cards
shown are made), closes it, and takes `footprint` at 3 s and 15 s after; rounds follow one another in one
process. "Before" is the committed code in the Dev app with the real history.

| Measurement | Before | After | Target |
| --- | --- | --- | --- |
| Idle after launch | 23 MB | 23 MB | < 30 MB |
| History open, at the top | 106–113 MB | 55–60 MB | — |
| 15 s after closing it (no scrolling) | 89–103 MB | 49 / 53 / 53 MB (rounds 1–3) | < 60 MB |
| History open, every card shown | 262–269 MB (peak 271 MB) | 107–112 MB (peak 112 MB) | — |
| 15 s after closing it, every card shown | 133 MB or 262–266 MB, the window kept in 4 closes of 5 | 52–57 MB, six rounds in two processes | < 60 MB |
| Idle 60 s after (`Scripts/power-sample.sh`) | — | 0.00% CPU, 0 wakeups, 52 MB, no live resources | 0.0%, < 60, < 60 MB |

The thumbnails alone, the 120 screenshots made by a standalone tool (sizes and timings only: nothing in them was
looked at), then released; the process starts at 3 MB. Serial / three at once / eight at once, all from a Release
build of the tool except the last row's times, which are from a Debug build (4.6 / 1.6 s in Release; its Debug
peaks are 11 / 13 MB):

| Way of making a card's thumbnail | Peak footprint | Left after release | Time (serial / 3 at once) |
| --- | --- | --- | --- |
| ImageIO's thumbnail call (before) | 52 / 81 / — MB | 41 / 65 / 95 MB | 4.6 / 1.5 s |
| Decoding the picture, then drawing it | 225 / 386 / 891 MB | 6 / 9 / 12 MB | 4.1 / 1.4 s |
| Reading the PNG's rows (now) | 11 / 14 / 22 MB | 3 / 5 / 12 MB | 5.0 / 1.7 s |

Against ImageIO's, the new thumbnails' gradient (a sharpness measure) is 1.00 at the median, 0.95 at the 10th
percentile and 0.87 at worst (1.12 at best), their mean difference 1.3 of 255 (3.0 at p90, 6.0 at most), and 19 of
the 120 are a pixel off in one side. A drawn page of text 3346 × 16811 gave the same thumbnail to the eye, in 0.05 s
against 0.26 s.

### Findings

- **The closed window was not let go** (found here, not new): the model, 19 cards' views and 224 images were still
  alive 15 s and more after the close in 4 of 5 runs of the committed code, so what was loaded stayed (262–266 MB, not the
  allocator's doing). A window whose root view is a single `Text` also stayed, and the retention was not found:
  the model was held by SwiftUI's key-handler cache for the grid (`FocusBridge`), the window by something in
  AppKit. Emptying the root view when it closes was not reliable (the model stayed alive on later rounds, done in a
  task or in the close itself); clearing `model.thumbnails` and removing the window's content
  view in the same call freed the memory in every round since. The window now closes without its fade, as it
  would show empty while it faded (unseen: judge it by eye).
- **ImageIO's thumbnail call leaves its working blocks dirty**: 41 MB serial and 95 MB at eight at once, 15 s
  later, and `malloc_zone_pressure_relief` (which `onClose` already calls) returns none of it, as in M4.
- **Drawing the decoded picture takes the heap out of it and the footprint up**: the pixels are mapped pages given
  back at once, but all of them are there at the peak, 225 MB for the long scrolling capture and 891 MB for eight
  at once. Tried and dropped.
- **Reading the PNG's rows** (`OMSPixels`, `PNGThumbnail`): the rows the card shows are inflated one at a time and
  averaged down, so the peak is a few rows and nothing is left behind, and a long capture is read only as far as
  its card shows. It reads the PNGs the app writes (8 bits, RGBA or RGB, one pass, an iCCP profile or sRGB, all 122
  in the history) and leaves anything else to ImageIO. Unoptimized Swift took 357 s over the 120 screenshots in a
  Debug build, so the target is built with `-O` always (`unsafeFlags` in the package, a local one: 5.0 s, as Release;
  the Xcode Debug build passes `-O` after `-Onone` for it).
- **What is left, 52–57 MB, is mostly what any SwiftUI window leaves** (M0: Settings alone takes the app from 23 to
  41 MB; with no thumbnails at all the History window left 49 MB). The window object may also be kept after it
  closes, empty. The other windows built the same way (Settings, the OCR panel, the editor, Studio) were not
  checked for the same retention.
- **Not looked at**: one close, with the text reader running (`helperProcess` in `debug/resources`), left the app at
  116 MB 15 s later (24 MB in Foundation, 24 MB of large blocks); the reader was not part of these runs otherwise.

## M5 — Large selections in bands (2026-10-15)

Same machine. `VisionPipeline.recognize` reads an image more than 2560 pixels tall (or very wide) in overlapping
pieces and puts the lines back together in the whole image's coordinates, so Capture Text, the OCR panel, and
Translate Area get per-line boxes for highlighting and copy as before (Docs/ocr.md › Large selections in bands).
Release build of the pipeline, warm, over the 18 captures in this Mac's Capture History that are that large
(timings and character counts only; nothing they show was read out):

| Measurement | Result | Target |
| --- | --- | --- |
| Characters read, all 18 | 26,731 (15,563 whole) | no loss |
| `recognize`, summed over the 18 | 27.3 s (43.3 s whole) | not slower |
| The three captures that took 10–15 s whole | 2.1–2.3 s | — |
| `analyze` (the panel), summed | 33.4 s (49.7 s whole) | not slower |
| Four screens 2573–2672 tall | +170–330 ms each, +0.1–0.6% characters | — |
| A sideways scrolling capture 10989 × 2880 | 3.2 s, 1372 characters (0.53 s, 567 whole); 7 cut lines read whole in one extra request | — |
| Benchmark, 27 cases and 12 real crops (one piece each) | text and scores byte-identical to before; p50 184–205 ms against 184–190, p95 348–406 against 365–373 (four runs against three) | no regression |
| The benchmark's new `tall-page` (1128 × 5950) | content CER 1.2%, line order 0.90 (23.1% and 0.31 whole) | — |
| Peak resident size of the harness, image decoded: 3346 × 16811 / 3700 × 8000 / the sideways capture | 1286 / 604 / 1607 MB (2561 / 984 / 1417 whole) | — |
| A drawn ultrawide page of 55 long lines, 5120 × 1440 / 10240 × 2880 | 55 lines, 99.9% of the text, 3.5 s / 7.3 s (whole: 65 / 68 lines, 62% / 85%, 1.9 s / 2.9 s) | — |
| Unit tests | `PieceMergeTests` (14), `BandedReadingTests` (3, with Vision); the whole package passes | pass |

### Findings

- **Banding is faster as well as better on anything tall**, because Vision's time over a large picture grows far
  faster than its area: 10–15 s whole against 2 s in bands for the three worst. It costs 0.25–0.45 s per band, so
  a picture just over the threshold (2573–2672 tall) pays 170–330 ms for little; cut to 2600–3600 pixels, five
  tall captures read +19% to +66% more on 11 of 20 crops and never meaningfully less (−2% at worst), so the
  threshold stays where the history reader put it.
- **Ownership by position beats comparing text.** Each piece answers for itself less half the overlap; a line cut by
  a piece's edge lies in the neighbour's core, whole, and the cut reading is dropped. Comparing text would keep
  every cut fragment and every line the two pieces read differently (the Latin-or-Chinese choice is made per piece).
  No line a piece read was left with nothing in its place.
- **A column cut splits a line, unless it is read again.** A line across a whole 256-pixel overlap is cut in both
  columns (8 of the sideways capture's 99 lines; most lines of a dense ultrawide page). They are stacked in strips
  of at most 2048 pixels and read whole, a request per strip: 0.4 s on the sideways capture, 1.6 s on a drawn
  5120 × 1440 page. One strip for all of them failed at 2× (Vision shrank it and nothing came back whole).
- **Tables and codes stay on the whole image.** A table taller than the overlap would be cut in two (the panel's
  281-cell table 7182 pixels tall came back as 93 and 70 cells from the bands), and the bands found small tables
  the whole image missed, so a union is open. The cells' text takes the bands' lines.
- **The history reader takes the merged text** (`PictureText.read` is now `recognize(image).text`, so it reads in
  pieces once, through the same code): over the 120 pictures in the Debug app's History, 91,969 characters in 73.6 s
  against 94,715 in 67.9 s for the per-piece text joined; the 3% are lines read twice in the overlaps (largest text
  3606 characters either way).
- **Vision's document request stalled for 17–29 s four times** in the first sweeps (3710 × 9875 whole twice,
  2173 × 4242 once, and the bands of 3499 × 8440 once), against 0.2–0.7 s when it ran normally and on every rerun;
  the app's 30 s timeout then returns no tables without an error. Other processes using Vision at the time cannot
  be ruled out.

## M5 — power gate (2026-10-17)

Debug build of `ba3234b` with this gate's changes, the same machine and displays, a fresh launch. Every step ran
through the app's own hidden demos (behind the desktop picture, or made up in memory), so nothing of the user's
was read, shown, or copied: a scrolling capture of the demo window through the coordinator (`debug/scroll-flow`),
a long one made up in memory, 3346 × 17650 from 137 views (`debug/scroll-long`), a drawn page added to the history,
read for search by the text reader and found in English and Chinese, then removed (`history-add`,
`history-search`, `history-remove-tests`), All-In-One's bars (`allinone-render`), each display's desktop picture
as window backgrounds take it (`wallpaper-check`), and the Shortcuts action Recognize Text in Image on a drawn page
(`shortcut-recognize`); then 30 s of nothing before a 60 s `Scripts/power-sample.sh`. Footprints are taken a few
seconds after each step, before and after an event of the app's own (`debug/end-event-wait`, below); the table
gives the first.

| Measurement | Result | Target |
| --- | --- | --- |
| Idle after launch, 60 s | 0.00% CPU, 0 wakeups, 24 MB | 0.0%, < 60, < 30 MB |
| Footprint after each step: scrolling capture / long scrolling capture / read for search / All-In-One / desktop picture / Recognize Text | 72 / 99 / 59 / 63 / 63 / 119 MB | — |
| The long scrolling capture: stitching (Debug) / highest footprint | 20.3 s (0.15 s a view) / 505 MB | — |
| The text reader, reading the page for search | 252 MB at most, in its own process, gone when it exits | gone after use |
| Idle after the tour, 60 s | 0.00% CPU, 0 wakeups, 119 MB | 0.0%, < 60, < 60 MB |
| Live resources and the app's own processes after the tour | none | none when idle |
| Live heap after the tour | 22.7 MB of the default zone's 86.5 MB dirty | — |

The Dev app this gate replaced had been in the user's own use for 6.5 hours (the morning's live checks of M5:
Settings, History, captures). It stood idle at 101 MB with no live resources.

The idle targets hold, and the app is idle after use: no CPU, no wakeups, nothing live, no helper still running.
The footprint after use is over its budget, 119 MB against 60, and in-process reading for the Shortcuts action is
the largest part of it. Without that step this run would have ended at 63 MB, still over the budget. That is one
run, in a footprint that swung by 40 MB between steps.

- **The Shortcuts action reads text in the app's own process.** It added 56 MB (63 → 119), and Vision's models
  stay loaded after it (Espresso's and E5RT's objects still alive). This is M2's cost of reading in the app
  (Capture Text leaves the app at 61–70 MB). The history's search reads in the text reader instead, so the app did
  not grow on that step.
- **The rest is the allocator's.** After the tour only 22.7 MB of the default zone's 86.5 MB dirty is allocated
  (41.6 MB of it in small-block regions with nothing in them), and 25.4 MB sits in empty large blocks, as after the
  scrolling picture's PNG in M5 — Scrolling capture. `malloc_zone_pressure_relief` returned none of it (101 MB
  before and after it, after the long capture). With nothing in use, the footprint rose and fell by tens of
  megabytes between steps as the allocator reused or let go of what it keeps: 99 → 59 MB over the read for
  search here; 116 → 71 MB at the desktop picture in an earlier run.
- **A closed editor stayed whole until the app's next event** (found here, not new). Ten seconds after the editor
  closed, its session, canvas, view model, and content view were still alive; only the window controller had gone.
  `leaks` traced them to the window through the application's current event (the last event the app took, here
  one that went to the editor's window) and through stale dispatch continuations. In scripted runs the app is
  never active, so nothing came until a later hook showed a window; in use, it would be the next click or key
  press, though that was not checked in use (a click in another app deactivates the app, which is an event
  too). `MemoryRelief.endEventWait()` now posts an event of the app's own once an editor has
  been let go. None of the editor was alive 10 s after the close in every run since. With the demo editor, the
  app went 24 → 98 MB open → 72 MB closed; before the fix it was 128 MB open → 156 MB closed. Part of what stays
  is the demo's own: the drawn page is made with Core Image, and reading it on the CPU leaves about 30 MB that a
  real capture would not (M3). For every other step the event changed nothing (72 → 70 MB after the scrolling
  capture, the same elsewhere): it is not why the footprint stays up.
- **A capture on the clipboard kept a full-size TIFF in the app** (found here, not new). One of the user's own
  captures, 2694 × 2385, was on the clipboard during a run. Once an app had asked for TIFF, a 24.5 MB region of
  the app held it: the uncompressed TIFF, 25.7 MB, kept by the pasteboard item for as long as the capture stays on
  the clipboard. At `largestTIFF` (24 million pixels) it would be 96 MB. The lazy TIFF is now LZW-compressed. On
  pictures the app drew itself:

  | Picture | Uncompressed TIFF | LZW |
  | --- | --- | --- |
  | 1280 × 6474 scrolled page | 32.4 MB in 33 ms | 3.1 MB in 127 ms |
  | 1840 × 1396 editor render | 10.0 MB in 14 ms | 1.2 MB in 49 ms |
  | 2000 × 1240 All-In-One render | 9.7 MB in 5 ms | 134 KB in 30 ms |
  | 6880 × 2880 drawn interface, PNG decoding included | 79.3 MB in 70 ms | 1.7 MB in 305 ms |
  | 6880 × 2880 drawn gradients with noise (photo-like), PNG decoding included | 79.3 MB in 152 ms | 30.0 MB in 770 ms |

  The price is time on the main thread, where the TIFF is made when an app asks for it. A clipboard manager asks
  right after a copy, while the card comes in. For a full 6880 × 2880 display that is 0.3 s for an interface and
  0.8 s for a photo-like capture, against 0.07–0.15 s uncompressed. PackBits was faster (19 ms) but kept 9.0 of
  the editor render's 10.0 MB. Deflate made the interface smaller (0.7 MB in 234 ms) but took 2.2 s and 50.7 MB
  on the photo-like one. The compression and the picture's colors are checked by a test. The app itself was not
  measured with it, as that takes the real clipboard.
- **The scrolling demo kept its page after it closed** (the debug demo only). AppKit kept the closed demo window,
  and with it the page's picture: 31 MB of image and a 33 MB copy in its layer. This left 134 MB after the
  scrolling capture. The demo now lets the picture go when it closes: 72 MB.
- **Three of the four runs had the user's own use in them.** The Dev app is now the user's screenshot tool, and
  the log showed a Capture Area, a Capture Text, and the 2694 × 2385 capture above (pasted) during them. The
  numbers above are from the fourth run, checked against the log: no hotkey, overlay, or capture between its
  start and its end. Measuring in an isolated build (M5 — Capture History memory) would avoid this, but such a
  build has no Screen Recording grant of its own, so it cannot capture.

Not part of this gate, because each shows something on screen, reads the user's own data, or needs a setup this
session does not have: uploads (the local storage servers belonged to an earlier session's scratchpad, and an
upload adds a record to the user's upload list), the History window (M5 — Capture History memory: 52–57 MB after
it closes), printing (the panel shows the real printer), the Share extension (off until the user turns it on),
Open With (opens a window and adds to the history), All-In-One in a live overlay, and Quick Access cards. The
design gate and the macOS 26 smoke test were not run either.

## M6 — Model pack downloads (2026-10-17)

Debug build, the same machine, a fresh launch. A made-up 25 MB pack was served from this Mac at full speed
(`Tools/model-packs/lab-server.py`), downloaded with `debug/modelpack-act` with Settings closed, then removed
(Docs/ocr.md › Model packs). No hotkey, overlay, or capture showed in the log during the run.

| Measurement | Result | Target |
| --- | --- | --- |
| Idle after launch, 60 s | 0.00% CPU, 0 wakeups, 24 MB (as before the packs) | 0.0%, < 60, < 30 MB |
| Footprint after the download | 39 MB | — |
| Idle after it, 60 s | 0.00% CPU, 0 wakeups, 39 MB, no live resources | 0.0%, < 60, < 60 MB |

- **Nothing at launch.** The center is made when Settings or a hook first asks for it. It reads the disk only
  when the Tools pane appears.
- **The 15 MB a first download leaves** (24 → 39 MB) was not looked into: it is the first use of the network
  stack in the process, plus whatever the allocator keeps.

## M6 — Recognize Text in Image, read beside the app (2026-10-17)

Debug build, a fresh launch, `debug/shortcut-recognize` (the Shortcuts action on a drawn page, nothing shown or
copied). The action now hands the picture to the text reader (`TextReaderTool`) instead of reading it in the app.

| Measurement | Before (M5 — power gate) | Now |
| --- | --- | --- |
| The app's footprint across the action | +56 MB, kept (63 → 119 MB) | 24 → 31 MB |
| The text read | 401 characters, 23 lines | the same |
| The text reader | — | 252 MB at most, in its own process, gone when it exits |

## M6 — L2 beside L1 in the text reader (2026-10-17)

The text reader with the PP-OCRv6 small pack (Docs/ocr.md › L2 beside L1), run from the shell, Debug build, a new
process each run, the pack's models already compiled. Nothing in the app changes: the panel's Vision reading stays
where it was, and the pack is read only in the text reader, which exits.

| Picture | Vision alone | The pack alone (the OCR panel's second reading) | Vision with the pack (the history's reading) |
| --- | --- | --- | --- |
| Full-screen captures, 2000–4112 wide (10) | 0.6–1.4 s, 283–405 MB | 0.95–2.52 s, 494–810 MB | 1.5–4.1 s, 655–944 MB |
| The tallest capture in the history, 3346 × 16811 | 3.3 s, 589 MB | 4.8 s, 1009 MB | 7.4 s, 1236 MB |

- **The footprint is the recognizer's,** kept by Core ML for each of its enumerated widths a run has used: 13 MB at
  160 wide, 257 MB at 4000, 1.1–1.5 GB with all twelve. It is no leak, and nothing in the reader's code moved it
  (Docs/ocr.md › L2 beside L1). Pack v2 cuts it (› M6 — The recognizer's head on the CPU, below).
- **Reading the history again after an install** keeps one reader of about 1 GB for as long as it has captures to
  read, at background priority.
- **Release** read the pack alone 0.97–2.23 s on six of the captures, about a tenth faster: the time is the Neural
  Engine's.
- **In the Dev app** (Docs/ocr.md › L2 beside L1 › In the Dev app):

  | Step | Time | The reader at most | The app |
  | --- | --- | --- | --- |
  | Download from Hugging Face, 15.8 MB | 18 s | — | 24 MB |
  | Warming the installed pack | 10.9 s | 24 MB | — |
  | Reading 46 captures again, background priority | 4 min 31 s | 1073 MB | 26 MB after |
  | Reading 43 again, utility priority | 96 s | 1494 MB | — |
  | Five test pictures, read and read again | 39 s and 15 s | 860 and 1111 MB | 24 → 30 MB |
  | The OCR panel's second reading, four pictures | 0.35–2.69 s | 381–674 MB | 150 MB after four panels (one panel left 110–125 MB in M2) |

- **For the M6 power gate:** idle numbers with a pack installed are not measured yet.

## M6 — The recognizer's head on the CPU (pack v2, 2026-10-17)

Pack version 2 applies the recognizer's last layer in Accelerate instead of on the Neural Engine (Docs/ocr.md › The
recognizer's head on the CPU). It was measured against version 1 in the text reader, built from the shell with
SwiftPM in Debug from the same code for both packs. Each reading ran in a new process, the models already compiled,
with the peak from `/usr/bin/time -l`. Version 2 is published and listed in the catalog. The app reads it once it
has been downloaded again in Settings (Docs/ocr.md › The recognizer's head on the CPU › Published).

| Picture | The pack alone (the OCR panel's second reading) | Vision with the pack (the history's reading) |
| --- | --- | --- |
| Full-screen captures, 2000–4112 wide (10) | 464–724 → 174–327 MB, 1.1–2.9 → 1.0–2.3 s | 640–931 → 394–611 MB, 1.7–4.6 → 1.6–3.8 s |
| Of them, the four 4K ones | 636–724 → 324–327 MB | 816–931 → 603–611 MB |
| The tallest capture in the history, 3346 × 16811, four runs | 982–1014 → 806–808 MB, 4.9–5.6 → 4.4–4.7 s | 1145–1232 → 925–981 MB, 7.5–8.4 → 7.1–7.7 s |
| All 11 in one process (the history read again) | — | 1236 → 1066 MB, 35.9 → 32.1 s |

| Warm, one process, the full-screen captures three times | p50 | p95 |
| --- | --- | --- |
| The pack alone | 1.63 → 1.39 s | 2.99 → 2.28 s |
| Vision with the pack | 2.49 → 2.15 s | 4.22 → 3.72 s |
| `ocr-bench`, L2 alone, per case (Release) | 126 → 113 ms | 933 → 766 ms |
| `ocr-bench`, L1 with L2, per case (Release) | 306 → 294 ms | 822 → 778 ms |

- **The same text:** the reader's answers were byte for byte the same with both packs. `ocr-bench`'s mean content CER
  stayed at 1.48% with no case worse (Docs/ocr.md).
- **Full-screen captures** lose most of what Core ML kept for the recognizer's widths: the pack alone now needs no
  more than Vision alone did (283–405 MB in › M6 — L2 beside L1 in the text reader, the app's own build).
- **Tall captures** keep more. On the tallest, decoding the picture peaks at 266 MB by itself, and detection's
  footprint climbs with each of its ten pieces, from 280 to 510–640 MB. Version 2 changes only the recognizer.
- **The head's weights:** the reader holds them as 9 MB of 32-bit floats. Warming peaked at 47 MB, against 22 MB with
  version 1.

## M6 — The L2 reader on tall pictures (2026-10-17)

With pack version 2, two things in `PPOCRReader` made the footprint climb with each piece of a tall picture: drawing
each piece from `image.cropping(to:)`, and the detector's map, given no array of the reader's to write into. Each
piece is now drawn from the whole picture, and the detector writes into an output backing (Docs/ocr.md › Tall
pictures in the L2 reader). The text reader was measured before and after, built from the shell with SwiftPM in Debug,
pack version 2 for both. Each reading ran in a new process, with the peak from `/usr/bin/time -l`. "Before" is the
v2 session's code; "after" changes only `PPOCRPixels.swift` and `PPOCRReader.swift`.

| Picture | The pack alone (the OCR panel's second reading) | Vision with the pack (the history's reading) |
| --- | --- | --- |
| The tallest capture in the history, 3346 × 16811, three runs | 807–812 → 475–480 MB | 940–963 → 750–763 MB |
| Full-screen captures, 2000–4112 wide (10), one run each | 179–332 → 166–329 MB | 323–606 → 319–557 MB |
| All 11 in one process (the history read again) | — | 973 → 805 MB, 74 → 70 s |

| Warm, one process, the full-screen captures three times | p50 | p95 |
| --- | --- | --- |
| The pack alone, three runs of each build | 1.22–1.28 → 1.19–1.38 s | 2.06–2.10 → 2.03–2.20 s |
| Vision with the pack | 2.25 → 2.28 s | 3.49 → 3.44 s |
| `ocr-bench`, L1 with L2, per case (Release) | 294 → 287 ms | 681 → 675 ms |

- **The same answers:** byte for byte, for all 11 pictures in both modes. `ocr-bench --engine l1+l2` read all 40
  cases the same, content CER 1.48% and raw 3.33% as before.
- **Times** are within the runs' own spread. A new process of the other build loaded the models for the Neural Engine
  again, about 10 s, and Vision's first reading took about 40 s. So the times are from warm runs, not from the new
  process per reading.
- **Full-screen captures** are one piece, so they gain only from the output backing and from reading the rows out of
  it: 2–38 MB less for the pack alone. With Vision, one capture read 24 MB higher (533 → 557 MB), from one run each.
- **What is left on the tallest,** about 475 MB for the pack alone:
  - The decoded picture's 215 MB. The footprint counts it again during each piece's draw.
  - About 120–180 MB of freed buffers that malloc keeps. With the undocumented `MallocSpaceEfficient=1`, the
    peak was 339 MB in the Release probe. It isn't used.
- **Vision with the pack** dropped less, by about 200 MB. `VisionPipeline` hands Vision its pieces as
  `image.cropping(to:)` too. In a Release probe of Vision alone on the tallest capture, a piece at a time:
  - Cropped: 597–603 MB at the peak, and 507–511 MB after.
  - Drawn into a bitmap of its own first: 528–540 MB, and 290–300 MB after.
  - Both read 115 lines over the pieces. Vision's pieces are left as they are for now: their output wasn't compared.

## M6 — Pieces of a tall PNG (2026-10-17)

The text reader now reads a tall PNG's pieces from the file, a band of rows at a time, and never decodes the whole
picture (Docs/ocr.md › Pieces of a tall PNG, from the file). L2 draws each piece in strips of at most 4 MB, and Vision
gets each piece as a picture of its own rows. The text reader was measured before and after on 15 pictures: the five
tallest in the history and the ten in Tools/ocr-bench/real/source. Before is e8dc373 with the L2 tall-picture changes
above; after adds only this. Both were built from the shell with SwiftPM in Debug, pack version 2. Each reading ran in a
new process, with the peak from `/usr/bin/time -l`.

| Picture | Pieces | The pack alone | Vision with the pack |
| --- | --- | --- | --- |
| 3346 × 16811 (three runs) | 10 | 477, 481, 480 → 287, 284, 279 MB | 764, 768, 758 → 534, 523, 556 MB |
| 3710 × 9875 | 6 | 448 → 311 MB | 720 → 547 MB |
| 3499 × 8440 | 5 | 415 → 287 MB | 643 → 472 MB |
| 3667 × 8418 | 5 | 392 → 292 MB | 644 → 530 MB |
| 3687 × 8237 | 5 | 424 → 297 MB | 568 → 458 MB |
| 4109–4112 × 2574–2579 (4) | 2 | 328–329 → 320–321 MB | 480 → 533, 558 → 522, 494 → 467, 492 → 457 MB |
| Screens 2000–2186 wide (6) | 1 | 167–180 → 165–178 MB | 322–421 → 324–419 MB |
| All 15 in one process, two runs | | — | 932, 921 → 808, 806 MB; 94–97 s either way |

- **The answers** were byte for byte the same for all 15 pictures in both modes, and in one process. The final code,
  built again after the runs (names changed only), read the tallest once more: 289 MB alone and 553 MB paired, the
  same answers. Built in Release, as the app ships the helper, both builds gave the same answers as in Debug, on the
  tallest (478 → 282 MB alone, 760 → 524 paired) and on a 4K screen in two pieces (322 → 313, 539 → 543).
- **One piece** is read as before, so those rows show only the runs' own spread: paired, up to 23 MB either way.
- **Two pieces with the pack:** one of the four read 53 MB higher. A probe of that capture, three runs each way, gave
  536–549 → 523–541 MB. Vision keeps more after a 4K screen read from its bands (333–336 MB, against 285–288 from the
  decoded picture), and L2 then reads on top of that.
- **Debug times** per reading are those of loading the models in a new process: switching between the two builds
  costs the Neural Engine's compiling again, and Vision's first load. Warm times are below.
- **An earlier run of the tallest, paired, failed** in both builds alike, with Vision timing out and Core ML's
  `e5rt_execution_stream_operation_create_precompiled_compute_operation` failing. Another session's benchmark was
  running beside it, and the Mac had restarted shortly before (contactsd, fileproviderd and ANECompilerService busy).
  Run again on a quiet Mac, every run read.

| Warm, Release, one process per build, the nine pictures in more than one piece twice (two runs) | min | p50 | max |
| --- | --- | --- | --- |
| The pack alone | 1.42 → 1.36–1.37 s | 2.40 → 2.27 s | 4.93–4.94 → 4.73–4.86 s |
| Vision with the pack | 2.30–2.38 → 2.34–2.40 s | 4.05–4.14 → 4.12–4.18 s | 7.19–7.43 → 7.39–7.49 s |

The pack alone no longer waits for the whole picture to be decoded. Vision with the pack inflates the file twice, once
for each reading, where one decoded picture served both: about 1% more.

**A probe of where the footprint goes** (`phys_footprint` every millisecond, the pack alone on the tallest, Debug):

| Path | Peak | Shape |
| --- | --- | --- |
| The decoded picture, a piece drawn from it | 474–482 MB | ~290 MB between pieces, 480 during each piece's draw |
| A band's picture drawn whole per piece | 516–527 MB | 125 → 516: up 25 MB with each piece, kept |
| The same, `MallocLargeCache=0` / `MallocSpaceEfficient=1` | 227 / 220 MB | (the decoded picture's path: 341 / 338) |
| The same, in an `NSMutableData`, a pool around making each band's picture | 291–297 MB | flat (not explained) |
| Strips of 64 / 128 / 512 / 1024 / 2048 rows | 292 / 285–290 / 272–273 / 475 / 521 MB | flat up to 512, then climbing |
| Strips of 16–512 rows, `MallocMediumZone=0` | 273–285 MB | flat |
| Vision alone, crops of the decoded picture → bands | 618–623 → 388–395 MB | |
| Vision with the pack, the same | 739–759 → 519–544 MB | |

What climbed with whole bands wasn't memory in use. At the end, malloc's live blocks were Core ML's, as in the decoded
picture's path. The "Malloc Large" regions held about 230 MB more dirty pages, and every band's buffer had been freed,
whether it came from a `CFData`, malloc, a mapping of its own, or one buffer reused for every band. So the blocks kept
are most likely CG's own for drawing a band's picture. The same draws and allocations without Core ML's predictions
between them stayed flat (179 MB). One variant stayed flat and isn't explained: the band in an `NSMutableData`, with an
autorelease pool around making its picture (291–297 MB, twice; without the pool it climbs, the data autoreleased by its
`mutableBytes`). Strips were chosen because they stay flat however the rows are held and with `MallocMediumZone=0`,
where the pool's result hung on how malloc happened to hand out blocks.

`ocr-bench --engine l1+l2` (Release, with the real screenshots, a fresh copy of the pack for each build): all 40
outputs the same, content CER 1.4842% and raw 3.3305% for both; p50 291 → 278 ms, p95 677 → 662 ms, one run each.

## M6 — Vision's pieces of a tall picture (2026-10-17)

Same machine. Tried: `VisionPipeline.recognize` handing Vision each piece of a large picture drawn into a bitmap of
its own (the whole picture drawn moved, in the picture's own kind: Docs/ocr.md › Large selections in bands › Vision's
pieces stay crops) instead of `image.cropping(to:)`, as the L2 reader draws its pieces. **Not kept.** Measured on
02f2a88 with the L2 changes then uncommitted (pack version 2's head, the L2 reader's pieces drawn from the whole picture
moved); `VisionPipeline` is the same in both. The pack was a copy of the installed version 1, the only one left on this
Mac. A new process per reading: `ledger_phys_footprint_peak` for the probe (Release, outside the repository), `/usr/bin/time
-l` for the text reader (Debug, built with SwiftPM from the shell). Sizes, times, and hashes only.

| The tallest history capture, 3346 × 16811, 10 pieces | Crops | Drawn |
| --- | --- | --- |
| Vision alone, probe: peak, after the reading (3 runs) | 588–605, 497–517 MB | 559–579, 319–339 MB |
| Vision alone, text reader (3 runs) | 596–615 MB | 575–580 MB |
| Vision with the pack, probe: at L2's start, peak, after (3 runs) | 525–530, 1201–1206, 814–819 MB | 346–352, 1177–1183, 614–620 MB |
| Vision with the pack, text reader (3 runs; the history's reading) | 1154–1200 MB | 1175–1183 MB |
| Vision alone, the picture as a plain bitmap in memory, as a capture comes in the app (probe, 3 runs): peak, after | 572–580, 516–521 MB | 593–610, 545–553 MB |
| Vision alone, probe: time | 2.85–2.86 s | 2.83–2.92 s |
| Lines (text, box, confidence) | the same hash, every run | |

The text reader over the other ten captures in `Tools/ocr-bench/real/source` (Debug, a new process per reading, 3 runs
for a picture read in pieces, 1 for the others):

| Pictures | Vision alone: crops → drawn | Vision with the pack: crops → drawn |
| --- | --- | --- |
| The opaque 4K screen, 4109 × 2574 (2 pieces, both drawn) | 373–381 → 326–360 MB | 780–932 → 858–869 MB |
| Three 4K screens with a few transparent pixels (2 pieces each; crops both ways, drawn first and found not opaque) | 372–399 → 365–400 MB | 710–1028 → 755–982 MB |
| Six screens 2000–2186 wide (one piece: nothing changes) | 278–313 → 284–317 MB | 684–823 → 685–751 MB |
| All 11 with the pack in one process (1 run) | — | 1216 → 1143 MB, 74.9 → 76.2 s |
| Warm, the ten screens ×3 in one process: p50, p95 | 0.78, 1.37 → 0.77, 1.45 s | 2.07, 3.69 → 2.08, 3.78 s |

Answers were hash-identical in every pair that both builds answered. Vision itself failed 8 of 12 readings of two
one-piece screens, in both builds alike, while the two builds took turns (six `e5rtError` 13 from Espresso, two
time-outs at 60 s); one of them, read with the pack, never came back from the earlier build in three tries.

### Findings

- **Vision's crops don't pile up.** From the second piece on, each piece starts 5–6 MB above the one before either way
  (479 → 525 MB with crops, 306 → 350 drawn); the L2 reader's drawn crops added 26 MB a piece. What the crops keep is
  a constant, about 175 MB from the first crop read on: by its size, the decoded picture's pixels staying counted.
  `PictureText.image`'s picture counts little until something reads it, then about its size while that lasts
  (observed, mechanism not pinned down). Drawn pieces count it only while each is drawn.
- **L2 takes it back.** The pack's reader draws the whole picture for each of its own pieces, so the picture is counted
  again from L2's first piece: L2 adds 676 MB over its start with Vision's crops, 831 after drawn pieces, and the
  reading's peak, which is L2's, moves by about 25 MB. In the text reader the ranges overlap; a one-piece screen, which
  nothing changes, read with the pack at 823 MB in one build and 749 in the other. With pack version 2 the peak is still
  L2's (750–763 MB in the L2 change's own measurements, against Vision's 600 or so), so the same is expected there; not
  measured.
- **In the app it costs.** A capture there is a plain bitmap, counted whole already; a piece of its own is one more
  piece's copy, about 20–30 MB on the peak. Both ways the footprint climbs about 25 MB a piece there, as if the
  bitmap's rows were counted again as each piece reads them (observed only).
- **Vision reads by kind**, so a bitmap of its own changes L1's reading unless it keeps the picture's alpha, layout, and
  space (Docs/ocr.md › Large selections in bands). The tried version did, and the 12 pieces it drew read exactly as
  their crops.
- **What the reading with the pack peaks on** is the decoded picture, counted at L2's peak, plus L2's own memory. The
  lever left is reading a tall PNG's rows a piece at a time instead of decoding it whole, each piece in the picture's
  kind.
- **So "not kept" holds while L2 draws the decoded picture.** If L2 reads a tall PNG from the file instead, nothing in
  its phase needs the decoded picture counted, and Vision's crops would then keep about 175 MB through it for nothing:
  drawn pieces could take up to that off the reading's peak. To be measured again then.

## M6 — Capture Formula (2026-10-18)

Debug build, the Dev app, the Math Formulas pack (PP-FormulaNet_plus-L, Core ML with 8-bit weights, on the CPU;
Docs/ocr.md › The formula pack) downloaded through the app with `debug/modelpack-act`. Capture Formula is timed with
`debug/formula-flow`: the real overlay, frozen frame, and text reader, over drawn screens (a picture of a formula drawn
at its pixels in the middle of the display, never the real screen), the area chosen without the mouse, nothing
copied. The time runs from the selection's end, the mouse-up, to the LaTeX.

| Step | Time | The reader at most | The app |
| --- | --- | --- | --- |
| Download from Hugging Face, 184.9 MB | 3 min 26 s (0.9–1.4 MB/s) | — | 24 MB |
| Warming: compiling the two models for the CPU | 1.2 s | 45 MB | — |
| A 2x formula, the first after launch (and the first after install) | 0.73 s | about 330 MB | 24–25 MB after |
| The same, five more | 0.74–0.76 s | | |
| A dark formula | 0.67–0.68 s | | |
| A one-line formula 21 times as wide as tall (174 characters) | 2.55–2.58 s | 309 MB | |
| A tweet's screenshot, no formula (stopped as it repeated itself) | 2.50 s | 319 MB | |

- **The reader's peak** is from `/usr/bin/time -l` on the same jobs from the shell. It is gone when the reader exits,
  after each capture: no reader stays.
- **The app** stays at 24–25 MB across three readings of files (`debug/formula-test`). After a drawn-screen run it
  shows 67 MB: a freed 41.7 MB block, one drawn display's frame (4112 × 2658 × 4 bytes) that the hook made with
  malloc, kept by the allocator (`malloc_zone_pressure_relief` doesn't take it). The overlay's own frozen frames come
  from ScreenCaptureKit, not malloc; a real drag over the real screen was not measured (computer use can't drive the
  Dev app).
- **Where the time goes,** per reading: the encoder 190 ms and 6.7–6.9 ms a token on the CPU (native Core ML probe,
  `Tools/l3-spike/fprobe.swift`), the rest the reader's start, the models' load (8 ms and
  1 ms once compiled, 490 ms and 280 ms the first time after compiling), and the picture's preparation (50–100 ms in a
  Debug build).
- **Not measured:** a cold start with the models out of the file cache (every run here had them in it; that takes
  `sudo purge`), a Release build, and idle with the pack installed for the M6 power gate (nothing of it runs between
  captures).
- **The other compute units** (native probe, Docs/ocr.md › L3 spike): the encoder takes 61 ms on the GPU but the reader
  peaks at 1.16 GB, and 234 ms on the Neural Engine with 817 MB there and a 7.6 s first compile; the decoder is no
  faster off the CPU. CPU only: 287–310 MB.
- **Energy** (the spike's Python harness, CPU energy from `proc_pid_rusage`): about 4.3 J a formula on the CPU, 4.8 J
  with the encoder on the GPU.

## M6 — Formulas in the panel, and the M6 power gate (2026-10-18)

Debug build of `327aa45` with the OCR panel's Formulas pane and the two Shortcuts actions, the Dev app with both packs
installed, a fresh launch. The tour ran through hidden hooks, on the formula tests' three pictures and a page drawn from
them (prose around them, the dark one on a dark band, 1400 × 900), never the user's own: Capture Formula reading the
three files (`debug/formula-test`, nothing copied), Recognize Formula in Image's path twice (`debug/shortcut-formula`,
the same `formulaForShortcut(inImage:)` the action runs), then the page in the OCR panel (`debug/panel-file`, read with
L2 beside L1), its Formulas pane, three boxes dragged in at once (`debug/panel-state?formula=`), and the panel closed.

| Measurement | Result | Target |
| --- | --- | --- |
| Idle after launch, 60 s, two runs | 0.04% and 0.01% CPU (seconds at 0.4–0.6%), 0 wakeups, 24 MB | 0.0%, < 60, < 30 MB |
| The app after Capture Formula ×3 and the Shortcuts path ×2 | 24 MB | — |
| A box in the panel, from its drag to its LaTeX | 0.49–0.68 s, one after another | — |
| The panel open with three formulas / 10 s after it closed | 132 / 120 MB | — |
| The same page, text only, on a fresh launch | 145 / 115 MB | — |
| Idle after the tour, 60 s, two runs | 0.06% and 0.01% CPU (one second at 2.4%), 0 wakeups, 120 MB | 0.0%, < 60, < 60 MB |
| Live resources and the app's own processes after the tour | none (`debug/resources` idle, no text reader) | none when idle |

- **Formulas cost the app nothing.** Every reading runs in the text reader, which exits after it, so Capture Formula
  and the Shortcuts path left the app at 24 MB. The panel's 115–120 MB after it closes is Vision's, reading the
  page's text in the app (M2: 110–125 MB): the same page with no formulas left 115 MB. The footprint after use stays
  over budget for that reason alone, as at the M5 gate.
- **The CPU wasn't 0.00%** as at the M4 and M5 gates. With 0 wakeups, the busy seconds came with work other processes
  asked for, as the app's log shows: preference reloads from `cfprefsd`, an AppKit lifecycle message, and the system
  asking the app for a Spotlight donation for its App Intents (whose list this build changed) after URL events. 87
  context switches in an idle minute, no timers. The user was at the Mac and trying the panel during these runs.
- **The text reader on one formula** (`/usr/bin/time -l` from the shell, the 2x quadratic formula):

  | Run | Time | Peak |
  | --- | --- | --- |
  | Release reader, warm | 0.66–0.72 s | 298–299 MB |
  | Debug reader, warm | 0.66–0.67 s | 298 MB |
  | Release, the dark formula / the Chinese one | 0.61 / 0.48 s | 314 / 299 MB |
  | Release, the pack's files out of the page cache, models at a new path | 1.35–1.36 s | 315–318 MB |
  | Release, the same with the files read once first | 1.12 s | 315 MB |

  Release is no faster: the pixel work is built optimized in Debug too, and the rest is Core ML's. Without `sudo
  purge`, a pack out of the page cache was an APFS clone of it (`cp -c`: the same blocks, none of the cache; `cat`
  reads its 352 MB in 0.07–0.08 s, 0.04 s warm). A clone is also a new path to Core ML, whose load cache is kept by
  path: reading the clone's files first leaves 0.46 s of the 0.69 s, Core ML's first load, and the files' 0.2 s.
  A first reading after a restart, at the installed path with Core ML's cache on disk, should take about 0.9 s; the
  first load at a new path is what warming pays after an install (› M6 — Capture Formula).
- **Core ML's cache keeps a copy of the pack for each path** it was loaded from: 157 MB and 195 MB of entries in
  `~/Library/Caches/io.github.fzlzjerry.ohmyshot.text-reader/com.apple.e5rt.e5bundlecache` (shared by the Debug and
  Release readers), never removed when the path goes away. The four clones left 1.4 GB, removed afterwards. With
  the pack's 352 MB folder (its packages and their compiled models), the Math Formulas pack takes about 700 MB of
  disk, against the 185 MB its row in Settings names; a new version of it would leave its old cache behind.
  Now, once a pack is removed or an old version cleared away, the app has the reader remove every entry whose model
  file is gone (a "tidy" job; `CompiledModelCache`), the reader's being the process whose cache it is. An entry's
  `.e5` description names the model it was made from. Entries made from a copy Core ML keeps in the cache itself (the
  L2 pack's, for the Neural Engine: 1 MB in all) name none and stay, as do those whose model is still there (Vision's
  own, the installed packs'). Checked with the reader: a read of a clone took the cache from 703 MB in 39 entries to
  1.0 GB in 41; with the clone deleted, tidying removed those 2 and left 703 MB in 39, and the installed pack still
  read warm.

Not part of this gate: Option at the end of a Capture Formula drag (it needs the overlay over the real screen) and the
actions run from a real shortcut in the Shortcuts app. The design gate and the macOS 26 smoke test were not run.
