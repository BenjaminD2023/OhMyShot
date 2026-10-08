---
name: OhMyShot
description: Native macOS capture, bright and soft, with the capture as the hero and the chrome receding.
colors:
  system-accent: "AccentColor"
  white: "#FFFFFF"
  selection-outline: "rgba(0,0,0,0.32)"
  selection-outline-contrast: "rgba(0,0,0,0.7)"
  room-dim: "rgba(0,0,0,0.26)"
  room-dim-contrast: "rgba(0,0,0,0.45)"
  loupe-grid: "rgba(0,0,0,0.08)"
  reading-capsule-light: "rgba(255,255,255,0.96)"
  reading-capsule-dark: "rgba(43,43,46,0.94)"
  reading-ink-light: "rgba(0,0,0,0.85)"
  reading-ink-dark: "rgba(255,255,255,0.92)"
  reading-border-light: "rgba(0,0,0,0.08)"
  reading-border-dark: "rgba(255,255,255,0.12)"
  swatch-border-light: "rgba(0,0,0,0.3)"
  swatch-border-dark: "rgba(255,255,255,0.38)"
  chip-selected-light: "rgba(0,0,0,0.08)"
  chip-selected-dark: "rgba(255,255,255,0.16)"
  chip-hover-light: "rgba(0,0,0,0.045)"
  chip-hover-dark: "rgba(255,255,255,0.09)"
  action-white: "#F7F7F7"
  action-white-hover: "#FFFFFF"
  action-white-pressed: "#D6D6D6"
  action-ink: "#1A1A1A"
  corner-button: "rgba(0,0,0,0.5)"
  corner-button-hover: "rgba(0,0,0,0.62)"
  corner-button-pressed: "rgba(0,0,0,0.72)"
  scrim-floating: "rgba(0,0,0,0.22)"
  scrim-window: "rgba(0,0,0,0.28)"
  picture-border-light: "rgba(0,0,0,0.10)"
  picture-border-dark: "rgba(255,255,255,0.16)"
  media-badge: "rgba(0,0,0,0.55)"
typography:
  reading:
    fontFamily: "SF Pro Rounded, ui-rounded, system-ui"
    fontSize: "12px"
    fontWeight: 600
    fontFeature: "\"tnum\" 1"
  control-label:
    fontFamily: "SF Pro Rounded, ui-rounded, system-ui"
    fontSize: "12px"
    fontWeight: 500
  control-label-selected:
    fontFamily: "SF Pro Rounded, ui-rounded, system-ui"
    fontSize: "12px"
    fontWeight: 600
  action-label:
    fontFamily: "SF Pro Rounded, ui-rounded, system-ui"
    fontSize: "13px"
    fontWeight: 600
  title:
    fontFamily: "SF Pro, system-ui"
    fontSize: "15px"
    fontWeight: 600
  body:
    fontFamily: "SF Pro, system-ui"
    fontSize: "13px"
    fontWeight: 400
  callout:
    fontFamily: "SF Pro, system-ui"
    fontSize: "12px"
    fontWeight: 400
  caption:
    fontFamily: "SF Pro, system-ui"
    fontSize: "10px"
    fontWeight: 400
rounded:
  card: "12px"
  capsule: "9999px"
spacing:
  chip-gap: "2px"
  edge: "6px"
  inset: "8px"
  offset: "10px"
  card-gap: "12px"
  stack-margin: "18px"
  grid-gap: "20px"
  window-inset: "24px"
  panel-padding: "28px"
