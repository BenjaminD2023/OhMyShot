"""Re-render the formulas at 2x with other math fonts, to see how much each reader leans on Computer Modern.

render_font.py OUT_DIR   -> OUT_DIR/{id}_x2.png (STIX Two Math) and {id}_p2.png (TeX Gyre Pagella Math)
"""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
import render

out = Path(sys.argv[1])
# fontspec finds STIX Two by name; Pagella only by its file name.
fonts = {"x2": ("STIX Two Text", "STIX Two Math"), "p2": ("texgyrepagella-regular.otf", "texgyrepagella-math.otf")}
base = render.PREAMBLE
for tag, (text, math) in fonts.items():
    render.PREAMBLE = base.replace(r"\usepackage{xeCJK}", r"\usepackage{unicode-math}\setmainfont{" + text + r"}\setmathfont{" + math + "}\n" + r"\usepackage{xeCJK}")
    for fid, tex in render.load():
        if not render.render_png(tex, out / f"{fid}_{tag}.png", 192):
            print("FAILED", fid, tag)
print("done")
