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

FIRST VIEWPORT: Picture fitted, never above on-screen size; rail 12 pt from the left; capsule 10 pt below the selected mark (beside a highlight, clear of the lines of text around it), else at the rail's foot, following the selection with 0.12 s fades.

FORM: Rail + contextual capsule, 5th of 7, seed b6cc82c6.

FINISH: unreviewed and undocumented is unfinished; this build ends with the finish review, the verdict, DESIGN.md, and every shipping raster carrying its provenance

## Open decisions

- Background tool, combine, and project files: built (2026-10-09) inside the locked structure — a rail
  chip whose capsule holds the fills, an Adjust popover, and a Presets menu; images dropped or pasted
  in; a split Save button for a project copy.
- In-place annotation: built (2026-10-09). The same canvas runs inside the capture overlay at the
  screen's own size (no zoom, crop, background, or combining there), beside a small glass toolbar of
  the rail's tools, Undo/Redo, and Open in Editor, Save, Cancel, and accent Copy; the style capsule
  sits right-aligned under it. The selection keeps a resizable frame. Its interface is specified in
  DESIGN.md's In-Place Annotation component.
- OCR redaction suggestions: built (2026-10-10). Picking up the Redact tool reads the capture once,
  on this Mac, and outlines text better covered (emails, phones, cards, ID numbers, keys, IPs,
  passwords, addresses, names) in dashed accent over a same-width white line, no fill; a click covers
  one in the current method, Redact All in the capsule covers the rest, and "Finding text…" holds the
  capsule's place while reading. The same in the editor and in place; never exported. Its interface
  is specified in DESIGN.md's Canvas, Style Capsule, and Suggestion Outline entries.
- Text-snapping highlighter: built (2026-10-10), matching CleanShot's smart highlighter. Picking up
  the Highlighter reads the capture once, on this Mac, for where its lines and words lie (never what
  they say); a drag that starts on text runs on as a text selection does (the rest of the first line,
  the lines between whole, the last line up to the pointer), whole words only, each band the height of
  its paragraph's letters, and a click highlights one word. ⌘ draws freely,
  the I-beam over text says a drag will snap, and "Finding text…" holds the capsule's place while
  reading. The same in the editor and in place, where only the selection and its surroundings are
  read. Its interface is specified in DESIGN.md's Canvas, Style Capsule, and Marks entries.
- Highlighter follow-ups: built (2026-10-10). Over dark ground (a shade darker than mid-gray under
  most of the mark) highlights screen a deep tint of their color instead of multiplying, so a dark
  editor takes a visible band and its light text stays light. A selected highlight's capsule keeps
  clear of the lines of text around it. A reading that fails (for suggestions or lines) shows
  "Couldn't read text" and Try Again in the capsule, and the next pickup of the tool reads again.
