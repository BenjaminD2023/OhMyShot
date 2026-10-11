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
