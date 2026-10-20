# OhMyShot

A native macOS capture tool — screenshots, recordings, annotation, pins, and on-device OCR — built to cost nothing while it waits in the menu bar.

一个原生 macOS 截图工具：截图、录屏、标注、贴图和端侧 OCR，常驻菜单栏时几乎不耗电。

> **Status: not released yet.** No builds or version tags have been published; build it from source (below). It is
> developed and tested on macOS 27 beta, on one Mac (Apple silicon, a 6880 × 2880 ultrawide beside a built-in XDR
> display). It builds for macOS 26 but has never been run there.

## What it does

- **Screenshots**: area, window (with or without its shadow, on a background), full display, the previous area,
  and a self-timer; areas can cross displays, and the screen freezes while you choose. All-In-One sets up any of
  them from one bar.
- **Quick Access and Capture History**: a card for each capture to copy, save, mark up, pin, upload, or drag
  out, and a history you can search by the text in the pictures (Chinese included).
- **Annotation**: an editor, or drawing straight on the frozen selection: arrows, shapes, text, highlighter that
  snaps to text, counters, blur and pixelation (with redaction suggestions from the text it reads), crops,
  backgrounds, combined images, and project files you can open again.
- **Text from pixels**: Capture Text copies the text in an area; the Recognized Text window shows it beside the
  picture with tables, links, and codes, and translates it, also over the original. Optional downloadable model
  packs read Chinese a second time, formulas as LaTeX, and tables and charts; a cloud model with your own API key
  and the text native apps report can refine it further. Everything is read on the Mac unless you set up the
  cloud model.
- **Pins, color, and measuring**: always-on-top pictures, text, and colors; a screen color picker and a pixel
  ruler that snaps to edges.
- **Recording**: screen, window, or area to MP4 or GIF, with system audio, microphone, camera, clicks, and keys;
  Studio edits a recording afterwards, with automatic zooms that follow the cursor. On macOS 27, with Replay
  turned on, the last 15 seconds can be saved at any time.
- **Scrolling capture**: scroll by hand or let Auto-scroll do it, into one long picture.
- **Sharing**: uploads to your own storage (S3-compatible, WebDAV, or a custom HTTP endpoint), never a service of
  ours; printing, email, and the Share menu.

[CHANGELOG.md](CHANGELOG.md) lists the changes so far, with their commits and contributors.

## Requirements

- macOS 26 or later on Apple silicon
- Xcode 26 or later, with its Metal Toolchain (MLX, which the VLM pack reads with, has Metal kernels to compile):
  `xcodebuild -downloadComponent MetalToolchain`
- [XcodeGen](https://github.com/yonaskolb/XcodeGen): `brew install xcodegen`

## Build and run

```sh
Scripts/bootstrap.sh   # generate OhMyShot.xcodeproj from project.yml (build.sh and run.sh do it again when project.yml has changed)
Scripts/run.sh         # build the Debug app ("OhMyShot Dev") and launch it
Scripts/test.sh        # both packages' unit tests (OhMyShotKit, OhMyShotVLM)
```

Debug builds use their own bundle identifier (`….ohmyshot.dev`), URL scheme (`ohmyshot-dev://`), and default shortcuts (⌃⌥⌘ plus a digit), so they can run next to a release build without fighting over permissions or shortcuts.

### Signing and Screen Recording permission

macOS ties the Screen Recording permission to the app's code signature. An ad-hoc signed build looks like a new app after every rebuild and loses the permission. To keep it, copy `Config/Signing.local.xcconfig.example` to `Config/Signing.local.xcconfig` and fill in your Apple Development team (a free personal team works). `Scripts/reset-tcc.sh` clears the Debug build's permissions when you want to start over.

After you grant Screen Recording, relaunch the app: macOS applies the permission only to new processes.

## Updates and releases

Release builds look for updates with [Sparkle](https://sparkle-project.org) about once a day (Settings › General ›
Updates), in signed appcasts attached to this repository's GitHub releases; debug builds never look. How releases are
made, signed, and notarized is in [Docs/release.md](Docs/release.md).

## Automation

OhMyShot answers CleanShot X's URL commands under `ohmyshot://`, offers actions in Shortcuts and Spotlight, and
comes with a Raycast extension. See [Docs/automation.md](Docs/automation.md).

## Share menu, Open With, and email

OhMyShot is in the Share menu of other apps (Preview, Safari, Photos, Finder) for pictures, to mark them up or pin
them; switch it on in System Settings › General › Login Items & Extensions › Sharing. It also appears in Finder's
Open With for images, and a capture's Quick Access card and its row in Capture History can start an email with the
file attached.

## Languages

OhMyShot is in English, Simplified and Traditional Chinese, Japanese, Spanish, and French. It follows the system's
language, or the one chosen in Settings › General. To add or improve a translation, you don't need Xcode: see
[Docs/localization.md](Docs/localization.md).

## Power budget

Idle means idle. While OhMyShot sits in the menu bar it runs no timers, polls nothing, and holds no capture streams
or event taps. Every milestone is gated on measured numbers, recorded in [Docs/perf.md](Docs/perf.md); sample them
yourself with `Scripts/power-sample.sh` and `Scripts/latency.sh`. The latest measurements, on the Mac above with
Debug builds, against the targets (misses included):

| Metric | Target | Measured |
| --- | --- | --- |
| Idle CPU after launch (60 s average) | 0.0% | 0.06–0.09%, seconds that came with macOS updating the menu bar; no timers of the app's own (M6, 2026-10-19) |
| Idle wakeups | < 1 per second | 0 |
| Memory footprint after launch | < 30 MB | 26 MB |
| Memory footprint after use, idle | < 60 MB | 57 MB after recording, a GIF, and a Studio film (M4); 68 MB after reading text, formulas, and tables (M6); 110–130 MB while Vision's models stay loaded after the Recognized Text window (M2–M6) |
| Shortcut to the selection overlay on screen | p95 < 50 ms | p95 9.8 ms over 50 runs (M1); 18.9 ms on one real press with the screen frozen, the default since M3 |
| Shortcut to the frozen picture | p95 < 150 ms | p95 47.7 ms over 50 runs (M1); 54–106 ms over 23 real presses since (median about 73) |
| Text from an area of about 1000 × 600 px | < 300 ms | p50 187 ms, p95 370 ms over 27 test pages (M2): met at p50, not at p95 |
| Recording 1920 × 1080 at 60 fps | < 15% CPU | 15.7% (app 8.4%, encoder 4.4%, `replayd` 2.9%; the window server not counted) |
| App size, without model packs | < 30 MB | 37 MB as `Scripts/release.sh` builds it, stripped (14 MB zipped; 60 MB unstripped), 2026-10-20 |

The optional model packs are read in a helper process that exits when it is done, so they cost the app's own memory
nothing; the helper itself takes up to 2.6 GB while the table model reads.

## License

OhMyShot is free software, licensed under the [GNU General Public License v3.0](LICENSE).
Copyright © 2026 OhMyShot contributors.
