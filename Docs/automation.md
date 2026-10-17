# Automation

OhMyShot can be driven three ways: the `ohmyshot://` URL scheme, Shortcuts (which also puts the actions in
Spotlight), and the Raycast extension in `Integrations/Raycast`. All three run what the menu and the keyboard
shortcuts run.

Debug builds answer `ohmyshot-dev://` instead, and show up in Shortcuts as "OhMyShot Dev".

## URL scheme

The commands and parameters are CleanShot X's
([its documentation](https://cleanshot.com/docs-api)). A script written for CleanShot works after you change
`cleanshot://` to `ohmyshot://`. Unknown parameters are ignored.

The first time an app or a script sends a command, OhMyShot asks whether it may. Apps are approved one by one, by
bundle identifier. Tools that are not apps (`open`, `osascript`, shell scripts) exit before their command arrives,
so they can't be told apart: they are approved, or refused, as one group. You can see and remove approvals, or
turn the URL scheme off, in Settings › Automation. A refusal lasts until the app quits.

Every command needs approval, not only those that read files. A capture run for an app that has no Screen
Recording permission would hand that app your screen. Upload destinations never come from a URL. Commands that
capture the screen open the permissions window when Screen Recording is off.

### Areas

`x`, `y`, `width`, and `height` come together or not at all. They are points on one display, measured from its
bottom-left corner. `display` numbers the displays from 1, the main display, in the order macOS lists them.
Without `display`, the area is on the display under the pointer. An area reaching past its display is cut to fit.
An area off its display, or a display that isn't attached, makes OhMyShot beep and do nothing.

### After a capture: `action`

`action` is one of `copy`, `save`, `annotate`, `upload`, or `pin`. It is done on top of what Settings says
should happen after a capture:

| `action`   | What happens                                                                                   |
|------------|------------------------------------------------------------------------------------------------|
| `copy`     | The capture is copied, even if Copy after capture is off.                                      |
| `save`     | A copy is saved to the export folder, even if Save after capture is off. It is written in the format Settings › General chooses, and never asks for a name. |
| `annotate` | The capture opens in the editor. No Quick Access card, nothing copied.                         |
| `upload`   | The capture goes to the default upload destination. With none set up, nothing is captured.    |
| `pin`      | The capture stays on screen as a pin where it was taken. No card, nothing copied.              |

### Commands

| Command | Parameters | What it does |
|---|---|---|
| `all-in-one` | area | Opens All-In-One. With an area, the area comes framed with All-In-One's bar, to adjust and then capture, copy, save, annotate, pin, upload, read, scroll, or record. |
| `capture-area` | area, `action` | Opens Capture Area. With an area, captures it at once without the overlay. That area is the next Capture Previous Area. |
| `capture-previous-area` | `action` | Captures the area chosen last again, as the screen shows it now. Beeps if no area was chosen since launch. |
| `capture-fullscreen` | `action` | Captures the display under the pointer. |
| `capture-window` | `action` | Opens Capture Window. |
| `self-timer` | `action` | Opens Capture Area. What you choose is captured once the Self-Timer delay is over. |
| `scrolling-capture` | area, `start`, `autoscroll` | Opens Scrolling Capture. With an area, the scrolling bar comes up around it. `start=true` starts the capture without the bar, at once when there is an area. `autoscroll=true` lets the app scroll (needs Accessibility). While a scrolling capture runs, finishes it. |
| `pin` | `filepath` | Pins the picture at `filepath`. Without one, asks for a file. |
| `record-screen` | area | Opens Record Screen. With an area, the recording bar comes up around it. While recording, stops. |
| `capture-text` | `filepath`, area, `linebreaks` | Opens Capture Text. With an area, reads that area at once. With `filepath`, reads the picture's text without showing it. The text is copied. `linebreaks=false` joins wrapped lines. |
| `open-annotate` | `filepath` | Opens the picture or `.ohmyshot` project at `filepath` in the editor. Without one, asks for a file. Pictures are added to Capture History first. |
| `open-from-clipboard` | | Opens the clipboard's picture in the editor. |
| `toggle-desktop-icons`, `hide-desktop-icons`, `show-desktop-icons` | | Covers the desktop icons with a picture of the wallpaper, or removes the cover. See [Desktop icons](#desktop-icons). |
| `add-quick-access-overlay` | `filepath` (required) | Adds a copy of a picture, an MP4 or MOV, or a GIF to Capture History and shows its Quick Access card, whatever Settings says about cards. The file itself is left where it is. |
| `open-history` | | Opens Capture History. |
| `restore-recently-closed` | | Brings back the capture whose card closed last. |
| `open-settings` | `tab` | Opens Settings. Our tab names work, and so do CleanShot's: `wallpaper` and `screenshots` open Screenshots; `quickaccess` opens Quick Access; `annotate` opens Tools; `cloud` opens Sharing; `advanced` opens Automation. |

`filepath` must be an absolute path. A leading `~` is expanded. Percent-encode the path. A `+` is read as a plus
sign, not as a space.

```sh
open "ohmyshot://capture-area?x=0&y=0&width=800&height=600&display=1&action=save"
open "ohmyshot://capture-text?filepath=$HOME/Desktop/receipt.png&linebreaks=false"
```

### Desktop icons

Hiding the desktop icons lays a picture of the wallpaper over them on every display. The picture sits just above
the icons, so every window stays above it, and Finder is never restarted. It is taken from the windows that draw
the wallpaper, so dynamic and photo wallpapers look as they do on screen. Without Screen Recording permission,
the picture is drawn from the wallpaper's file instead.

The picture is taken again when you switch Spaces, when the Mac wakes, and when Dark Mode turns on or off. In
between, a wallpaper that changes on its own stays as it was. While the icons are hidden, clicks on the desktop
do nothing: hidden icons can't be selected or opened by accident, but the desktop's menu isn't there either.
Screenshots show the desktop as it looks, without the icons. The choice is remembered when OhMyShot restarts.

The menu bar menu has Hide Desktop Icons too.

### The Share extension's URL

The `share` command is not part of CleanShot's API, and nothing else should send it: it is how OhMyShot's Share
extension (OhMyShot in other apps' Share menus) tells the app that pictures are waiting. It is answered without
approval, and works with the URL scheme turned off, because choosing OhMyShot in a Share menu is the approval.
It carries no path, only the name of a folder in the app's own Share Inbox (`~/Library/Application Support/<bundle
identifier>/Share Inbox`) and what to do with it (`action=annotate` or `pin`). The app opens only the pictures it
finds directly in that folder, and removes the folder afterwards.

## Shortcuts and Spotlight

These actions appear in the Shortcuts app under OhMyShot:

| Action | Input | Output |
|---|---|---|
| Capture Area, Capture Window, Capture Fullscreen, Capture Previous Area, Self-Timer | After Capture (optional): Copy, Save, Annotate, Upload, Pin | The screenshot, as a file in the format Settings › General chooses (PNG, JPEG, or HEIC, at 1×, in sRGB, with a border, as set; a save a shortcut asks for never asks for a name), or nothing when the capture was cancelled |
| Capture Text | Keep Line Breaks | The text copied, or nothing |
| Recognize Text in Image | An image, Keep Line Breaks | The image's text. Nothing is copied or shown. |
| Pin Image | An image | |
| Annotate Image | An image | |
| Record Screen | | |
| Scrolling Capture | Auto-scroll | |
| Open Capture History | | |
| Hide or Show Desktop Icons | Hide, Show, or Toggle | |

Capture Area, Capture Window, Capture Fullscreen, Capture Text, Record Screen, Scrolling Capture, Open Capture
History, and Desktop Icons are also App Shortcuts. They work in Spotlight and with Siri without making a
shortcut first.

Shortcuts need no approval in Settings › Automation, because you built the shortcut yourself. The URL scheme
being off doesn't affect them. The capture actions wait until the capture is kept, so the next action gets the
picture. That is what CleanShot's URL API can't do. Actions that capture the screen fail with a message when
Screen Recording is off.

## Raycast

`Integrations/Raycast` is a Raycast extension with these commands: Capture Area, Capture Previous Area, Capture
Fullscreen, Capture Window, and Self-Timer (each with an optional After Capture choice), All-In-One, Scrolling
Capture, Record Screen, Capture Text, Recognize Text in Image, Pin Image, Annotate Image (the last three act on
the image selected in Finder), Annotate Clipboard Image, Toggle Desktop Icons, Open Capture History, Restore
Recently Closed, and Open OhMyShot Settings. Each one sends a URL command. The first one makes OhMyShot ask once
whether it may be controlled. Depending on how Raycast opens the URL, the request names Raycast or command-line
tools; approving command-line tools lets every script send commands. (Not yet tried with Raycast installed.)

To try it, run `npm install && npm run dev` in `Integrations/Raycast`. Raycast then lists the commands. Its App
preference chooses between OhMyShot and OhMyShot Dev. Before publishing to the Raycast Store, set `author` in
`package.json` to your Raycast username. `ray lint` rejects any name Raycast doesn't know. The extension's own
files are MIT-licensed, as the Store requires.
