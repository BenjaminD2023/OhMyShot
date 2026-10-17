"""Builds the PP-OCRv6 small model pack (Docs/ocr.md › L2 runtime, › Model packs) and checks it.

    python3 -I Tools/model-packs/ppocr_pack.py convert MODELS OUT
        Core ML fp16 ML programs with the pack's enumerated shapes, from the pinned upstream revisions in MODELS
        (each repository in its own folder, as Tools/l2-spike/README.md fetches them), after checking them
        against the official ONNX exports.
    python3 -I Tools/model-packs/ppocr_pack.py check OUT CORPUS OUT_JSON [--limit 736]
        Reads the OCR benchmark's corpus (ocr-bench --save) through the pack as the app will: in bands, each
        line kept by the band holding its center, every input padded up to an enumerated shape.
    python3 -I Tools/model-packs/ppocr_pack.py assemble OUT PACK --license PADDLEOCR_LICENSE --checked CHECK_JSON --reference REF_JSON
        The pack's files in PACK: the two models, characters.txt, config.json, LICENSE.txt, README.md (with the
        benchmark's means from the check above and from Tools/l2-spike/run_coreml.py's flexible-size run).

Run with the Python environment of Tools/l2-spike (its README), from outside the models' folder.
"""

import json
import math
import os
import shutil
import sys
import time

import numpy as np

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "l2-spike"))

# The upstream revisions the pack is made from (Hugging Face, PaddlePaddle organization, Apache-2.0).
UPSTREAM = {
    "PP-OCRv6_small_det_safetensors": "eae2ee920a39fb3087637d3dbb58df1896ec1f24",
    "PP-OCRv6_small_rec_safetensors": "fe049fb103f57443fe8840c54ed06b702f3c1de5",
    "PP-OCRv6_small_det_onnx": "28fe5895c24fd108c19eb3e8479f4ab385fbfc62",
    "PP-OCRv6_small_rec_onnx": "b8f84f0b80c529de40b4fbb3544b84fa7233a513",
}

# Detection reads a region in bands BAND tall, each reaching OVERLAP into the next; a line belongs to the band
# whose core (the band less half the overlap on each side it shares) holds its center, as PieceMerge does for L1.
# A region wider than MAX_WIDTH is scaled down to it first. Every band is padded up to the smallest of these
# shapes that holds it (height, width), multiples of 32 as the detector needs.
BAND = 1280
OVERLAP = 256
MAX_WIDTH = 4096
# Before that, a region whose shorter side is shorter than this is scaled up to it, as transformers' preprocessor
# does (PaddleX uses 64): on the benchmark, mean content CER 2.40% against 2.78% at 64.
SHORTEST_SIDE = 736
DET_SHAPES = [(h, w) for h in (640, 1280) for w in (640, 1280, 2560, 4096)]
# Recognition reads a line 48 tall, padded up to the smallest of these widths; a longer line is narrowed to the last.
REC_HEIGHT = 48
REC_WIDTHS = [160, 320, 480, 640, 800, 960, 1280, 1600, 2000, 2400, 3200, 4000]
# DBPostProcess as PaddleX runs PP-OCRv6.
DET_THRESHOLDS = {"thresh": 0.2, "box_thresh": 0.45, "unclip_ratio": 1.4}


