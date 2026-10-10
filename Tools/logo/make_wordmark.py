#!/usr/bin/env python3
"""Outlines the OhMyShot wordmark: the loupe ring as the O, then "hMyShot" in Nunito ExtraBold.

Usage: python3 Tools/logo/make_wordmark.py <path to Nunito[wght].ttf>
The font (SIL Open Font License) is not kept in the repository; get it from
https://github.com/google/fonts/tree/main/ofl/nunito. Writes Tools/logo/preview/wordmark-light.svg and
wordmark-dark.svg as plain paths, so they render where SVG fonts don't load (GitHub READMEs).
"""
import math
import os
import sys

from fontTools.pens.boundsPen import BoundsPen
from fontTools.pens.recordingPen import RecordingPen
from fontTools.pens.svgPathPen import SVGPathPen
from fontTools.pens.transformPen import TransformPen
from fontTools.ttLib import TTFont
from fontTools.varLib import instancer

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from make_icon import BLUE, LENS, MID, PREVIEW, WHITE  # noqa: E402

WEIGHT = 800
TRACKING = -15          # font units per letter, the canvas's -0.015 em
TEXT = "hMyShot"        # the ring stands in for the capital O
INKS = {"light": "#1D1D1F", "dark": "#F5F5F7"}


def kerning(font):
    """Pair adjustments (x advance) from the GPOS pair-positioning lookups."""
    pairs, class_tables = {}, []
    gpos = font["GPOS"].table
    for lookup in gpos.LookupList.Lookup:
        for sub in lookup.SubTable:
            if lookup.LookupType == 9:
                sub = sub.ExtSubTable
            if getattr(sub, "LookupType", 2) != 2 or not hasattr(sub, "Format"):
                continue
            if sub.Format == 1:
                for first, pset in zip(sub.Coverage.glyphs, sub.PairSet):
                    for rec in pset.PairValueRecord:
                        v = getattr(rec.Value1, "XAdvance", 0) if rec.Value1 else 0
                        pairs.setdefault((first, rec.SecondGlyph), v)
            elif sub.Format == 2:
                class_tables.append(sub)

    def adjust(a, b):
        if (a, b) in pairs:
            return pairs[(a, b)]
        for sub in class_tables:
            if a not in sub.Coverage.glyphs:
                continue
            c1 = sub.ClassDef1.classDefs.get(a, 0)
            c2 = sub.ClassDef2.classDefs.get(b, 0)
            rec = sub.Class1Record[c1].Class2Record[c2]
            v = getattr(rec.Value1, "XAdvance", 0) if rec.Value1 else 0
            if v:
                return v
        return 0
    return adjust


def contour_bounds(glyphset, name):
    rec = RecordingPen()
    glyphset[name].draw(rec)
    contours, current = [], []
    for op, args in rec.value:
        current.append((op, args))
        if op in ("closePath", "endPath"):
            contours.append(current)
            current = []
    boxes = []
    for c in contours:
        bp = BoundsPen(glyphset)
        for op, args in c:
            getattr(bp, op)(*args)
        boxes.append(bp.bounds)
    return sorted(boxes, key=lambda b: (b[2] - b[0]) * (b[3] - b[1]), reverse=True)


