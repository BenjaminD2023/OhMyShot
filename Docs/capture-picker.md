# Capture magnifier and window selection

Settings → Capture → Magnifier chooses what screenshots (All-In-One and the Self-Timer's choosing too) and Annotate Area show at the pointer before an area is chosen:

- **Magnified** (the default): the 120 pt loupe below and right of the pointer, 15 captured pixels across at 8 pt each, with a faint grid, the accent center cell, and the crosshair at the pointer. It follows the pointer through the drag, so an edge can be put on the exact pixel.
- **Actual Size**: a lens centered on the pointer, Small (75 pt, the default), Medium (90 pt), or Large (120 pt), showing the screen at its own scale with no grid. The picture in it is 75% opaque over a clear backing, so the area under the pointer shows undimmed; Reduce Transparency makes it opaque. Its center cell is the target, in place of the crosshair, stroked white or black against the pixel under it over an outline of the other; the color reading under it is what C copies. Near a display's edge the lens runs off the edge rather than move off its target, and the reading stays on screen.

With Actual Size, the first press puts the lens and its reading away on every display, and the crosshair marks the pointer through the drag. A click with no drag leaves no selection, so the lens comes back: the overlay hides the system pointer, and without it nothing would show where the pointer is.

Pick Color, Capture Text, recording, and scrolling keep the magnified loupe whatever the setting. Sampled and copied colors are the captured pixels, unchanged.

Unit coverage (`OverlayLoupeTests`) includes 1×/2× geometry, display edges, the first press across displays, a click with no drag, late frames, reused sessions and sizes, saturated colors, appearance changes, and the default magnified loupe.

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
