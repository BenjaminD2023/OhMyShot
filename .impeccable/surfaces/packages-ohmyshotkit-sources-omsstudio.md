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
  own), motion blur, speed changes, and redaction in the movie. The camera and motion blur came in the
  second cut (below).

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

## Second cut (2026-10-11)

What the plan's Studio row still listed (摄像头布局, 动态模糊, 打字隐藏), with conventional defaults rather
than new decisions:

- The camera: chosen on the bar as for Video, its bubble shown on screen but kept out of the stream; a
  `CameraRecorder` (OMSRecording) adds an `AVCaptureVideoDataOutput` to the bubble's session and writes the
  camera's frames, unmirrored, into `<draft>.camera.mov` through a second `RecordingWriter` given the same
  pauses, so the two movies stay in step on the host clock; it finishes where the screen's movie ended.
  Telemetry keeps where the camera's movie begins on the recording's timeline, when the bubble was
  double-clicked to fill what was recorded, and the bubble's look (shape, size, mirror, nearest corner),
  which the project starts from. The composition takes the camera as a second video track, cut as the
  recording is, its nearest frame held where it has none; the renderer draws it in its bubble 24 pt in from
  a corner of the recording's frame, never zoomed, with the bubble's continuous corners, ring, and shadow,
  or filling the frame while it did (composited into the frame's contents before its shape is cut, so
  nothing under it shows at the soft edges), crossfading 0.25 s. Inspector: Camera (Show, Shape, Size, Corner, Mirror).
- Motion blur, on by default: while the camera zooms or pans, each frame is exposed over half a frame of
  the movie's 60 from up to 32 positions (1.5 pixels apart at the frame's edges, the blur at most 1% of the
  movie's longer side); still, one exposure. The cursor and everything over the recording stay crisp.
  Inspector: Zoom › Motion blur.
- The cursor fades while typing (keys without ⌘⌃⌥, never function keys) and comes back on a move or
  click. Inspector: Cursor › Hide while typing, when keys were written down.

Finish review (impeccable-finish-reviewer): first pass asked for recaptures (the renders predated the last
edits) and flagged two real faults, both fixed: circular-arc corners on the rounded-square bubble (now
continuous, from SwiftUI's continuous rounded rectangle) and the recording showing through along a filled
frame's edges (the camera now goes in before the frame's shape is cut, and scaled images are clamped to
their extent first, since a scaled image's outermost pixels blend with clear;
`aFilledCameraLeavesNothingOfTheRecordingAtItsEdges`). Second pass on fresh captures (disposition fix), all
applied: the change between bubble and full frame showed the person twice (now the bubble fades out over the
first half and the frame fills over the second, as the live bubble fades out and in;
`theCameraIsNeverShownTwice`); a camera that showed but couldn't be recorded was dropped silently (now
`StudioTelemetry.cameraFailed` and a callout, "The camera couldn’t be recorded.", in the Camera section);
DESIGN.md's Future Surfaces still listed the camera and motion blur; and, of the nice-to-haves, the Motion
blur tooltip's wording, VoiceOver names Camera shape / Camera size, the camera chip's reason for a window
recorded for Studio, and nothing drawn under a camera that covers the frame.

