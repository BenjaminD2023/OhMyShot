# Capture magnifier

Settings → Capture → Magnifier chooses what screenshots (All-In-One and the Self-Timer's choosing too) and Annotate Area show at the pointer before an area is chosen:

- **Magnified** (the default): the 120 pt loupe below and right of the pointer, 15 captured pixels across at 8 pt each, with a faint grid, the accent center cell, and the crosshair at the pointer. It follows the pointer through the drag, so an edge can be put on the exact pixel.
- **Centered**: a lens centered on the pointer, Small (75 pt, the default), Medium (90 pt), or Large (120 pt), showing a pixel grid at the chosen magnification. Its square center marks one physical screen pixel. The picture in it is 75% opaque over a clear backing, so the area under the pointer shows undimmed; Reduce Transparency makes it opaque. Its center cell is the target, in place of the crosshair, stroked white or black against the pixel under it over an outline of the other; the color reading under it is what C copies. Near a display's edge the lens runs off the edge rather than move off its target, and the reading stays on screen.

With Centered selected, **Color picker size** and **Color picker magnification** are separate controls. Choose 1×, 2×, 4× (default), or 8×; changing zoom keeps the chosen diameter. The zoom is approximate so the grid always has an odd number of cells and an exact center pixel. Grid and target strokes narrow at low zoom to leave the pixel visible. Changes apply to the next capture.

With Centered, the first press puts the lens and its reading away on every display, and the crosshair marks the pointer through the drag. A click with no drag leaves no selection, so the lens comes back: the overlay hides the system pointer, and without it nothing would show where the pointer is.

Pick Color, Capture Text, recording, and scrolling keep the magnified loupe whatever the setting. Sampled and copied colors are the captured pixels, unchanged.

Unit coverage (`OverlayLoupeTests`) includes 1×/2× geometry, display edges, the first press across displays, a click with no drag, late frames, reused sessions, sizes and magnifications, saturated colors, appearance changes, and the default magnified loupe.
