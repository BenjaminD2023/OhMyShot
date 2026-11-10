# Changelog

All notable changes to OhMyShot will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
Each version is published as a GitHub release with a matching tag; its section here is the release's notes.
This initial backfill groups notable app changes from the first commit through [42c6bfa]; documentation-only work, internal refactors, and unmerged proposals are omitted.
Each entry links its implementation commits or merged pull request and credits verified contributors. Named coauthors follow explicit commit trailers.

## [Unreleased]

### Stay up to date

- **Updates, closer to you.** Checks use the OhMyShot website for both the update feed and download, with GitHub as a backup.
- **Easy to spot.** An update stays at the top of the menu, with an arrow beside the menu bar icon. A reminder lets you update now or come back tomorrow.

### A fresh welcome

- A new **What’s New** window opens after updating, with release notes available offline.
- Release notes support Markdown headings, lists, links, emphasis and code, with an optional bundled banner.

### Always your choice

- Updates are checked at launch and every six hours. Downloads and restarts still wait for your confirmation.

### Added

- Window opens a chooser that previews every app's windows on any display or Space, full-screen games included, without bringing the app forward or leaving its Space; Capture Window opens it directly. ([0946850]; by [@fzlzjerry])
- A getting-started guide for new installations walks through allowing Screen Recording, freeing the screenshot keys macOS still takes, and a real first capture, whose Quick Access card gets a hint naming its Copy, Save, and Annotate buttons. The status menu and Settings › General replay it. ([bf3ce5e]; by [@fzlzjerry])
- A click on the menu bar icon opens a capture launcher: every command that takes a shortcut is a tile, whose keys (or Set Shortcut, while it has none) open Settings › Shortcuts on its row; every other command of the status menu (Images & Pins, Getting Started, Join Discord, Keyboard Shortcuts…, Debug, Quit) is a row, those with more choices opening a menu in place. A right-click still opens the status menu. ([6bda14e]; by [@bobbyhuang-dev]; coauthored by Codex and Claude Opus 5.5)
- The capture launcher answers the arrow keys: they move a highlight across its tiles and rows as a menu's do, passing over dimmed commands, and Return or Space presses the command they reach. ([db7bffc]; by [@fzlzjerry])
- In the window chooser, Up and Down go through the chosen app's windows, as Left and Right go through the apps. ([84a0c3a]; by [@fzlzjerry])
- The camera bubble can be placed and made to fill the recording without dragging or double-clicking it: before recording, the recording bar's camera menu has Position (each corner) and Fill the Recording; VoiceOver offers the same as the bubble's actions at any time. ([ea1e905]; by [@fzlzjerry])
- In the editor and when marking up in place, Text and the dragged shapes (Arrow, Line, Rectangle, Ellipse, Highlight Box, Redact, Spotlight) put themselves down once their mark is made, and Select takes over: a click away from text you wrote finishes it instead of starting another, and a shape just drawn is selected to adjust. Pen, Highlighter, and Counter stay in hand, and the next editor still opens with the tool you last picked. ([f69d36e]; by [@bobbyhuang-dev])

### Fixed

