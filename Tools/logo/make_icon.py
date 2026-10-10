#!/usr/bin/env python3
"""Draws the OhMyShot mark (the capture loupe) and writes every shipped form of it.

Outputs, all regenerated from the geometry below:
  App/AppIcon.icon/                      Icon Composer bundle: icon.json + one SVG per layer
  App/Assets.xcassets/MenuBarIcon.imageset  18 pt template image for the status item
  Tools/logo/preview/                    flattened light/dark icons and the wordmark O, for docs and review

Run from anywhere: python3 Tools/logo/make_icon.py
The geometry is drawn on the 1024 pt icon grid with the icon body at 100...924 (824 pt);
layer SVGs use that body as their viewBox, so Icon Composer's full-bleed canvas equals the body.
"""
import json
import math
import os

ROOT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))
ICON = os.path.join(ROOT, "App", "AppIcon.icon")
ASSETS = os.path.join(ROOT, "App", "Assets.xcassets")
PREVIEW = os.path.join(ROOT, "Tools", "logo", "preview")

C = 512          # center of the 1024 grid
BODY = 412       # half the icon body
RING_OUT, RING_IN = 316, 252
PITCH, CELL, CELL_R = 96, 84, 18

# Colors (sRGB). The ground is the app's Ocean background fill.
GROUND = ("#5E9CF5", "#37CDBE")
GROUND_DARK = ("#2D3140", "#15161C")
WHITE, MID, BLUE, LENS, SHADE = "#FFFFFF", "#9CC3F8", "#3D7FEA", "#DCEBFC", "#0B2A5B"
DARK = {"white": "#F5F5F7", "mid": "#8AAEF0", "blue": "#3A6FD0", "lens": "#20232C", "ring": "#F5F5F7", "shade": "#000000"}
SHADE_OPACITY = 0.6       # the navy outline under the center cell's white frame
EDGE_OPACITY = 0.28       # the navy band inside the ring, so the ring holds against white pixels


# ---------------------------------------------------------------- geometry
def rounded_rect_path(x, y, w, h, r):
    return (f"M{x + r:.2f},{y:.2f} H{x + w - r:.2f} A{r},{r} 0 0 1 {x + w:.2f},{y + r:.2f} "
            f"V{y + h - r:.2f} A{r},{r} 0 0 1 {x + w - r:.2f},{y + h:.2f} H{x + r:.2f} "
            f"A{r},{r} 0 0 1 {x:.2f},{y + h - r:.2f} V{y + r:.2f} A{r},{r} 0 0 1 {x + r:.2f},{y:.2f} Z")


def rounded_rect_poly(x, y, w, h, r, seg=12):
    pts = []
    corners = [(x + w - r, y + r, -90), (x + w - r, y + h - r, 0), (x + r, y + h - r, 90), (x + r, y + r, 180)]
    for cx, cy, start in corners:
        for k in range(seg + 1):
            a = math.radians(start + 90 * k / seg)
            pts.append((cx + r * math.cos(a), cy + r * math.sin(a)))
    return pts


def circle_poly(cx, cy, r, n=360):
    return [(cx + r * math.cos(2 * math.pi * k / n), cy + r * math.sin(2 * math.pi * k / n)) for k in range(n)]


def clip_convex(subject, clipper):
    """Sutherland-Hodgman: subject clipped by a convex, clockwise (screen) clipper."""
    def inside(p, a, b):
        return (b[0] - a[0]) * (p[1] - a[1]) - (b[1] - a[1]) * (p[0] - a[0]) >= 0

    def cross(p1, p2, a, b):
        x1, y1 = p1; x2, y2 = p2; x3, y3 = a; x4, y4 = b
        d = (x1 - x2) * (y3 - y4) - (y1 - y2) * (x3 - x4)
        t = ((x1 - x3) * (y3 - y4) - (y1 - y3) * (x3 - x4)) / d
        return (x1 + t * (x2 - x1), y1 + t * (y2 - y1))

    out = subject
    for i in range(len(clipper)):
        a, b = clipper[i], clipper[(i + 1) % len(clipper)]
        inp, out = out, []
        if not inp:
            break
        s = inp[-1]
        for e in inp:
            if inside(e, a, b):
                if not inside(s, a, b):
                    out.append(cross(s, e, a, b))
                out.append(e)
            elif inside(s, a, b):
                out.append(cross(s, e, a, b))
            s = e
    return out


def poly_path(pts):
    return "M" + " L".join(f"{x:.2f},{y:.2f}" for x, y in pts) + " Z"