def convert(models, out):
    import coremltools as ct
    import onnxruntime as ort
    import torch
    from transformers import PPOCRV6SmallDetForObjectDetection, PPOCRV6SmallRecForTextRecognition

    os.makedirs(out, exist_ok=True)
    torch.set_grad_enabled(False)

    class Det(torch.nn.Module):
        def __init__(self, model):
            super().__init__()
            self.model = model

        def forward(self, x):
            return self.model(pixel_values=x).last_hidden_state

    class Rec(torch.nn.Module):
        def __init__(self, model):
            super().__init__()
            self.model = model

        def forward(self, x):
            return self.model(pixel_values=x).last_hidden_state

    det_model = PPOCRV6SmallDetForObjectDetection.from_pretrained(os.path.join(models, "PP-OCRv6_small_det_safetensors")).eval()
    rec_model = PPOCRV6SmallRecForTextRecognition.from_pretrained(os.path.join(models, "PP-OCRv6_small_rec_safetensors")).eval()

    rng = np.random.default_rng(0)
    det_x = rng.standard_normal((1, 3, 640, 1280), dtype=np.float32)
    rec_x = rng.standard_normal((1, 3, REC_HEIGHT, 320), dtype=np.float32)
    det_ref = ort.InferenceSession(os.path.join(models, "PP-OCRv6_small_det_onnx/inference.onnx"), providers=["CPUExecutionProvider"]).run(None, {"x": det_x})[0]
    rec_ref = ort.InferenceSession(os.path.join(models, "PP-OCRv6_small_rec_onnx/inference.onnx"), providers=["CPUExecutionProvider"]).run(None, {"x": rec_x})[0]
    det_torch = Det(det_model)(torch.from_numpy(det_x)).numpy()
    rec_torch = Rec(rec_model)(torch.from_numpy(rec_x)).numpy()
    det_diff, rec_diff = float(np.abs(det_torch - det_ref).max()), float(np.abs(rec_torch - rec_ref).max())
    print(f"parity with the ONNX exports: detection {det_diff:.2e}, recognition {rec_diff:.2e}")
    assert det_diff < 1e-3 and rec_diff < 1e-3, "the PyTorch weights don't match the ONNX exports"
    # The recognizer's head ends in a softmax, as the ONNX export's does.
    assert np.allclose(rec_torch.sum(-1), 1, atol=1e-3)

    from coremltools.converters.mil.frontend.torch import ops as torch_ops
    from coremltools.converters.mil.mil import Builder as mb

    # coremltools 9.0 casts a folded one-element array with int(), which NumPy 2.5 no longer allows.
    def _cast(context, node, dtype, dtype_name):
        x = torch_ops._get_inputs(context, node, expected=1)[0]
        if not (len(x.shape) == 0 or np.all([d == 1 for d in x.shape])):
            raise ValueError("input to cast must be either a scalar or a length 1 tensor")
        if x.can_be_folded_to_const():
            res = x if isinstance(x.val, dtype) else mb.const(val=dtype(np.asarray(x.val).reshape(-1)[0]), name=node.name)
        elif len(x.shape) > 0:
            res = mb.cast(x=mb.squeeze(x=x, name=node.name + "_item"), dtype=dtype_name, name=node.name)
        else:
            res = mb.cast(x=x, dtype=dtype_name, name=node.name)
        context.add(res, node.name)

    torch_ops._cast = _cast
    common = dict(convert_to="mlprogram", compute_precision=ct.precision.FLOAT16, minimum_deployment_target=ct.target.macOS15)
    started = time.perf_counter()
    det = ct.convert(
        torch.jit.trace(Det(det_model).eval(), torch.from_numpy(det_x)),
        inputs=[ct.TensorType(name="x", shape=ct.EnumeratedShapes(shapes=[(1, 3, h, w) for h, w in DET_SHAPES], default=(1, 3, 640, 1280)))],
        outputs=[ct.TensorType(name="prob")], **common,
    )
    det.short_description = "PP-OCRv6 small text detection (DB), converted to Core ML for OhMyShot"
    det.license = "Apache-2.0"
    det.save(os.path.join(out, "det.mlpackage"))
    rec = ct.convert(
        torch.jit.trace(Rec(rec_model).eval(), torch.from_numpy(rec_x)),
        inputs=[ct.TensorType(name="x", shape=ct.EnumeratedShapes(shapes=[(1, 3, REC_HEIGHT, w) for w in REC_WIDTHS], default=(1, 3, REC_HEIGHT, 320)))],
        outputs=[ct.TensorType(name="probs")], **common,
    )
    rec.short_description = "PP-OCRv6 small text recognition (CTC), converted to Core ML for OhMyShot"
    rec.license = "Apache-2.0"
    rec.save(os.path.join(out, "rec.mlpackage"))
    print(f"converted in {time.perf_counter() - started:.0f} s")
    import yaml
    characters = [str(c) for c in yaml.safe_load(open(os.path.join(models, "PP-OCRv6_small_rec_safetensors", "inference.yml")))["PostProcess"]["character_dict"]]
    classes = rec_torch.shape[-1]
    # CTC: the blank at 0, then the dictionary, then a space.
    assert classes == len(characters) + 2, f"{classes} classes for {len(characters)} characters"
    with open(os.path.join(out, "characters.txt"), "w", encoding="utf-8") as f:
        f.write("\n".join(characters) + "\n")
    print(f"{len(characters)} characters, {classes} classes")


# ---------------------------------------------------------------- reading, as the app will

def bands(height):
    """(top, bottom, core top, core bottom) of each band of a region `height` tall."""
    if height <= BAND:
        return [(0, height, 0, height)]
    starts = list(range(0, height - BAND, BAND - OVERLAP)) + [height - BAND]
    result = []
    for i, top in enumerate(starts):
        bottom = top + BAND
        core_top = 0 if i == 0 else (top + starts[i - 1] + BAND) // 2
        core_bottom = height if i == len(starts) - 1 else (bottom + starts[i + 1]) // 2
        result.append((top, bottom, core_top, core_bottom))
    return result


