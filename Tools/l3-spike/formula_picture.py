"""The formula pack's picture preparation in plain NumPy, as the app does it (OMSOCR's FormulaPicture), against
transformers' PPFormulaNetImageProcessor (torchvision, antialiased uint8 resizing).

formula_picture.py CORPUS_DIR [GLOB]          compares the two on every picture
formula_picture.py CORPUS_DIR GLOB --dump DIR writes each picture's pixel values (float32, 3 × 768 × 768) to DIR

Resampling is PIL's: a separable filter (triangle for bilinear, cubic with a = -0.5 for bicubic) widened by the scale
when shrinking, its weights in 22-bit fixed point, the rows first, then the columns, rounded to 8 bits after each.
torchvision's antialiased uint8 resize gives the same within 1 on about 0.01% of values.
"""
import sys
from pathlib import Path

import numpy as np

SIZE, MEAN, STD, CROP_GRAY, DARK_BORDER = 768, 0.7931, 0.1738, 200, 128
BITS = 22


def kernel(kind):
    if kind == "bilinear":
        return 1.0, lambda x: np.maximum(0.0, 1.0 - np.abs(x))
    a = -0.5

    def cubic(x):
        x = np.abs(x)
        return np.where(x < 1, ((a + 2) * x - (a + 3)) * x * x + 1, np.where(x < 2, (((x - 5) * x + 8) * x - 4) * a, 0.0))
    return 2.0, cubic


def taps(n_in, n_out, kind):
    """(first source index, fixed-point weights) for each output index."""
    support, f = kernel(kind)
    scale = n_in / n_out
    widen = max(scale, 1.0)
    result = []
    for o in range(n_out):
        center = (o + 0.5) * scale
        lo = max(int(center - support * widen + 0.5), 0)
        hi = min(int(center + support * widen + 0.5), n_in)
        w = f((np.arange(lo, hi) - center + 0.5) / widen)
        total = w.sum()
        if total:
            w = w / total
        fixed = np.where(w < 0, np.trunc(-0.5 + w * (1 << BITS)), np.trunc(0.5 + w * (1 << BITS))).astype(np.int64)
        result.append((lo, fixed))
    return result


def resample(img, height, width, kind):
    """H × W × C uint8 to height × width × C: the rows (horizontally) first, then the columns."""
    out = img.astype(np.int64)
    for axis, n_out in ((1, width), (0, height)):
        moved = np.moveaxis(out, axis, 0)
        rows = [np.clip((np.tensordot(k, moved[lo:lo + len(k)], axes=(0, 0)) + (1 << (BITS - 1))) >> BITS, 0, 255)
                for lo, k in taps(moved.shape[0], n_out, kind)]
        out = np.moveaxis(np.stack(rows), 0, axis)
    return out.astype(np.uint8)


def gray(img):
    """torchvision's rgb_to_grayscale on uint8: 0.2989 R + 0.587 G + 0.114 B in float32, truncated to uint8."""
    f = img.astype(np.float32)
    return (f[..., 0] * np.float32(0.2989) + f[..., 1] * np.float32(0.587) + f[..., 2] * np.float32(0.114)).astype(np.uint8)


def is_dark(img):
    """Tools/l3-spike/darkfix.py's rule: the mean of PIL's gray along the border, sampled every 1/32 of each side."""
    g = (img[..., 0].astype(np.int64) * 299 + img[..., 1].astype(np.int64) * 587 + img[..., 2].astype(np.int64) * 114) // 1000
    h, w = g.shape
    samples = [g[y, x] for x in range(0, w, max(1, w // 32)) for y in (0, h - 1)] + \
              [g[y, x] for y in range(0, h, max(1, h // 32)) for x in (0, w - 1)]
    return sum(samples) / len(samples) < DARK_BORDER


def crop_margin(img):
    g = gray(img).astype(np.float32)
    lo, hi = g.min(), g.max()
    if lo == hi:
        return img
    ink = (g - lo) / (hi - lo) * 255 < CROP_GRAY
    ys, xs = np.nonzero(ink)
    return img[ys.min():ys.max() + 1, xs.min():xs.max() + 1]


def prepare(img):
    """H × W × 3 uint8 RGB to 3 × SIZE × SIZE float32, as the pack's config.json describes it."""
    if is_dark(img):
        img = 255 - img
    img = crop_margin(img)
    h, w = img.shape[:2]
    short, long = min(h, w), max(h, w)
    new_long = int(SIZE * long / short)
    h, w = (new_long, SIZE) if w <= h else (SIZE, new_long)
    img = resample(img, h, w, "bilinear")
    th, tw = min(h, SIZE), min(w, SIZE)
    if (th, tw) != (h, w):
        if h > w:
            tw = int(w * th / h)
        elif w > h:
            th = int(h * tw / w)
        img = resample(img, th, tw, "bicubic")
    h, w = img.shape[:2]
    top, left = (SIZE - h) // 2, (SIZE - w) // 2
    canvas = np.zeros((SIZE, SIZE, 3), np.uint8)
    canvas[top:top + h, left:left + w] = img
    return ((canvas.astype(np.float32) / 255 - MEAN) / STD).transpose(2, 0, 1)


if __name__ == "__main__":
    from PIL import Image

    corpus = Path(sys.argv[1])
    pattern = sys.argv[2] if len(sys.argv) > 2 else "f*_*.png"
    dump = Path(sys.argv[sys.argv.index("--dump") + 1]) if "--dump" in sys.argv else None
    if dump:
        dump.mkdir(parents=True, exist_ok=True)
        for png in sorted(corpus.glob(pattern)):
            prepare(np.array(Image.open(png).convert("RGB"))).astype("<f4").tofile(dump / f"{png.stem}.f32")
        raise SystemExit
    from transformers import AutoProcessor

    sys.path.insert(0, str(Path(__file__).parent))
    from darkfix import light
    processor = AutoProcessor.from_pretrained(sys.argv[3] if len(sys.argv) > 3 else "PaddlePaddle/PP-FormulaNet_plus-L_safetensors")
    worst, differing, values = 0.0, 0, 0
    for png in sorted(corpus.glob(pattern)):
        image = Image.open(png)
        theirs = processor(images=light(image), return_tensors="np")["pixel_values"][0]
        mine = prepare(np.array(image.convert("RGB")))
        d = np.abs(theirs - mine)
        worst = max(worst, float(d.max()))
        differing += int((d > 1e-5).sum())
        values += d.size
        if d.max() > 0.05:
            print(f"{png.stem}: max {d.max():.3f} ({int((d > 1e-5).sum())} values)")
    print(f"max difference {worst:.4f} (1/255 is {1 / 255 / STD:.4f}), {100 * differing / values:.4f}% of values differ")