def annulus(r_out, r_in):
    return (f"M{C},{C - r_out} A{r_out},{r_out} 0 1 1 {C},{C + r_out} A{r_out},{r_out} 0 1 1 {C},{C - r_out} Z "
            f"M{C},{C - r_in} A{r_in},{r_in} 0 1 0 {C},{C + r_in} A{r_in},{r_in} 0 1 0 {C},{C - r_in} Z")


def frame(size, width, radius):
    """A rounded-square outline around the center cell, as a filled even-odd path."""
    o, i = size / 2 + width / 2, size / 2 - width / 2
    return (rounded_rect_path(C - o, C - o, 2 * o, 2 * o, radius + width / 2) + " "
            + rounded_rect_path(C - i, C - i, 2 * i, 2 * i, max(radius - width / 2, 2)))


def cells():
    """The 5x5 lens pixels, clipped to the lens, grouped by tone across one diagonal edge."""
    lens = circle_poly(C, C, RING_IN)
    groups = {"white": [], "mid": [], "blue": []}
    for j in range(5):
        for i in range(5):
            v = i + j
            tone = "white" if v <= 3 else ("mid" if v == 4 else "blue")
            x = C + (i - 2) * PITCH - CELL / 2
            y = C + (j - 2) * PITCH - CELL / 2
            corners = [(x, y), (x + CELL, y), (x, y + CELL), (x + CELL, y + CELL)]
            if all(math.hypot(px - C, py - C) <= RING_IN for px, py in corners):
                groups[tone].append(rounded_rect_path(x, y, CELL, CELL, CELL_R))
            else:
                clipped = clip_convex(rounded_rect_poly(x, y, CELL, CELL, CELL_R), lens)
                if len(clipped) > 2:
                    groups[tone].append(poly_path(clipped))
    return {k: " ".join(v) for k, v in groups.items()}


CELLS = cells()
CENTER_FRAME = frame(CELL + 8, 10, 22)
CENTER_SHADE = frame(CELL + 8, 32, 22)
RING = annulus(RING_OUT, RING_IN)
LENS_EDGE = annulus(RING_IN, RING_IN - 20)
LENS_DISC = f"M{C},{C - RING_IN} A{RING_IN},{RING_IN} 0 1 1 {C},{C + RING_IN} A{RING_IN},{RING_IN} 0 1 1 {C},{C - RING_IN} Z"


# ---------------------------------------------------------------- Icon Composer bundle
def layer_svg(path, color, opacity=1.0):
    vb = f"{C - BODY} {C - BODY} {2 * BODY} {2 * BODY}"
    op = f' fill-opacity="{opacity}"' if opacity < 1 else ""
    return (f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="{vb}" width="1024" height="1024">'
            f'<path fill-rule="evenodd" fill="{color}"{op} d="{path}"/></svg>\n')


def srgb(hexcolor, alpha=1.0):
    h = hexcolor.lstrip("#")
    r, g, b = (int(h[k:k + 2], 16) / 255 for k in (0, 2, 4))
    return f"srgb:{r:.5f},{g:.5f},{b:.5f},{alpha:.5f}"


def fills(light, dark, tinted):
    return [{"value": {"solid": light}}, {"appearance": "dark", "value": {"solid": dark}},
            {"appearance": "tinted", "value": {"solid": tinted}}]


def gradient(a, b):
    return {"linear-gradient": [srgb(a), srgb(b)],
            "orientation": {"start": {"x": 0.15, "y": 0.0}, "stop": {"x": 0.85, "y": 1.0}}}


