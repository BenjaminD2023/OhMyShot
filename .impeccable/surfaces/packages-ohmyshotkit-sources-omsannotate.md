---
version: 1
slug: "packages-ohmyshotkit-sources-omsannotate"
primary_target: "Packages/OhMyShotKit/Sources/OMSAnnotate"
related_targets: ["Packages/OhMyShotKit/Sources/OMSUI","App"]
---

# Annotation editor

Scope: the annotation editor window: its canvas, the tool rail, the style capsule, and the toolbar; the same canvas later hosts in-place annotation over the capture overlay. Mode: Operate. Inherits the world in `packages-ohmyshotkit-sources-omscapture`.

Audience and task: the author, many times a day: mark up a fresh capture (arrows, boxes, text, counters, redactions) and send it on, often within seconds; keyboard and pointer alike.

Constraints: macOS HIG; standard titled window; glass only on the small rail; marks render identically on screen and in exports; Chinese input in text marks; no work while idle.

## Direction contract

THESIS: The capture owns the window: tools in a slim glass rail at its left edge, a mark's style in a capsule beside the mark; no wide tool toolbar, no fixed option strip.

OWN-WORLD: System colors and accent; toolbar: Undo/Redo (no menu bar shows), zoom, drag-out, Save, glassProminent Copy; opaque-backed glass rail of 30 pt chips; white reading-capsule style capsule, system face; square-cornered picture, hairline, in-window shadow, quiet backdrop.

STORY: Pick a tool, mark, restyle the mark where it sits, copy or drag out.

FIRST VIEWPORT: Picture fitted, never above on-screen size; rail 12 pt from the left; capsule 10 pt below the selected mark, else at the rail's foot, following the selection with 0.12 s fades.

FORM: Rail + contextual capsule, 5th of 7, seed b6cc82c6.

FINISH: unreviewed and undocumented is unfinished; this build ends with the finish review, the verdict, DESIGN.md, and every shipping raster carrying its provenance

## Open decisions

- Background tool, combine, and project files arrive after the core editor.
- In-place annotation reuses the canvas inside the capture overlay with its own small toolbar.
