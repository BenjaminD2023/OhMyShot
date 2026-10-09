---
version: 1
slug: "packages-ohmyshotkit-sources-omscapture"
primary_target: "Packages/OhMyShotKit/Sources/OMSCapture"
related_targets: ["Packages/OhMyShotKit/Sources/OMSUI","App"]
---

# Capture overlay, Quick Access, and Capture History

Scope: the capture overlay (selection, crosshair, loupe, readings, window highlight, All-In-One bar), the Quick Access cards a capture lands in, the Capture History window, and the General settings that govern them. Mode: Operate. The world chosen here governs every OhMyShot surface.

Audience and task: a developer-designer capturing dozens of times a day across a 2× ultrawide and a scaled XDR panel; frame exactly, capture instantly, send the capture where it belongs, find it again later.

Constraints: macOS HIG; glass only on small HUDs, never over a full-screen frame; hotkey to visible overlay under 50 ms at p95; nothing saved to disk until the user asks.

## Direction contract

THESIS: Feel like the part of macOS Apple forgot to ship: bright, soft, and quiet, with the capture as the hero and the chrome receding; refuse dark heavy chrome, frame counters, joined strips, and anything that reads as a Linux utility.

OWN-WORLD: System semantic colors and the user's accent; white (Light) or window-colored (Dark) capsules with soft shadows; continuous corners (cards 12 pt, panels 18 pt, capsules fully round); SF Pro Rounded with monospaced digits for readings; Liquid Glass tinted toward the window color only on small HUDs; the full-screen overlay dims 26% (45% with Increase Contrast) and carries no glass.

STORY: Frame exactly, capture instantly, find the capture already copied and waiting as a card one action from its destination, and find it again in Capture History.

FIRST VIEWPORT: Softly dimmed screen; selection with a white edge and a hairline dark outline; W×H in a rounded capsule below it; a small crosshair and a 120 pt loupe with a white rim and an info capsule (pixel coordinates, swatch, hex); a glass All-In-One capsule at the bottom; on release the capture is copied and a rounded card slides into the bottom-left corner.

FORM: Native, CleanShot-class (user direction of 2026-10-07, replacing Contact Sheet seed 32572271). Cards are separate rounded thumbnails with no numbers; hovering dims the picture and shows opaque white Copy and Save capsules with dark round Close and More buttons in the corners; cards slide in over 0.22 s with an ease-out, and simply appear with Reduce Motion. Capture History is a standard window with a Liquid Glass toolbar and a grid of rounded, cropped thumbnails.

FINISH: unreviewed and undocumented is unfinished; this build ends with the finish review against this contract and DESIGN.md derived from the shipped code.

## Open decisions

- The card's editor action arrives with the annotation editor (M3).
- The capture sound is the system Screen Capture sound for now.
- Selections may cross displays (2026-10-09, the user's request; the roadmap had kept v1 to one
  display): one selection drawn in parts, the size capsule on one display, the capture stitched at the
  sharpest display's scale with no fill where no display reaches. In-place annotation stays on one.
- Pins (2026-10-09): image pins in OMSUI beside Quick Access and the Translation Lens (the roadmap's
  module map had OMSAnnotate; OMSUI holds the card buttons and floating-panel patterns pins reuse).
  Floating level with Quick Access a level above, on every Space and over full-screen apps, the system
  window shadow and hairline of the Translation Lens, 12 pt corners by default. Capture Area and Pin
  lands the pin over the captured area at 1:1 (the Snipaste convention), keeps the capture in the
  history, and shows no card and leaves the clipboard alone. Pins appear in new captures by default.
  The release build has no default shortcut for Capture Area and Pin (⇧⌘7 types a slash on German
  layouts).
- Text and color pins (2026-10-09): Pin from Clipboard takes a picture first, then a color (a copied
  color, or text that is exactly a color's value), then text; a copied file that is not a picture beeps
  rather than pinning its name. Text sits on a card in the Text Result Card's materials, monospaced
  for code, cut at 30 lines, laid out once at 100 percent and drawn scaled, so it wraps the same at
  every zoom. A color is a 128 pt swatch in its own color space, on the checkerboard when translucent,
  with its hex resting in the reading capsule while it fits. Saving, Annotate, and Recognize Text stay
  with pictures.
- Live Text on picture pins (2026-10-09): direct selection as in Preview, the user's call over a selection mode with
  its own button. Over text the cursor is an I-beam and a drag selects; a drag elsewhere, within 6 pt of the edge,
  or with ⌘ held moves the pin. They accepted that the first drag on a tightly cropped text capture selects rather
  than moves it. VisionKit reads a pin once, the first time the pointer comes to it, never in the background.
- Self-Timer (2026-10-09): choose first, then count down, then capture live at zero (the ⌘⇧5 timer and
  camera convention), so a menu that closes on any key can be opened during the countdown. The
  countdown takes neither the keyboard nor the pointer; it is cancelled by its shortcut again or from
  the menu bar, never by Escape (a bare global Escape would steal it from the user's app). No default
  shortcut; delays 2/3/5/10/15 s, default 5.
- While an area is chosen the overlay sits at the screen-saver level (2026-10-09): just above pop-up
  menus, presses in the menu bar's band went to the menu bar on macOS 26+.
- Freeze the screen is on by default (2026-10-09, the user's call; the roadmap had live selection as
  the default). The screen is taken on the shortcut, before the app takes the keyboard or the pointer
  (the overlay shows at once but lets the pointer through until then), and the kept area is cut from
  it, so a hover card that closes as the pointer leaves is still captured.
- In-place annotation (Annotate Area, built 2026-10-09): after the area is chosen the overlay stays on
  the frozen screen; the selection keeps its frame (the crop frame's corners) and resizes from its edges;
  a horizontal glass toolbar in the All-In-One manner stands 10 pt below the selection against its right
  edge (above it, or inside it, without room), the editor's style capsule under it. The convention of
  Chinese screenshot tools, which the product's users prefer.