- Escape stops Capture Text, Capture Formula, and Translate Area while the selection is still highlighted, so a reading the system holds up (the first after a macOS update can take over 30 seconds) no longer has to be waited out. ([7cfd445]; by [@fzlzjerry])
- Studio's Plain color is a tile beside the gradients that opens the Colors panel, every time reads to the hundredth in one format, saving is reported under the window's title, and Fit and Fit Selection look like buttons. ([7502f44], [0b20def], [9514883]; by [@fzlzjerry])
- The editor sets kept colors apart from the inks with a divider and no longer offers to keep a color that is indistinguishable from an ink; Other Color… no longer changes the window that last used the Colors panel, and opening an editor no longer logs broken layout constraints. ([4353a67], [bae605a], [5fb5917]; by [@fzlzjerry])
- Scrolling capture's Auto button uses Auto-scroll's arrow instead of a triangle that looked like a pop-up menu. ([be0a7ed]; by [@fzlzjerry])
- Settings' pop-up choices use sentence case throughout, and each model pack has its own symbol. ([2323913], [5203022]; by [@fzlzjerry])
- The editor's Picture menu and a Quick Access card's Transform menu use a rotate symbol instead of a crop symbol. ([4601011]; by [@fzlzjerry])
- The editor's eyedropper tooltip, a locked pin's Unlock button, and the overlay's window count are translated. ([4c48f7e]; by [@fzlzjerry])
- Capture Text no longer waits about 37 s and copies nothing after a cleaner empties `~/Library/Caches` or macOS updates: the app compiles Vision's text models again in the background as soon as they are gone. ([81a46de]; by [@fzlzjerry])
- A first reading that has to wait for Vision's models to compile (about 37 s) now finishes: Capture Text, Translate Area, and the Recognized Text window wait up to 60 seconds instead of 30, and Escape still stops them. ([7304cae]; by [@fzlzjerry])
- The What’s New banner shows OhMyShot's own mark (the app icon's ground, the loupe, and the wordmark) with type that reads on it, in place of a gradient and a viewfinder of its own, and a list item's wrapped lines start under its text. ([b2b2471]; by [@fzlzjerry])
- The capture launcher no longer cuts command names short in French and Spanish (a row's name takes a second line, and Set Shortcut fits its capsule), its tiles are easier to see in Dark, and Set Shortcut no longer sits on a wash of the accent. ([db7bffc]; by [@fzlzjerry])
- The first-capture hint's Got It no longer looks dimmed, and the hint casts the same shadow as the Quick Access card beside it. ([3ba14d1]; by [@fzlzjerry])
- The window chooser's preview and app tiles have the continuous corners the rest of the app has, a tile shows a focus ring under Full Keyboard Access, a long app name is shown whole when the pointer rests on it, and Increase Contrast applies as it is switched. ([84a0c3a]; by [@fzlzjerry])
- The getting-started guide's step numbers and keycaps use the system typeface, a failed first capture's note no longer has an orange tint, and only the step itself fades when the step changes. ([d955c65]; by [@fzlzjerry])
- Capture History no longer stops searching a capture whose text reading failed until the app relaunches: it is read again with the next capture, up to three times, and once more when History opens. ([71ba1c3]; by [@fzlzjerry])
- Taking a capture no longer lists the whole history on the main thread (17 ms with 300 captures, 280 ms with 5,000), and a card's actions find their capture at once; with Settings changing the file format or scale, a capture is converted for dragging out ahead of time instead of when the drag starts (up to 150 ms), and History's Copy converts in the background. ([b5acc7d], [dc8b831]; by [@fzlzjerry])
- In Chinese and Japanese, sentences put together no longer take a stray space or a Latin period; VoiceOver counts in the editor use singular and plural ("1 suggestion to redact"); Studio's decimals use the language's separator; a retention inside a sentence uses the system's own words for the duration; and a Custom HTTP destination's kind is translated. ([f2b90c0], [fa9a2c0]; by [@fzlzjerry])
- A failed Launch at login explains itself and offers System Settings instead of showing the system's error in red; the update reminder's title no longer ends in an ellipsis; a Studio preview that fails says what that means and keeps the system's reason in its tooltip; and Settings, the model pack's description, and Shortcuts name things as the app does (Capture History, Recognized Text). ([a98c3a5], [1050f8b], [fa9a2c0]; by [@fzlzjerry])
- Increase Contrast and Reduce Transparency take effect at once on Quick Access cards, the Recognized Text picture, the recording control bar, and the camera bubble; the auto-close ring on a card starts at twelve o'clock, reads on light pictures, and steps once a second under Reduce Motion. ([a336488]; by [@fzlzjerry])
- The camera bubble's ring and shadow follow its rounded corners, so a recording and its Studio export match; a History recording's badge matches the Quick Access card's, and History's hover controls fade in; shadows follow continuous corners and are no longer cut off at the scrolling panel's, the keystrokes', and the Copied note's edges; window notices in Studio, the recording window, and History look alike; Studio's keystroke captions keep their digits steady, and its chosen click color is ringed in label ink. ([3009de2], [33ce73f], [f29ccf0], [44be1b8]; by [@fzlzjerry])
- The app no longer logs broken layout constraints at launch or each time an editor opens. ([c66815b]; by [@fzlzjerry])
- Text typed in the editor is shown whole while it is typed: a long line's last words are no longer cut off at the field's edge when the picture is zoomed out (as a Retina capture is, and always in place), and the field wraps where the mark does. ([f69d36e]; by [@bobbyhuang-dev])
- Selected text shows on a white or black label, where the selection had no color of its own. ([f69d36e]; by [@bobbyhuang-dev])


## [0.1.0] - 2026-11-03

### Added

- Area, window, and full-display screenshots, Quick Access cards, and Capture History with configurable retention; selections can cross displays and use a self-timer. ([c999cc0], [47460d9], [4fba5e2]; by [@fzlzjerry])
- An annotation editor with drawing, shapes, text, blur, pixelation, and counters; backgrounds, combined images, and editable project files. ([82a1188], [72d434f]; by [@fzlzjerry])
- Annotation directly on the frozen selection, plus image resizing, rotation, flipping, highlight boxes, ratio crops, and saved colors in the editor. ([3301d5f], [6945ecb]; by [@fzlzjerry])
- Always-on-top pins for pictures, clipboard text, and colors, with Live Text in picture pins. ([c74adf4], [f8ecfb2], [fea8757]; by [@fzlzjerry])
- A screen color picker and pixel ruler for measuring distances and areas. ([f973024]; by [@fzlzjerry])
- OCR-based redaction suggestions and a highlighter that snaps to recognized text. ([e69955f], [b2c60ff]; by [@fzlzjerry])
- Capture Text copies recognized text from a selection; the Recognized Text window shows the image beside editable text, line-break controls, tables, and detected links and codes. ([c6b6b58], [8df4f3f]; by [@fzlzjerry])
- Translation in the OCR window and an in-place Translate Area overlay. ([0d924fd]; by [@fzlzjerry])
- Text search across Capture History, with recognition performed by a background helper. ([b9474f8]; by [@fzlzjerry])
- Optional downloadable on-device OCR model packs, with a second reading alongside Vision in the OCR window and History search. ([18059d3], [70711ac]; by [@fzlzjerry])
- Capture Formula and an optional formula pack; recognized formulas are inserted as LaTeX in Capture Text, the OCR window, and image-recognition automation. ([0897744], [cfbe3ac]; by [@fzlzjerry])
- Optional cloud OCR using a configured model and the user's own API key, including Read with in the OCR window and fallback to the Mac's reading. ([34f042b], [0f80678]; by [@fzlzjerry])
- Optional text supplied by the source app to refine recognized characters in Capture Text and the OCR window. ([9b5aa53]; by [@fzlzjerry])
- An optional VLM model pack for reading tables and charts within recognized text. ([1971598]; by [@fzlzjerry])
- Screen and window recording, GIF export, microphone and system audio, camera overlays, and displayed keystrokes. ([3e37cd6], [8ddb274]; by [@fzlzjerry])
- Studio editing for recordings, including automatic zooms, camera layout, motion blur, cursor and click effects, and adding keystrokes after recording. ([dd88b79], [195f1df], [131e96f]; by [@fzlzjerry])
- Scrolling Capture with manual scrolling and Auto-scroll to assemble a long image. ([fcdb351]; by [@fzlzjerry])
- All-In-One area setup with adjustable selection bounds, pixel-by-pixel arrow-key control, typed dimensions, and optional cursor capture. ([c174fbe], [d3f931c]; by [@fzlzjerry])
- Optional capture-selection snapping to text blocks, lists, code, and tables on a frozen screen. ([a941ced]; by [@fzlzjerry])
- PNG, JPEG, and HEIC output options, 1× scaling, sRGB, borders, and filename patterns; window screenshots can omit shadows or use the desktop wallpaper. ([4199e2c], [ce5cf5b]; by [@fzlzjerry])
- Printing from cards, History, pins, and the editor, including multi-page long captures; Share-menu import, Finder Open With, and Send by Email. ([b17e518], [528bbea]; by [@fzlzjerry])
- Uploads to user-owned storage with copied links, saved upload records, automatic upload options, and multipart transfers for large files. ([a1602ec], [c11532a]; by [@fzlzjerry])
- CleanShot-compatible URL commands, Apple Shortcuts capture actions, desktop-icon hiding, and dedicated copy, save, and annotate shortcuts. ([5b5abf6], [fb86ac4]; by [@fzlzjerry])
- Simplified and Traditional Chinese, Japanese, Spanish, and French interface translations. ([1c86bc4]; by [@bobbyhuang-dev]; coauthored by Claude Opus 5.5)
- Per-window OCR text wrapping, a saved default for new windows, and horizontal scrolling when wrapping is off. ([#6]; by [@BenjaminD2023], [@fzlzjerry])
- Measurement snapping preferences and edge tolerance, with keyboard adjustments during measurement. ([#3]; by [@BenjaminD2023], [@fzlzjerry])
- A three-second Quick Access auto-close option; Never remains the default and saved delays are preserved. ([#5]; by [@BenjaminD2023], [@fzlzjerry])
- One- and two-second Quick Access auto-close options; Never remains the default and saved delays are preserved. ([#12]; by [@BenjaminD2023], [@fzlzjerry])
- A saved default for whether Capture Text and new Recognized Text windows keep or join the image's line breaks (Settings › Text › Image line breaks); Keep Line Breaks remains the default. ([#8]; by [@BenjaminD2023], [@fzlzjerry])
- Settings for where the Capture Text result card stands (below the selection, or in the bottom-left corner, above Quick Access's cards when they are there) and how long a card the user asked for stays; four seconds remains the default, and cards that report a problem keep at least their own time. ([#11]; by [@BenjaminD2023], [@fzlzjerry])
- An onboarding step, after Screen Recording, for turning off the macOS screenshot keys that answer OhMyShot's shortcuts first. ([b3ee8ce]; by [@fzlzjerry])
- Updates for release builds with Sparkle: about once a day (Settings › General › Updates, on by default), from signed appcasts on this repository's GitHub releases; a version found in the background waits in the menu bar menu and in Settings rather than in a window, and nothing is downloaded before it is chosen. ([d69ff9c]; by [@fzlzjerry])
- Settings › About › Acknowledgments…, with the licenses of OhMyShot and of the software it is built with. ([42c6bfa]; by [@fzlzjerry])
- Capture History selects several captures as Finder does (⌘-click, ⇧-click, ⌘A) to copy, save, restore, or move them to the Trash together, and ⌘O (File › Open in Editor) opens the selection in the editor. ([6523646]; by [@fzlzjerry])
- A right-click on the editor's tool rail lists every tool with its key. ([656bbcb]; by [@fzlzjerry])
- Studio's timeline zooms and scrolls along a long recording, with Fit, Fit Selection, zoom buttons, a scroller, and trackpad or wheel scrolling; Option-← and Option-→ choose the previous or next edit, and a chosen zoom or layout has Start and End fields and its duration in the inspector. ([49e3114]; by [@fzlzjerry])
- The Save panel for a screenshot chooses PNG, JPEG, or HEIC, the quality, and 1×, sRGB, and border for that file, starting from Settings; picking a format renames the file. The annotation editor's Save is a button of its own beside a Save Options menu, which holds Save As… (⌥⇧⌘S). ([#16], [#17]; by [@bobbyhuang-dev]; coauthored by Claude Opus 5.5)
- Settings › About links to OhMyShot's source code on GitHub and to MMFoundation's website. ([49aef5a], [497086d]; by [@bobbyhuang-dev], [@fzlzjerry]; coauthored by Claude Opus 5.5)
- Settings › General › Reset to Default Settings… puts every choice in Settings back as a new install has it, after a confirmation; shortcuts, upload destinations, cloud reading, language, approved apps, and capture history stay as they are. ([3e00641]; by [@bobbyhuang-dev]; coauthored by Claude Opus 5.5)
- Symbol-only controls in the capture bars, the editor's rail and style capsule, and on cards show their name in a small tag after a short rest, where the system tooltip came late or not at all; VoiceOver reads the same words. ([1ba5e94]; by [@bobbyhuang-dev])
- Window capture takes several windows at once: Shift-click each, then click or press Return, for screenshots, annotation, and Capture Text; Tab, Shift-Tab, [, and ] step through the windows under the pointer. For a screenshot or annotation, L brings back the last captured area to adjust or take again; Delete or a right-click during a drag starts the drag over, and a right-click otherwise closes the overlay. ([26a3deb], [6981fa7]; by [@fzlzjerry])
- The annotation editor selects the marks a box dragged with the Select tool touches (Shift adds them), pans a zoomed-in picture while Space is held, picks a color off the picture with I or the style capsule's eyedropper, snaps a moved mark to other marks' edges and centers and to the picture's center with guides (⌘ holds it back), takes hold of a mark by its inside with ⌘ whatever the tool, and opens a text mark on a double-click with any tool. ([26a3deb], [6981fa7]; by [@fzlzjerry])
- Pins resize from a corner, keeping their proportions; a double-click switches between actual size and the zoom before it (200% from actual size); Option-dragging a picture pin drops its image file into another app; and a click on a locked pin's lock badge unlocks it. ([26a3deb], [6981fa7]; by [@fzlzjerry])
- The Capture Text result card has Open in Panel, which shows the capture in the Recognized Text window. ([26a3deb]; by [@fzlzjerry])
- Studio's timeline marks where a click will land as the pointer passes over it, snaps the playhead, a range, and zoom and layout edges to cuts, zooms, layouts, the playhead, and the ends with a guide line (⌘ holds it back), and adds a zoom where the zoom lane is double-clicked. ([26a3deb], [6981fa7]; by [@fzlzjerry])
- A one-time invitation to MMFoundation's Discord, at a launch after 10 captures have been kept on at least 3 different days, never the first launch and never over a capture, recording, editor, or other window in use; Settings › About (with Discord's logo) and the menu bar menu have Join Discord. ([#20], [542fbb2]; by [@fzlzjerry], [@bobbyhuang-dev])

### Changed

- Screenshot selection freezes the screen by default and retains the frozen image for the capture. ([1a44474]; by [@fzlzjerry])
- Quick Access supports automatic closing, either screen corner, three card sizes, keyboard operation, and picture transformations. ([d65a655]; by [@fzlzjerry])
- Settings split capture and tool options out of General, then gained a searchable sidebar, dedicated panes, and Back and Forward navigation. ([#1], [af0aa70], [d43258a]; by [@bobbyhuang-dev]; coauthored by Claude Opus 5.5)
- Screenshot and annotation capture offer an optional centered, translucent actual-size picker with adjustable size and an adaptive target border. The centered picker and color reading clear when area selection begins; the crosshair remains, and the magnified loupe stays the default. ([#4]; by [@BenjaminD2023], [@fzlzjerry])
- Large measurement selections are analyzed in the background to keep the overlay responsive. ([#3]; by [@BenjaminD2023], [@fzlzjerry])
- Recording and Studio expose quality controls and estimated movie size; recording areas can be dimmed or framed, and automatic zooms better follow sustained activity. ([8cf6555], [202dc77], [a2f2527]; by [@fzlzjerry])
- Large and tall OCR images are read in bands, then assembled in image order to limit memory use. ([a8b2131], [14fdf15]; by [@fzlzjerry])
- Model-pack updates download only changed files instead of fetching the whole pack again. ([5a1dcd2]; by [@fzlzjerry])
- Quick Access: Delete alone no longer moves a card to the Trash (⌘Delete does); a card moved to the Trash waits five seconds under Undo (also ⌘Z and Restore Recently Closed) before its capture goes; side buttons keep fixed places; and a copy made from the keyboard says Copied on the card. ([4000b7c]; by [@fzlzjerry])
- On a taller Quick Access card each column of side buttons runs from the card's top to its bottom, three a side at the top, middle, and bottom; Upload keeps its place while an upload goes on or waits on Retry, and a button's hover tag stands beside it instead of over the button below. ([896502f]; by [@bobbyhuang-dev]; coauthored by Claude Opus 5.5)
- Recording's Delete and Restart, and Scrolling Capture's Cancel once something is stitched, ask for a second click before throwing the recording or picture away. ([b67e465]; by [@fzlzjerry])
- Return in the annotation editor copies the picture and closes the window; Background has a rail symbol of its own; Marker Yellow leads the highlighter's colors in place of Yellow; size chips name their sizes. ([656bbcb], [733fd08]; by [@fzlzjerry])
- All-In-One leaves out its Copy chip while every capture is copied anyway, and Annotate has one symbol everywhere. ([e43c395]; by [@fzlzjerry])
- Settings search finds more rows and opens a pane on the row it found, its title lit for a moment. ([6523646], [78c83f6]; by [@fzlzjerry])
- Studio shows the chosen zoom's controls first in the inspector, says how to choose a stretch to cut, and dims Add Zoom where it has no room. ([97f9d2c]; by [@fzlzjerry])
- Simplified Chinese tells the Capture pane from Screenshots and counts captures as items. ([77b18cb]; by [@fzlzjerry])
- Settings has a Text pane for Capture Text's card, line breaks, text from apps, translation, model packs, and cloud reading, leaving Tools to colors, Measure, and pins; a search lists a pane it names first. ([892e562]; by [@fzlzjerry])
- Settings explains each group of rows behind one help button, its popover taking the rows in order, in place of a help button or a long tooltip beside every control. ([6481709], [53de98a]; by [@fzlzjerry])
- The recording bar's microphone and camera chips name the device they record in their tooltip and to VoiceOver. ([1d31f21]; by [@fzlzjerry])
- A paused recording shows a pause symbol for the red dot, pulses its time, and lights Resume. ([55956a4]; by [@fzlzjerry])
- The recording bar no longer opens in Studio after a Studio take; it opens with the last of Video and GIF. ([22e8288]; by [@fzlzjerry])
- Studio says under the transport whether the project is saving, saved, or not saved (offering Retry Saving), and keeps showing the last preview frame while the preview updates (offering Retry Preview if it can't); Add Layout is dimmed, with the reason, when the playhead has no room for a layout. ([49e3114]; by [@fzlzjerry])
- Capture History reads its folder and matches searches in the background, so the window keeps responding with many captures; it shows Loading captures… and Updating search results… while it works, and Return moves to the first result once the search is done. ([49e3114]; by [@fzlzjerry])
- Recognized text is read column by column: side-by-side columns follow one another, full-width headings and paragraphs divide them, side notes stay out of the main paragraph, and right-to-left text orders its columns from the right; code, tables, and chats keep row order. ([49e3114]; by [@fzlzjerry])
- Settings › Screenshots › File name builds the name from bricks in a tray: click or drag in Date, Time, App, Window, Counter, text, and separators, drag bricks to reorder them, drag one back out or click its × to remove it, and click a word to change it; the tray's menu has Edit as Text and Restore Default. With PNG chosen, Lossless stands in place of the Quality slider. ([3c09290]; by [@bobbyhuang-dev])
- Studio frames a zoom after the fact from the whole cursor path: the camera holds on each run of clicks and keys and moves between them a little ahead of time, keeping the cursor inside the view, so an automatic zoom's first click is in the shot and a zoom no longer slides sideways as it scales. ([8f329e8]; by [@fzlzjerry])
- Recording notes each pointer event at its own time, so with Input Monitoring on, Studio's cursor no longer pauses and jumps when the app is busy; clicks keep their releases, automatic zooms count drags, and presses on OhMyShot's own windows, such as the recording bar's Stop and Pause, no longer leave click rings in the movie. ([468526b]; by [@fzlzjerry])
- Studio composes export frames faster and leaves out frames that repeat the one before, so a movie with still stretches exports in less time and, like a recording, has a variable frame rate. ([84ecfd2], [7294035]; by [@fzlzjerry])
- Settings › Permissions explains in each row's help popover what the permission is used for and what goes missing without it, in place of a short tooltip. ([be25671]; by [@bobbyhuang-dev]; coauthored by Claude Opus 5.5)
- The menu bar menu gathers less-used actions into submenus: More Area Captures, Open Image, From Clipboard, Pins, and Tools (Pick Color, Measure, Hide Desktop Icons); Save Last 15 Seconds leads the replay submenu, and submenu items show their shortcuts. ([#18]; by [@bobbyhuang-dev])
- Annotation on the frozen selection has a Select chip in its toolbar; once marks are drawn, Select works on them (a dragged box selects several, a double-click inside the selection away from the marks copies the picture), and Space held moves the selection. ([26a3deb]; by [@fzlzjerry])
- A Quick Access card counting down to close shows a ring running out around its Close button, a swiped card follows the swipe and springs back when let go short of closing, and while the cards have the keyboard the card under the pointer takes its ring. ([26a3deb], [6981fa7], [75e384d]; by [@fzlzjerry])
- OhMyShot appears in Command-Tab and the Dock while one of its windows, such as Settings, Capture History, an editor, or Studio, is open, and leaves them once the last one closes; Settings opens faster. ([6981fa7]; by [@fzlzjerry])

### Fixed

- OCR warmups no longer queue ahead of repeated Capture Text requests. Recognition has a complete-run deadline, cancelled captures leave newer results alone, and stalled model-reader helpers terminate on cancellation or timeout. Completed codes and tables survive the other optional reading's timeout, and element helpers have time to return completed formulas and tables when their reading budget ends. (by [@BenjaminD2023])
- The native arrow appears over capture toolbar controls, and cursor visibility is restored correctly when returning to the canvas, cancelling, or entering another capture setup. ([#7]; by [@BenjaminD2023], [@fzlzjerry])
- Shortcut recorders support Use Anyway for menu conflicts, including Command-Shift-S; assigning a shortcut to another OhMyShot action clears the previous assignment. ([#2]; by [@BenjaminD2023], [@fzlzjerry])
- Measurement snapping better handles faint outlines and thin details, retaining the drawn rectangle when no credible boundary is found. ([#3]; by [@BenjaminD2023], [@fzlzjerry])
- Editor copies keep the annotation document that produced the copied image, and failed saves or drags no longer silently discard unkept edits. Quick Access holds captures while their editor loads and tracks hover after cards move. ([#5]; by [@BenjaminD2023], [@fzlzjerry])
- Unwrapped OCR windows no longer open with the first characters scrolled out of view. ([33cd6bf]; by [@fzlzjerry])
- Editor Undo and styled counter numbering behave consistently. ([4558f10]; by [@fzlzjerry])
- Pin zooming preserves the picture's proportions, and text pins allow selecting part of their text. ([b9c8e30], [9d53b01]; by [@fzlzjerry])
- VoiceOver names the Save buttons in the editor, recording window, and Studio, and presses History's cards. ([745e2f4]; by [@fzlzjerry])
- Onboarding avoids duplicate Screen Recording permission prompts and actually reopens the app after Quit & Reopen. ([6ec2f1d]; by [@bobbyhuang-dev]; coauthored by Claude Opus 5.5)
- Launch at login toggles the login item on and off again. ([3c49e89]; by [@fzlzjerry])
- Quick Access repositions cards when displays are disconnected; cards and pins place their More menus beside them where they fit. ([bb75542], [460c047], [3750631]; by [@bobbyhuang-dev]; coauthored by Claude Opus 5.5)
- Scrolling captures reduce repeated fixed buttons, sticky-sidebar seams, and gaps around rounded window corners; a fixed button holding page-colored marks or sitting over text at the foot no longer leaves traces, and a carousel that changes slide while in view comes out as its newer slide. ([e3e5215], [c7ea72a], [e895346], [2ebd715], [49e3114]; by [@fzlzjerry])
- Scrolling captures incorporate images that load after scrolling starts and keep continuously changing content together as a frame instead of a patchwork. ([6c56a00], [c319bdb], [309c84b]; by [@fzlzjerry])
- Scrolling and Auto-scroll continue through long blank stretches, and repeated table cells retain the correct row numbers. ([0d32c35], [b65fad1], [35c03e9]; by [@fzlzjerry])
- Recording warns when a microphone stops delivering audio instead of leaving a disconnected microphone silently recording. ([450f4a6]; by [@fzlzjerry])
- Closing History and editors releases more memory, clipboard TIFFs use compression, and GIF frame buffers return their memory when freed. ([cff3ddb], [0182817], [6d3b0af]; by [@fzlzjerry])
- Capture History's Move All to Trash acts on what the window shows, states the count, and no longer says captures can be put back from the Trash. ([6523646]; by [@fzlzjerry])
- Recording shows when the microphone was left out because access to it is off, the microphone chip shows that before recording, and a recording that can't start says so on screen. ([b67e465]; by [@fzlzjerry])
- A scrolling capture whose Auto-scroll needs Accessibility keeps its framed area for the next try, and its warnings stand apart from its progress. ([b67e465]; by [@fzlzjerry])
- The editor's style capsule no longer covers the next line of text under a highlight drawn freely. ([656bbcb]; by [@fzlzjerry])
- VoiceOver names the app a History card was taken in and the action of each shortcut recorder in Settings. ([e45b631]; by [@fzlzjerry])
- The Settings window opened on General is titled General, not "Untitled". ([8ea9c06]; by [@fzlzjerry])
- The capture overlay shows one pointer at a time: the system's pointer no longer stays beside the drawn crosshair (two crosshairs after Capture Text), and Capture Text's crosshair shows from the start. ([43a1529], [7fc5a39], [1134e64]; by [@fzlzjerry])
- Save As in the recording window and in Studio replaces an existing file only once the new copy is complete; closing or quitting waits for a Studio project to be saved, and a failed save keeps the window and its edits open; cancelling a Studio export, even while the file is being finished, stops it and leaves no partial movie; and a GIF shows a still screen held longer than 655 seconds for its whole time instead of cutting it short. ([49e3114]; by [@fzlzjerry])
- Capture-bar and editor chips center their symbols in round fills, a titled chip such as Record centers its dot and title, and All-In-One's size fields fit their numbers. ([#16], [fb22898]; by [@bobbyhuang-dev]; coauthored by Claude Opus 5.5)
- Filled chips in the editor's style capsule are all 30 pt, so none looks smaller than its neighbor, and its color swatches are matching 16 pt discs. ([a99c1cd]; by [@bobbyhuang-dev])
- The editor's drag-out thumbnail drags the capture into another app instead of moving the window. ([c021411]; by [@bobbyhuang-dev]; coauthored by Claude Opus 5.5)
- Outlined Text in the annotation editor has a black outline around white and colored text (white only around black and very dark text) and shows the outline while the text is typed. ([6647d69]; by [@fzlzjerry])
- Windows opened from the menu bar icon come to the front instead of opening behind the active app. ([ec080f7]; by [@bobbyhuang-dev])

[Unreleased]: https://github.com/MMFoundation/OhMyShot/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/MMFoundation/OhMyShot/releases/tag/v0.1.0
[7502f44]: https://github.com/MMFoundation/OhMyShot/commit/7502f44fe7ed357d46b451e2b9d772e1727fa5d7
[0b20def]: https://github.com/MMFoundation/OhMyShot/commit/0b20defc0f9585a62237ab9f6901a838127f1217
[9514883]: https://github.com/MMFoundation/OhMyShot/commit/95148832a84d2d7ad60dce740149819dc5eac6fe
[4353a67]: https://github.com/MMFoundation/OhMyShot/commit/4353a67ea68d2a46ab00078dc793ff0ce79cf4bb
[bae605a]: https://github.com/MMFoundation/OhMyShot/commit/bae605a0af68f7c37070e0bff6dfee1ed8dc7de9
[5fb5917]: https://github.com/MMFoundation/OhMyShot/commit/5fb5917f81d15f3cf269d2ab1ef26899ac05ddae
[be0a7ed]: https://github.com/MMFoundation/OhMyShot/commit/be0a7ed26e5c4738bb8231f34f95d7a5e9107430
[2323913]: https://github.com/MMFoundation/OhMyShot/commit/232391325a1f3b514299cfc6c8799e8e329ebd9c
[5203022]: https://github.com/MMFoundation/OhMyShot/commit/5203022dd97c8ff760a76dc33455434e5b861c6e
[4601011]: https://github.com/MMFoundation/OhMyShot/commit/4601011d5b85125b335a3ed0adf27af096a4ea97
[4c48f7e]: https://github.com/MMFoundation/OhMyShot/commit/4c48f7e1851c1139fcc267161808ee636a623983
[7cfd445]: https://github.com/MMFoundation/OhMyShot/commit/7cfd445909e8298f04e098f4343f364ecab7c920
[81a46de]: https://github.com/MMFoundation/OhMyShot/commit/81a46defc0b498eba30e6ebd086116ff06ffadb7
[7304cae]: https://github.com/MMFoundation/OhMyShot/commit/7304cae0a7e7330c69022d49f463d610aedf63a2
[0946850]: https://github.com/MMFoundation/OhMyShot/commit/0946850a6bc20896c0d6646526d7a3a08735e0be
[bf3ce5e]: https://github.com/MMFoundation/OhMyShot/commit/bf3ce5ed6403c19a926a5d48e1fc6a68c576f362
[6bda14e]: https://github.com/MMFoundation/OhMyShot/commit/6bda14ecb7bf955eb70bb4a81c6bd9f443010b07
[db7bffc]: https://github.com/MMFoundation/OhMyShot/commit/db7bffc0d269c1709c5a57f44fb1428851567601
[b2b2471]: https://github.com/MMFoundation/OhMyShot/commit/b2b2471de5f14ffbd4e63fdb21710874a87eee5a
[84a0c3a]: https://github.com/MMFoundation/OhMyShot/commit/84a0c3a6e9f9b6f70c2db252f40d8d297d4de309
[d955c65]: https://github.com/MMFoundation/OhMyShot/commit/d955c65dd378a4660adb2a00614c68961e163b68
[3ba14d1]: https://github.com/MMFoundation/OhMyShot/commit/3ba14d10a1f8119dd5bd6721748c488e48113158
[ea1e905]: https://github.com/MMFoundation/OhMyShot/commit/ea1e9058dfe37035757d429ec52cac5357455c6c
[71ba1c3]: https://github.com/MMFoundation/OhMyShot/commit/71ba1c3ff943b5e225f7d289bad01588c73bf04e
[b5acc7d]: https://github.com/MMFoundation/OhMyShot/commit/b5acc7d4a0763f203592d1386781bf42b9301079
[dc8b831]: https://github.com/MMFoundation/OhMyShot/commit/dc8b83146cd28502868beb032636a51c943c2f66
[f2b90c0]: https://github.com/MMFoundation/OhMyShot/commit/f2b90c0f1ca5f2dfa54fa7b2fc8f35ce03aa5bc2
[fa9a2c0]: https://github.com/MMFoundation/OhMyShot/commit/fa9a2c098747be41aa7c9d0355d61a6b3ab6d335
[a98c3a5]: https://github.com/MMFoundation/OhMyShot/commit/a98c3a59b00428fed0f472bae7e17eb162af26d5
[1050f8b]: https://github.com/MMFoundation/OhMyShot/commit/1050f8be152cf0390695c3ddcd37375ade751b86
[a336488]: https://github.com/MMFoundation/OhMyShot/commit/a336488af47364ec65d633ad200ce028e55c651f
[3009de2]: https://github.com/MMFoundation/OhMyShot/commit/3009de268fd48b3b82824e90dcadd8adcf87ad50
[33ce73f]: https://github.com/MMFoundation/OhMyShot/commit/33ce73f60b206e8888f7cdd655135ad25253e274
[f29ccf0]: https://github.com/MMFoundation/OhMyShot/commit/f29ccf06c4d35f1cf33088039d734de0b7720f77
[44be1b8]: https://github.com/MMFoundation/OhMyShot/commit/44be1b8296f9e04530c90534294bca862ed9810c
[c66815b]: https://github.com/MMFoundation/OhMyShot/commit/c66815b972f787cbb1bea89f69d7e51917e6e500
[f69d36e]: https://github.com/MMFoundation/OhMyShot/commit/f69d36eb7a58764e3c70fbe066797f1b89aaf21e
[c999cc0]: https://github.com/MMFoundation/OhMyShot/commit/c999cc03ce4ca38c5596a17b13265ddebd1cc54d
[47460d9]: https://github.com/MMFoundation/OhMyShot/commit/47460d9161fd9a2526b7964ce00a5727a34b688d
[4fba5e2]: https://github.com/MMFoundation/OhMyShot/commit/4fba5e228a53a7d7bf18be4495663cd7c89c4287
[82a1188]: https://github.com/MMFoundation/OhMyShot/commit/82a11888819ad0d40fb218aa36d131aa68adc58d
[72d434f]: https://github.com/MMFoundation/OhMyShot/commit/72d434f62e04cd4b33fadf846b962b1bac3e1ca0
[3301d5f]: https://github.com/MMFoundation/OhMyShot/commit/3301d5f1b386f9fa69ab6075c44bf2c8940a2da9
[6945ecb]: https://github.com/MMFoundation/OhMyShot/commit/6945ecbac64adce3019999530804d00407c290fb
[c74adf4]: https://github.com/MMFoundation/OhMyShot/commit/c74adf4e724c95c7dbf888afa45a542142b4d209
[f8ecfb2]: https://github.com/MMFoundation/OhMyShot/commit/f8ecfb256574cc5552fbb8e61ced67d6c02db0da
[fea8757]: https://github.com/MMFoundation/OhMyShot/commit/fea875732b2595616c5b7d16545bce2e2c496e36
[f973024]: https://github.com/MMFoundation/OhMyShot/commit/f973024fcb9bf539d9cf28dd803250222f5be2aa
[e69955f]: https://github.com/MMFoundation/OhMyShot/commit/e69955f2031770af0abb78d3464eff3e95966dd5
[b2c60ff]: https://github.com/MMFoundation/OhMyShot/commit/b2c60ff12b4fc33cbc2fa0aad013ddb73c279402
[c6b6b58]: https://github.com/MMFoundation/OhMyShot/commit/c6b6b58d9feb626a5c935e339a04c77f588503e7
[8df4f3f]: https://github.com/MMFoundation/OhMyShot/commit/8df4f3f8d2aad82dd5a05456ba5d8370f5ba0421
[0d924fd]: https://github.com/MMFoundation/OhMyShot/commit/0d924fd533ac5d9dc7d2d9e11307f597d883a9e2
[b9474f8]: https://github.com/MMFoundation/OhMyShot/commit/b9474f842e72f1728c9d2f442f77c8d626ee9901
[18059d3]: https://github.com/MMFoundation/OhMyShot/commit/18059d3891ba14edc1ec4a8522ea910edcee3fb9
[70711ac]: https://github.com/MMFoundation/OhMyShot/commit/70711acddc0091474e5f1571bff0df77fe8116c0
[0897744]: https://github.com/MMFoundation/OhMyShot/commit/0897744a2786821f516641d646e7989f78d5f0b2
[cfbe3ac]: https://github.com/MMFoundation/OhMyShot/commit/cfbe3ac01fe669db99e6192732f6e6d0a71d5471
[34f042b]: https://github.com/MMFoundation/OhMyShot/commit/34f042b51c3dac788b8fdfcd48772b5e2dc56ea8
[0f80678]: https://github.com/MMFoundation/OhMyShot/commit/0f806785933230e3a409195b9d654d2ded7a6aeb
[9b5aa53]: https://github.com/MMFoundation/OhMyShot/commit/9b5aa530a82bc7c0477183980f206de80d86bdb1
[1971598]: https://github.com/MMFoundation/OhMyShot/commit/19715982bdbc99afadb76beca65135f0449aab57
[3e37cd6]: https://github.com/MMFoundation/OhMyShot/commit/3e37cd6e1d7c58679695b09abef607f55b9f4fc8
[8ddb274]: https://github.com/MMFoundation/OhMyShot/commit/8ddb274d5db440bb2100d028b61e5460d0ab2917
[dd88b79]: https://github.com/MMFoundation/OhMyShot/commit/dd88b79ccf00c521232ef02415fcea3f1c92525b
[195f1df]: https://github.com/MMFoundation/OhMyShot/commit/195f1df86d253790bcf108089082b333cff2c035
[131e96f]: https://github.com/MMFoundation/OhMyShot/commit/131e96fa5a3f9f4c9076a6c4d260112e0a33381f
[fcdb351]: https://github.com/MMFoundation/OhMyShot/commit/fcdb351c46f9fea7dce8dd2d6ae7c62771bbb59e
[c174fbe]: https://github.com/MMFoundation/OhMyShot/commit/c174fbe4fc0e4b3410ab708953c84fae67e80e78
[d3f931c]: https://github.com/MMFoundation/OhMyShot/commit/d3f931ccb2083822e154b57ae34e2a22c96a4df9
[a941ced]: https://github.com/MMFoundation/OhMyShot/commit/a941cedfeea506b39642bf2b29d09c530deb192b
[4199e2c]: https://github.com/MMFoundation/OhMyShot/commit/4199e2c517bedf30925318b44cd5fee24512df84
[ce5cf5b]: https://github.com/MMFoundation/OhMyShot/commit/ce5cf5bdd0c9ba422de3fb37305b99cd52b196d9
[b17e518]: https://github.com/MMFoundation/OhMyShot/commit/b17e518fae244c2b4e3a78d84cccb1bb478ca230
[528bbea]: https://github.com/MMFoundation/OhMyShot/commit/528bbeaeefe3af7122e3065fe33812f6fea66b24
[a1602ec]: https://github.com/MMFoundation/OhMyShot/commit/a1602ec028369cad8f6cc9310ab0747f2d1b745d
[c11532a]: https://github.com/MMFoundation/OhMyShot/commit/c11532a4a679d86660bb43913b6b830133eb3234
[5b5abf6]: https://github.com/MMFoundation/OhMyShot/commit/5b5abf6c41df6b7fb30802ff6ad4b28f04f72722
[fb86ac4]: https://github.com/MMFoundation/OhMyShot/commit/fb86ac4001e980ed2f34a06ff7662a7a2ccea256
[1c86bc4]: https://github.com/MMFoundation/OhMyShot/commit/1c86bc4768690cfb88c5ca805cffb7e800b60128
[#6]: https://github.com/MMFoundation/OhMyShot/pull/6
[#3]: https://github.com/MMFoundation/OhMyShot/pull/3
[#5]: https://github.com/MMFoundation/OhMyShot/pull/5
[1a44474]: https://github.com/MMFoundation/OhMyShot/commit/1a444742c501ebab637a097fa38b13d3ef4905f6
[d65a655]: https://github.com/MMFoundation/OhMyShot/commit/d65a655463baf3b3494f76e7d9fcdc1f54db5b76
[#1]: https://github.com/MMFoundation/OhMyShot/pull/1
[af0aa70]: https://github.com/MMFoundation/OhMyShot/commit/af0aa70b6ac1466d1cc704d586854c48dfc8fbc8
[d43258a]: https://github.com/MMFoundation/OhMyShot/commit/d43258a2f8e382e07537e54f5a946b89fa2f19f9
[#4]: https://github.com/MMFoundation/OhMyShot/pull/4
[8cf6555]: https://github.com/MMFoundation/OhMyShot/commit/8cf6555894ed714a157a5bd0a26ca080f340ce58
[202dc77]: https://github.com/MMFoundation/OhMyShot/commit/202dc77659b133db41357fc3fec47001100970f2
[a2f2527]: https://github.com/MMFoundation/OhMyShot/commit/a2f25279207fdc5673f9abbef7f369fd849817b1
[a8b2131]: https://github.com/MMFoundation/OhMyShot/commit/a8b2131897ec0d0306825f11b01c2488fa2b8de8
[14fdf15]: https://github.com/MMFoundation/OhMyShot/commit/14fdf152fbc4a8cd3350422f13678026562e83a5
[5a1dcd2]: https://github.com/MMFoundation/OhMyShot/commit/5a1dcd217dafe7daa2f6b1ae3e3a4d6fa5c933fc
[#7]: https://github.com/MMFoundation/OhMyShot/pull/7
[#2]: https://github.com/MMFoundation/OhMyShot/pull/2
[33cd6bf]: https://github.com/MMFoundation/OhMyShot/commit/33cd6bf3b697c6cad2acebb474b847577cf1634c
[4558f10]: https://github.com/MMFoundation/OhMyShot/commit/4558f101adaede630f73711178dbca08e5f45208
[b9c8e30]: https://github.com/MMFoundation/OhMyShot/commit/b9c8e307af33415680b785a27a092d53af506a60
[9d53b01]: https://github.com/MMFoundation/OhMyShot/commit/9d53b0155c23bca79440eeac136df4d7bccefc09
[6ec2f1d]: https://github.com/MMFoundation/OhMyShot/commit/6ec2f1d81545ea65b6e599544dd1ae1fc8a29ccb
[3c49e89]: https://github.com/MMFoundation/OhMyShot/commit/3c49e89eac218d01d1b97df2392d4e86e79808dc
[bb75542]: https://github.com/MMFoundation/OhMyShot/commit/bb75542e8236a7ecee19a393fd4c891e3c1ea49c
[460c047]: https://github.com/MMFoundation/OhMyShot/commit/460c047f5e3c314186779bb6a54bac9314bcb260
[3750631]: https://github.com/MMFoundation/OhMyShot/commit/37506310b3704d145008e84a7abe6c7c9391d8b9
[e3e5215]: https://github.com/MMFoundation/OhMyShot/commit/e3e5215b31f9aafe6fd5ed0a1b0c6c3fa890e2cd
[c7ea72a]: https://github.com/MMFoundation/OhMyShot/commit/c7ea72a7cfe9a4a579672ca0f793867372f8fa0b
[e895346]: https://github.com/MMFoundation/OhMyShot/commit/e895346ace94a9891a54877883ab7911daf51bd0
[2ebd715]: https://github.com/MMFoundation/OhMyShot/commit/2ebd715ba48e2c558f7007219e0c18d05d13ec25
[6c56a00]: https://github.com/MMFoundation/OhMyShot/commit/6c56a0024f0ca74696aabf71ee3b6f7c384445db
[c319bdb]: https://github.com/MMFoundation/OhMyShot/commit/c319bdbc7803dd7da371d6e9c60588dc247943e6
[309c84b]: https://github.com/MMFoundation/OhMyShot/commit/309c84ba8543170b6b07e0a2416482813e03ab84
[0d32c35]: https://github.com/MMFoundation/OhMyShot/commit/0d32c35d4540741598eedff0c9e2afe023a1fcd4
[b65fad1]: https://github.com/MMFoundation/OhMyShot/commit/b65fad1cf114765b718daa53c904b5f1744231ee
[35c03e9]: https://github.com/MMFoundation/OhMyShot/commit/35c03e9f0a13696c466250f48b477c226fd568dd
[450f4a6]: https://github.com/MMFoundation/OhMyShot/commit/450f4a6c60a5247daf0028ead3b7c58128018980
[cff3ddb]: https://github.com/MMFoundation/OhMyShot/commit/cff3ddb3ca3bd762ed203a21b32a04443e27eaec
[0182817]: https://github.com/MMFoundation/OhMyShot/commit/01828172073f4816c9dba6054957f27d631abee8
[6d3b0af]: https://github.com/MMFoundation/OhMyShot/commit/6d3b0af34efe0b65102e02e829c53f5f31f5b203
[#12]: https://github.com/MMFoundation/OhMyShot/pull/12
[#8]: https://github.com/MMFoundation/OhMyShot/pull/8
[#11]: https://github.com/MMFoundation/OhMyShot/pull/11
[42c6bfa]: https://github.com/MMFoundation/OhMyShot/commit/42c6bfada8d898892676d32b2b0daa0bdcc878b6
[b3ee8ce]: https://github.com/MMFoundation/OhMyShot/commit/b3ee8ce17153c308b1247a9eb28f487af92dca85
[745e2f4]: https://github.com/MMFoundation/OhMyShot/commit/745e2f4e76a8be01f02ca25c84a8e4dc6d08ffef
[d69ff9c]: https://github.com/MMFoundation/OhMyShot/commit/d69ff9c7a0c3b71e9eb6a7146d831af4fcb36f6c
[77b18cb]: https://github.com/MMFoundation/OhMyShot/commit/77b18cbdac714a39f5338e7cbafde8a72ff22454
[4000b7c]: https://github.com/MMFoundation/OhMyShot/commit/4000b7cc3febbcddda7133414a339d38457342dc
[6523646]: https://github.com/MMFoundation/OhMyShot/commit/6523646dc6302412d56d33eafa1c8bc070f638b1
[b67e465]: https://github.com/MMFoundation/OhMyShot/commit/b67e465792577aff675d28115c1089db4be74eba
[e43c395]: https://github.com/MMFoundation/OhMyShot/commit/e43c3955b5bf52e841f9786d0caeafca3ca3c9cf
[656bbcb]: https://github.com/MMFoundation/OhMyShot/commit/656bbcba7b3bf9cfe0764069f8f37bbbfdd204be
[97f9d2c]: https://github.com/MMFoundation/OhMyShot/commit/97f9d2cdc702585b8aa3710c7d5207ba07ff9f69
[733fd08]: https://github.com/MMFoundation/OhMyShot/commit/733fd0888bc8ca99ce1e47779f825d0ceaf65a74
[78c83f6]: https://github.com/MMFoundation/OhMyShot/commit/78c83f6af6e5f4430afc4cd31a48a6fd8d3659e1
[892e562]: https://github.com/MMFoundation/OhMyShot/commit/892e56289c3bd28239e252f4b281990d0c53c297
[6481709]: https://github.com/MMFoundation/OhMyShot/commit/648170986ddcf368b463765beebbe7e2da24beeb
[1d31f21]: https://github.com/MMFoundation/OhMyShot/commit/1d31f2128dc52cca7858222220a64170840128f7
[55956a4]: https://github.com/MMFoundation/OhMyShot/commit/55956a475a12b5a240a724e0b883c37f6349dd05
[22e8288]: https://github.com/MMFoundation/OhMyShot/commit/22e82886573cf4f32ba53e585bc2ee721005cd6f
[e45b631]: https://github.com/MMFoundation/OhMyShot/commit/e45b631339ca0660b6a8ebdf72df23c1266282c3
[53de98a]: https://github.com/MMFoundation/OhMyShot/commit/53de98a3004745d40add007ab82b620de21365ba
[8ea9c06]: https://github.com/MMFoundation/OhMyShot/commit/8ea9c0654dce1dc928ceafeed629c892178219de
[43a1529]: https://github.com/MMFoundation/OhMyShot/commit/43a15294271a0090ffb0da5f84a4cedf97301019
[7fc5a39]: https://github.com/MMFoundation/OhMyShot/commit/7fc5a392938eb0df2f07ee4e2c238fd569a4070d
[1134e64]: https://github.com/MMFoundation/OhMyShot/commit/1134e6464c53f5dae261be1fa041c64098684c69
[49e3114]: https://github.com/MMFoundation/OhMyShot/commit/49e3114ea72c4c61169fbef674d614de7084dae3
[#16]: https://github.com/MMFoundation/OhMyShot/pull/16
[3c09290]: https://github.com/MMFoundation/OhMyShot/commit/3c0929043350efed6ae093bd3adad5b5e766b52b
[8f329e8]: https://github.com/MMFoundation/OhMyShot/commit/8f329e86357870199f9a2728c6a110ed987dafd2
[468526b]: https://github.com/MMFoundation/OhMyShot/commit/468526b0eb3b619704976f436ae632fa53b79294
[84ecfd2]: https://github.com/MMFoundation/OhMyShot/commit/84ecfd2a7157df02b5558b1928b7ddd6e5a516c6
[7294035]: https://github.com/MMFoundation/OhMyShot/commit/729403523ac656e3d3242e10e07254c4607a3869
[a99c1cd]: https://github.com/MMFoundation/OhMyShot/commit/a99c1cdd0ab5d1b8fde6e12b85ea5b0146fc90b9
[49aef5a]: https://github.com/MMFoundation/OhMyShot/commit/49aef5a6ae17b0bb7ed6f8b92a747a12bd7ed599
[be25671]: https://github.com/MMFoundation/OhMyShot/commit/be25671439829b15c7a509d38e7abf5b2a7c5ddc
[#17]: https://github.com/MMFoundation/OhMyShot/pull/17
[c021411]: https://github.com/MMFoundation/OhMyShot/commit/c021411ea6d5fdaecf4783b6af6ab1bea49e2eed
[#18]: https://github.com/MMFoundation/OhMyShot/pull/18
[fb22898]: https://github.com/MMFoundation/OhMyShot/commit/fb22898cf4eb25f2a53ee31455dc348efb335ad5
[3e00641]: https://github.com/MMFoundation/OhMyShot/commit/3e00641d32cec093843f2aec694a236e1f09b6c9
[497086d]: https://github.com/MMFoundation/OhMyShot/commit/497086d06d49faba91739c4dd3691cb76c0894e2
[1ba5e94]: https://github.com/MMFoundation/OhMyShot/commit/1ba5e947392fdb40bda150e231cba02d4809c483
[26a3deb]: https://github.com/MMFoundation/OhMyShot/commit/26a3deb80e544e2ef5bfb0e6e724568638ad23a7
[6981fa7]: https://github.com/MMFoundation/OhMyShot/commit/6981fa7362be29e22f6c779aad94c17cce5d659f
[#20]: https://github.com/MMFoundation/OhMyShot/pull/20
[75e384d]: https://github.com/MMFoundation/OhMyShot/commit/75e384d18c9b8090e9674a2c5f5d51bf04fa8ebf
[6647d69]: https://github.com/MMFoundation/OhMyShot/commit/6647d69da7f67c9f16a20a38834068a6faabb3dc
[542fbb2]: https://github.com/MMFoundation/OhMyShot/commit/542fbb2b1dad55fe4ecb1ac1c9353c0f9940f386
[896502f]: https://github.com/MMFoundation/OhMyShot/commit/896502fecc4335d59b6405283bffc500e67c0585
[ec080f7]: https://github.com/MMFoundation/OhMyShot/commit/ec080f7ab7fac2a0833a0b7abc6b782e0f9ad333
[@BenjaminD2023]: https://github.com/BenjaminD2023
[@bobbyhuang-dev]: https://github.com/bobbyhuang-dev
[@fzlzjerry]: https://github.com/fzlzjerry
