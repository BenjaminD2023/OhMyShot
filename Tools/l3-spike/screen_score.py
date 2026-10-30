"""How much of a whole screen's known text a reading holds: the benchmark's real regions, found in a reading of the
whole capture they were cut from.

screen_score.py SCREENS_DIR READING...
SCREENS_DIR holds NAME.png and NAME.txt, the truths of the regions cut from it (Tools/ocr-bench/real). A READING is a
vlm_mlx.py or uocr_mlx.py result (.json, keyed by NAME), or a pattern with %s for NAME (ocr-bench --save's
"DIR/real-%s.l1.txt"). Each truth line is matched to the closest stretch of the whole reading (edit distance, the
stretch free to start and end anywhere, on vlm_score's content characters), so reading order and the rest of the
screen cost nothing. Recall is 1 - the lines' summed distance / their characters; a line is missed when its
distance is half its length or more.
"""
import json, sys
from pathlib import Path
import numpy as np

sys.path.insert(0, str(Path(__file__).parent))
from vlm_score import content, strip_markup

def distances(lines, text):
    """Each line's least edit distance to any stretch of text (semi-global), all lines at once."""
    lens = np.array([len(l) for l in lines])
    width = lens.max()
    pattern = np.full((len(lines), width), -1)
    for i, l in enumerate(lines):
        pattern[i, :len(l)] = [ord(c) for c in l]
    rows, ar = np.arange(len(lines)), np.arange(width + 1)
    prev = np.tile(ar, (len(lines), 1))
    best = lens.copy()
    for c in text:
        base = np.empty_like(prev)
        base[:, 0] = 0
        base[:, 1:] = np.minimum(prev[:, :-1] + (pattern != ord(c)), prev[:, 1:] + 1)
        prev = np.minimum.accumulate(base - ar, axis=1) + ar
        best = np.minimum(best, prev[rows, lens])
    return best, lens

screens, readings = Path(sys.argv[1]), sys.argv[2:]
names = sorted(p.stem for p in screens.glob("*.png"))
for reading in readings:
    texts = json.loads(Path(reading).read_text()) if reading.endswith(".json") else None
    tot_d = tot_n = missed = count = 0
    print(reading)
    for name in names:
        if texts is not None:
            if name not in texts:
                continue
            text = texts[name]["text"]
        else:
            path = Path(reading % name)
            if not path.exists():
                continue
            text = path.read_text()
        lines = [c for c in (content(l) for l in (screens / f"{name}.txt").read_text().splitlines()) if c]
        d, n = distances(lines, content(strip_markup(text)))
        d = np.minimum(d, n)
        tot_d += d.sum(); tot_n += n.sum(); missed += (d * 2 >= n).sum(); count += len(lines)
        print(f"  {name}: recall {100 * (1 - d.sum() / n.sum()):.1f}%, {(d * 2 >= n).sum()} of {len(lines)} lines missed, "
              f"reading {len(content(strip_markup(text)))} characters")
    print(f"recall {100 * (1 - tot_d / max(1, tot_n)):.1f}%, {missed} of {count} lines missed")