def write_icon():
    os.makedirs(os.path.join(ICON, "Assets"), exist_ok=True)
    layers = {
        "center.svg": (CENTER_FRAME, WHITE, 1.0),
        "center-shade.svg": (CENTER_SHADE, SHADE, SHADE_OPACITY),
        "ring.svg": (RING, WHITE, 1.0),
        "lens-edge.svg": (LENS_EDGE, SHADE, EDGE_OPACITY),
        "pixels-white.svg": (CELLS["white"], WHITE, 1.0),
        "pixels-mid.svg": (CELLS["mid"], MID, 1.0),
        "pixels-blue.svg": (CELLS["blue"], BLUE, 1.0),
        "lens.svg": (LENS_DISC, LENS, 1.0),
    }
    for name, (path, color, op) in layers.items():
        with open(os.path.join(ICON, "Assets", name), "w") as f:
            f.write(layer_svg(path, color, op))

    def layer(name, light, dark, tinted, glass=False):
        return {"image-name": f"{name}.svg", "name": name, "glass": glass,
                "fill-specializations": fills(light, dark, tinted)}

    spec = {
        "fill-specializations": [
            {"value": gradient(*GROUND)},
            {"appearance": "dark", "value": gradient(*GROUND_DARK)},
        ],
        "groups": [
            {
                "name": "Loupe",
                "layers": [
                    layer("center", srgb(WHITE), srgb(DARK["ring"]), "gray:1.000,1.000"),
                    layer("center-shade", srgb(SHADE, SHADE_OPACITY), srgb(DARK["shade"], SHADE_OPACITY), "gray:0.000,0.500"),
                    layer("ring", srgb(WHITE), srgb(DARK["ring"]), "gray:1.000,1.000", glass=True),
                    layer("lens-edge", srgb(SHADE, EDGE_OPACITY), srgb(DARK["shade"], 0.45), "gray:0.000,0.400"),
                ],
                "shadow-specializations": [{"value": {"kind": "neutral", "opacity": 0.5}},
                                           {"appearance": "dark", "value": {"kind": "neutral", "opacity": 0.6}}],
                "translucency-specializations": [{"value": {"enabled": False, "value": 0.5}}],
                "specular": True,
                "position": {"scale": 1.0, "translation-in-points": [0, 0]},
            },
            {
                "name": "Pixels",
                "layers": [
                    layer("pixels-white", srgb(WHITE), srgb(DARK["white"]), "gray:1.000,1.000"),
                    layer("pixels-mid", srgb(MID), srgb(DARK["mid"]), "gray:1.000,0.550"),
                    layer("pixels-blue", srgb(BLUE), srgb(DARK["blue"]), "gray:1.000,0.220"),
                    layer("lens", srgb(LENS), srgb(DARK["lens"]), "gray:0.000,0.250", glass=True),
                ],
                "shadow-specializations": [{"value": {"kind": "neutral", "opacity": 0.2}}],
                "translucency-specializations": [{"value": {"enabled": True, "value": 0.2}}],
                "specular": True,
                "position": {"scale": 1.0, "translation-in-points": [0, 0]},
            },
        ],
        "supported-platforms": {"squares": "shared"},
    }
    with open(os.path.join(ICON, "icon.json"), "w") as f:
        json.dump(spec, f, indent=1)
        f.write("\n")


# ---------------------------------------------------------------- menu bar template image
def menubar_svg(scale=1):
    """18 pt template: the ring over a 3x3 pixel grid whose tones step across the loupe's diagonal edge.
    Black + alpha only; the alpha steps stand in for the icon's white, mid, and blue pixels. They are
    `opacity`, not `fill-opacity`: Apple's SVG renderer (NSImage and the asset catalog alike) ignores
    fill-opacity on a shape whose fill is inherited from its group, and drew every cell solid."""
    cx = cy = 9
    parts = [f'<path fill-rule="evenodd" d="M{cx},{cy - 7.5} A7.5,7.5 0 1 1 {cx},{cy + 7.5} A7.5,7.5 0 1 1 {cx},{cy - 7.5} Z '
             f'M{cx},{cy - 6} A6,6 0 1 0 {cx},{cy + 6} A6,6 0 1 0 {cx},{cy - 6} Z"/>']
    pitch, size = 2.75, 2.0
    for j in range(3):
        for i in range(3):
            v = i + j
            op = "" if v > 2 else f' opacity="{0.65 if v == 2 else 0.35}"'
            x = cx + (i - 1) * pitch - size / 2
            y = cy + (j - 1) * pitch - size / 2
            parts.append(f'<rect x="{x:.3f}" y="{y:.3f}" width="{size}" height="{size}" rx="0.5"{op}/>')
    return (f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 18 18" width="{18 * scale}" height="{18 * scale}">'
            f'<g fill="#000000">{"".join(parts)}</g></svg>\n')


def write_menubar():
    os.makedirs(os.path.join(ASSETS, "MenuBarIcon.imageset"), exist_ok=True)
    with open(os.path.join(ASSETS, "Contents.json"), "w") as f:
        json.dump({"info": {"author": "xcode", "version": 1}}, f, indent=2)
        f.write("\n")
    with open(os.path.join(ASSETS, "MenuBarIcon.imageset", "MenuBarIcon.svg"), "w") as f:
        f.write(menubar_svg())
    with open(os.path.join(ASSETS, "MenuBarIcon.imageset", "Contents.json"), "w") as f:
        json.dump({"images": [{"filename": "MenuBarIcon.svg", "idiom": "universal"}],
                   "info": {"author": "xcode", "version": 1},
                   "properties": {"preserves-vector-representation": True,
                                  "template-rendering-intent": "template"}}, f, indent=2)
        f.write("\n")


