"""Read images with Unlimited-OCR 2 on MLX (mlx-vlm 0.7.11), greedy, with the upstream no-repeat n-gram guard.

uocr_mlx.py MODEL_PATH OUT.json [--no-guard] [--bands HEIGHT] [--max-tokens N] IMAGE...
Each image is one page, read in gundam mode (a 1024 global view and up to 16 crops of 640), as upstream reads a single
page. --bands cuts each image into pages about HEIGHT pixels tall, at the emptiest row near each cut, and reads them as
one multi-page document (base mode, one 1024 view a page), as upstream reads several pages. The guard is SGLang's
DeepseekOCRNoRepeatNGramLogitProcessor with upstream's settings: no 35-gram repeated within the last 128 tokens (1024
for several pages). Records per image: the plain text (blocks' contents, tables as HTML), the raw blocks, prompt
tokens, generated tokens, prefill and decode speed, wall time, MLX peak.
"""
import json, re, sys, time
from pathlib import Path
import mlx.core as mx
import numpy as np
from PIL import Image
from mlx_vlm import load, generate
from mlx_vlm.prompt_utils import apply_chat_template

sys.path.insert(0, str(Path(__file__).parent))
from usage import usage

PROMPT = "Multi page parsing."
BLOCK = re.compile(r"<BLOCK>\s*([a-zA-Z_]+)\s*(?:<LEVEL\d*>)?\s*(?:\[[-\d,\s，]+\])?\s*(?:<LEVEL\d*>)?\s*(?:<FORK>)?")
NOISE = {"[non-text]", "[unreadable]", "[image]", "[figure]"}

def plain(raw):
    """The blocks' contents in reading order, one block a paragraph; pictures' blocks dropped."""
    out = []
    for page in re.split(r"<PAGE>", raw):
        heads = list(BLOCK.finditer(page))
        if not heads:
            if page.strip():
                out.append(page.strip())
            continue
        for i, m in enumerate(heads):
            end = heads[i + 1].start() if i + 1 < len(heads) else len(page)
            body = re.sub(r"<MERGE>|<[|｜][^>]*[|｜]>", "", page[m.end():end]).strip()
            label = m.group(1).lower().removeprefix("cross_").removeprefix("append_")
            if body and body not in NOISE and label not in {"image", "figure", "picture", "chart", "seal"}:
                out.append(body)
    return "\n\n".join(out)

def guard(ngram, window):
    """Ban any token that would repeat an ngram-gram already among the last `window` generated tokens."""
    def process(tokens, logits):
        seq = np.array(tokens).reshape(-1).tolist()
        n = len(seq)
        if n < ngram:
            return logits
        start = max(0, n - window)
        prefix = tuple(seq[n - ngram + 1:])
        banned = {seq[i + ngram - 1] for i in range(start, n - ngram + 1) if tuple(seq[i:i + ngram - 1]) == prefix}
        if not banned:
            return logits
        mask = np.zeros(logits.shape[-1], dtype=bool)
        mask[list(banned)] = True
        return mx.where(mx.array(mask), mx.array(-np.inf, dtype=logits.dtype), logits)
    return process

def bands(image, height):
    """Cut a tall image into pieces about `height` tall, each cut on the row nearest it with the least ink."""
    gray = np.asarray(image.convert("L"), dtype=np.int16)
    ink = np.abs(gray - np.median(gray, axis=1, keepdims=True)).sum(axis=1)
    cuts, top = [0], 0
    while image.height - top > height * 1.25:
        lo, hi = top + int(height * 0.8), min(image.height - 1, top + int(height * 1.2))
        top = lo + int(np.argmin(ink[lo:hi]))
        cuts.append(top)
    cuts.append(image.height)
    return [image.crop((0, a, image.width, b)) for a, b in zip(cuts, cuts[1:])]

args, images = sys.argv[1:], []
model_path, out = args.pop(0), Path(args.pop(0))
use_guard, band_height, max_tokens = True, 0, 8192
while args:
    a = args.pop(0)
    if a == "--no-guard": use_guard = False
    elif a == "--bands": band_height = int(args.pop(0))
    elif a == "--max-tokens": max_tokens = int(args.pop(0))
    else: images.append(a)

t = time.perf_counter()
model, processor = load(model_path)
load_s = time.perf_counter() - t
# generate() doesn't pass processor options on, and the processor crops every page: crop a single page only.
tokenize = processor.tokenize_with_images
processor.tokenize_with_images = lambda text, pages, cropping=None, **kw: tokenize(
    text, pages, cropping=len(pages) == 1 if cropping is None else cropping, **kw)

def read(pages, warm=False):
    prompt = apply_chat_template(processor, model.config, PROMPT, num_images=len(pages))
    window = 1024 if len(pages) > 1 else 128
    kw = {"logits_processors": [guard(35, window)]} if use_guard else {}
    return generate(model, processor, prompt, image=pages, max_tokens=8 if warm else max_tokens * len(pages),
                    temperature=0.0, verbose=False, **kw)

# One unscored warm-up so the first image doesn't carry Metal's kernel compilation.
read([Image.open(images[0]).convert("RGB")], warm=True)
results = {}
for path in images:
    picture = Image.open(path).convert("RGB")
    pages = bands(picture, band_height) if band_height else [picture]
    mx.reset_peak_memory()
    t = time.perf_counter()
    r = read(pages)
    wall = time.perf_counter() - t
    results[Path(path).stem] = {"text": plain(r.text), "raw": r.text, "pages": len(pages), "prompt_tokens": r.prompt_tokens,
                                "tokens": r.generation_tokens, "prefill_tps": r.prompt_tps, "decode_tps": r.generation_tps,
                                "wall": wall, "peak_gb": r.peak_memory}
    print(f"{Path(path).stem}: {len(pages)} page(s), {wall:.2f} s, prompt {r.prompt_tokens} tok at {r.prompt_tps:.0f}/s, "
          f"{r.generation_tokens} tok at {r.generation_tps:.0f}/s: {plain(r.text)[:120]!r}", flush=True)
out.write_text(json.dumps(results, ensure_ascii=False, indent=0))
u = usage()
walls = sorted(v["wall"] for v in results.values())
print(f"[{Path(model_path).name} {'guard' if use_guard else 'no guard'}{f' bands {band_height}' if band_height else ''}] "
      f"load {load_s:.1f} s; wall p50 {walls[len(walls)//2]:.2f} s p95 {walls[int(len(walls)*0.95)]:.2f} s; "
      f"decode {sum(v['tokens'] for v in results.values())/sum(v['tokens']/max(v['decode_tps'],1e-9) for v in results.values()):.0f} tok/s; "
      f"mlx peak {mx.get_peak_memory()/2**30:.2f} GB; footprint peak {u['peak_footprint_mb']:.0f} MB; cpu {u['cpu_s']:.1f} s, "
      f"cpu energy {u['cpu_energy_j']:.0f} J")
