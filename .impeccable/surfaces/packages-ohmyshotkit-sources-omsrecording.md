---
version: 1
slug: "packages-ohmyshotkit-sources-omsrecording"
primary_target: "Packages/OhMyShotKit/Sources/OMSRecording"
related_targets: ["Packages/OhMyShotKit/Sources/OMSCapture/Recording","Packages/OhMyShotKit/Sources/OMSUI/Recording","App/RecordingCoordinator.swift"]
---

# Screen recording (quick mode)

Scope: choosing what to record and what it takes along (the overlay's recording purpose, the setup frame, the recording bar), the countdown, what shows while recording (the area's outline, the control bar, the menu bar's time), and where a recording lands (Quick Access card with its length, Capture History, Settings › Recording). Mode: Operate. Inherits the world in `packages-ohmyshotkit-sources-omscapture`. Studio mode (M4b) is out of scope here.

Audience and task: the author, a few times a day: record a bug, a demo, or a flow on one display of a 2× ultrawide and a scaled XDR panel, usually an area or one window, then drop the MP4 into an issue, a chat, or a document.

Constraints: macOS HIG; nothing of the app is ever in a recording (the bar, outline, countdown, and cards are left out by the content filter); glass only on small HUDs; the app never takes the keyboard from the app being recorded; recording costs no more than the stream and the hardware encoder (Docs/perf.md, M4 spike); no work while idle.

## Direction contract

THESIS: Recording is a capture that runs on: the same overlay chooses it, the same capsules and outline frame it, the same card receives it. Nothing new to learn, nothing in the video that was not on screen.

OWN-WORLD: The capture overlay's dimming, selection frame, size reading, and All-In-One bar; the in-place frame's corners for an adjustable area; a glass recording bar of 30 pt chips (on = selected fill and accent symbol) with the one red in the app on Record and Stop; the Self-Timer disc for the countdown; Self-Timer's outline while recording; a small glass control bar with the time in the reading face.

STORY: Press Record Screen, drag an area (or click for the whole display, or Space for a window), set what it takes along on the bar, press Return, count down, record, stop from the bar, the menu bar, or the shortcut, and find the MP4 copied and waiting as a card.

FIRST VIEWPORT: The live screen dimmed 26% with the chosen area clear, framed with corner arms and its pixel size above its corner; the recording bar 12 pt under it: Computer Audio, Microphone, Show Clicks, a divider, Record, Cancel.

FORM: Pre-record bar → countdown disc → outline + control bar + menu bar time → card, as the user chose on 2026-10-10.

FINISH: unreviewed and undocumented is unfinished; the build ends with the finish review and DESIGN.md's recording components.

## Open decisions

- Decided by the user on 2026-10-10, before the first recording was built:
  - After choosing what to record, a bar under it holds the choices and Record (CleanShot's way), rather
    than recording at once with the choices in Settings. The area can still be moved and resized there.
  - While recording: a small floating bar beside the area (time, Pause/Resume, Restart, Delete, Stop),
    left out of the recording and switchable off in Settings, plus the menu bar's icon turning into Stop
    with the time.
  - The area is marked by its outline only (Self-Timer's white edge over the dark outline); nothing is
    dimmed and no red frame is drawn.
  - Video: H.264 whenever the frame fits the hardware encoder (no side over 4096 pixels), HEVC beyond it
    or when chosen in Settings; 60 frames per second, 30 in Low Power Mode; constant quality 0.6.
- Built in the first cut (2026-10-10): area, window, and whole-display recording; computer audio and the
  microphone (system default input) as tracks of their own, mixed into one when the MP4 is made; clicks as
  the system draws them; the countdown (none, 3, or 5 s; 3 by default); pause, restart, delete, stop; crash
  and quit recovery; Settings › Recording (countdown, controls, pointer, frame rate, video format).
- Not built yet: the microphone's device picker, the camera bubble, keystroke display, GIF, trimming and
  basic editing, Do Not Disturb, and Studio mode.
- Window recordings show no outline (a window moves) and keep their size from the start; a whole display
  shows none either. The control bar goes under the area, above it without room, inside its bottom edge on
  a whole display.
