---
version: 1
slug: "packages-ohmyshotkit-sources-omsstudio"
primary_target: "Packages/OhMyShotKit/Sources/OMSStudio"
related_targets: ["Packages/OhMyShotKit/Sources/OMSRecording","Packages/OhMyShotKit/Sources/OMSCapture/Recording","App/RecordingCoordinator.swift"]
---

# Studio recording (M4b)

Scope: recording in Studio mode and the Studio window that turns it into a polished movie: zoom that follows
the pointer, a cursor drawn again smooth and larger, clicks, the keys pressed, a background with padding,
rounded corners, and a shadow, cuts, and the export. Mode: Operate. Inherits the world in
`packages-ohmyshotkit-sources-omscapture` and the recording surface in `packages-ohmyshotkit-sources-omsrecording`.

Audience and task: the author, a few times a week: record a product demo, a bug walk-through, or a feature
for a README or a release note, then make it look finished in a minute or two rather than in a video editor.

Constraints: macOS HIG; standard window, toolbar, and controls; glass only on small HUDs; nothing of the app in
the movie but what Studio draws on purpose; the preview plays in real time on the built-in display; export
faster than real time; no work while idle; every edit can be made again from the project.

## Direction contract

THESIS: Studio is a recording that knows where the pointer was. It records the screen without the cursor and,
beside it, where the pointer went, how it looked, and every click and key; the Studio window then films it
again: following the pointer in, drawing the cursor smooth, framing it on a background.

OWN-WORLD: The recording bar's chips (Studio a third mode beside Video and GIF); the annotation editor's
window, toolbar, and its background gradients (the same ten, painted by the same code); the recording window's
player; reading-face numbers; system controls in the inspector.

STORY: Choose Studio on the bar, record, stop: the Studio window opens on the recording with zooms already
placed where clicks and typing were, a background behind it, the cursor smooth. Play it, drag a zoom's edges,
delete one, cut a slip, pick another background, export, and find the MP4 copied and waiting as a card.

FIRST VIEWPORT: The movie framed on its background in the preview, the transport under it, a timeline across
the bottom with the clip and its zoom segments, and an inspector on the right: Background, Frame, Cursor, Zoom.

FORM: Preview + timeline + inspector, as the user chose on 2026-10-11.

FINISH: unreviewed and undocumented is unfinished; the build ends with the finish review and DESIGN.md's
Studio components.

## Open decisions

- Decided by the user on 2026-10-11:
  - Studio is chosen on the recording bar, a third mode beside Video and GIF: it has to be chosen before
    recording, since a cursor recorded into the picture can't be drawn again.
  - Stopping a Studio recording opens the Studio window at once.
  - The window: the preview, a timeline along the bottom, an inspector on the right.
  - Automatic zoom is on by default, following clicks and typing; each zoom can be changed or removed on the
    timeline.
- Measured before building (2026-10-11, scratch spike): NSCursor.currentSystem gives other apps' cursor and
  its hotspot without any permission, sampled at 120 Hz; a custom AVVideoCompositing compositor (the
  macOS 26 AVVideoComposition.Configuration) drawing a gradient, the screen padded with rounded corners and a
  shadow, a 2x zoom, and a cursor with Core Image exported 10 s of 2000x1280 at 60 fps to 1080p in 1.7 s
  (6x real time, 70 MB).
- First version leaves out: the camera in Studio (it would be zoomed with the screen; it needs a track of its
  own), motion blur, speed changes, and redaction in the movie.

## Built (2026-10-11)

Recording: the Studio chip on the bar; the stream records without the cursor or click circles while
`TelemetryRecorder` writes down the pointer (60 Hz, `NSCursor.currentSystem`), clicks (a global monitor), and
keys under Settings' mode (Shortcuts only keeps typing as bare presses); stopping keeps the recording in the
history with its project (`<file>.studio/`: telemetry.json, project.json, source.mp4 cloned at first open,
exported.json) and opens the Studio window. The window: preview (the export's composition, filmed at the
view's pixels), transport, timeline (ruler, zoom chips, filmstrip clip, cuts, playhead), inspector
(Background, Frame, Cursor, Zoom, Keys). Export: custom compositor in 4:2:0 with the recording's color tags,
H.264 up to 4096 and HEVC beyond. Specs in DESIGN.md › Studio; measurements in Docs/perf.md › Studio.

Finish review (impeccable-finish-reviewer, disposition fix) — all eight must-fixes applied:
1. Captions follow Settings › Recording › Keystrokes (project `keystrokeMode`; the recorder never writes
   down typing under Shortcuts only; the inspector offers Shortcuts only for a recording that kept all).
2. The frame's shadow is the editor's card shadow (drop 2+10s, blur 8+32s, black 0.14+0.30s); defaults
   match the editor (shadow 0.5, corners 0–40). Corners stay circular arcs, as the editor draws its card.
3. Zoom segments are chips in the chip fill with label ink; the chosen one a 2 pt accent ring; contrast
   hairlines under Increase Contrast.
4. The cursor closes on the pointer over the 0.15 s before a click (and carries the pointer's speed on), so
   the ring lands under its tip; captions carry the reading hairline and floating reading shadow.
5. Undo for every project change, a drag as one step, named steps for the commands.
6. Automatic zooms are a stored setting; with nothing to follow, it stays on and says so.
7. Timeline keyboard (← → ⇧, I/O, Delete), VoiceOver (adjustable playhead, zoom and cut actions), context
   menus, Restore Cut in the transport, grips and resize pointers on zooms.
8. States: the preview's spinner and unreadable-recording state, Cancel on the export card (Esc) and Cancel
   Studio Export in the status menu, and the failure alert's title.
Also taken from its list: the system face for in-window numbers (Rounded-Off-Window Rule), the capsule
swatch edge, the preview's picture border, a spoken transport time, "−0.6 s" on cuts.

Left for later (from the review's nice-to-haves): zooming the timeline for long recordings (a 30-minute
recording leaves under a point a second), Lanczos sampling for sharper text at 2×, Open in QuickTime Player
in the Save menu, Space taking the key from focused controls under Full Keyboard Access.

Checked behind the desktop picture: Undo sent down the window's responder chain as Edit › Undo sends it is
answered by the window with the project's own undo manager (a padding change taken back); a cancelled export
returns nothing, leaves the change waiting, no alert, no progress. Verified only behind the desktop picture
(renders, exports, memory); not yet tried live: the real
record → stop → Studio flow on screen, timeline drags and key routing with a real pointer and keyboard,
the menu bar's progress and Cancel after closing, quitting with an export pending.
