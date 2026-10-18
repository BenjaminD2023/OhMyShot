"""Score formula predictions against formulas.txt.

score.py CORPUS_DIR PRED.json [--render] [--worst]
PRED.json: {"f01_s1": "E=mc^2", ...}
Prints token error rate (normalized LaTeX tokens, edit distance / truth length), exact match after
normalization, and with --render the share whose render draws the same pixels as the truth's.
"""
import json, re, sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
import render

SPACING = {r"\,", r"\;", r"\:", r"\!", r"\quad", r"\qquad", "~", r"\ ", r"\displaystyle", r"\textstyle",
           r"\left", r"\right", r"\bigl", r"\bigr", r"\Bigl", r"\Bigr", r"\big", r"\Big", r"\biggl", r"\biggr"}
ALIASES = {r"\dfrac": r"\frac", r"\tfrac": r"\frac", r"\le": r"\leq", r"\ge": r"\geq", r"\ne": r"\neq",
           r"\operatorname": r"\mathrm", r"\rm": r"\mathrm", r"\lbrace": r"\{", r"\rbrace": r"\}",
           r"\vert": "|", r"\lvert": "|", r"\rvert": "|", r"\Vert": r"\|", r"\lVert": r"\|", r"\rVert": r"\|",
           r"\to": r"\rightarrow", r"\gets": r"\leftarrow", r"\land": r"\wedge", r"\lor": r"\vee",
           r"\epsilon": r"\epsilon", r"\dots": r"\ldots"}
TOKEN = re.compile(r"\\[a-zA-Z]+\*?|\\.|[^\s]")

def tokens(tex: str) -> list[str]:
    tex = tex.strip().strip("$").strip()
    tex = re.sub(r"^\\\[|\\\]$", "", tex).strip()
    out = []
    for t in TOKEN.findall(tex):
        t = ALIASES.get(t, t)
        if t in SPACING:
            continue
        out.append(t)
    # drop braces holding one token after ^ or _, and empty groups
    changed = True
    while changed:
        changed = False
        for i in range(len(out) - 2):
            if out[i] == "{" and out[i + 2] == "}" and i > 0 and out[i - 1] in ("^", "_"):
                del out[i + 2]; del out[i]; changed = True; break
            if out[i] == "{" and out[i + 1] == "}":
                del out[i:i + 2]; changed = True; break
    return out

def edit(a, b) -> int:
    prev = list(range(len(b) + 1))
    for i, x in enumerate(a, 1):
        cur = [i]
        for j, y in enumerate(b, 1):
            cur.append(min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (x != y)))
        prev = cur
    return prev[-1]

def main():
    corpus, pred_path = Path(sys.argv[1]), Path(sys.argv[2])
    do_render = "--render" in sys.argv
    truth = dict(render.load())
    preds = json.loads(pred_path.read_text())
    keys = {}
    rows = []
    for key, p in sorted(preds.items()):
        fid, variant = key.rsplit("_", 1)
        t = tokens(truth[fid]); q = tokens(p or "")
        ter = edit(t, q) / max(1, len(t))
        exact = t == q
        same = None
        if do_render:
            if fid not in keys:
                keys[fid] = render.render_key(truth[fid])
            same = exact or (render.render_key(p) == keys[fid] if p else False)
        rows.append((key, variant, ter, exact, same))
    by = {}
    for key, v, ter, exact, same in rows:
        by.setdefault(v, []).append((ter, exact, same))
        by.setdefault("all", []).append((ter, exact, same))
    for v, xs in sorted(by.items()):
        n = len(xs)
        line = f"{v:4} n={n:3} TER {100*sum(x[0] for x in xs)/n:5.1f}%  exact {100*sum(x[1] for x in xs)/n:5.1f}%"
        if do_render:
            line += f"  same render {100*sum(bool(x[2]) for x in xs)/n:5.1f}%"
        print(line)
    if "--worst" in sys.argv:
        for key, v, ter, exact, same in sorted(rows, key=lambda r: -r[2])[:10]:
            print(f"  {key}: TER {100*ter:.0f}%  pred={preds[key]!r}")

if __name__ == "__main__":
    main()
