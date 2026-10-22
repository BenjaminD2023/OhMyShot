---
target: history, settings, onboarding
total_score: 28
max_score: 40
na_heuristics:
p0_count: 0
p1_count: 2
target_identity: "file:/Users/moraxcheng/Documents/Github.nosync/ohmyshot/Packages/OhMyShotKit/Sources/OMSUI"
timestamp: 2026-10-22T08-18-14Z
slug: packages-ohmyshotkit-sources-omsui
---
# Critique: Capture History, Settings, Onboarding
Method: as in the capture critique (2026-10-22; History rendered with test pictures only; Settings first viewport per pane).

Verdict: specific, reads as Apple-built; shortfalls are information architecture, copy, and safety.
Score 28/40 (H1 3, H2 3, H3 3, H4 2, H5 2, H6 3, H7 3, H8 3, H9 3, H10 3).

## Priority issues
- [P1] Move All to Trash says "You can put them back from the Trash" (HistoryWindowController.swift:481) but records, originals, marks, and text are deleted (HistoryStore.swift:529-539); no count; acts on all items even while searching (:365-369, :599).
- [P1] zh-Hans: Capture and Screenshots panes both "截图"; captures counted as "截图" (OMSUI Localizable.xcstrings).
- [P2] Settings search terms hand-written and incomplete (SettingsNavigation.swift:24-130); Return opens the pane but never scrolls to the row (:248-251).
- [P2] Tools pane mixes text recognition, colors, Measure, Pins (SettingsViews.swift:692-857). Conflicts with DESIGN.md Layout › Settings (11 panes).
- [P2] Help inconsistent: long tooltips vs "?" popovers; 9 "?" in one Screenshots viewport. Partly conflicts with DESIGN.md.
- [P2] History: no key opens the editor; single selection only (HistoryWindowController.swift:214, :937).

## Minor
Shortcut recorders likely lack VoiceOver labels (SettingsViews.swift:896-900, unverified); History card VoiceOver label omits the app; empty-state casing mixed; unclear labels ("Keep the keys pressed", "Image line breaks", "H.264 when it fits"); onboarding's relaunch advice leaves the judgement to the user.
