---
target: annotation editor
total_score: 27
max_score: 40
na_heuristics:
p0_count: 0
p1_count: 2
target_identity: "file:/Users/moraxcheng/Documents/Github.nosync/ohmyshot/Packages/OhMyShotKit/Sources/OMSAnnotate"
timestamp: 2026-10-22T08-18-14Z
slug: packages-ohmyshotkit-sources-omsannotate
---
# Critique: annotation editor
Method: as in the capture critique (2026-10-22; detect not applicable to Swift; renders of the drawn demo page).

Verdict: specific (rail + contextual capsule, OCR redaction, text-snapped highlighter); weak spots are flow and glyph meaning.
Score 27/40 (H1 3, H2 3, H3 3, H4 2, H5 3, H6 2, H7 3, H8 3, H9 3, H10 2).

## Priority issues
- [P1] No copy-and-close: Return does nothing in the editor (AnnotationCanvasView.swift:1490-1503) while it is "Copy and finish" in place (InPlaceToolbar.swift:217). Fix: Return copies then closes when no text mark is selected/edited and no picture mode is on.
- [P1] Highlight Box and Background glyphs nearly identical (ToolRail.swift:209,215). Conflicts with DESIGN.md Tool Rail.
- [P2] Highlighter capsule: sizes ignored by snapped drags (StyleCapsule.swift:393-394); marker yellow lost once another color is chosen (348-356); its chip never reports selection to VoiceOver; size chips lack tooltips (405).
- [P2] Capsule covers the next text line under a free highlighter stroke (EditorContentView.swift:311-337 applies clear-of-lines only to textHighlight).
- [P2] Tool keys recall-only (tooltips only, ToolRail.swift:220-224). Fix: rail context menu listing tools with keys.

## Minor
Picture menu wears crop.rotate with no crop in it; checkmark means Copy in place but Copied in the editor; editor Copy failure only beeps; leaving Crop applies the frame, Escape never leaves Crop.
