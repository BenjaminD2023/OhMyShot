# OhMyShot

A native macOS capture tool — screenshots, recordings, annotation, pins, and on-device OCR — built to cost nothing while it waits in the menu bar.

一个原生 macOS 截图工具：截图、录屏、标注、贴图和端侧 OCR，常驻菜单栏时几乎不耗电。

> **Status: pre-alpha.** Milestone M0 (foundations) is done: the app lives in the menu bar, registers its shortcuts, walks you through permissions, and answers URL commands, at 0.0% idle CPU and a 14 MB footprint. It does not capture anything yet; that is milestone M1.

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

Idle means idle. While OhMyShot sits in the menu bar it runs no timers, polls nothing, and holds no capture streams or event taps. Every milestone is gated on measured numbers:

| Metric | Target |
| --- | --- |
| Idle CPU (60 s average) | 0.0% |
| Idle wakeups | < 1 per second |
| Memory footprint | < 30 MB after launch, < 60 MB after use |

Measured results are recorded in [Docs/perf.md](Docs/perf.md). Sample them yourself with `Scripts/power-sample.sh`.

## License

OhMyShot is free software, licensed under the [GNU General Public License v3.0](LICENSE).
Copyright © 2026 OhMyShot contributors.