def ring_o(glyphset, font, x):
    """A circle as tall as the font's O, its stroke the O's mean stroke, with the loupe's pixels inside."""
    outer, inner = contour_bounds(glyphset, "O")[:2]
    stroke = ((inner[0] - outer[0]) + (outer[2] - inner[2]) + (outer[3] - inner[3]) + (inner[1] - outer[1])) / 4
    d = outer[3] - outer[1]
    r_out, cy = d / 2, -(outer[1] + outer[3]) / 2
    lsb = outer[0]
    rsb = font["hmtx"]["O"][0] - outer[2]
    cx = x + lsb + r_out
    r_in = r_out - stroke
    pitch, size, rx = 0.567 * r_in, 0.5 * r_in, 0.117 * r_in
    cells = []
    for j in range(3):
        for i in range(3):
            v = i + j
            col = BLUE if v >= 3 else (MID if v == 2 else WHITE)
            cells.append(f'<rect x="{cx + (i - 1) * pitch - size / 2:.1f}" y="{cy + (j - 1) * pitch - size / 2:.1f}" '
                         f'width="{size:.1f}" height="{size:.1f}" rx="{rx:.1f}" fill="{col}"/>')
    lens = (f'<clipPath id="lens"><circle cx="{cx:.1f}" cy="{cy:.1f}" r="{r_in:.1f}"/></clipPath>',
            f'<g clip-path="url(#lens)"><circle cx="{cx:.1f}" cy="{cy:.1f}" r="{r_in:.1f}" fill="{LENS}"/>{"".join(cells)}</g>')
    ring = (f'M{cx:.1f},{cy - r_out:.1f} A{r_out:.1f},{r_out:.1f} 0 1 1 {cx:.1f},{cy + r_out:.1f} '
            f'A{r_out:.1f},{r_out:.1f} 0 1 1 {cx:.1f},{cy - r_out:.1f} Z '
            f'M{cx:.1f},{cy - r_in:.1f} A{r_in:.1f},{r_in:.1f} 0 1 0 {cx:.1f},{cy + r_in:.1f} '
            f'A{r_in:.1f},{r_in:.1f} 0 1 0 {cx:.1f},{cy - r_in:.1f} Z')
    advance = lsb + d + rsb
    return lens, ring, advance, (cx - r_out, cy - r_out, cx + r_out, cy + r_out)


def main(font_path):
    font = instancer.instantiateVariableFont(TTFont(font_path), {"wght": WEIGHT})
    glyphset = font.getGlyphSet()
    cmap = font.getBestCmap()
    kern = kerning(font)

    (clip, lens), ring, x, box = ring_o(glyphset, font, 0)
    x += TRACKING + kern("O", cmap[ord(TEXT[0])])
    xmin, ymin, xmax, ymax = box
    paths = [ring]
    names = [cmap[ord(ch)] for ch in TEXT]
    for k, name in enumerate(names):
        svg = SVGPathPen(glyphset)
        glyphset[name].draw(TransformPen(svg, (1, 0, 0, -1, x, 0)))
        paths.append(svg.getCommands())
        bp = BoundsPen(glyphset)
        glyphset[name].draw(TransformPen(bp, (1, 0, 0, -1, x, 0)))
        if bp.bounds:
            xmin, ymin = min(xmin, bp.bounds[0]), min(ymin, bp.bounds[1])
            xmax, ymax = max(xmax, bp.bounds[2]), max(ymax, bp.bounds[3])
        x += font["hmtx"][name][0] + TRACKING
        if k + 1 < len(names):
            x += kern(name, names[k + 1])

    pad = 8
    vb = f"{xmin - pad:.0f} {ymin - pad:.0f} {xmax - xmin + 2 * pad:.0f} {ymax - ymin + 2 * pad:.0f}"
    height = 96
    width = height * (xmax - xmin + 2 * pad) / (ymax - ymin + 2 * pad)
    for mode, ink in INKS.items():
        svg = (f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="{vb}" width="{width:.0f}" height="{height}" '
               f'role="img" aria-label="OhMyShot"><defs>{clip}</defs>{lens}'
               f'<path fill-rule="evenodd" fill="{ink}" d="{paths[0]}"/>'
               f'<path fill="{ink}" d="{" ".join(paths[1:])}"/></svg>\n')
        with open(os.path.join(PREVIEW, f"wordmark-{mode}.svg"), "w") as f:
            f.write(svg)
    print("wrote wordmark-light.svg, wordmark-dark.svg in", os.path.relpath(PREVIEW))


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    main(sys.argv[1])
