# Capture picker

Screenshots, All-In-One, the Self-Timer's area selection, and Annotate Area use a color picker centered on the pointer before an area is chosen. Its center cell marks the exact captured pixel; the grid separates neighboring pixels, and four short target ticks make the center easy to find at low magnification. The center border changes between light and dark against the sampled pixel, with an opposite-color outline.

Settings → Capture has two independent controls:

- **Color picker size**: Small (75 pt, the default), Medium (90 pt), or Large (120 pt).
- **Color picker magnification**: approximately 1×, 2×, 4× (the default), or 8× per captured device pixel. Changing magnification keeps the picker diameter fixed. An odd number of cells keeps one exact center pixel at every size and display scale.

The picker image is slightly translucent; Reduce Transparency makes it opaque. Near a display edge, the lens clips at the edge rather than move away from its target, while the color reading stays on screen. The system pointer stays hidden over the screenshot canvas and returns over the toolbar, including the hand cursor on its drag grip.

The first area press hides the picker, its reading, and the separate crosshair on every display, before the selection has any size. They stay hidden for the rest of that selection session, including after a click with no drag, late frames, pointer movement, and switching selection modes. A new capture session restores the picker. The selection's border and size reading still identify the chosen area.

These size and magnification preferences apply to the next screenshot or Annotate Area session. The standalone **Pick Color** tool keeps its existing offset magnifier and crosshair. Capture Text, measurement, recording, and scrolling keep their own pointer behavior. Styling and magnification never change the sampled or copied color.

Settings → Capture → **Copy color shortcut** defaults to **Option + Left Click**. Before starting an area selection, or while using Pick Color, this gesture copies the color under the mouse without starting a selection or closing the overlay. Choose Option, Control, Command, Shift + Option, Command + Option, or Off. Only the selected modifier combination and the left mouse button trigger it; other clicks retain their usual behavior. Existing keyboard color actions, including C and Option-Return, remain available.

Regression coverage includes picker geometry at 1×/2× display scales, every size and magnification, exact pixel sampling, display edges, first-press suppression across displays, reused sessions, adaptive contrast, native cursor handoffs, and the full modifier-click press/drag/release sequence.
## Windows on other displays and Spaces

**Window** is the single entry in Capture Area, Record Screen, and All-In-One. **W** opens the app preview chooser. Capture Window opens it directly, without first capturing or covering every display. Space keeps the quick, native-style interaction: point at a visible window and click it.

The chooser starts with the app that was in front. It shows one actual window preview and a horizontally scrollable strip of app icons. Click another app to preview its window. Only when that app has multiple windows does a window switcher appear; it remembers the last chosen window of each app. Capture / Record acts on the displayed target. The search button (or Command-F) reveals app/window search when needed. Left/Right switches apps. Return captures or records. Escape closes search first, then goes back to selection (or cancels a direct Capture Window); Back provides the same way out with the pointer.

A window recording shows computer audio, microphone, Options, Record, and Cancel. Format (Video / GIF / Studio), clicks, and supported keystrokes live in Options. Unsupported camera controls are absent. Microphone selection and permission behavior stay the same as area recording.

The catalog includes off-screen windows from normal applications across all displays and Spaces, excluding our own UI, system/helper processes, and tiny utility surfaces. Visible windows retain their stacking order; full-screen game surfaces at elevated levels are eligible too. Applications are grouped before they reach the interface, so an app with twenty windows is still one app choice. Only the selected window gets a bounded preview; there is no thumbnail capture of every window, no continuous preview stream, and no idle polling. A changed selection clears the old image immediately; a late result cannot replace the new target. Capture / Record stays unavailable until that target's preview succeeds. An unavailable target has an inline retry; Command-R refreshes the catalog.

The chooser and overlay take key focus through nonactivating panels. Neither brings the target app forward, moves it, nor exits its full-screen Space. The capture remains a desktop-independent window filter, with a fresh target lookup when capturing or recording starts. The target's own display supplies display metadata, and its owning app supplies the recording's name. Scrolling and in-place annotation continue to work on visible screen regions. Apps that stop rendering in the background still require testing with that app.

`WindowPickerTests` and `OverlayKeyTests` cover grouping and defaults, remembered window choices, hidden-window search, one-preview-at-a-time behavior, late async results, unavailable targets, nonactivating panel configuration, compact controls, keyboard entry, and light/dark layout. `OMS_WINDOW_PICKER_SNAPSHOTS` exports fixture-only review images when running these tests.

Manual checks on macOS:

1. Invoke Capture Window while a game is full screen; verify it previews that app and Escape returns input without leaving full screen.
2. From another display or Space, click Window, choose the game's icon, verify its preview, and capture it. Check that the resulting image belongs to the game.
3. Record that window with audio, return to the game's Space, and stop with the recording shortcut. Check the movie and app name.
4. Switch apps quickly, change windows within one app, search and clear search, and go Back. Verify the displayed preview always matches the capture target.
5. Close a chosen window or disconnect its display. Verify an unavailable preview cannot start recording, and a display-topology change cancels selection safely.
