# OhMyShot

A native macOS capture tool — screenshots, recordings, annotation, pins, and on-device OCR — built to cost nothing while it waits in the menu bar.

一个原生 macOS 截图工具：截图、录屏、标注、贴图和端侧 OCR，常驻菜单栏时几乎不耗电。

This is [BenjaminD2023's maintained fork](https://github.com/BenjaminD2023/OhMyShot) of [fzlzjerry/OhMyShot](https://github.com/fzlzjerry/OhMyShot). It preserves the local capture, pixel-picker, shortcut, OCR, preview and toolbar improvements, including proposals that were not merged upstream. Updates and packaged builds come from this fork.

Download the Apple silicon build from [Releases](https://github.com/BenjaminD2023/OhMyShot/releases). The DMG contains the app and an Applications shortcut. The first fork release is not Apple-notarized; its update feed and update archives are signed independently with Sparkle's Ed25519 key. See [release and signing instructions](Docs/releasing.md).

这是独立维护的 fork，保留本地增强功能；安装包和自动更新均来自本 fork。

## Requirements

- macOS 26 or later on Apple silicon
- Xcode 27 or later
- [XcodeGen](https://github.com/yonaskolb/XcodeGen): `brew install xcodegen`

## Build and run

```sh
Scripts/bootstrap.sh   # generate OhMyShot.xcodeproj from project.yml (build.sh and run.sh do it again when project.yml has changed)
Scripts/run.sh         # build the Debug app ("OhMyShot Dev") and launch it
swift test --package-path Packages/OhMyShotKit
```

Debug builds use their own bundle identifier (`….ohmyshot.dev`), URL scheme (`ohmyshot-dev://`), and default shortcuts (⌃⌥⌘ plus a digit), so they can run next to a release build without fighting over permissions or shortcuts.

### Signing and Screen Recording permission

This fork keeps Hardened Runtime and library validation enabled. Before building, copy `Config/Signing.local.xcconfig.example` to the ignored `Config/Signing.local.xcconfig` and select an existing Apple Development identity for local use, or Developer ID Application for distribution. Use the certificate's actual organizational-unit Team ID. An ad-hoc build is insufficient for loading the separately distributed Sparkle framework with these protections enabled.

macOS ties Screen Recording permission to the app's code signature; a stable signing identity also avoids treating every rebuild as a new app. `Scripts/reset-tcc.sh` clears the Debug build's permissions when needed.

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

When no capture is active, the app holds no capture streams or screenshot event taps. Sparkle checks this fork for updates on its standard daily schedule; automatic checks and downloads can be changed in Settings › General. The original capture power targets remain:

| Metric | Target |
| --- | --- |
| Idle CPU (60 s average) | 0.0% |
| Idle wakeups | < 1 per second |
| Memory footprint | < 30 MB after launch, < 60 MB after use |

Measured results are recorded in [Docs/perf.md](Docs/perf.md). Sample them yourself with `Scripts/power-sample.sh`.

## License

OhMyShot is free software, licensed under the [GNU General Public License v3.0](LICENSE).
Copyright © 2026 OhMyShot contributors.