components:
  reading-capsule-light:
    backgroundColor: "{colors.reading-capsule-light}"
    textColor: "{colors.reading-ink-light}"
    typography: "{typography.reading}"
    rounded: "{rounded.capsule}"
    padding: "0 11px"
  reading-capsule-dark:
    backgroundColor: "{colors.reading-capsule-dark}"
    textColor: "{colors.reading-ink-dark}"
    typography: "{typography.reading}"
    rounded: "{rounded.capsule}"
    padding: "0 11px"
  bar-chip:
    typography: "{typography.control-label}"
    rounded: "{rounded.capsule}"
    height: "30px"
    width: "84px"
  bar-chip-selected-light:
    backgroundColor: "{colors.chip-selected-light}"
    typography: "{typography.control-label-selected}"
    rounded: "{rounded.capsule}"
    height: "30px"
  bar-chip-selected-dark:
    backgroundColor: "{colors.chip-selected-dark}"
    typography: "{typography.control-label-selected}"
    rounded: "{rounded.capsule}"
    height: "30px"
  card-action-button:
    backgroundColor: "{colors.action-white}"
    textColor: "{colors.action-ink}"
    typography: "{typography.action-label}"
    rounded: "{rounded.capsule}"
    width: "112px"
    height: "30px"
  card-action-button-hover:
    backgroundColor: "{colors.action-white-hover}"
  card-action-button-pressed:
    backgroundColor: "{colors.action-white-pressed}"
  card-corner-button:
    backgroundColor: "{colors.corner-button}"
    textColor: "{colors.white}"
    rounded: "{rounded.capsule}"
    size: "24px"
  card-corner-button-hover:
    backgroundColor: "{colors.corner-button-hover}"
  card-corner-button-pressed:
    backgroundColor: "{colors.corner-button-pressed}"
  capture-card:
    rounded: "{rounded.card}"
    width: "220px"
  history-card:
    rounded: "{rounded.card}"
    height: "150px"
  media-badge:
    backgroundColor: "{colors.media-badge}"
    textColor: "{colors.white}"
    typography: "{typography.caption}"
    rounded: "{rounded.capsule}"
    padding: "3px 7px"
---

# Design System: OhMyShot

## Overview

**Creative North Star: "The Part of macOS Apple Forgot to Ship"**

OhMyShot looks like a system feature, not an app with a brand. Light and dark follow the system, the accent is the user's own macOS accent, and every window is a standard window with standard controls. What the app adds is a thin, consistent layer of softness for the things that float over other people's screens: continuous-corner cards, fully round capsules, gentle downward shadows, opaque white action capsules, and the rounded system face with fixed-width digits for every live reading. The capture is the hero; the chrome recedes.

Density is low and the vocabulary is small. A handful of shapes (12 pt cards, capsules, one circular loupe) and a handful of tints (black and white at stated opacities over system colors) cover every shipped surface: the capture overlay, the All-In-One bar, Quick Access cards, Capture History, and Settings. Light and dark are first-class and are resolved per view, and Reduce Motion, Reduce Transparency, and Increase Contrast each have a shipped, specific response rather than a generic fallback.

The confirmed rejection is the first world, "Contact Sheet" (rejected by the user on 2026-10-07): no frame numbers, no captures joined into one strip, no film-edge or darkroom motifs, no dark heavy panels, nothing that reads as a Linux utility.

Units: every dimension in this file is in points. The frontmatter writes points as `px` for tool compatibility; 1 pt renders as 2 device pixels on Retina displays.

**Key Characteristics:**
- System semantic colors and the user's accent carry all appearance; literal values are only black or white at fixed opacities.
- Continuous corners everywhere: 12 pt cards, fully round capsules for every control and reading.
- Soft, downward, widely blurred shadows; never a hard edge or a halo.
- SF Pro Rounded with monospaced digits for readings; plain system text styles inside windows.
- Liquid Glass only on small controls (the All-In-One bar, History hover buttons, the History toolbar), never over a full-screen frame.
- Motion is a single short ease-out or nothing; under Reduce Motion it is nothing.

## Colors

A system-colored world: macOS semantic colors and the user's accent do the work, and the app's own values are neutral black and white at stated opacities.

### Primary
- **The User's Accent** (`AccentColor`, AppKit `controlAccentColor`): the only hue the app ever uses for state. It marks the selected mode's symbol in the All-In-One bar, the center cell outline in the loupe, and the 3 pt selection ring around a selected Capture History card. It is never a fill behind text and never a brand color; OhMyShot has no brand hue.