class Reader:
    def __init__(self, out, compute_units="cpu_ne"):
        import coremltools as ct

        import ppocr

        units = {"cpu_ne": ct.ComputeUnit.CPU_AND_NE, "cpu": ct.ComputeUnit.CPU_ONLY}[compute_units]
        self.ppocr = ppocr
        self.det = ct.models.MLModel(os.path.join(out, "det.mlpackage"), compute_units=units)
        self.rec = ct.models.MLModel(os.path.join(out, "rec.mlpackage"), compute_units=units)
        characters = open(os.path.join(out, "characters.txt"), encoding="utf-8").read().split("\n")[:-1]
        self.characters = ["blank"] + characters + [" "]
        self.widest_line = 0

    def detect(self, x):
        _, _, h, w = x.shape
        sh, sw = min(((sh, sw) for sh, sw in DET_SHAPES if sh >= h and sw >= w), key=lambda s: s[0] * s[1])
        padded = np.zeros((1, 3, sh, sw), dtype=np.float32)
        padded[:, :, :h, :w] = x
        return self.det.predict({"x": padded})["prob"][0, 0, :h, :w]

    def recognize(self, crop):
        import cv2

        h, w = crop.shape[:2]
        width = int(math.ceil(REC_HEIGHT * w / h))
        self.widest_line = max(self.widest_line, width)
        width = min(width, REC_WIDTHS[-1])
        target = next(rw for rw in REC_WIDTHS if rw >= width)
        resized = (cv2.resize(crop, (width, REC_HEIGHT)).astype(np.float32) / 255.0 - 0.5) / 0.5
        x = np.zeros((1, 3, REC_HEIGHT, target), dtype=np.float32)
        x[0, :, :, :width] = resized.transpose(2, 0, 1)
        probs = self.rec.predict({"x": x})["probs"][0]
        indices, scores = probs.argmax(axis=1), probs.max(axis=1)
        keep = np.ones(len(indices), dtype=bool)
        keep[1:] = indices[1:] != indices[:-1]
        keep &= indices != 0
        text = "".join(self.characters[i] for i in indices[keep] if i < len(self.characters))
        return text, float(scores[keep].mean()) if keep.any() else 0.0

    def __call__(self, image, limit=64):
        import cv2

        ppocr = self.ppocr
        h, w = image.shape[:2]
        scale = limit / min(h, w) if min(h, w) < limit else 1.0
        scale = min(scale, MAX_WIDTH / w)
        rh, rw = max(int(round(h * scale / 32) * 32), 32), max(int(round(w * scale / 32) * 32), 32)
        resized = cv2.resize(image, (rw, rh))
        sy, sx = rh / h, rw / w
        boxes = []
        for top, bottom, core_top, core_bottom in bands(rh):
            pred = self.detect(ppocr.det_normalize(resized[top:bottom]))
            for box in ppocr.db_postprocess(pred, None, pred.shape, **DET_THRESHOLDS):
                center = box[:, 1].mean() + top
                if not core_top <= center < core_bottom:
                    continue
                box = box.copy()
                box[:, 1] += top
                box[:, 0] /= sx
                box[:, 1] /= sy
                boxes.append(box)
        boxes = ppocr.sorted_boxes(boxes)
        return [(*self.recognize(ppocr.rotate_crop(image, b)), b) for b in boxes]


def check(out, corpus, out_json, limit=SHORTEST_SIDE):
    import cv2

    import ppocr

    reader = Reader(out)
    cases = sorted(n[:-4] for n in os.listdir(corpus) if n.endswith(".png"))
    results, total = [], []
    for case in cases:
        image = cv2.imread(os.path.join(corpus, case + ".png"), cv2.IMREAD_COLOR)
        truth_file = os.path.join(corpus, case + ".truth.txt")
        truth = open(truth_file, encoding="utf-8").read() if os.path.exists(truth_file) else ""
        started = time.perf_counter()
        lines = reader(image, limit=limit)
        seconds = time.perf_counter() - started
        text = ppocr.assemble(lines)
        cer = ppocr.content_cer(text, truth)
        results.append({"case": case, "cer": cer, "ms": seconds * 1000, "lines": len(lines), "text": text})
        total.append(seconds)
        print(f"{case:28} {seconds * 1000:6.0f} ms  lines {len(lines):3}  CER {cer * 100:5.1f}%")
    json.dump({"limit": limit, "shapes": DET_SHAPES, "widths": REC_WIDTHS, "widest_line": reader.widest_line, "cases": results}, open(out_json, "w"), ensure_ascii=False, indent=1)
    times = sorted(total)
    print(f"{len(cases)} cases, p50 {times[len(times) // 2] * 1000:.0f} ms, p95 {times[int(len(times) * 0.95)] * 1000:.0f} ms, widest line {reader.widest_line} px at {REC_HEIGHT}")


