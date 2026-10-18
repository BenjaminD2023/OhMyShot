"""Render LaTeX formulas to PNG at screen scale (xelatex + pdftoppm), and compare renders.

render.py OUT_DIR   -> OUT_DIR/{id}_{s1,s2,d2}.png for each formula in formulas.txt (beside this script): 1x
                       (96 dpi), 2x (192 dpi), and 2x dark (light gray on #1f1f1f).
"""
import hashlib, os, subprocess, sys, tempfile
from pathlib import Path

PREAMBLE = r"""\documentclass[11pt,border=6pt,varwidth=40cm]{standalone}
\usepackage{amsmath,amssymb,amsfonts,bm,mathtools}
\usepackage{xeCJK}
\setCJKmainfont{Hiragino Sans GB}
\begin{document}
"""

def render_pdf(latex: str, workdir: Path) -> Path | None:
    tex = workdir / "f.tex"
    tex.write_text(PREAMBLE + "$\\displaystyle " + latex + "$\n\\end{document}\n")
    r = subprocess.run(["xelatex", "-interaction=nonstopmode", "-halt-on-error", "f.tex"],
                       cwd=workdir, capture_output=True, timeout=60)
    pdf = workdir / "f.pdf"
    return pdf if r.returncode == 0 and pdf.exists() else None

def render_png(latex: str, out: Path, dpi: int, dark: bool = False) -> bool:
    with tempfile.TemporaryDirectory() as d:
        d = Path(d)
        pdf = render_pdf(latex, d)
        if pdf is None:
            return False
        subprocess.run(["pdftoppm", "-r", str(dpi), "-png", "-singlefile", str(pdf), str(d / "p")], check=True)
        png = d / "p.png"
        if dark:
            subprocess.run(["magick", str(png), "-colorspace", "Gray", "-negate", "+level", "12%,90%",
                            "-colorspace", "sRGB", str(out)], check=True)
        else:
            subprocess.run(["magick", str(png), "-colorspace", "sRGB", str(out)], check=True)
        return True

def render_key(latex: str, dpi: int = 150) -> str | None:
    """A hash of the rendered pixels: equal keys mean the two LaTeX strings draw the same picture."""
    with tempfile.TemporaryDirectory() as d:
        out = Path(d) / "k.png"
        if not render_png(latex, out, dpi):
            return None
        raw = subprocess.run(["magick", str(out), "-trim", "+repage", "-threshold", "50%", "gray:-"],
                             capture_output=True, check=True).stdout
        size = subprocess.run(["magick", str(out), "-trim", "+repage", "-format", "%wx%h", "info:"],
                              capture_output=True, check=True, text=True).stdout
        return size + ":" + hashlib.sha1(raw).hexdigest()

FORMULAS = Path(__file__).with_name("formulas.txt")


def load():
    """(id, LaTeX) of each formula, written for the benchmark: its ground truth."""
    for line in FORMULAS.read_text().splitlines():
        if line.strip():
            fid, tex = line.split("\t", 1)
            yield fid, tex

if __name__ == "__main__":
    corpus = Path(sys.argv[1])
    variants = {"s1": (96, False), "s2": (192, False), "d2": (192, True)}
    for fid, tex in load():
        for v, (dpi, dark) in variants.items():
            ok = render_png(tex, corpus / f"{fid}_{v}.png", dpi, dark)
            if not ok:
                print("FAILED", fid, v)
    print("done")
