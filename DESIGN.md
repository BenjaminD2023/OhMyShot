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
  chip-selected-contrast-light: "rgba(0,0,0,0.16)"
  chip-selected-contrast-dark: "rgba(255,255,255,0.28)"
  chip-hover-contrast-light: "rgba(0,0,0,0.09)"
  chip-hover-contrast-dark: "rgba(255,255,255,0.16)"
  capsule-surface-light: "rgba(255,255,255,0.97)"
  capsule-surface-dark: "rgba(43,43,46,0.96)"
  hairline-contrast-light: "rgba(0,0,0,0.35)"
  hairline-contrast-dark: "rgba(255,255,255,0.5)"
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
  spotlight-dim: "rgba(0,0,0,0.5)"
  capsule-swatch-edge-light: "rgba(0,0,0,0.18)"
  capsule-swatch-edge-dark: "rgba(255,255,255,0.38)"
  capsule-swatch-edge-contrast-light: "rgba(0,0,0,0.4)"
  capsule-swatch-edge-contrast-dark: "rgba(255,255,255,0.6)"
  checker-light: "#FFFFFF"
  checker-light-alt: "#E8E8E8"
  checker-dark: "#333333"
  checker-dark-alt: "#404040"
  mark-red: "#FF3B30"
  mark-orange: "#FF9500"
  mark-yellow: "#FFCC00"
  mark-green: "#34C759"
  mark-blue: "#007AFF"
  mark-purple: "#AF52DE"
  mark-black: "#000000"
  mark-white: "#FFFFFF"
  mark-marker: "#FFE74A"
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
  capsule-text-chip:
    fontFamily: "SF Pro, system-ui"
    fontSize: "12px"
    fontWeight: 600
  mark-text:
    fontFamily: "SF Pro, system-ui"
    fontSize: "20px"
    fontWeight: 600
    lineHeight: 1.25
  counter-label:
    fontFamily: "SF Pro Rounded, ui-rounded, system-ui"
    fontWeight: 700
rounded:
  card: "12px"
  capsule: "9999px"
spacing:
  chip-gap: "2px"
  capsule-inset: "4px"
  edge: "6px"
  inset: "8px"
  offset: "10px"
  card-gap: "12px"
  stack-margin: "18px"
  grid-gap: "20px"
  window-inset: "24px"
  panel-padding: "28px"
  style-capsule-height: "38px"
  rail-width: "42px"
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
  tool-rail:
    rounded: "{rounded.capsule}"
    width: "{spacing.rail-width}"
    padding: "6px"
  rail-chip:
    rounded: "{rounded.capsule}"
    size: "30px"
  rail-chip-selected-light:
    backgroundColor: "{colors.chip-selected-light}"
    rounded: "{rounded.capsule}"
    size: "30px"
  rail-chip-selected-dark:
    backgroundColor: "{colors.chip-selected-dark}"
    rounded: "{rounded.capsule}"
    size: "30px"
  style-capsule-light:
    backgroundColor: "{colors.capsule-surface-light}"
    rounded: "{rounded.capsule}"
    height: "{spacing.style-capsule-height}"
    padding: "4px 4px 4px 8px"
  style-capsule-dark:
    backgroundColor: "{colors.capsule-surface-dark}"
    rounded: "{rounded.capsule}"
    height: "{spacing.style-capsule-height}"
    padding: "4px 4px 4px 8px"
  capsule-chip:
    rounded: "{rounded.capsule}"
    height: "30px"
    width: "30px"
  capsule-chip-selected-light:
    backgroundColor: "{colors.chip-selected-light}"
    rounded: "{rounded.capsule}"
    height: "30px"
  capsule-chip-selected-dark:
    backgroundColor: "{colors.chip-selected-dark}"
    rounded: "{rounded.capsule}"
    height: "30px"
  capsule-text-chip-prominent-light:
    backgroundColor: "{colors.chip-selected-light}"
    typography: "{typography.capsule-text-chip}"
    rounded: "{rounded.capsule}"
    height: "30px"
  inplace-toolbar:
    rounded: "{rounded.capsule}"
    height: "42px"
    padding: "6px"
  countdown-disc:
    rounded: "{rounded.capsule}"
    size: "64px"
---

# Design System: OhMyShot

## Overview

**Creative North Star: "The Part of macOS Apple Forgot to Ship"**

OhMyShot looks like a system feature, not an app with a brand. Light and dark follow the system, the accent is the user's own macOS accent, and every window is a standard window with standard controls. What the app adds is a thin, consistent layer of softness for the things that float over other people's screens: continuous-corner cards, fully round capsules, gentle downward shadows, opaque white action capsules, and the rounded system face with fixed-width digits for every live reading. The capture is the hero; the chrome recedes.

Density is low and the vocabulary is small. A handful of shapes (12 pt cards, capsules, one circular loupe) and a handful of tints (black and white at stated opacities over system colors) cover every shipped surface: the capture overlay, the All-In-One bar, in-place annotation, the Self-Timer countdown, Quick Access cards, Capture History, the OCR panel, the annotation editor, and Settings. Light and dark are first-class and are resolved per view, and Reduce Motion, Reduce Transparency, and Increase Contrast each have a shipped, specific response rather than a generic fallback.

The confirmed rejection is the first world, "Contact Sheet" (rejected by the user on 2026-10-07): no frame numbers, no captures joined into one strip, no film-edge or darkroom motifs, no dark heavy panels, nothing that reads as a Linux utility.

Units: every dimension in this file is in points. The frontmatter writes points as `px` for tool compatibility; 1 pt renders as 2 device pixels on Retina displays.