def main():
    command = sys.argv[1]
    if command == "convert":
        convert(sys.argv[2], sys.argv[3])
    elif command == "check":
        limit = int(sys.argv[sys.argv.index("--limit") + 1]) if "--limit" in sys.argv else SHORTEST_SIDE
        check(sys.argv[2], sys.argv[3], sys.argv[4], limit)
    elif command == "assemble":
        option = lambda name: sys.argv[sys.argv.index(name) + 1]
        assemble(sys.argv[2], sys.argv[3], option("--license"), option("--checked"), option("--reference"))
    else:
        raise SystemExit(__doc__)


# Where the license text comes from: PaddleOCR's own LICENSE (Apache-2.0 with its copyright line; it has no NOTICE).
PADDLEOCR_LICENSE = ("https://github.com/PaddlePaddle/PaddleOCR/blob/dab3fe35379033fdcb2d0e9572fac0b36c9a9ebf/LICENSE", "dab3fe35379033fdcb2d0e9572fac0b36c9a9ebf")


def config():
    return {
        "format": 1,
        "model": "PP-OCRv6 small",
        "computeUnits": "cpuAndNeuralEngine",
        "detection": {
            "file": "det.mlpackage", "input": "x", "output": "prob",
            # Height and width the region is scaled to first: the shorter side to at least shortestSide, the width
            # to at most maxWidth, each side then rounded to a multiple of 32.
            "shortestSide": SHORTEST_SIDE, "maxWidth": MAX_WIDTH, "multiple": 32,
            "band": BAND, "overlap": OVERLAP,
            "shapes": [[h, w] for h, w in DET_SHAPES],
            # Pixel values / 255, then (value - mean) / std per channel, the channels in BGR order.
            "channels": "BGR", "mean": [0.485, 0.456, 0.406], "std": [0.229, 0.224, 0.225],
            "padding": 0,
            "threshold": DET_THRESHOLDS["thresh"], "boxThreshold": DET_THRESHOLDS["box_thresh"],
            "unclipRatio": DET_THRESHOLDS["unclip_ratio"], "minSize": 3, "maxCandidates": 3000,
        },
        "recognition": {
            "file": "rec.mlpackage", "input": "x", "output": "probs",
            "height": REC_HEIGHT, "widths": REC_WIDTHS,
            "channels": "BGR", "mean": [0.5, 0.5, 0.5], "std": [0.5, 0.5, 0.5],
            "padding": 0,
            # CTC over softmax probabilities: class 0 is the blank, 1...n the lines of characters.txt, n + 1 a space.
            "characters": "characters.txt", "blank": 0, "spaceAfterCharacters": True,
            # A crop at least this many times taller than wide is vertical text, turned a quarter to lie as a line.
            "verticalRatio": 1.5,
        },
    }


def versions():
    import coremltools
    import torch
    import transformers
    return {"coremltools": coremltools.__version__, "torch": torch.__version__, "transformers": transformers.__version__}


def mean_cer(path, key):
    cases = json.load(open(path))["cases"]
    scored = [c[key] for c in cases if (c.get("case") or c.get("id")) not in ("ko", "vertical-zh")]
    return sum(scored) / len(scored) * 100, len(scored)


