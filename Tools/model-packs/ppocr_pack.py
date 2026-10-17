"""Builds the PP-OCRv6 small model pack (Docs/ocr.md › L2 runtime, › Model packs) and checks it.

    python3 -I Tools/model-packs/ppocr_pack.py convert MODELS OUT
        Core ML fp16 ML programs with the pack's enumerated shapes, from the pinned upstream revisions in MODELS
        (each repository in its own folder, as Tools/l2-spike/README.md fetches them), after checking them
        against the official ONNX exports. The recognizer ends at its encoder; its last layer, the linear map to
        the classes, is written apart as head.bin (pack format 2, Docs/ocr.md › The recognizer's head on the CPU).
    python3 -I Tools/model-packs/ppocr_pack.py check OUT CORPUS OUT_JSON [--limit 736]
        Reads the OCR benchmark's corpus (ocr-bench --save) through the pack as the app will: in bands, each
        line kept by the band holding its center, every input padded up to an enumerated shape.
    python3 -I Tools/model-packs/ppocr_pack.py assemble OUT PACK --license PADDLEOCR_LICENSE --checked CHECK_JSON --reference REF_JSON [--detection EARLIER_PACK]
        The pack's files in PACK: the two models, head.bin, characters.txt, config.json, LICENSE.txt, README.md (with
        the benchmark's means from the check above and from Tools/l2-spike/run_coreml.py's flexible-size run). With
        --detection, det.mlpackage is an earlier pack's, its weights checked to be OUT's: a conversion writes the same
        weights with another date and other identifiers, and the published files then stay as they were.

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
# The recognizer's head: a linear map from the encoder's HEAD_INPUTS features at each step to CLASSES classes (the CTC
# blank, the characters, a space), then a softmax. On the Neural Engine its [steps, CLASSES] output crossed to the CPU
# for the softmax, and Core ML kept that crossing's buffers for every width, about 760 MB over the twelve; so the
# pack's recognizer ends at the encoder, and the reader applies the head: head.bin holds its weights, CLASSES ×
# HEAD_INPUTS row by row, then its CLASSES biases, as little-endian 16-bit floats.
HEAD_INPUTS = 120
CLASSES = 18710
# One step of the encoder's output for every 8 pixels of a line's width.
REC_STRIDE = 8


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

    # The recognizer up to its head: the backbone, then the head's encoder.
    class Features(torch.nn.Module):
        def __init__(self, model):
            super().__init__()
            self.model = model

        def forward(self, x):
            features = self.model.model(pixel_values=x).last_hidden_state
            return self.model.head.encoder(features).last_hidden_state

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
    # The model up to its head, and the head applied as the reader applies it, give the whole model's probabilities.
    head = rec_model.head.head
    weight, bias = head.weight.detach().numpy(), head.bias.detach().numpy()
    assert weight.shape == (CLASSES, HEAD_INPUTS) and bias.shape == (CLASSES,), f"head {weight.shape}, {bias.shape}"
    features_torch = Features(rec_model)(torch.from_numpy(rec_x)).numpy()
    assert features_torch.shape == (1, 320 // REC_STRIDE, HEAD_INPUTS), features_torch.shape
    split_diff = float(np.abs(softmax(features_torch[0] @ weight.T + bias) - rec_torch[0]).max())
    print(f"the model up to its head, then the head: {split_diff:.2e} from the whole model")
    assert split_diff < 1e-5
    # Its weights as the pack keeps them, 16-bit, still choose the ONNX export's class at every step.
    half = half_head(weight, bias)
    assert (head_logits(features_torch[0], *half).argmax(-1) == rec_ref[0].argmax(-1)).all()

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
        torch.jit.trace(Features(rec_model).eval(), torch.from_numpy(rec_x)),
        inputs=[ct.TensorType(name="x", shape=ct.EnumeratedShapes(shapes=[(1, 3, REC_HEIGHT, w) for w in REC_WIDTHS], default=(1, 3, REC_HEIGHT, 320)))],
        outputs=[ct.TensorType(name="features")], **common,
    )
    rec.short_description = "PP-OCRv6 small text recognition (CTC) up to its last layer (head.bin), converted to Core ML for OhMyShot"
    rec.license = "Apache-2.0"
    rec.save(os.path.join(out, "rec.mlpackage"))
    print(f"converted in {time.perf_counter() - started:.0f} s")
    with open(os.path.join(out, "head.bin"), "wb") as f:
        f.write(half[0].astype("<f2").tobytes() + half[1].astype("<f2").tobytes())
    assert os.path.getsize(os.path.join(out, "head.bin")) == (CLASSES * HEAD_INPUTS + CLASSES) * 2
    import yaml
    characters = [str(c) for c in yaml.safe_load(open(os.path.join(models, "PP-OCRv6_small_rec_safetensors", "inference.yml")))["PostProcess"]["character_dict"]]
    classes = rec_torch.shape[-1]
    # CTC: the blank at 0, then the dictionary, then a space.
    assert classes == len(characters) + 2, f"{classes} classes for {len(characters)} characters"
    with open(os.path.join(out, "characters.txt"), "w", encoding="utf-8") as f:
        f.write("\n".join(characters) + "\n")
    print(f"{len(characters)} characters, {classes} classes")


# ---------------------------------------------------------------- the head, as the reader applies it

def softmax(logits):
    exp = np.exp(logits - logits.max(-1, keepdims=True))
    return exp / exp.sum(-1, keepdims=True)


def half_head(weight, bias):
    """The head's weights and biases as head.bin keeps them, 16-bit, read back as 32-bit floats."""
    return weight.astype(np.float16).astype(np.float32), bias.astype(np.float16).astype(np.float32)