**Key Characteristics:**
- System semantic colors and the user's accent carry all appearance; literal values are only black or white at fixed opacities.
- Continuous corners everywhere: 12 pt cards, fully round capsules for every control and reading.
- Soft, downward, widely blurred shadows; never a hard edge or a halo.
- SF Pro Rounded with monospaced digits for readings; plain system text styles inside windows.
- Liquid Glass only on small controls (the All-In-One bar, the in-place toolbar, the editor's tool rail, the Self-Timer disc, History hover buttons, window toolbars), never over a full-screen frame.
- Motion is a single short ease-out or nothing; under Reduce Motion it is nothing.

## Colors

A system-colored world: macOS semantic colors and the user's accent do the work, and the app's own values are neutral black and white at stated opacities.

### Primary
- **The User's Accent** (`AccentColor`, AppKit `controlAccentColor`): the only hue the app ever uses for state. It marks the selected mode's symbol in the All-In-One bar, the tool in hand in the editor's rail and in the in-place toolbar, the in-place toolbar's Copy check, the selected variant in the style capsule, the ring around the chosen color dot, the editor's selection box and handle rings, the center cell outline in the loupe, and the 3 pt selection ring around a selected Capture History card. It is never a fill behind text and never a brand color; OhMyShot has no brand hue.

### Neutral
- **System surfaces** (`windowBackgroundColor`, `controlBackgroundColor`, SwiftUI `.background.secondary`): the opaque backing inside the All-In-One and in-place toolbar glass, the Reduce Transparency capsule, the letterbox behind a Quick Access picture, and the placeholder behind a History thumbnail. These follow light and dark automatically; no hex is recorded because none exists.
- **System ink** (`labelColor`, `.secondary`, `.tertiary`, `separatorColor`): all window text, bar labels, the empty-state symbol (tertiary), a disabled Undo or Redo in the in-place toolbar (tertiary), the bar's hairline edge, and History card borders.
- **White** (#FFFFFF): the 1.5 pt selection border and the thick corners of a resizable frame, the crosshair, and the loupe rim and fill. White reads on the dimmed screen; the dark outline underneath makes it read on white pages.
- **Selection Outline** (black at 0.32, 0.7 with Increase Contrast): a 3.5 pt stroke under the white edge and the crosshair, so the white line holds on light content.
- **Room Dimming** (black at 0.26, 0.45 with Increase Contrast): the flat fill over the screen outside the selection, in the capture overlay and in in-place annotation. Light enough that the screen stays readable.
- **Reading Capsule** (white at 0.96 in Light; a near-neutral 0.17 gray at 0.94 in Dark): the fill of every on-screen reading, with ink at 0.85 black or 0.92 white and a 0.5 pt border at 0.08 black or 0.12 white.
- **Action White** (#F7F7F7, #FFFFFF on hover, #D6D6D6 pressed, ink #1A1A1A): the opaque Copy and Save capsules over a hovered Quick Access card. They stay white in both appearances because they sit on a picture, not on chrome.
- **Corner Button** (black at 0.5, 0.62 on hover, 0.72 pressed, white symbol): the small round Close and More buttons on a hovered card.
- **Scrims** (black at 0.22 over floating Quick Access cards; black at 0.28 over in-window History cards): the hover dimming that lets white or glass controls read on any picture.
- **Picture Border** (black at 0.10 in Light, white at 0.16 in Dark, 0.5 pt): the edge of a Quick Access picture.
- **Saved green** (`systemGreen` with a white glyph): the saved badge on a card, the one non-accent hue, used only as a status mark.
- **Chip Fill steps** (selected black 0.08 / white 0.16, hover black 0.045 / white 0.09; with Increase Contrast selected black 0.16 / white 0.28, hover black 0.09 / white 0.16): one pair for every tinted chip in a floating control. The editor's rail and style capsule carry the Increase Contrast steps; the All-In-One bar uses the base steps.
- **Capsule Surface** (white 0.97; Dark a 0.17 gray at 0.96): the fill of the text result card and the editor's style capsule, the reading capsule's materials at control and card size. The style capsule draws its Dark fill as a pure 0.17 gray where the text card lifts blue to 0.18; the difference is 1/255 and is not a second token.
- **Contrast Hairline** (black 0.35 / white 0.5, 1 pt): the edge every floating capsule, card, and picture takes under Increase Contrast in place of its 0.5 pt hairline (reading capsules, the text result card, the lens, the in-place toolbar, the editor's rail, capsule, and picture).
- **Spotlight Dimming** (black at 0.5): what a spotlight mark leaves of the picture outside its spots; overlapping spots stay bright. It is drawn into the picture, so it is darker than the room dimming, which only shows a selection.
- **Capsule Swatch Edge** (black 0.18 in Light, white 0.38 in Dark, 0.5 pt; 1 pt at black 0.40 / white 0.60 under Increase Contrast): the edge of every color dot and background swatch in the style capsule, so white and yellow hold on the light capsule and black and Graphite on the dark one.
- **Checkerboard** (8 pt squares in view points; Light white and a 0.91 gray, Dark a 0.20 and a 0.25 gray; 0.84 and 0.30 under Increase Contrast): what shows through a Transparent background's room on screen. It is an editing aid and is never exported.

### Mark Inks
Colors a user puts into a picture are content, not chrome, and are fixed sRGB values so the screen and the export agree in either appearance. The style capsule offers eight, in this order: **Red** (#FF3B30, the default for every tool), **Orange** (#FF9500), **Yellow** (#FFCC00), **Green** (#34C759), **Blue** (#007AFF), **Purple** (#AF52DE), **Black** (#000000, the default for solid redaction), and **White** (#FFFFFF); the color panel adds any other opaque color. **Marker Yellow** (#FFE74A, multiplied into the picture) is the highlighter's default. Ink on a mark (text on a label, a counter's number, the outline around outlined text) is black 0.88 on light colors and white on dark ones, chosen by the color's luminance.

### Background Fills
A background is content too, fixed values so the screen and the export agree. The ten gradients are a corner-to-corner blend (top-left to bottom-right) with one or two soft radial glows over it, in the manner of a desktop picture: **Sky** (#9CC8FA to #D9C6FA, the default), **Lilac** (#A996DC to #F6C5E6), **Rose** (#FFA6A9 to #FDD6EC), **Peach** (#FFE3C2 to #FFA488), **Citrus** (#F9DB72 to #FCA982), **Mint** (#CFF5DE to #5ACFC2), **Ocean** (#5E9CF5 to #37CDBE), **Dusk** (#464FBF to #C07BE8), **Graphite** (#4A4E57 to #1E2024), and **Paper** (#FBFBFC to #E6E7EC). Dusk and Graphite are the dark ones. Besides them: **Transparent** (no fill; only the card's shadow is drawn), **Blurred Capture** (the capture blurred until only its colors are left, aspect-filled), a **Background Color** of one's own (opaque, from the color panel without alpha), and a **Picture** (aspect-filled, read no larger than it shows). A missing picture falls back to Sky; a blur not yet made, to Paper.
- **Matte:** canvas reaching past the capture (combined images beside it), and the room Inset and Auto Balance add, is filled with the capture's edge color, or white where the edge has no one color, on screen and in exports. A window captured with its shadow gets no matte; its surroundings stay clear.

### Named Rules
**The No Brand Hue Rule.** The accent is whatever the user chose in System Settings. Never hard-code a blue in chrome, never tint a surface toward a house color. Mark inks and background fills are the user's content and the one place fixed hues live.

**The Black-and-White Opacity Rule.** Every literal color the app's chrome introduces is pure black or white at a stated opacity (or the single 0.17 gray of the Dark reading capsule, and the opaque grays of the on-screen checkerboard). New surfaces reuse these steps before inventing a tint.

**The Resolve-Per-Appearance Rule.** Layer colors do not follow appearance changes on their own; every layer-drawn color is resolved for the view's effective appearance and re-resolved when it changes.

## Typography

**Display Font:** none; OhMyShot has no display tier.
**Body Font:** SF Pro (the system face) via SwiftUI and AppKit text styles.
**Label/Mono Font:** SF Pro Rounded (system font with the rounded design), with monospaced digits for readings.

**Character:** The rounded face softens the few words that float over someone else's screen; the plain system face keeps windows indistinguishable from Apple's own.

### Hierarchy
- **Reading** (SF Pro Rounded semibold 600, 12 pt, monospaced digits): live numbers on screen, such as "1200 × 720", "App · W × H", and "x, y  #HEX". Fixed-width figures keep the capsule from jittering as values change. The Self-Timer disc's seconds take the same face at 26 pt.
- **Control Label** (SF Pro Rounded medium 500, 12 pt; semibold 600 when selected): All-In-One bar labels. Symbols beside them are 13 pt medium.
- **Action Label** (SF Pro Rounded semibold 600, 13 pt; symbol 12 pt bold): the Copy and Save capsules on a card.
- **Title** (system `title3` semibold, 15 pt): empty-state titles in Capture History; `title2` semibold for the About and onboarding headings.
- **Body** (system body, 13 pt): Settings rows and window text, via the grouped Form defaults.
- **Callout** (system `callout`, 12 pt; medium for a History card's relative time): secondary explanations and empty-state messages, max width 360 pt.
- **Caption** (system `caption`, 10 pt, secondary): a History card's "W × H · App" line; semibold with monospaced digits in the recording badge.
- **Capsule Text Chip** (system semibold 600, 12 pt, label color): the words in the editor's style capsule (crop's Reset and Done). The capsule sits inside a window, so it takes the system face.
- **Mark Text** (system semibold 600, 14 / 20 / 28 / 40 pt steps, 20 by default, 1.25 line height): text the user types into a picture, drawn by the same layout on screen, in exports, and in the editing field, so nothing moves when editing ends.
- **Counter Label** (SF Pro Rounded bold, half the disc's diameter, shrunk to fit 72% of it): the numbers, letters, or Roman numerals in counter marks.
- The editor's zoom menu label ("100%") uses monospaced digits.

### Named Rules
**The Rounded-Off-Window Rule.** The rounded face is for floating controls and readings over the screen. Inside a standard window, use system text styles and never the rounded face. A counter's rounded numerals are content drawn into the picture, not chrome.

**The Steady Digits Rule.** Any number that changes while the user watches uses monospaced digits.

## Layout

There is no page grid; layout is anchored to screens, selections, and windows.

- **Overlay:** the size capsule centers under the selection 10 pt below it; with no room below it tucks 10 pt inside the selection; if it would meet the All-In-One bar it lifts 10 pt above the bar. All floating readings clamp 6 pt from the display edges. The loupe sits 22 pt below-right of the pointer and flips away from the display edges; its info capsule sits 8 pt below the lens. The All-In-One bar centers horizontally 40 pt above the bottom of the display and fades out while a region is dragged.
- **In-place annotation:** the toolbar stands 10 pt below the selection, right-aligned to it, and the style capsule 6 pt under the toolbar, right-aligned to the toolbar. When that stack (42 + 6 + 38 pt) does not fit below, both go above, the capsule above the toolbar; when it fits neither way, the toolbar sits inside the selection's bottom-right, 10 pt clear of the frame as drawn, with the capsule above it, right-aligned to the toolbar. Everything stays 8 pt inside the display. The side is chosen with the capsule's band reserved whether it shows or not, so picking a tool never moves the toolbar. The size reading sits 10 pt above the selection's top-left corner; covered or off screen, 8 pt inside that corner (when the selection has 16 pt to spare); too small for that, 8 pt left of the toolbar on its row; else 10 pt below the selection. It keeps 6 pt from the toolbar and capsule and clamps 6 pt from the display's edges.
- **Quick Access:** a single column of separate cards, 220 pt wide, each 100 to 172 pt tall by the capture's aspect (extreme shapes letterbox). Cards are 12 pt apart inside an 18 pt margin that leaves room for their shadows; the column sits at the bottom-left of the screen's visible frame, inset 8 pt. Newest is at the bottom; the oldest card drops when the column would exceed the visible height.
- **Card hover layout:** Copy and Save capsules stacked 8 pt apart, centered; Close and More round buttons 8 pt from the top corners; the saved badge 8 pt from the bottom-right.
- **Capture History:** a standard 920 × 640 pt window (minimum 560 × 420) with an adaptive grid of cards 200 to 280 pt wide, 20 pt between columns, 22 pt between rows, 24 pt side insets, 20 pt top and bottom.
- **Annotation editor:** a standard window sized to show the capture at its on-screen size plus 100 pt across and 138 pt down (at least 760 × 560, at most 90% of the visible screen; minimum 720 × 560). The picture is fitted, never above on-screen size, inside canvas insets of 24 top, 72 left (the rail), 62 bottom (the capsule's band), and 28 right, sized on whole points. The tool rail stands 12 pt from the left edge, centered in the height above the 62 pt band and never closer than 12 pt to the top. The style capsule centers 10 pt below the selected marks, goes 10 pt above them without room, and drops to the window's bottom when the selection fills the view; it clamps 8 pt from the edges and never left of the rail plus 8 pt. With nothing selected it rests in the band at the rail's foot, 12 pt from the left and the bottom. With a background the fitted picture is the whole output, background and all; crop fits the plain capture again.
- **Settings:** a preference-style window with toolbar tabs; each pane is a grouped Form 520 pt wide. Non-form panes (About) use 28 pt padding.
- **Spacing rhythm:** 2 (chip gap), 4 (style capsule inset), 6 (edge clamp, bar and rail inset, space around a chip divider), 8 (insets, capsule clamps), 10 (offsets from a selection), 12 (card gap, rail inset), 18 (stack margin, divider length), 20 to 24 (window grid), 28 (panel padding).

## Elevation & Depth

Depth is soft shadow plus system materials. Floating elements over arbitrary screen content carry a diffuse downward shadow and a 0.5 pt hairline so they hold their edge on white pages; in-window elements carry a lighter shadow. Shadows always follow the element's exact rounded shape. Liquid Glass gives the All-In-One bar its rim, but its fill is opaque, so screen text never shows through a control.

### Shadow Vocabulary
- **Floating card** (black 0.22, blur radius 14, offset 6 pt downward): Quick Access cards.
- **Floating lens** (black 0.28, blur radius 12, offset 4 pt downward): the loupe.
- **Floating bar** (black 0.16, blur radius 10, offset 3 pt downward): the All-In-One capsule, the in-place toolbar, and the Self-Timer disc.
- **Floating reading** (black 0.18, blur radius 8, offset 2 pt downward): reading capsules, the in-place size reading among them.
- **Action lift** (black 0.18, blur radius 4, offset 1 pt downward): the white Copy and Save capsules, so they hold on bright pictures.
- **In-window card** (black 0.12, blur radius 10, offset 4 pt downward): Capture History cards, the OCR panel's picture, and the annotation editor's picture.
- **Mark shadow** (black 0.3, blur 3 pt, drop 1 pt, scaled with the capture): drawn into the picture under arrows, lines, shapes, pen strokes, text, and counters (on by default; off for highlighter, redaction, and spotlight; off by default for combined images), so marks hold on busy pictures. It is exported.
- **Background card** (for Shadow strength s from 0 to 1: drop 2 + 10s pt, blur 8 + 32s pt, black at 0.14 + 0.30s; at the default 0.5, drop 7, blur 24, black 0.29; scaled with the capture): under the capture on a background, following the card's rounded shape, drawn from a small blurred mask so a large picture's shadow costs milliseconds, and never seen through clear room in the card. It is exported. A window captured with its shadow keeps its own and gets none.

The editor's tool rail takes the floating bar shadow and its style capsule the floating reading shadow; selection handles carry a small lift (black 0.3, blur 2, 1 pt down) of their own. The Adjust popover is the system's popover with its own shadow.

`Theme.Shadow` also declares a 5 pt offset that no shipped surface uses; the card applies 6 pt.


A floating panel leaves room around its card for the whole shadow to fade out: twice the blur plus the drop (34 pt for the floating card shadow; the Self-Timer disc's panel leaves 24 pt for the floating bar shadow). A shadow cut off at the panel's edge reads as a hard rectangle.

### Named Rules
**The Soft Lift Rule.** Shadows are downward, widely blurred, and low opacity. No hard offset shadows, no glows, no halos.

**The Small Glass Rule.** Liquid Glass appears only on small controls: the All-In-One bar, the in-place toolbar, the editor's tool rail, the Self-Timer disc, window toolbars and their glassProminent Copy, and History hover buttons. The two overlay toolbars are small controls on the overlay, not over it; the full-screen overlay itself is a flat dimming fill and never carries glass, and neither does the editor's style capsule, which sits beside text-bearing marks.

**The Opaque Behind Text Rule.** Any control with text that floats over a capture or a screen has an opaque (or at least 0.94) fill. Glass supplies the rim, not the backing; the editor's Adjust popover sets its Form on the opaque window color inside the system popover.

**The Exported-Is-Drawn Rule.** What is drawn into the picture is exported: marks, the mark shadow, the background, its card shadow, and the matte. What helps on screen never is: the checkerboard, selection and handles, the drop ring, the crop frame and the in-place selection frame, the picture border, and the in-window shadow.

## Shapes

Continuous (squircle) corners throughout. Pictures and cards are 12 pt, except the annotation editor's picture, which is square: it is the image that gets exported, edge to edge, and marks and the crop run to its pixel edges (on a background, the capture's card inside it takes the background's Corners, 0 to 40 pt, 12 by default); every control, reading, and badge is a full capsule whose radius is half its height; nested controls are capsules concentric with their capsule container (the bar insets its chips by 6 pt). The History selection ring is 16 pt (card radius plus 4), drawn 5 pt outside the card so the corner stays concentric. The loupe is a circle with a 3 pt white rim; its center pixel cell has a 1.5 pt corner. The color swatch in a reading is a 10 pt square with a 5 pt radius. The editor's rail is a capsule 42 pt wide whose 30 pt chips are circles; the style capsule is 38 pt tall with 30 pt chips 4 pt inside it, concentric; the in-place toolbar is the rail laid flat, a capsule 42 pt tall with 30 pt circular chips 6 pt inside it. The drag-out thumbnail in the editor's toolbar has a 4 pt continuous corner. Background swatches are 14 pt discs in 24 pt chips; the Position grid's cells are 16 × 12 pt with 3 pt continuous corners.

Hairlines are 0.5 pt (card borders, bar, rail, and in-place toolbar edges, reading and style capsule edges, picture edges); the capture, crop, and in-place selection edge is 1.5 pt; the editor's mark selection is a 1 pt accent line; Increase Contrast turns the hairlines into the 1 pt contrast hairline and adds a 1 pt outline to card buttons.

## Components

### Buttons
- **Card action capsule** (Copy, Save): hand-drawn opaque white capsule, 112 × 30 pt, symbol and label centered 6 pt apart, action lift shadow. Brightens to pure white on hover and drops to #D6D6D6 while pressed; fires only on release inside, like a standard button. "Copied" (1.2 s) and "Saved" swap the label and symbol to a checkmark. With Increase Contrast, a 1 pt black 0.5 outline.
- **Card corner button** (Close, More): 24 pt dark circle, 10.5 pt bold white symbol, tooltip as label. More opens the card's menu. With Increase Contrast, a 1 pt white 0.7 outline.
- Card buttons are drawn by hand because AppKit draws standard controls dimmed in non-key windows and the Quick Access panel never becomes key. Clicking them never brings OhMyShot forward.
- **In windows:** standard controls only. History hover actions use `.glassProminent` (Restore, large, callout semibold) and `.glass` icon buttons (16 pt symbols); toolbars put one `.glassProminent` Copy with title and symbol last (the OCR panel, the annotation editor); Settings uses standard toggles, pickers, and push buttons.

### Chips (All-In-One bar)
- **Style:** borderless capsule chips, 30 pt tall, at least 84 pt wide (Cancel is a 30 pt icon-only chip after a 20 pt separator), SF Symbol plus label.
- **State:** selected = light highlight (black 0.08 / white 0.16) + accent-tinted symbol + semibold label in the label color; hover = half-strength highlight (black 0.045 / white 0.09); rest = clear.

### Cards / Containers
- **Quick Access card:** separate rounded picture, 12 pt continuous corners, 0.5 pt picture border, floating card shadow, no number or caption. Hover fades in the 0.22 scrim and the controls over 0.12 s ease-out; the saved badge hides while hovered. Click-through without activating the app, double-click to annotate, drag out to another app, two-finger swipe to close, right-click for the full menu.
- **Capture History card:** cropped (aspect-fill) thumbnail 150 pt tall, 12 pt corners, 0.5 pt separator border, in-window shadow; relative time and "W × H · App" below. Hover shows the 0.28 scrim with Restore and four glass icon buttons. Selected = 3 pt accent ring 5 pt outside. Recordings carry a bottom-left play badge with the duration.

### Reading Capsule (Signature)
The rounded capsule for every on-screen number: the selection size, the window name and size, and the loupe's coordinates with color swatch and hex. Height is text height plus 9 pt, 11 pt side padding, 0.5 pt border (the 1 pt contrast hairline under Increase Contrast), floating reading shadow. The swatch border is strong enough (black 0.3 / white 0.38) that a white sample still reads.

### Text Selection (Capture Text)
Copying text gets a lighter overlay than a screenshot: no dimming, no magnifier, no readings, no All-In-One bar, and the system crosshair instead of a drawn one. The selection (or the hovered window, after Space) is drawn like selected text: the system's text-selection color for the current appearance, filled at 0.35 (0.45 in Dark), edged with a 1 pt line in the accent (2 pt under Increase Contrast), on whole points. When the mouse is released, the same highlight takes over in place, just above pop-up menus, click-through and without taking focus, while the text is read; if reading takes over a second it breathes slowly (opacity 1 to 0.5, 0.9 s each way; not under Reduce Motion). It fades over 0.35 s once the text is on the clipboard; with nothing to read it fades in 0.15 s with the system beep. VoiceOver hears the count or "No text found". That is the whole feedback by default.

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
Translate Area's result: a borderless panel exactly over the selection, holding the captured area with the Translation Overlay drawn on it, so the screen seems to change language where it was dragged over. A 0.5 pt black 0.18 hairline (1 pt black 0.35 under Increase Contrast) and the system window shadow say it lies over the screen. It sits just below the level of menus, over the menu bar and the Dock but under its own context menu. It takes keys without bringing the app forward: Escape closes it, ⌘C copies the translation (the lens stays; the copy button shows a checkmark for 1.2 s), Return opens the area in the OCR panel, translated, and Option held shows the original. A click on it, or another window taking the keys, closes it. While the pointer is over it (also when it opens under the pointer), three card corner buttons (24 pt dark circles: Copy Translation, Open in Panel, Close) fade in outside it, in a row ending at its right edge 6 pt above it, below it when the area reaches the top of the screen, inside its corner only when it fills the screen's height; they never cover the translation. Its context menu holds Copy Translation, Show Original, Open in Panel, and Close. VoiceOver reads it as text, "Translation, English → Chinese, Simplified", with the translation as its value (its translated parts in the target language) and Copy Translation, Open in Panel, and Close as actions, and hears "Translated, … Escape closes it." when it appears, with where to read lines that were shortened. Between the drag and the lens, the Text Selection highlight holds the area. When nothing could be translated (text already in the target, code, a language still to download), the area opens in the OCR panel, translated, which says why and offers a download or another language. Option held as the drag ends opens the panel instead.

### Annotation Editor
A standard titled window named for the capture, unified toolbar, full-size content, on `.background.secondary`. The capture owns it: tools stand in a slim glass rail at its left edge and a mark's style sits in a capsule beside the mark; there is no wide tool toolbar and no fixed option strip. Reached by double-clicking a Quick Access card, Annotate… in a card's menu, Annotate… on a screenshot in Capture History, Annotate Image… in the status menu (a picture is added to Capture History first), Open in Editor in in-place annotation (the marks stay editable), or a project (.ohmyshot) opened from Finder; one editor per capture. An editor opened from a project shows the project's proxy icon in the title bar. Edits are kept in the capture itself when the window closes and whenever the capture leaves it (copied, saved, dragged out): its file then shows the marks, the marks stay editable, and the card and History thumbnail show the new picture.

- **Toolbar:** Undo and Redo at the leading edge (disabled when there is nothing to undo); then, trailing, the zoom menu (its label the current percentage, monospaced digits; Zoom to Fit ⌘0, Actual Size, Zoom In ⌘+, Zoom Out ⌘−), a 34 × 24 pt drag-out thumbnail of the capture (aspect-fill, 0.5 pt black 0.18 edge, open-hand cursor), Save, a fixed space, and one `.glassProminent` Copy with title and symbol (⌘C). Save is a split button: its face saves a copy to the export folder (tooltip "Save a Copy (⌘S)"); its menu holds Save a Copy as Project… (⇧⌘S), which keeps the capture and its marks, still editable, in one .ohmyshot file. Copy and Save swap to "Copied" / "Saved" with a checkmark for 1.5 s; VoiceOver hears "Copied" or "Saved". A failure beeps.
- **Picture:** square-cornered, the picture border (0.5 pt; the contrast hairline under Increase Contrast) and the in-window card shadow; both are hidden for a window captured with its shadow, whose corners are transparent, and on a Transparent background, where only the card's own shadow marks the edge, so no rectangle is drawn that is not in the picture. With a background, border and shadow wrap the whole output.

### Tool Rail (Signature)
The All-In-One bar turned upright: a 42 pt Liquid Glass capsule with an opaque window-colored backing inside, a 0.5 pt separator hairline, and the floating bar shadow; with Reduce Transparency a solid window-colored capsule, swapped live when the setting changes. Under Increase Contrast its edge is the 1 pt contrast hairline.

- **Chips:** 30 pt circular borderless chips, 6 pt inside the rail and 2 pt apart, each an SF Symbol at 14 pt medium in label color, no label; the tooltip names the tool and its key ("Arrow (A)").
- **Groups:** Select; Arrow, Line, Rectangle, Ellipse, Pen, Highlighter; Text, Counter; Redact, Spotlight; Crop, Background (`rectangle.center.inset.filled`, G). Groups are split by 18 pt separator hairlines with 6 pt around them.
- **State:** the tool in hand takes the selected chip fill and an accent-tinted symbol; hover takes the hover fill; rest is clear. Increase Contrast uses the contrast chip fills.

### Style Capsule (Signature)
A white capsule holding the controls for one kind of mark, beside the selected mark or at the rail's foot for the next one. It uses the capsule surface (white 0.97; Dark 0.17 gray at 0.96), a 0.5 pt hairline (black 0.08 / white 0.12; the 1 pt contrast hairline under Increase Contrast), and the floating reading shadow; 38 pt tall, 4 pt inset (8 pt at the leading edge), chips 2 pt apart, sections split by 18 pt separator hairlines with 6 pt around them. No glass.

- **Sections, in order:** colors (the eight mark inks, then Other Color…), sizes, the kind's variants, Shadow, and Delete when a mark is selected. A kind shows only what it uses: no colors for spotlight, crop, or a blur or pixelate redaction; no sizes for redaction or spotlight; Shadow only for arrows, lines, shapes, pen, text, and counters.
- **Color dots:** 24 pt chips holding a 12 pt disc with the capsule swatch edge (black 0.18 / white 0.38, 0.5 pt; 1 pt black 0.40 / white 0.60 under Increase Contrast), so white and yellow hold on the light capsule and black on the dark. The chosen color is ringed in the accent (2 pt) instead of filled. Other Color… shows a hue wheel, or the custom color ringed when one is in use, and opens the system color panel without alpha.
- **Sizes:** dots of 4, 7, 10, and 13 pt in 26 pt chips for stroke widths 2 / 4 / 6 / 10 pt (default 4, pen 3); highlighter 10 / 18 / 28 (default 18); counters 2 / 4 / 7. Text sizes are letters of 9, 12, 15, and 18 pt in 28 pt chips for 14 / 20 / 28 / 40 pt. A size set another way shows as the nearest step.
- **Variants:** 30 pt chips with drawn or SF Symbol glyphs (13 pt medium): arrow heads (classic, tapered, open, double), line (solid, dashed), rectangle and ellipse (outline, filled), text looks (plain, outlined, label), counter numbering (1, A, I), redaction (solid, blur, pixelate), spotlight (rectangle, oval). The Shadow chip draws a rounded square over its own soft shadow.
- **State:** selected chips take the selected chip fill and an accent-tinted glyph; hover the hover fill; Increase Contrast the contrast fills. VoiceOver reads chips by name with "Selected", and Shadow as On or Off.
- **Crop:** the capsule holds only Reset and Done, text chips in the capsule text face (title width plus 28 pt). Done carries the selected fill with label-colored text: the accent is never a fill behind text.
- **Combined images:** a selected image shows only Shadow and Delete.
- **Background:** the capsule rests at the rail's foot and holds the fills, then a separator, then Adjust Background (`slider.horizontal.3`) and Background Presets (`square.stack`), 30 pt symbol chips. The fills are 14 pt swatch discs in 24 pt chips with the capsule swatch edge, in order: No Background (white with a red diagonal), Transparent (a small checker), the ten gradients Sky to Paper, Blurred Capture (always in its place, so later chips never shift), Background Color… (a hue wheel, or the color ringed when one is in use), and Picture (the last picture used, the one in use as Choose Another Picture…, or a `photo.badge.plus` symbol for Choose Picture…). The fill in use is ringed in the accent (2 pt) instead of filled. The picture chooser starts in /System/Library/Desktop Pictures the first time.
- **Adjust popover:** the system popover, transient, above its chip, holding a grouped Form 320 pt wide on the opaque window color. Padding (0 to 25%, 8% by default) and Inset (0 to 12%), both measured against the side of a square of the capture's area so a background looks the same on any size; Auto Balance (evens out the room around what the capture shows); Corners (0 to 40 pt, 12 by default); Shadow (0 to 100%, 50% by default); Shape (Automatic, then 1:1, 4:3, 3:2, 16:10, 16:9, 4:5, 9:16; a shape only adds room); Position, a 3 × 3 grid of cells filled with the tint when chosen and quaternary otherwise, dimmed with its tertiary label while the shape is Automatic. Readings sit to the right of each slider in secondary ink with monospaced digits ("8%", "12 pt"), 40 pt wide; VoiceOver hears each slider by name with its reading. Inset and Auto Balance work in the capture's edge color and are disabled, with a footnote saying why, when the edge is not one color. A slider drag is one undo step.
- **Presets menu:** the saved presets (the one in use checked), Save as Preset…, Delete Preset, and Use for New Screenshots (None or a preset), which also sets Settings' Background picker.

### Canvas
- **Selection:** a 1 pt accent box (2 pt under Increase Contrast) with 9 pt white circular handles ringed in the accent and lifted by a small shadow, drawn in view points so they keep their size at any zoom. Arrows show start, end, and a bend handle at the curve's middle.
- **Crop frame:** drawn as the capture overlay draws a selection: the picture outside the frame dimmed with the room dimming (26%, 45% with Increase Contrast; only the picture, never the window), a 1.5 pt white edge over a 3.5 pt selection outline, white 0.6 thirds at 0.5 pt while dragging, and thick white corners (3 pt over a 5.5 pt outline, round caps, arms up to 18 pt).
- **Text editing:** the field matches the mark exactly (face, size, line height, color, label fill and corner) so text does not move when editing ends; no automatic substitutions; Chinese and other input methods work in place. Selected text keeps its ink: on plain and outlined text the system selection color at 0.35 (0.45 in Dark); on a label a wash opposite to the ink (white 0.35 under dark ink, black 0.22 under white ink).
- **Cursors:** crosshair for drawing tools, I-beam for Text, arrow for Select and Background, open hand over a mark (closed while moving), resize cursors on handles, crosshair on arrow ends and bends.
- **Background mode:** the picture takes no clicks while the Background tool is in hand; the capsule sets everything. Escape or Return leaves the mode. The background layer is drawn at 1 px per point, only over what is on screen. Crop hides the background and shows the plain capture.
- **Combining:** images dropped (files, Quick Access cards, image data), pasted (⌘V), or added from the empty canvas's context menu (Paste, Add Image…) become image marks. While a drag hovers, a 3 pt accent ring stands just outside the picture, as Finder rings a drop target. An image has four corner handles that keep its proportions; Shift frees them. The canvas grows to hold the images, and canvas past the capture takes the matte.

### Marks
Every mark is drawn by one renderer, on screen and in exports, so what is copied is what was seen.

- **Arrows:** one filled outline per arrow, bendable along a quadratic curve. Heads are 3 × the stroke plus 4 pt long. Classic: a filled head with a notched back; tapered: a body widening from a fine tail to the head; open: a chevron over the full body; double: classic heads at both ends.
- **Lines and shapes:** round-capped lines, dashed at 1.5 × the stroke on, 2.5 × off; rectangles with 4 pt corners by default; rectangles and ellipses outlined or filled.
- **Pen and highlighter:** smooth curves through the pointer's samples; the highlighter multiplies into the picture, so text stays dark and white turns yellow.
- **Text looks:** plain; outlined (an edge of 16% of the size, at least 2 pt, in the opposite ink); label (a rounded fill in the color, corners 32% of the size, padding 40% across and 16% down, ink black 0.88 or white).
- **Counters:** a disc (16 + 3 × the stroke pt across) in the color with the label in the opposite ink, numbered 1, 2, 3; A, B, C; or I, II, III. Each numbering counts on its own (after 1, 2 the first letter is A), and a counter is placed by a click and not selected, so a change of numbering applies to the next counters.
- **Redaction:** solid (the color, black by default), blur (strong enough that text cannot be read), or pixelate (blocks at least 12 px, larger for larger areas, each nudged by noise seeded from the mark so it redraws the same and cannot be worked back).
- **Spotlight:** everything outside the spots dimmed by the spotlight dimming; rectangle or oval spots.
- **Images:** combined images are part of the picture: they lie under the spotlight and every other mark, and blurs and pixelations show them under them. Shadow is off by default.

### Capture Overlay (Signature)
Softly dimmed screen; selection with a white 1.5 pt edge over a dark outline; a crosshair with a 4 pt center gap and 13 pt arms, white over the same outline; a 120 pt loupe showing 15 captured pixels across (8 pt per pixel, aligned to device pixels) with a faint 0.08 grid, an accent center cell, a white rim, and the lens shadow. Window mode drops the crosshair and loupe and highlights the hovered window.

A drag can carry the selection from one display onto another: each display draws its own part of it (dimmed outside, the white edge only where the selection ends), the crosshair and loupe show only on the display the pointer is over (the key panel hears every move and the controller passes it to each display; window mode highlights the hovered window on every display it reaches), and the size capsule appears once, on the display under the middle of the selection's bottom edge. The capture is put together from each display's part at the sharpest display's scale, clear where no display reaches. In-place annotation keeps its selection on the display it began on, where its interface lives.

While an area or a window is chosen, the overlay's panels sit at the screen-saver level, above full-screen apps, the menu bar, open menus, and the Dock: just above pop-up menus, macOS 26 and later handed presses in the menu bar's band to the menu bar, so a selection could neither start there nor be dragged into it. It still never hides macOS's Screen Recording confirmation: a frozen overlay appears only once a frame has arrived, and a live one is dismissed by a watchdog when none does. In-place annotation goes back to just above pop-up menus, under input methods' candidate windows.

The screen is frozen by default: it is captured the moment the shortcut is pressed, before the overlay covers it or takes the keyboard, so hover cards, tooltips, and open menus are still in it, and the overlay appears already holding it (about 45 ms later). What is kept is cut from that frozen screen. With Freeze off (Settings › General) the overlay appears at once over the live screen and the area is captured when the drag ends. A window is always captured on its own, with its shadow and transparent corners.

### All-In-One Bar (Signature)
A Liquid Glass capsule with an opaque window-colored backing inside, a 0.5 pt separator hairline, and the floating bar shadow. With Reduce Transparency it is a solid window-colored capsule with the same hairline.

### In-Place Annotation (Annotate Area)
Marking up a selection where it lies, without opening a window. Annotate Area (⇧⌘6) opens the capture overlay as for a screenshot: frozen screen, All-In-One bar, crosshair and loupe. Once an area or a window is chosen, the overlay's own selection layers, readings, crosshair, loupe, and bar step aside, the other displays' panels go away, and the editor's canvas takes over at the screen's own size over the frozen screen: no zoom, no window chrome, no combining, and no crop or background.

- **Selection chrome:** vector layers, drawn as the canvas's crop frame is: the screen around the selection dimmed with the room dimming (26%, 45% under Increase Contrast), a 1.5 pt white edge over a 3.5 pt selection outline, thick white corners (3 pt over a 5.5 pt outline, round caps, arms up to 18 pt, never more than a third of a side), and white 0.6 thirds at 0.5 pt while the selection is adjusted. Where the selection meets the display's edge, the frame steps in by 4.5 pt, so its edge and corners stay on screen to be seen and grabbed. The size reading is a reading capsule ("1616 × 1216", pixels).
- **Toolbar:** the rail laid flat, in the All-In-One manner: a 42 pt Liquid Glass capsule with an opaque window-colored backing, a 0.5 pt separator hairline (the 1 pt contrast hairline under Increase Contrast), and the floating bar shadow; solid under Reduce Transparency, swapped live. 30 pt circular chips 6 pt inside and 2 pt apart, each a 14 pt medium symbol in label ink, no labels; tooltips name the tool and its key. Groups split by 18 pt separators with 6 pt around them: Arrow, Line, Rectangle, Ellipse, Pen, Highlighter | Text, Counter | Redact, Spotlight | Undo, Redo (tertiary ink when disabled) | Open in Editor (`arrow.up.forward.square`), Save (`square.and.arrow.down`), Cancel (`xmark`), Copy (`checkmark` in the accent). There is no Select chip: with no tool in hand the selection itself is adjusted. The tool in hand takes the selected chip fill and an accent symbol; clicking it again puts it down. Hover takes the hover fill; Increase Contrast the contrast fills.
- **Style capsule:** the editor's, unchanged, under the toolbar for the tool in hand or the selected mark.
- **Adjusting:** with no tool in hand, a drag inside moves the selection and its corners and edges resize it (corners reach 12 pt and edges 6 pt, shrinking to a quarter and a sixth of the frame on small selections, never under 4 and 3 pt); a drag outside chooses a new area while nothing is drawn. With a tool in hand, only presses on the frame line or outside it resize, so marks run to the edge. The toolbar hides while the selection is adjusted.
- **Keys:** the editor's tool keys, Delete, arrows, and Undo work as in the editor. Return, Enter, or a double-click copies. Escape cancels an adjustment, then puts the tool down, then cancels.
- **Outcomes:** Copy puts the marked selection on the clipboard, into Capture History (the plain selection kept beside the marks, still editable), and in a Quick Access card. Save does the same and also saves to the export folder. Open in Editor keeps it in the history and opens the editor with the marks editable, without the clipboard or a card. The picture reaches the clipboard before anything is written; a failure beeps and is announced.
- **VoiceOver:** the area announces "Mark up the selection. Press Return to copy it, or Escape to cancel." when it starts; its value is "W × H pixels", posted again after each adjustment; the toolbar reads as "Mark Up".

### Self-Timer Countdown
Self-Timer opens the capture overlay as for a screenshot (frozen by default, All-In-One bar, crosshair and loupe); once an area or a window is chosen the overlay leaves, and the countdown shows where the capture will be while the screen is set up: a menu opened, a card hovered. It takes neither the keyboard nor the pointer, which would close the very menu being set up.

- **Outline:** the chosen area (a window's frame for a window) drawn as the capture overlay draws a selection: a white 1.5 pt edge over the 3.5 pt dark outline (0.32; 0.7 under Increase Contrast). Nothing is dimmed: the screen is in use. One outline panel per display the area reaches.
- **Disc:** 64 pt, Liquid Glass over an opaque window-colored backing, as the All-In-One bar is; a solid window-colored disc under Reduce Transparency. The seconds left in the reading face at 26 pt, label ink, centered. A 2.5 pt ring in the accent, inset 6 pt, round caps, starting at twelve o'clock, runs out over the whole countdown over a faint track of label ink at 0.12 (0.3 under Increase Contrast). Rim: the 0.5 pt separator hairline, or the 1 pt contrast hairline under Increase Contrast. The floating bar shadow, with 24 pt of room around the disc in its panel. The first second is on the disc before it shows, so it never appears blank; seconds are counted to absolute deadlines and never drift.
- **Placement:** centered 12 pt below the area; above it when there is no room below; inside its bottom edge only when neither fits, since inside covers what is being set up. Always on a display, 8 pt from its edges.
- **Panels:** borderless and clear, just above pop-up menus so an opened menu cannot cover them, on every Space, never key, never activating the app, and letting every click through. Like every window of the app, they are left out of the capture.
- **Ending:** at zero the countdown leaves the screen and the capture is taken live, the screen as it is then, whatever was frozen while choosing; it is named after the app in front at that moment. An area is cut from the screen; a window is captured on its own. If another capture is being chosen at zero, nothing is captured.
- **Cancelling:** the Self-Timer shortcut again, or the status menu entry, which reads "Cancel Self-Timer" while the countdown runs. Starting another capture cancels it too. Nothing is captured.
- **Delay:** 2, 3, 5, 10, or 15 seconds, 5 by default (Settings › General › Self-Timer delay). Self-Timer has no shortcut by default.
- **VoiceOver:** the disc is not an element. Starting announces "Capturing in N seconds. Press [the shortcut's keys] again to cancel.", or "Capturing in N seconds. Choose Cancel Self-Timer in the menu bar to cancel." when it has no shortcut; cancelling announces "Self-Timer cancelled."

### Navigation
- **Capture History toolbar:** a SwiftUI toolbar bridged into a unified window toolbar: segmented Show filter (All, Screenshots, Recordings), a "Keep for …" menu, and Move All to Trash. Empty states are filter-aware (a 40 pt light tertiary symbol, title3 title, callout message).
- **Keyboard:** arrows select, Return restores, Space opens Quick Look; ⌘C, ⌘S, and ⌘⌫ arrive as commands through an invisible main menu and are disabled with nothing selected.
- **Settings:** preference toolbar tabs; grouped sections such as "After capturing", "Capture History", and "Translation" (Translate into: Automatic, the first of the preferred languages the text isn't already in, then the system's languages). General › After capturing ends with a Background picker (None, then the saved presets) that puts each new screenshot on a preset; it is disabled, with a line saying to save a preset in the editor first, while there are none.
- **Status menu:** grouped capture commands (Capture Area, Annotate Area, Window, Fullscreen, Self-Timer, Capture Text, Translate Area; Self-Timer reads "Cancel Self-Timer" while a countdown runs, its title asked again each time the menu opens), then Recognize Text in Clipboard Image (enabled when the clipboard offers an image or a file) and Recognize Text in Image…, then Annotate Image… (a picture or a project; several at once), Capture History, and Restore Recently Closed. An image dropped on the menu bar icon opens in the OCR panel; the icon highlights while it is over it.
- **Find:** the Edit menu carries Find…, Find Next, Find Previous, and Use Selection for Find for the OCR panel's text.
- **Destructive confirmations** state the count and consequence and name the action ("Delete 3 Captures"; "This can't be undone.").

### Motion
- Cards slide in 36 pt from the screen edge with a fade over 0.22 s ease-out; the stack reflows over 0.22 s ease-out; a dismissed card slides 40 pt left and fades. Hover fades take 0.12 s ease-out. History scrolls to a new selection over 0.15 s ease-out.
- The text selection highlight fades out over 0.35 s once the text is copied (0.15 s when there was none).
- The optional text result card fades in over 0.22 s with a 6 pt rise of its layer (never of its window, whose size can change mid-animation), and fades out over 0.12 s.
- In the OCR panel, Copy buttons swap their symbol for a checkmark with the system's symbol replace transition and back after 1.5 s (toolbar) or 1.2 s (rows).
- The translation lens fades in over 0.18 s ease-out and out over 0.15 s ease-in; its buttons fade over 0.12 s.
- In the annotation editor, the style capsule fades in over 0.12 s ease-out when a new selection or tool calls for it and simply moves when the picture zooms or scrolls; it hides while a mark is drawn, moved, or reshaped. In in-place annotation the capsule fades in the same way (0.12 s ease-out) for a new tool or selection and hides while a mark is drawn or the selection is adjusted; the toolbar and selection chrome appear and move without animation. Canvas layers never animate on their own, so marks, handles, and the crop frame stay under the pointer.
- The Self-Timer countdown's outline and disc fade in together over 0.12 s ease-out; its ring runs out linearly over the whole delay while the digit steps down each second; at zero it is gone at once, with no fade out.
- Under Reduce Motion all of these are instant; the Self-Timer countdown appears without a fade and its ring steps down each second instead of running out. Nothing trails the pointer: overlay layers update without animation. The two durations live in `Theme.Motion` (`slide` 0.22 s, `fade` 0.12 s).

### Future Surfaces
Recording controls and pins are not built. They must use this system (system colors and accent, 12 pt cards and capsules, soft lift shadows, rounded readings, small glass only, the three accessibility responses); their specs are recorded when they ship, not before.

## Do's and Don'ts

### Do:
- **Do** use system semantic colors and `controlAccentColor` for every surface and state; add only black or white at the stated opacities.
- **Do** make every floating control a full capsule (radius = height / 2) with concentric inner chips, and every picture a 12 pt continuous-corner card; the one exception is a picture being edited for export, which shows its own square edges.
- **Do** give floating elements a soft downward shadow plus a 0.5 pt hairline so they hold on white pages.
- **Do** put live numbers in a reading capsule: SF Pro Rounded 12 pt semibold with monospaced digits.
- **Do** keep text-bearing controls opaque over captures; use glass for the rim, not the fill.
- **Do** answer accessibility settings specifically: Reduce Motion = instant; Reduce Transparency = solid window-colored capsule; Increase Contrast = 45% dimming, 0.7 outline, 1 pt contrast hairlines and button outlines, doubled chip fills.
- **Do** use standard windows, toolbars, grouped Forms, and SwiftUI glass button styles inside windows.
- **Do** build chips in floating controls (the All-In-One bar, the in-place toolbar, the tool rail, the style capsule) as borderless buttons with the chip fills, and hand-draw whole controls only where AppKit would render them dimmed (non-key floating panels), tracking presses like standard buttons.

### Don't:
- **Don't** bring back Contact Sheet: no frame numbers, no captures joined into a strip, no film-edge or darkroom motifs.
- **Don't** build dark heavy panels, bars, or strips; small dark round corner buttons over a hovered picture are the only dark chrome.
- **Don't** put glass, blur, or a material over the full-screen overlay; the room is a flat 26% fill.
- **Don't** use hard offset shadows, glows, or halos.
- **Don't** use the rounded face inside standard windows, or proportional digits in a changing number.
- **Don't** invent a brand hue or tint chrome toward one; fixed hues belong to mark inks only.
- **Don't** animate anything that follows the pointer, or run any motion under Reduce Motion.
- **Don't** give the editor a wide tool toolbar or a fixed option strip; tools live in the rail and a mark's style beside the mark.
