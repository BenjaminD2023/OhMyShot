---
version: 1
slug: "app-appicon-icon"
primary_target: "App/AppIcon.icon"
related_targets: ["Packages/OhMyShotKit/Sources/OMSUI/StatusItem"]
---

# App icon, menu bar glyph, and wordmark

Scope: the brand mark in three forms (macOS app icon as an Icon Composer `.icon`, the 18 pt menu bar template image that replaces `camera.viewfinder`, the README wordmark). Mode: Persuade at Dock scale, Operate in the menu bar.

Decision: chosen 2026-10-10 on the Design canvas (https://claude.ai/artifact/8jgebCfhrwMygNCaP3iFHY) over Pin (a lifted piece of screen) and Highlight (a highlighted text line). Unchosen candidates: Oh! face, Text Lift, Reading Capsule, Room Dim; canon (viewfinder brackets) not shown.

## Direction contract

THESIS: The mark is the app's own capture loupe, a white ring over magnified pixels with the center cell outlined; it refuses viewfinder brackets, camera bodies, and scissors.

OWN-WORLD: Ocean Background Fill ground (#5E9CF5 to #37CDBE); white glass ring; 5×5 rounded pixels stepping white, #9CC3F8, #3D7FEA across one diagonal edge on a #DCEBFC lens; center cell in white over a navy outline. Menu bar: ring plus a pixel staircase. Wordmark: heavy rounded face, ring as the O.

STORY: In the Dock, Finder, and menu bar the user recognizes the loupe they see while capturing and reads it as pixel-precise capture.

FIRST VIEWPORT: Ring centered, outer radius 0.38 of the icon, lens filling it, nothing else on the ground.

FORM: Loupe, 1st of 7 grounded candidates, seed cf04a833.

FINISH: unreviewed and undocumented is unfinished; this build ends with the finish review, the verdict, DESIGN.md, and every shipping raster carrying its provenance
