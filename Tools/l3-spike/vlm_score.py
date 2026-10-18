"""Score VLM output (from vlm_mlx.py).

vlm_score.py formula CORPUS_DIR RESULT.json        token error rate / exact / same render
vlm_score.py table   TABLES_DIR RESULT.json         cell accuracy (ocr-bench's rule: same row and column, content equal)
vlm_score.py text    BENCH_DIR RESULT.json          content CER (ocr-bench's Normalize.content), markup stripped
"""
import html, json, re, sys, unicodedata
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
import score

PUNCT = {"，": ",", "、": ",", "。": ".", "：": ":", "；": ";", "！": "!", "？": "?", "（": "(", "）": ")", "【": "[", "】": "]",
         "「": "\"", "」": "\"", "『": "\"", "』": "\"", "“": "\"", "”": "\"", "‘": "'", "’": "'", "～": "~", "—": "-",
         "–": "-", "−": "-", "…": "..."}

def is_emoji(ch):
    o = ord(ch)
    return ch == "️" or 0x1F000 <= o <= 0x1FAFF or 0x2600 <= o <= 0x27BF and o > 0x238C

def content(text):
    out = []
    for ch in unicodedata.normalize("NFC", text):
        if ch.isspace() or is_emoji(ch):
            continue
        if ch in PUNCT:
            out.extend(PUNCT[ch])
        elif 0xFF01 <= ord(ch) <= 0xFF5E:
            out.append(chr(ord(ch) - 0xFEE0))
        else:
            out.append(ch)
    return out

def strip_markup(text):
    text = re.sub(r"<(fcel|ecel|lcel|ucel|xcel|nl)>", " ", text)
    text = re.sub(r"</?[a-zA-Z][^>]*>", " ", text)          # HTML tags
    text = re.sub(r"^\s*\|?\s*:?-{3,}.*$", " ", text, flags=re.M)  # markdown table rules
    text = text.replace("|", " ")
    text = re.sub(r"^#+\s*", "", text, flags=re.M)
    text = text.replace("**", "").replace("$$", "")
    return html.unescape(text)

def parse_table(text):
    """Rows of cell strings from OTSL tokens, an HTML table, or a Markdown table."""
    if "<fcel>" in text or "<ecel>" in text:
        rows = []
        for line in text.split("<nl>"):
            cells = re.findall(r"<(fcel|ecel|lcel|ucel|xcel)>([^<]*)", line)
            if cells:
                rows.append([c[1].strip() if c[0] == "fcel" else "" for c in cells])
        return rows
    if "<tr" in text:
        rows = []
        for tr in re.findall(r"<tr[^>]*>(.*?)</tr>", text, flags=re.S):
            rows.append([html.unescape(re.sub(r"<[^>]+>", "", c)).strip() for c in re.findall(r"<t[dh][^>]*>(.*?)</t[dh]>", tr, flags=re.S)])
        return rows
    rows = []
    for line in text.splitlines():
        if "|" in line and not re.match(r"^\s*\|?\s*:?-{3,}", line):
            rows.append([c.strip() for c in line.strip().strip("|").split("|")])
    return rows

def cer(a, b):
    return score.edit(a, b) / max(1, len(b))

mode = sys.argv[1]
if mode == "formula":
    corpus, res = Path(sys.argv[2]), json.loads(Path(sys.argv[3]).read_text())
    preds = {}
    for k, v in res.items():
        t = v["text"].strip()
        t = re.sub(r"^\$\$|\$\$$", "", t).strip()
        t = re.sub(r"^\\\[|\\\]$", "", t).strip()
        preds[k] = t
    p = Path(sys.argv[3]).with_suffix(".latex.json")
    p.write_text(json.dumps(preds, ensure_ascii=False))
    sys.argv = ["score.py", str(corpus), str(p), "--render"] + (["--worst"] if "--worst" in sys.argv else [])
    score.main()
elif mode == "table":
    tables, res = Path(sys.argv[2]), json.loads(Path(sys.argv[3]).read_text())
    tot_c = tot_n = shapes = 0
    for k, v in sorted(res.items()):
        truth = json.loads((tables / f"{k.rsplit('_', 1)[0]}.json").read_text())
        rows = parse_table(v["text"])
        n = sum(len(r) for r in truth)
        c = sum(1 for i, r in enumerate(truth) for j, cell in enumerate(r)
                if i < len(rows) and j < len(rows[i]) and content(rows[i][j]) == content(cell))
        shape = len(rows) == len(truth) and all(len(a) == len(b) for a, b in zip(rows, truth))
        tot_c += c; tot_n += n; shapes += shape
        print(f"  {k}: cells {c}/{n}, shape {'ok' if shape else 'off'}")
    print(f"cells {100*tot_c/max(1,tot_n):.1f}% ({tot_c}/{tot_n}); shape {shapes}/{len(res)}")
elif mode == "text":
    bench, res = Path(sys.argv[2]), json.loads(Path(sys.argv[3]).read_text())
    rates = []
    for k, v in sorted(res.items()):
        truth = (bench / f"{k}.truth.txt").read_text()
        r = cer(content(strip_markup(v["text"])), content(truth))
        rates.append((k, r))
    for k, r in rates:
        print(f"  {k}: {100*r:.1f}%")
    print(f"mean content CER {100*sum(r for _, r in rates)/len(rates):.2f}% over {len(rates)}")
