---
target: capture flow
total_score: 28
max_score: 40
na_heuristics:
p0_count: 0
p1_count: 2
target_identity: "file:/Users/moraxcheng/Documents/Github.nosync/ohmyshot/Packages/OhMyShotKit/Sources/OMSCapture"
timestamp: 2026-10-22T08-18-14Z
slug: packages-ohmyshotkit-sources-omscapture
---
# Critique: capture flow (overlay, All-In-One, Quick Access, scrolling capture)
Method: dual-agent equivalent (A: one design-review agent per surface; B: `impeccable detect` returned [] — HTML/CSS only, not applicable to Swift; evidence = 52 light/dark renders of the current build, 2026-10-22). Live overlay over a real screen not rendered (privacy); Increase Contrast not covered.

Verdict: specific, a considered macOS feature; weak spots are density and undo on the card and the All-In-One bar.
Score 28/40 (H1 3, H2 3, H3 2, H4 3, H5 2, H6 3, H7 4, H8 3, H9 2, H10 3).

## Priority issues
- [P1] Bare Delete trashes a focused card (CardKeys.swift:75); trash skips close(), so no Recently Closed (QuickAccessController.swift:462-471); original, marks, text deleted (HistoryStore.swift:529-539). Fix: ⌘⌫ only; trashed card to Recently Closed + "Moved to Trash · Undo". Conflicts with DESIGN.md Quick Access Keyboard.
- [P1] ⌘C / Copy Latest Capture give no feedback when the card isn't hovered (CaptureCardView.swift:703-712). Fix: Copied reading over the card + VoiceOver announcement.
- [P2] Setup bar has 13 controls; Copy duplicates Capture under default settings (CaptureCoordinator.swift:615-620); Annotate glyph reads as "A". Untested live. Conflicts with DESIGN.md All-In-One.
- [P2] Card side buttons reshuffle when upload state changes under the pointer (CaptureCardView.swift:341,496-513; CardLayout.swift:66-80). Fix: fixed slots. Untested live. Conflicts with DESIGN.md Card hover layout.
- [P2] Scrolling capture: Cancel discards the stitched picture (ScrollingCaptureCoordinator.swift:364-368); Auto-scroll without Accessibility loses the framed area (98-110, 415-424); failure hint as faint as progress (ScrollingPanel.swift:189,346-348).

## Minor
"▼ Auto" vs "Auto-scroll"; Area/Screen tooltips omit A/F; two key vocabularies (All-In-One letters vs card ⌘ keys); remembered area makes a new drag move the frame; two-finger swipe either way closes a card.
