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