# ---------------------------------------------------------------- previews
def squircle(n=5.0, steps=360):
    pts = []
    for k in range(steps):
        t = 2 * math.pi * k / steps
        c, s = math.cos(t), math.sin(t)
        pts.append((C + BODY * math.copysign(abs(c) ** (2 / n), c), C + BODY * math.copysign(abs(s) ** (2 / n), s)))
    return poly_path(pts)


def preview_svg(dark=False):
    g = GROUND_DARK if dark else GROUND
    col = DARK if dark else {"white": WHITE, "mid": MID, "blue": BLUE, "lens": LENS, "ring": WHITE, "shade": SHADE}
    return ('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024" width="1024" height="1024"><defs>'
            f'<clipPath id="sq"><path d="{squircle()}"/></clipPath>'
            f'<linearGradient id="g" x1="0.15" y1="0" x2="0.85" y2="1"><stop offset="0" stop-color="{g[0]}"/><stop offset="1" stop-color="{g[1]}"/></linearGradient>'
            '<filter id="s" x="-30%" y="-30%" width="160%" height="170%"><feGaussianBlur in="SourceAlpha" stdDeviation="18"/>'
            f'<feOffset dy="14" result="b"/><feFlood flood-color="{"#000000" if dark else SHADE}" flood-opacity="{0.5 if dark else 0.32}"/>'
            '<feComposite in2="b" operator="in"/><feMerge><feMergeNode/><feMergeNode in="SourceGraphic"/></feMerge></filter>'
            '</defs><g clip-path="url(#sq)"><rect width="1024" height="1024" fill="url(#g)"/><g filter="url(#s)">'
            f'<path d="{LENS_DISC}" fill="{col["lens"]}"/>'
            f'<path d="{CELLS["white"]}" fill="{col["white"]}"/><path d="{CELLS["mid"]}" fill="{col["mid"]}"/>'
            f'<path d="{CELLS["blue"]}" fill="{col["blue"]}"/>'
            f'<path fill-rule="evenodd" d="{LENS_EDGE}" fill="{col["shade"]}" fill-opacity="{0.45 if dark else EDGE_OPACITY}"/>'
            f'<path fill-rule="evenodd" d="{CENTER_SHADE}" fill="{col["shade"]}" fill-opacity="{SHADE_OPACITY}"/>'
            f'<path fill-rule="evenodd" d="{CENTER_FRAME}" fill="{col["ring"]}"/>'
            f'<path fill-rule="evenodd" d="{RING}" fill="{col["ring"]}"/>'
            '</g></g></svg>\n')


def wordmark_o_svg():
    """The ring as the wordmark's O: stroke = 20% of the height, matched to a heavy rounded face."""
    parts = []
    for j in range(3):
        for i in range(3):
            v = i + j
            col = BLUE if v >= 3 else (MID if v == 2 else WHITE)
            parts.append(f'<rect x="{50 + (i - 1) * 17 - 7.5}" y="{50 + (j - 1) * 17 - 7.5}" width="15" height="15" rx="3.5" fill="{col}"/>')
    return ('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100" width="400" height="400">'
            '<defs><clipPath id="c"><circle cx="50" cy="50" r="30"/></clipPath></defs>'
            f'<g clip-path="url(#c)"><rect width="100" height="100" fill="{LENS}"/>{"".join(parts)}</g>'
            '<path fill-rule="evenodd" fill="#1D1D1F" d="M50,0 A50,50 0 1 1 50,100 A50,50 0 1 1 50,0 Z M50,20 A30,30 0 1 0 50,80 A30,30 0 1 0 50,20 Z"/></svg>\n')


def write_previews():
    os.makedirs(PREVIEW, exist_ok=True)
    for name, body in (("icon-light.svg", preview_svg()), ("icon-dark.svg", preview_svg(dark=True)),
                       ("menubar.svg", menubar_svg(scale=4)), ("wordmark-o.svg", wordmark_o_svg())):
        with open(os.path.join(PREVIEW, name), "w") as f:
            f.write(body)


if __name__ == "__main__":
    write_icon()
    write_menubar()
    write_previews()
    print("wrote", os.path.relpath(ICON, ROOT), os.path.relpath(ASSETS, ROOT), os.path.relpath(PREVIEW, ROOT))