def read_head(out):
    values = np.fromfile(os.path.join(out, "head.bin"), dtype="<f2").astype(np.float32)
    assert values.size == CLASSES * HEAD_INPUTS + CLASSES, f"head.bin holds {values.size} values"
    return values[:CLASSES * HEAD_INPUTS].reshape(CLASSES, HEAD_INPUTS), values[CLASSES * HEAD_INPUTS:]


def head_logits(features, weight, bias):
    """[steps, CLASSES] logits of [steps, HEAD_INPUTS] features, in 32-bit floats."""
    return features.astype(np.float32) @ weight.T + bias


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
        self.head = read_head(out)
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
        features = self.rec.predict({"x": x})["features"][0]
        logits = head_logits(features, *self.head)
        # The likeliest class at each step, and its softmax probability: 1 / Σ exp(logit - the largest).
        indices = logits.argmax(axis=1)
        scores = 1 / np.exp(logits - logits.max(axis=1, keepdims=True)).sum(axis=1)
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
        detection = option("--detection") if "--detection" in sys.argv else None
        assemble(sys.argv[2], sys.argv[3], option("--license"), option("--checked"), option("--reference"), detection)
    else:
        raise SystemExit(__doc__)


# Where the license text comes from: PaddleOCR's own LICENSE (Apache-2.0 with its copyright line; it has no NOTICE).
PADDLEOCR_LICENSE = ("https://github.com/PaddlePaddle/PaddleOCR/blob/dab3fe35379033fdcb2d0e9572fac0b36c9a9ebf/LICENSE", "dab3fe35379033fdcb2d0e9572fac0b36c9a9ebf")


def config():
    return {
        "format": 2,
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
            "file": "rec.mlpackage", "input": "x", "output": "features",
            "height": REC_HEIGHT, "widths": REC_WIDTHS,
            "channels": "BGR", "mean": [0.5, 0.5, 0.5], "std": [0.5, 0.5, 0.5],
            "padding": 0,
            # The model's output, [1, steps, inputs] features, goes through the head (HEAD_INPUTS above) to the classes'
            # logits, and a softmax gives their probabilities.
            "head": {"file": "head.bin", "type": "float16", "inputs": HEAD_INPUTS, "classes": CLASSES},
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


def assemble(out, pack, license_file, checked, reference, detection=None):
    pack_cer, count = mean_cer(checked, "cer")
    reference_cer, _ = mean_cer(reference, "cer_l2")
    score = {"pack": pack_cer, "reference": reference_cer, "count": count}
    os.makedirs(pack, exist_ok=True)
    # A reader compiles the models into the folder it loads (Compiled/): never into the pack that is published.
    assert not os.path.exists(os.path.join(pack, "Compiled")), f"{pack} was read from"
    weights = "det.mlpackage/Data/com.apple.CoreML/weights/weight.bin"
    if detection:
        same = open(os.path.join(detection, weights), "rb").read() == open(os.path.join(out, weights), "rb").read()
        assert same, f"{detection}'s detection weights aren't the ones converted"
    for name, source in (("det.mlpackage", detection or out), ("rec.mlpackage", out)):
        target = os.path.join(pack, name)
        if os.path.exists(target):
            shutil.rmtree(target)
        shutil.copytree(os.path.join(source, name), target)
    for name in ("head.bin", "characters.txt"):
        shutil.copyfile(os.path.join(out, name), os.path.join(pack, name))
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

The recognition model's last layer, the linear map from its {HEAD_INPUTS} features to its {CLASSES:,} classes, is not in
rec.mlpackage: its weights and biases are in head.bin, as 16-bit floating point numbers, and the app applies it and the
softmax after it. The weights were not trained, tuned, or otherwise changed. characters.txt is the recognition model's
character list from its inference.yml. config.json describes the reading the app does with them.

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
| `rec.mlpackage` | Text recognition (CTC) up to its last layer: input `x`, 1 × 3 × {REC_HEIGHT} × W, output `features`, 1 × W/{REC_STRIDE} × {HEAD_INPUTS}. Widths: {", ".join(map(str, REC_WIDTHS))}. |
| `head.bin` | The recognizer's last layer, a linear map from the {HEAD_INPUTS} features to {CLASSES:,} classes: its weights ({CLASSES:,} × {HEAD_INPUTS}, row by row), then its {CLASSES:,} biases, little-endian 16-bit floats. A softmax over its output gives the classes' probabilities. |
| `characters.txt` | The recognition model's characters, one a line: class 1 is the first line; class 0 is the blank and the class after the last line a space. |
| `config.json` | Pre- and post-processing: normalization, the bands a region is read in, detection thresholds. |
| `LICENSE.txt` | Apache License 2.0, with what was changed. |

Inputs are padded with zeros up to the smallest listed size that holds them. Run on the CPU and the Neural Engine
(`.cpuAndNeuralEngine`); macOS 27 beta's GPU path fails on these models.

This is version 2 of the pack (`config.json` format 2). Version 1's recognizer ended in the last layer and its softmax;
on the Neural Engine its output, a probability for each class at every step, crossed to the CPU, and Core ML kept
that crossing's memory for every width a reader used. Applied on the CPU instead, the last layer reads the same text
with a fraction of the memory.

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
