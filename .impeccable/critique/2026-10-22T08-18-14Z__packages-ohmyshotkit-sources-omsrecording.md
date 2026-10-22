---
target: recording and Studio
total_score: 26
max_score: 40
na_heuristics: 
p0_count: 0
p1_count: 2
target_identity: "file:/Users/moraxcheng/Documents/Github.nosync/ohmyshot/Packages/OhMyShotKit/Sources/OMSRecording"
timestamp: 2026-10-22T08-18-14Z
slug: packages-ohmyshotkit-sources-omsrecording
---
# Critique: screen recording and Studio
Method: as in the capture critique (2026-10-22; renders of bars, recording window, Studio on a 3 s demo).

Verdict: specific (reuses All-In-One chips, one red on Record, reading-face time); Studio is a competent grouped inspector without Screen Studio's focus on the edited thing.
Score 26/40 (H1 3, H2 3, H3 2, H4 3, H5 2, H6 2, H7 3, H8 3, H9 2, H10 3).

## Priority issues
- [P1] Delete and Restart discard on one click beside Stop (RecordingCoordinator.swift:481-505; RecordingControlBar.swift:246). Fix: two-step in place.
- [P1] Mic chip shows on without access; recording drops the mic with only a VoiceOver announcement (RecordingCoordinator.swift:202-208, 1286-1290); no panel allows tooltips while inactive; start failure is beep + VoiceOver only (337-348).
- [P2] Chosen zoom's controls below the inspector fold (StudioViews.swift:415-455). Conflicts with DESIGN.md Studio › Inspector order.
- [P2] Cut undiscoverable (help only, StudioViews.swift:182); Add Zoom silently does nothing without room (StudioDocument.swift:267).
- [P2] Mic and camera chips open menus but look like toggles and never name the device (RecordingBar.swift:250,273,380-384).
- [P3] Paused barely differs from recording (RecordingControlBar.swift:367-380).

## Minor
Studio mode sticky across takes (RecordingCoordinator.swift:173); Accent and Blue click colors identical with a blue accent; Plain color well reads as an off switch; moved zooms may overlap neighbours (StudioTimeline.swift:404-409); no bar keys for chips, no Add Zoom shortcut.