### Neutral
- **System surfaces** (`windowBackgroundColor`, `controlBackgroundColor`, SwiftUI `.background.secondary`): the opaque backing inside the All-In-One glass, the Reduce Transparency capsule, the letterbox behind a Quick Access picture, and the placeholder behind a History thumbnail. These follow light and dark automatically; no hex is recorded because none exists.
- **System ink** (`labelColor`, `.secondary`, `.tertiary`, `separatorColor`): all window text, bar labels, the empty-state symbol (tertiary), the bar's hairline edge, and History card borders.
- **White** (#FFFFFF): the 1.5 pt selection border, the crosshair, and the loupe rim and fill. White reads on the dimmed screen; the dark outline underneath makes it read on white pages.
- **Selection Outline** (black at 0.32, 0.7 with Increase Contrast): a 3.5 pt stroke under the white edge and the crosshair, so the white line holds on light content.
- **Room Dimming** (black at 0.26, 0.45 with Increase Contrast): the flat fill over the screen outside the selection. Light enough that the screen stays readable.
- **Reading Capsule** (white at 0.96 in Light; a near-neutral 0.17 gray at 0.94 in Dark): the fill of every on-screen reading, with ink at 0.85 black or 0.92 white and a 0.5 pt border at 0.08 black or 0.12 white.
- **Action White** (#F7F7F7, #FFFFFF on hover, #D6D6D6 pressed, ink #1A1A1A): the opaque Copy and Save capsules over a hovered Quick Access card. They stay white in both appearances because they sit on a picture, not on chrome.
- **Corner Button** (black at 0.5, 0.62 on hover, 0.72 pressed, white symbol): the small round Close and More buttons on a hovered card.
- **Scrims** (black at 0.22 over floating Quick Access cards; black at 0.28 over in-window History cards): the hover dimming that lets white or glass controls read on any picture.
- **Picture Border** (black at 0.10 in Light, white at 0.16 in Dark, 0.5 pt): the edge of a Quick Access picture.
- **Saved green** (`systemGreen` with a white glyph): the saved badge on a card, the one non-accent hue, used only as a status mark.

### Named Rules
**The No Brand Hue Rule.** The accent is whatever the user chose in System Settings. Never hard-code a blue, never tint a surface toward a house color.

**The Black-and-White Opacity Rule.** Every literal color the app introduces is pure black or white at a stated opacity (or the single 0.17 gray of the Dark reading capsule). New surfaces reuse these steps before inventing a tint.

**The Resolve-Per-Appearance Rule.** Layer colors do not follow appearance changes on their own; every layer-drawn color is resolved for the view's effective appearance and re-resolved when it changes.

## Typography

**Display Font:** none; OhMyShot has no display tier.
**Body Font:** SF Pro (the system face) via SwiftUI and AppKit text styles.
**Label/Mono Font:** SF Pro Rounded (system font with the rounded design), with monospaced digits for readings.

**Character:** The rounded face softens the few words that float over someone else's screen; the plain system face keeps windows indistinguishable from Apple's own.

### Hierarchy
- **Reading** (SF Pro Rounded semibold 600, 12 pt, monospaced digits): live numbers on screen, such as "1200 × 720", "App · W × H", and "x, y  #HEX". Fixed-width figures keep the capsule from jittering as values change.
- **Control Label** (SF Pro Rounded medium 500, 12 pt; semibold 600 when selected): All-In-One bar labels. Symbols beside them are 13 pt medium.
- **Action Label** (SF Pro Rounded semibold 600, 13 pt; symbol 12 pt bold): the Copy and Save capsules on a card.
- **Title** (system `title3` semibold, 15 pt): empty-state titles in Capture History; `title2` semibold for the About and onboarding headings.
- **Body** (system body, 13 pt): Settings rows and window text, via the grouped Form defaults.
- **Callout** (system `callout`, 12 pt; medium for a History card's relative time): secondary explanations and empty-state messages, max width 360 pt.
- **Caption** (system `caption`, 10 pt, secondary): a History card's "W × H · App" line; semibold with monospaced digits in the recording badge.

### Named Rules
**The Rounded-Off-Window Rule.** The rounded face is for floating controls and readings over the screen. Inside a standard window, use system text styles and never the rounded face.

**The Steady Digits Rule.** Any number that changes while the user watches uses monospaced digits.

## Layout

There is no page grid; layout is anchored to screens, selections, and windows.

- **Overlay:** the size capsule centers under the selection 10 pt below it; with no room below it tucks 10 pt inside the selection; if it would meet the All-In-One bar it lifts 10 pt above the bar. All floating readings clamp 6 pt from the display edges. The loupe sits 22 pt below-right of the pointer and flips away from the display edges; its info capsule sits 8 pt below the lens. The All-In-One bar centers horizontally 40 pt above the bottom of the display and fades out while a region is dragged.
- **Quick Access:** a single column of separate cards, 220 pt wide, each 100 to 172 pt tall by the capture's aspect (extreme shapes letterbox). Cards are 12 pt apart inside an 18 pt margin that leaves room for their shadows; the column sits at the bottom-left of the screen's visible frame, inset 8 pt. Newest is at the bottom; the oldest card drops when the column would exceed the visible height.
- **Card hover layout:** Copy and Save capsules stacked 8 pt apart, centered; Close and More round buttons 8 pt from the top corners; the saved badge 8 pt from the bottom-right.
- **Capture History:** a standard 920 × 640 pt window (minimum 560 × 420) with an adaptive grid of cards 200 to 280 pt wide, 20 pt between columns, 22 pt between rows, 24 pt side insets, 20 pt top and bottom.
- **Settings:** a preference-style window with toolbar tabs; each pane is a grouped Form 520 pt wide. Non-form panes (About) use 28 pt padding.
- **Spacing rhythm:** 2 (bar chip gap), 6 (edge clamp, bar inset), 8 (insets), 10 (offsets from a selection), 12 (card gap), 18 (stack margin), 20 to 24 (window grid), 28 (panel padding).

## Elevation & Depth

Depth is soft shadow plus system materials. Floating elements over arbitrary screen content carry a diffuse downward shadow and a 0.5 pt hairline so they hold their edge on white pages; in-window elements carry a lighter shadow. Shadows always follow the element's exact rounded shape. Liquid Glass gives the All-In-One bar its rim, but its fill is opaque, so screen text never shows through a control.

### Shadow Vocabulary
- **Floating card** (black 0.22, blur radius 14, offset 6 pt downward): Quick Access cards.
- **Floating lens** (black 0.28, blur radius 12, offset 4 pt downward): the loupe.
- **Floating bar** (black 0.16, blur radius 10, offset 3 pt downward): the All-In-One capsule.
- **Floating reading** (black 0.18, blur radius 8, offset 2 pt downward): reading capsules.
- **Action lift** (black 0.18, blur radius 4, offset 1 pt downward): the white Copy and Save capsules, so they hold on bright pictures.
- **In-window card** (black 0.12, blur radius 10, offset 4 pt downward): Capture History cards.

`Theme.Shadow` also declares a 5 pt offset that no shipped surface uses; the card applies 6 pt.


A floating panel leaves room around its card for the whole shadow to fade out: twice the blur plus the drop (34 pt for the floating card shadow). A shadow cut off at the panel's edge reads as a hard rectangle.

### Named Rules
**The Soft Lift Rule.** Shadows are downward, widely blurred, and low opacity. No hard offset shadows, no glows, no halos.

**The Small Glass Rule.** Liquid Glass appears only on small controls: the All-In-One bar, the History toolbar, and History hover buttons. The full-screen overlay is a flat dimming fill and never carries glass.

**The Opaque Behind Text Rule.** Any control with text that floats over a capture or a screen has an opaque (or at least 0.94) fill. Glass supplies the rim, not the backing.

## Shapes

Continuous (squircle) corners throughout. Pictures and cards are 12 pt; every control, reading, and badge is a full capsule whose radius is half its height; nested controls are capsules concentric with their capsule container (the bar insets its chips by 6 pt). The History selection ring is 16 pt (card radius plus 4), drawn 5 pt outside the card so the corner stays concentric. The loupe is a circle with a 3 pt white rim; its center pixel cell has a 1.5 pt corner. The color swatch in a reading is a 10 pt square with a 5 pt radius.

Hairlines are 0.5 pt (card borders, bar edge, reading capsule edge); the selection edge is 1.5 pt; Increase Contrast adds a 1 pt outline to card buttons.

## Components

### Buttons
- **Card action capsule** (Copy, Save): hand-drawn opaque white capsule, 112 × 30 pt, symbol and label centered 6 pt apart, action lift shadow. Brightens to pure white on hover and drops to #D6D6D6 while pressed; fires only on release inside, like a standard button. "Copied" (1.2 s) and "Saved" swap the label and symbol to a checkmark. With Increase Contrast, a 1 pt black 0.5 outline.
- **Card corner button** (Close, More): 24 pt dark circle, 10.5 pt bold white symbol, tooltip as label. More opens the card's menu. With Increase Contrast, a 1 pt white 0.7 outline.
- Card buttons are drawn by hand because AppKit draws standard controls dimmed in non-key windows and the Quick Access panel never becomes key. Clicking them never brings OhMyShot forward.
- **In windows:** standard controls only. History hover actions use `.glassProminent` (Restore, large, callout semibold) and `.glass` icon buttons (16 pt symbols); Settings uses standard toggles, pickers, and push buttons.

### Chips (All-In-One bar)
- **Style:** borderless capsule chips, 30 pt tall, at least 84 pt wide (Cancel is a 30 pt icon-only chip after a 20 pt separator), SF Symbol plus label.
- **State:** selected = light highlight (black 0.08 / white 0.16) + accent-tinted symbol + semibold label in the label color; hover = half-strength highlight (black 0.045 / white 0.09); rest = clear.

### Cards / Containers
- **Quick Access card:** separate rounded picture, 12 pt continuous corners, 0.5 pt picture border, floating card shadow, no number or caption. Hover fades in the 0.22 scrim and the controls over 0.12 s ease-out; the saved badge hides while hovered. Click-through without activating the app, double-click to open, drag out to another app, two-finger swipe to close, right-click for the full menu.
- **Capture History card:** cropped (aspect-fill) thumbnail 150 pt tall, 12 pt corners, 0.5 pt separator border, in-window shadow; relative time and "W × H · App" below. Hover shows the 0.28 scrim with Restore and four glass icon buttons. Selected = 3 pt accent ring 5 pt outside. Recordings carry a bottom-left play badge with the duration.

### Reading Capsule (Signature)
The rounded capsule for every on-screen number: the selection size, the window name and size, and the loupe's coordinates with color swatch and hex. Height is text height plus 9 pt, 11 pt side padding, 0.5 pt border, floating reading shadow. The swatch border is strong enough (black 0.3 / white 0.38) that a white sample still reads.

### Text Selection (Capture Text)
Copying text gets a lighter overlay than a screenshot: no dimming, no magnifier, no readings, no All-In-One bar, and the system crosshair instead of a drawn one. The selection (or the hovered window, after Space) is drawn like selected text: the system's text-selection color for the current appearance, filled at 0.35 (0.45 in Dark), edged with a 1 pt line in the accent (2 pt under Increase Contrast), on whole points. When the mouse is released, the same highlight takes over in place, at the overlay's level, click-through and without taking focus, while the text is read; if reading takes over a second it breathes slowly (opacity 1 to 0.5, 0.9 s each way; not under Reduce Motion). It fades over 0.35 s once the text is on the clipboard; with nothing to read it fades in 0.15 s with the system beep. VoiceOver hears the count or "No text found". That is the whole feedback by default.

### Text Result Card
An optional card after Capture Text (off by default; Settings › General › Capture Text), floating by the selection without taking focus: 10 pt below it, or above it when there is no room, and 8 pt from the screen's edges. It uses the reading capsule's materials at card size: a 12 pt continuous-corner card filled white 0.97 (Dark: 0.17 gray at 0.96), a 0.5 pt hairline (1 pt at black 0.35 / white 0.5 under Increase Contrast), and the floating card shadow. Width follows the selection between 300 and 420 pt.

- **Layout:** one column for everything but the symbol, which hangs to its left (a white check in a green disc for copied, a quiet magnifier for nothing found). The header row holds the title, the character count in the rounded reading face at the right in secondary ink, and a 24 pt close button. Below it, up to three lines of the copied text in label ink, truncated, then the line-break chip.
- **Chips:** buttons on a card are hand-drawn tinted capsules, 26 pt tall, black 0.06 (Dark: white 0.10), stronger on hover (×1.7) and press (×2.6), with label-colored symbol and text; the close button is the same tint in a 24 pt circle. AppKit would draw standard controls dimmed, since the card's panel never becomes key.
- **States:** *copied* stays 4 s; *nothing found* stays 2.5 s with a one-line hint. Hovering holds the card; with VoiceOver on, it stays 20 s so its buttons can be reached. VoiceOver announces the count or the empty result (also when the card is off).
- **Count:** every character a paste contains, with singular and plural forms.

### OCR Panel
A standard titled window, "Recognized Text", with the source as its subtitle (Screen Area, a window's app and title, a file name, Clipboard): 1040 × 660 pt by default, at least 760 × 460, its frame remembered. The picture is on the left on `.background.secondary`; the text is on the right (320 to 560 pt) on the window background. Opened by Option held as a Capture Text drag ends, Recognize Text… on a Quick Access card or in Capture History, the two Recognize Text items in the status menu, or an image dropped on the menu bar icon.

- **Picture:** the image as a 12 pt continuous-corner card with the picture border (0.5 pt; 1 pt under Increase Contrast) and the in-window card shadow, fitted with 24 pt around it and never drawn larger than it appeared on screen, sized and placed on whole points.
- **Line boxes:** every recognized line answers the pointer the way Text Selection is drawn. Hovered, it is outlined in the accent (1 pt, 2 pt under Increase Contrast); with its text selected, it is filled with the selection color at 0.35 (0.45 in Dark) and edged in the accent; while the text is not active it takes the inactive selection color and a secondary edge, as the text does. Clicking a line selects its text and focuses the editor. Codes outline the same way while hovered on the picture or in the Found list. In the Table pane the line boxes are hidden.
- **Editor:** the system body style (13 pt; monospaced at the same size for code) at a 1.15 line height, 12 × 14 pt insets, links and contacts underlined in the link color, the Find bar, and no automatic substitutions or spelling correction. Once the text is edited, lines stop reacting and a notice under the editor reads "Edited, no longer linked to the image" with Revert.
- **Toolbar:** the text side's controls sit together at the trailing edge: Text / Table (segmented, only when a table was found), the line-break menu (Keep Line Breaks / Join Lines; Text pane only, disabled for code), and one `.glassProminent` Copy with title and symbol (⇧⌘C). Copy reads "Copied" with a checkmark for 1.5 s, and VoiceOver hears "Copied" or "Table copied". While loading or after a failure, only the disabled Copy shows.
- **Table pane:** a grid in a 12 pt continuous card with one-pixel separator hairlines; the header row is semibold on black 0.045 / white 0.09; body text uses monospaced digits; columns of figures are right-aligned; cells are 56 to 260 pt wide. Copy as Markdown and Copy as CSV are small buttons under the table. The toolbar's Copy writes TSV, HTML, and Markdown at once, so spreadsheets paste cells.
- **Found in Image:** a semibold secondary caption header, then 28 pt rows: the kind's symbol in secondary ink, the value on one line (middle truncation), and borderless symbol buttons for the item's verb (Open Link, New Email, Call, Show in Maps, Add to Calendar) and Copy (a checkmark for 1.2 s). Rows take the chip hover fill (black 0.045 / white 0.09) at a 6 pt radius. VoiceOver reads a row as one element, kind and value, with its verbs as actions. The list is at most 176 pt tall and scrolls beyond that. Only web links open from a code.
- **States:** loading is a small spinner over "Recognizing text…" (callout, secondary). Empty and failed follow the Capture History empty state (40 pt light tertiary symbol, title3 semibold title, callout message at most 360 pt wide); a failed read offers Try Again. A file that is no image, or an empty clipboard, shows only the message, across the whole window.
- **Translation:** a Translate toggle (button style, the `translate` symbol alone, ⇧⌘T: a mode, so Copy stays the one titled, filled control) sits before Copy, a fixed toolbar space between them; on, it shows the "Translate Into" menu beside it, whose label is short and never changes under the pointer ("Automatic", or the language chosen) and whose items are Automatic (reading "Automatic: Chinese, Simplified" once it has chosen), then the system's languages by name. Text / Table and the line-break menu are hidden meanwhile. The picture shows the image with the translation drawn over its text (the Translation Overlay, below), fading in over the original in 0.18 s (instant under Reduce Motion), and no line boxes. The text side shows the translation, unit by unit, selectable but not editable, in the editor's type, with Find, its links underlined in the link color as in the editor, and its translated parts marked as in the target language for VoiceOver; under it, a status line in the edited notice's style reads "English → Chinese, Simplified" (VoiceOver: "Translated from English to Chinese, Simplified"), with a small Download Languages… button when part of the text needs a download. Copy copies the translation ("Translation copied"). Translating is a spinner over "Translating…"; nothing to translate, already in the target, code, a language that can't be translated, a download needed, and a failure use the empty state (the download offers Download…, which hands over to the system's own sheet; a failure offers Try Again). Turned off and on again, the same translation shows again; a new target translates again. The toggle stays on from image to image.

### Translation Overlay
How translated text is drawn over an image, in the OCR panel and Translate Area alike: each translated line is painted over with its own background (the median of the pixels just outside its box, 12% of its height above and below, never into a line that stays), then the translation is set in the original's ink (the median of its inkiest pixels), in the system font for the target language (PingFang for Chinese), its ink left-aligned with the ink of its column (translated lines and lines left as they were alike) and centered on where the original's ink was; right to left, it ends at the right edge. Its size is the original's, read from the line's width at the size it had on screen, made one across neighbors of a column or row; a unit a third larger than the body or more is set semibold. A translation that does not fit shrinks to 70% (a line on its own may first run on to the right over its own background, never over an icon or other text), then ends in an ellipsis; a paragraph keeps its column and line spacing. Code, links, figures ("5 GB"), and bilingual labels are left as they are.

### Translation Lens (Translate Area)
Translate Area's result: a borderless panel exactly over the selection, at the overlay's level, holding the captured area with the Translation Overlay drawn on it, so the screen seems to change language where it was dragged over. A 0.5 pt black 0.18 hairline (1 pt black 0.35 under Increase Contrast) and the system window shadow say it lies over the screen. It sits just below the level of menus, over the menu bar and the Dock but under its own context menu. It takes keys without bringing the app forward: Escape closes it, ⌘C copies the translation (the lens stays; the copy button shows a checkmark for 1.2 s), Return opens the area in the OCR panel, translated, and Option held shows the original. A click on it, or another window taking the keys, closes it. While the pointer is over it (also when it opens under the pointer), three card corner buttons (24 pt dark circles: Copy Translation, Open in Panel, Close) fade in outside it, in a row ending at its right edge 6 pt above it, below it when the area reaches the top of the screen, inside its corner only when it fills the screen's height; they never cover the translation. Its context menu holds Copy Translation, Show Original, Open in Panel, and Close. VoiceOver reads it as text, "Translation, English → Chinese, Simplified", with the translation as its value (its translated parts in the target language) and Copy Translation, Open in Panel, and Close as actions, and hears "Translated, … Escape closes it." when it appears, with where to read lines that were shortened. Between the drag and the lens, the Text Selection highlight holds the area. With nothing to translate, the highlight fades with the beep and VoiceOver hears why ("Already in Chinese, Simplified", "Nothing to translate"); a language still to download opens the OCR panel, which offers it. Option held as the drag ends opens the panel instead.

### Capture Overlay (Signature)
Softly dimmed screen; selection with a white 1.5 pt edge over a dark outline; a crosshair with a 4 pt center gap and 13 pt arms, white over the same outline; a 120 pt loupe showing 15 captured pixels across (8 pt per pixel, aligned to device pixels) with a faint 0.08 grid, an accent center cell, a white rim, and the lens shadow. Window mode drops the crosshair and loupe and highlights the hovered window.

### All-In-One Bar (Signature)
A Liquid Glass capsule with an opaque window-colored backing inside, a 0.5 pt separator hairline, and the floating bar shadow. With Reduce Transparency it is a solid window-colored capsule with the same hairline.

### Navigation
- **Capture History toolbar:** a SwiftUI toolbar bridged into a unified window toolbar: segmented Show filter (All, Screenshots, Recordings), a "Keep for …" menu, and Move All to Trash. Empty states are filter-aware (a 40 pt light tertiary symbol, title3 title, callout message).
- **Keyboard:** arrows select, Return restores, Space opens Quick Look; ⌘C, ⌘S, and ⌘⌫ arrive as commands through an invisible main menu and are disabled with nothing selected.
- **Settings:** preference toolbar tabs; grouped sections such as "After capturing", "Capture History", and "Translation" (Translate into: Automatic, the first of the preferred languages the text isn't already in, then the system's languages).
- **Status menu:** grouped capture commands (Capture Area, Window, Fullscreen, Capture Text, Translate Area), then Recognize Text in Clipboard Image (enabled when the clipboard offers an image or a file) and Recognize Text in Image…, then Capture History and Restore Recently Closed. An image dropped on the menu bar icon opens in the OCR panel; the icon highlights while it is over it.
- **Find:** the Edit menu carries Find…, Find Next, Find Previous, and Use Selection for Find for the OCR panel's text.
- **Destructive confirmations** state the count and consequence and name the action ("Delete 3 Captures"; "This can't be undone.").

### Motion
- Cards slide in 36 pt from the screen edge with a fade over 0.22 s ease-out; the stack reflows over 0.22 s ease-out; a dismissed card slides 40 pt left and fades. Hover fades take 0.12 s ease-out. History scrolls to a new selection over 0.15 s ease-out.
- The text selection highlight fades out over 0.35 s once the text is copied (0.15 s when there was none).
- The optional text result card fades in over 0.22 s with a 6 pt rise of its layer (never of its window, whose size can change mid-animation), and fades out over 0.12 s.
- In the OCR panel, Copy buttons swap their symbol for a checkmark with the system's symbol replace transition and back after 1.5 s (toolbar) or 1.2 s (rows).
- The translation lens fades in over 0.18 s ease-out and out over 0.15 s ease-in; its buttons fade over 0.12 s.
- Under Reduce Motion all of these are instant. Nothing trails the pointer: overlay layers update without animation. The two durations live in `Theme.Motion` (`slide` 0.22 s, `fade` 0.12 s).

### Future Surfaces
The annotation editor, recording controls, and pins are not built. They must use this system (system colors and accent, 12 pt cards and capsules, soft lift shadows, rounded readings, small glass only, the three accessibility responses); their specs are recorded when they ship, not before.

## Do's and Don'ts

### Do:
- **Do** use system semantic colors and `controlAccentColor` for every surface and state; add only black or white at the stated opacities.
- **Do** make every floating control a full capsule (radius = height / 2) with concentric inner chips, and every picture a 12 pt continuous-corner card.
- **Do** give floating elements a soft downward shadow plus a 0.5 pt hairline so they hold on white pages.
- **Do** put live numbers in a reading capsule: SF Pro Rounded 12 pt semibold with monospaced digits.
- **Do** keep text-bearing controls opaque over captures; use glass for the rim, not the fill.
- **Do** answer accessibility settings specifically: Reduce Motion = instant; Reduce Transparency = solid window-colored capsule; Increase Contrast = 45% dimming, 0.7 outline, 1 pt button outlines.
- **Do** use standard windows, toolbars, grouped Forms, and SwiftUI glass button styles inside windows.
- **Do** hand-draw controls only where AppKit would render them dimmed (non-key floating panels), and make them track presses like standard buttons.

### Don't:
- **Don't** bring back Contact Sheet: no frame numbers, no captures joined into a strip, no film-edge or darkroom motifs.
- **Don't** build dark heavy panels, bars, or strips; small dark round corner buttons over a hovered picture are the only dark chrome.
- **Don't** put glass, blur, or a material over the full-screen overlay; the room is a flat 26% fill.
- **Don't** use hard offset shadows, glows, or halos.
- **Don't** use the rounded face inside standard windows, or proportional digits in a changing number.
- **Don't** invent a brand hue or tint chrome toward one.
- **Don't** animate anything that follows the pointer, or run any motion under Reduce Motion.