def assemble(out, pack, license_file, checked, reference):
    pack_cer, count = mean_cer(checked, "cer")
    reference_cer, _ = mean_cer(reference, "cer_l2")
    score = {"pack": pack_cer, "reference": reference_cer, "count": count}
    os.makedirs(pack, exist_ok=True)
    for name in ("det.mlpackage", "rec.mlpackage"):
        target = os.path.join(pack, name)
        if os.path.exists(target):
            shutil.rmtree(target)
        shutil.copytree(os.path.join(out, name), target)
    shutil.copyfile(os.path.join(out, "characters.txt"), os.path.join(pack, "characters.txt"))
    with open(os.path.join(pack, "config.json"), "w") as f:
        json.dump(config(), f, indent=2)
        f.write("\n")
    tools = versions()
    def listed(kind):
        return "\n".join(f"    https://huggingface.co/PaddlePaddle/{repo}/tree/{revision}" for repo, revision in UPSTREAM.items() if repo.endswith(kind))
    sources, checks = listed("_safetensors"), listed("_onnx")
    notice = f"""PP-OCRv6 small, converted to Core ML for OhMyShot

The models in this repository are PaddlePaddle's PP-OCRv6 small text detection and recognition models,
Copyright (c) 2016 PaddlePaddle Authors, licensed under the Apache License, Version 2.0, below.

What was changed (Apache License 2.0, section 4(b)): the PyTorch (safetensors) weights of

{sources}

were converted to Core ML ML programs with 16-bit floating point weights and a fixed set of input sizes
(Tools/model-packs/ppocr_pack.py in https://github.com/fzlzjerry/OhMyShot, with coremltools {tools["coremltools"]},
torch {tools["torch"]}, transformers {tools["transformers"]}), after checking that they give what PaddlePaddle's own
ONNX exports give:

{checks}

The weights were not trained, tuned, or otherwise changed. characters.txt is the recognition model's character list
from its inference.yml. config.json describes the reading the app does with them.

The license text below is PaddleOCR's own ({PADDLEOCR_LICENSE[0]}).

--------------------------------------------------------------------------------

"""
    with open(os.path.join(pack, "LICENSE.txt"), "w", encoding="utf-8") as f:
        f.write(notice + open(license_file, encoding="utf-8").read())
    readme = f"""---
license: apache-2.0
library_name: coreml
pipeline_tag: image-to-text
tags:
  - ocr
  - coreml
  - pp-ocrv6
  - ohmyshot
base_model:
  - PaddlePaddle/PP-OCRv6_small_det_safetensors
  - PaddlePaddle/PP-OCRv6_small_rec_safetensors
---

# PP-OCRv6 small for Core ML (OhMyShot model pack)

PaddlePaddle's [PP-OCRv6 small](https://huggingface.co/PaddlePaddle/PP-OCRv6_small_rec_safetensors) text detection
and recognition models, converted to Core ML ML programs (16-bit floating point) for
[OhMyShot](https://github.com/fzlzjerry/OhMyShot), a screenshot app for macOS, which downloads them as a model pack to
read text that macOS's own text recognition reads poorly (Chinese-heavy interfaces, low-confidence regions). The
weights are PaddlePaddle's, unchanged; see LICENSE.txt for the license and what was changed.

| File | What it is |
| --- | --- |
| `det.mlpackage` | Text detection (DB): input `x`, 1 × 3 × H × W, output `prob`, 1 × 1 × H × W. Sizes: {", ".join(f"{h}×{w}" for h, w in DET_SHAPES)}. |
| `rec.mlpackage` | Text recognition (CTC): input `x`, 1 × 3 × {REC_HEIGHT} × W, output `probs`, softmax over {18710} classes. Widths: {", ".join(map(str, REC_WIDTHS))}. |
| `characters.txt` | The recognition model's characters, one a line: class 1 is the first line; class 0 is the blank and the class after the last line a space. |
| `config.json` | Pre- and post-processing: normalization, the bands a region is read in, detection thresholds. |
| `LICENSE.txt` | Apache License 2.0, with what was changed. |

Inputs are padded with zeros up to the smallest listed size that holds them. Run on the CPU and the Neural Engine
(`.cpuAndNeuralEngine`); macOS 27 beta's GPU path fails on these models.

Made with `Tools/model-packs/ppocr_pack.py` from these upstream revisions, and checked against PaddlePaddle's ONNX
exports of the same models:

{sources.replace("    ", "- ")}
{checks.replace("    ", "- ")}

Checked against the OhMyShot OCR benchmark (40 cases, 12 of them crops of real screenshots): every case read, mean
content character error rate {score["pack"]:.2f}% over the {score["count"]} cases scored, against {score["reference"]:.2f}% for the
same models at any input size with PaddlePaddle's own pre- and post-processing. Korean (not in the model) and
vertical Chinese (read right, but scored in another order) are left out of both.
"""
    with open(os.path.join(pack, "README.md"), "w", encoding="utf-8") as f:
        f.write(readme)
    listing = []
    for root, _, files in os.walk(pack):
        for name in sorted(files):
            path = os.path.join(root, name)
            relative = os.path.relpath(path, pack)
            import hashlib
            listing.append({"path": relative, "size": os.path.getsize(path), "sha256": hashlib.sha256(open(path, "rb").read()).hexdigest()})
    listing.sort(key=lambda f: f["path"])
    with open(os.path.join(out, "files.json"), "w") as f:
        json.dump(listing, f, indent=2)
    for item in listing:
        print(f"{item['size']:>10}  {item['sha256']}  {item['path']}")
    print(f"{sum(i['size'] for i in listing)} bytes in {len(listing)} files")


if __name__ == "__main__":
    main()
