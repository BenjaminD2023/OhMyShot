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
- Built in the second cut (2026-10-10, the user said to go on with the features; each took CleanShot's
  form, reported to the user to veto):
  - GIF as an output: Video and GIF chosen on the bar as the All-In-One bar's modes are; a GIF has no sound,
    so the two sound chips step back while it is chosen. The movie is recorded as always and made into a GIF
    when stopped (`GIFMaker`: ImageIO encodes each frame alone, frames written as they come, unchanged runs
    merged, only the changed box written, 15 fps by default, as large as things were on screen, at most 1920
    pixels); the menu bar shows how far along it is. Settings › Recording › GIF sets the frame rate.
  - The recording window (basic editing): a standard window with the movie in an AVPlayerView and a toolbar:
    Trim (QuickTime's trimming bar), Sound on or off, Size (full, three quarters, half, a quarter, shown as the
    size it makes), Make GIF, Save (Save As…, Open in QuickTime Player, Revert to Original), Copy. Edits are
    kept in the recording when it leaves the window and when the window closes, the recording as it was made
    kept beside it, as the annotation editor keeps marks. A GIF only plays there. Double-click on a recording's
    card opens it; Edit… in the card's and History's menus too.
  - The microphone chip opens a menu of the Mac's microphones (No Microphone, then each device; the system's
    default checked until one is chosen by name); one that is gone at recording time gives way to the default.
  - Keystrokes: a chip on the bar and Settings › Recording › Keystrokes (All keys, or Shortcuts only:
    keys with ⌘, ⌃, or ⌥, and the function keys). A large reading capsule 28 pt above the bottom of what is
    recorded, in its materials and face, recorded with it; typing runs on, shortcuts by their symbols; needs
    Input Monitoring.
  - The camera: a chip with a menu (No Camera, the Mac's cameras, Shape, Size, Mirror); a bubble (circle or
    rounded square, 120/180/260 pt, white ring, soft shadow, mirrored by default) 24 pt in from the bottom-left
    corner of what is recorded, shown as soon as it is chosen so it can be placed, dragged anywhere on its
    display; double-click fills what is recorded.
  - Keystrokes and the camera are windows on screen that the recording's filter takes in, so a window
    recorded on its own (which takes that window alone) has neither: their chips step back for windows.
- Finish review of the second cut (2026-10-10), fixes applied: Input Monitoring and camera access are asked at
  the chip, before anything records, and a chip without access steps back with a tooltip saying where to turn
  it on (still pressable); the camera bubble's panel leaves 28 pt for its shadow, shows the capsule surface
  before the first frame, never a dark disc, and nothing at all without access or a camera, takes a contrast
  hairline under Increase Contrast, fills through a 0.12 s fade, and goes under the menu bar when filling a
  recording; the control bar keeps clear of the keystrokes inside a whole display; the recording window is
  sized to the movie as it was on screen plus the toolbar, its busy card is opaque, a failure after it closed
  gets an alert of its own, and Revert to Original also forgets unkept edits; the menu bar keeps its menu
  while a GIF is made; the keystrokes fade over 0.12 s; mode chips are 84 pt as the All-In-One bar's.
- DESIGN.md records the recording components (Screen Recording, Recording Window) as of the second cut.
- Built after the second cut (2026-10-11, the user said to go on): the microphone's meter on the control bar
  (the system's mic-and-meter symbol, fed by the stream's own microphone buffers, ten times a second, never a
  second capture), and accent click rings as Settings' other click style (a clear window over what is
  recorded, taken in by the filter like the keystrokes; the stream's own circles off meanwhile).
- Not built, and why: a virtual camera (a Core Media I/O extension, out of proportion), Do Not Disturb (macOS
  has no public way to turn on a Focus), the 6K power gate (the ultrawide is not attached), Release-build
  measurements (the hooks are Debug-only); Studio mode is next, in a brief of its own.
- Window recordings show no outline (a window moves) and keep their size from the start; a whole display
  shows none either. The control bar goes under the area, above it without room, inside its bottom edge on
  a whole display.

## Replay (2026-10-11)

The plan's last M4 item (P2, macOS 27's `SCClipBufferingOutput`). Measured first (Docs/perf.md › Replay
spike), then decided by the user the same day: turned on by hand in the menu bar and off when the app quits;
the user chooses which displays are kept, one checkmark each; the system's sound and the microphone are both
kept, and each saved clip keeps both, one, or neither, as the menu's Sound in Saved Clips says (a remembered
setting, since a shortcut can't ask); a saved clip is kept as a recording is (history, clipboard, card). Two
calls made and said: Save keeps every display kept, one clip and card each; the orange microphone dot stays
on while the replay keeps the microphone.

Built: OMSRecording `ReplayBuffer` (one per display: the recording filter's own-window rules, frames scaled to
fit 4096, a frame-dropping screen output the buffer needs, the export into a fresh file, `nothingChanged` for
replayd's empty buffer), `RecordingFinisher.AudioTracks` (which tracks a finished file keeps; the clip's
system track comes before the microphone's, as measured by level with the user's word), OMSCore
`ReplaySound` + `SettingsStore.replaySound`, `CaptureShortcut.saveReplay` (dev ⌃⌥⌘-, release none; hidden
below macOS 27), status menu entries with checkmarks and a submenu made each time it opens, App
`ReplayCoordinator` (microphone access asked before keeping starts, one save per display through
`RecordingCoordinator.keepReplay`, quitting waits for saves, then stops the buffers). Specs in DESIGN.md ›
Replay.

Finish review (disposition fix), all applied: a buffer that failed left its stream running (now stopped, with
a beep; `ReplayBuffer.Ending`), unchecking a display during a save or while it started (now deferred or
cancelled), a second Save over the first (now one at a time, the menu item dims), the start-failure wording
and a non-localized fallback; and the nice-to-haves: an announcement for Save with nothing kept, one
announcement for all displays saved, and the microphone choices stepping back without access.

Verified behind the desktop picture on the app's own scrolling window (`debug/replay`): keeping, saving with
each sound choice (tracks kept as chosen), and turning off with the capture lease released. Not tried live
(it keeps the user's screen, so it waits for their word): a real display kept, a save with its card, the
microphone kept while saving each way, a display unplugged while kept, Low Power Mode.

