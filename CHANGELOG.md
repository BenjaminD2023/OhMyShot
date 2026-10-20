# Changelog

All notable changes to OhMyShot will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
The entries below summarize notable changes merged into `main`; dated version entries will be added when releases are published.

## [Unreleased]

### Added

- Editable screenshot previews in Quick Access, with basic annotation tools, Copy, and Edit to continue in the full editor. ([#5])
- Per-window text wrapping in Recognized Text, with a saved default for new windows and horizontal scrolling when wrapping is off. ([#6])
- Settings for measurement snapping and edge tolerance, plus keyboard controls to adjust tolerance during measurement. ([#3])
- Drag grips and Hide controls on the capture toolbar and selected area's action bar; press H to hide or restore them. ([#7])

### Changed

- New Quick Access preferences default to closing cards after three seconds; hovering or interacting pauses the timer, and existing saved delays are preserved. ([#5])
- Screenshot and annotation capture offer an optional centered, translucent color picker with adjustable size and a target border that adapts to the sampled color. The picker clears when area selection begins. ([#4])
- Large measurement selections are analyzed in the background to keep the overlay responsive. ([#3])
- General settings are organized into General, Capture, and Tools tabs, with scrolling when a pane is taller than the screen. ([#1])

### Fixed

- The native cursor remains visible over capture toolbar controls and restores the capture pointer when it returns to the canvas. ([#7])
- Shortcut recorders allow menu shortcut conflicts through Use Anyway, including Command-Shift-S. Reassigning a shortcut clears its previous OhMyShot action to prevent duplicate activation. ([#2])
- Measurement snapping handles faint outlines and thin details more reliably, while retaining the drawn rectangle when no credible boundary is found. ([#3])

[Unreleased]: https://github.com/fzlzjerry/OhMyShot/commits/main/
[#1]: https://github.com/fzlzjerry/OhMyShot/pull/1
[#2]: https://github.com/fzlzjerry/OhMyShot/pull/2
[#3]: https://github.com/fzlzjerry/OhMyShot/pull/3
[#4]: https://github.com/fzlzjerry/OhMyShot/pull/4
[#5]: https://github.com/fzlzjerry/OhMyShot/pull/5
[#6]: https://github.com/fzlzjerry/OhMyShot/pull/6
[#7]: https://github.com/fzlzjerry/OhMyShot/pull/7