Verified behind the desktop picture with a made-up camera (never the user's): renders light and dark,
rounded square and circle, every corner, a filled stretch; 4K exports with blur and camera (Docs/perf.md ›
Studio); the camera kept in step around a cut and before it began (`theCameraKeepsInStepAroundCuts`), and
compositions a player can draw (`aMovieWithTheCameraIsOneAPlayerCanDraw`, after an empty preview: a track a
6000th of a second past the instruction). Not tried: recording with the real camera (it records the user,
so it waits for their word), the bubble double-clicked while recording, a camera unplugged mid-recording.

Left for later: editing when the camera fills the frame (it follows the recording), the camera for windows
recorded alone, speed changes, redaction in the movie, a GIF from Studio, zooming the timeline.

## Built (2026-10-25): timeline detail and editing feedback

The timeline opens fitted to the whole recording. Fit returns to that view; Fit Selection frames the chosen
zoom, cut, camera layout, or range with room on either side. The minus and plus magnifying-glass buttons halve
or double the timeline's magnification, keeping the playhead at the same position in the view; an offscreen
playhead is centered first. The closest view spans one second, or the whole recording when it is shorter.
The viewport is window state only: it is not written to the project, changes no edit times, and starts fitted
again when the project reopens.

At magnification, a native horizontal scrollbar shows how much of the recording is visible; its thumb and
wheel or trackpad scrolling move the visible range. Playback and keyboard seeking bring an offscreen playhead
back into view. Only visible zooms, cuts, camera layouts, ruler ticks, and thumbnail slots are drawn. The
timeline is 180 pt high, or 208 pt with the camera-layout lane, including its view controls and scrollbar.
The inspector, semantic colors, selected outlines, and contrast responses keep the existing visual system.

The thumbnail grid is anchored to recording time, so nearby views reuse frames. It requests at most 65 slots
for the current viewport, waits 80 ms for rapid navigation to settle, and decodes pictures up to 640 × 80 px.
The per-window cache retains at most 96 pictures and 24 MiB, evicting the least recently used entries; the
visible pictures share those image objects. Changing the viewport cancels its previous request and pending
image generation. A generation check rejects late results; an unreadable frame leaves its own slot empty
instead of shifting later pictures to an incorrect time. Closing the view ends its thumbnail task.

There is one selection shared by every control: a range, zoom, cut, camera-layout segment, or nothing.
Dragging a range and marking it with I/O release any previously selected object. Choosing an object by mouse,
keyboard, or VoiceOver releases the range. Delete and the transport's Cut use the same document command, so
their target cannot disagree. With the timeline focused, Option-← and Option-→ choose the preceding or next
edit in recording-time order and bring it into view; Escape clears the selection. The existing ←/→ seeking
(Shift for a second), I/O marking, Delete, context menus, and VoiceOver actions remain. A timeline tooltip
lists these navigation commands.

A chosen zoom or camera-layout segment has Start and End fields in its inspector section. They accept
seconds, minutes:seconds, or hours:minutes:seconds, including fractional seconds, and display milliseconds.
Return or leaving the field commits one change; incomplete typing does not move an edit. Invalid input says
"Enter a time such as 0:12.500." Valid input is constrained by the document's duration and segment limits,
and the fields show the effective result. Choosing either kind of segment scrolls its controls into view.
Add Layout is unavailable when there is no room at the playhead, with a reason in its tooltip, as Add Zoom is.

A fixed 24 pt status row under the transport says "Project saved" or "Saving project…" without changing the
preview's size. A failed write says "Project changes haven’t been saved", exposes the system reason through
help and accessibility, and offers Retry Saving. Project saves are asynchronous, serial, and coalesced;
ending a drag requests an immediate save, and exporting or closing waits for the latest project revision.
A failed project save keeps the window open and cancels an app quit rather than losing the editable project.

The first preview has its preparing spinner. Updating an existing preview keeps its previous image and adds
a small "Updating preview…" reading near the bottom. Failure identifies an unreadable first preview or one
that could not be updated, gives the reason, and offers Retry Preview; an old image is not silently presented
as the latest edit. Playback failures use the same visible state. These are window controls and feedback,
not elements drawn into the exported movie.

Verification for the 2026-10-25 refinement: rebuilt the native app and captured only the synthetic Studio
demo, in light appearance at 1180 × 780 pt and dark appearance at 900 × 560 pt content size. A first pass
caught duplicated time-field labels; the confirmation pass verified their removal, visible duration,
transport, viewport controls, and scrolling inspector. The app's own accessibility tree successfully
pressed Zoom In Timeline and Fit Selection; the zoomed capture shows the new ruler range and horizontal
scrollbar. The accessibility audit found names for the new controls; its one unnamed toolbar split-menu
segment is the existing SwiftUI limitation documented above. This was not a physical-keyboard/VoiceOver
session or a test of every system accessibility setting. Synthetic demo entries were removed afterward.

Additional remaining-issue validation (2026-10-25): the demo window now has an opt-in `keyboard-check` action
covering 15 real responder/AX behaviors, including Option-arrow selection, object/range Delete and Undo,
I/O, arrow seek, accessible time-field input/Return, and AX playhead adjustment. All passed; the structured
record is in `Docs/benchmarks/studio-keyboard-2026-10-25.json`. A generated 30-minute file also completed
preview seek and real compositor/encoder export; `Docs/perf.md` records its 1 fps source, 60 fps composition,
measured timing, process/Metal resource peaks and idle results. These do not stand in for human VoiceOver
speech testing or watt-level power measurement. Save As now stages a complete sibling copy and atomically
renames it over the destination; copy failure or cancellation preserves the user's previous file.
