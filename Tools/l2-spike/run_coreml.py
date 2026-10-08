"""PP-OCRv6 small as Core ML ML programs over the benchmark corpus.
Usage: run_coreml.py SCRIPTS MODELS COREML_DIR CORPUS OUT_JSON VARIANT(range|enum) UNITS(all|cpu_ne|cpu|cpu_gpu) [CASE_PREFIX...]"""

import json
import os
import resource
import sys
import time

sys.path.insert(0, sys.argv[1])
import coremltools as ct  # noqa: E402
import cv2  # noqa: E402
import numpy as np  # noqa: E402

import ppocr  # noqa: E402

models, coreml_dir, corpus, out_json, variant, units = sys.argv[2:8]
prefixes = sys.argv[8:]
compute_units = {"all": ct.ComputeUnit.ALL, "cpu_ne": ct.ComputeUnit.CPU_AND_NE, "cpu": ct.ComputeUnit.CPU_ONLY, "cpu_gpu": ct.ComputeUnit.CPU_AND_GPU}[units]

load_started = time.perf_counter()
det = ct.models.MLModel(os.path.join(coreml_dir, f"det_small_{variant}.mlpackage"), compute_units=compute_units)
det_loaded = time.perf_counter()
rec = ct.models.MLModel(os.path.join(coreml_dir, f"rec_small_{variant}.mlpackage"), compute_units=compute_units)
load_seconds = (det_loaded - load_started, time.perf_counter() - det_loaded)

det_sizes = [tuple(map(int, s.split("x"))) for s in open(os.path.join(coreml_dir, "det_sizes.txt")).read().split()]
rec_widths = list(map(int, open(os.path.join(coreml_dir, "rec_widths.txt")).read().split()))


def run_det(x):
    if variant == "range":
        return det.predict({"x": x})["prob"]
    _, _, h, w = x.shape
    # The smallest enumerated size that holds the image, padded with zeros (the mean color).
    fits = [(sh, sw) for sh, sw in det_sizes if sh >= h and sw >= w]
    if not fits:
        raise ValueError(f"no enumerated size holds {h}x{w}")
    sh, sw = min(fits, key=lambda s: s[0] * s[1])
    padded = np.zeros((1, 3, sh, sw), dtype=np.float32)
    padded[:, :, :h, :w] = x
    return det.predict({"x": padded})["prob"][:, :, :h, :w]


def run_rec(x):
    if variant == "range":
        return rec.predict({"x": x})["probs"]
    outputs = []
    for item in x:
        w = item.shape[-1]
        width = next((rw for rw in rec_widths if rw >= w), None)
        if width is None:
            raise ValueError(f"no enumerated width holds {w}")
        padded = np.zeros((1, 3, 48, width), dtype=np.float32)
        padded[0, :, :, :w] = item
        outputs.append(rec.predict({"x": padded})["probs"][0])
    length = max(o.shape[0] for o in outputs)
    # Pad the time steps with blanks so the batch stacks.
    stacked = np.zeros((len(outputs), length, outputs[0].shape[1]), dtype=np.float32)
    stacked[:, :, 0] = 1
    for i, o in enumerate(outputs):
        stacked[i, :o.shape[0]] = o
    return stacked


decoder = ppocr.Decoder(os.path.join(models, "PP-OCRv6_small_rec_onnx/inference.yml"))
pipeline = ppocr.Pipeline(run_det, run_rec, decoder, rec_batch=6 if variant == "range" else 1)

cases = sorted(n[:-4] for n in os.listdir(corpus) if n.endswith(".png") and (not prefixes or any(n.startswith(p) for p in prefixes)))
first = cv2.imread(os.path.join(corpus, cases[0] + ".png"))
warm_started = time.perf_counter()
pipeline(first)
first_call = time.perf_counter() - warm_started

results = []
for case in cases:
    image = cv2.imread(os.path.join(corpus, case + ".png"))
    truth = open(os.path.join(corpus, case + ".truth.txt")).read()
    timings = {}
    usage = resource.getrusage(resource.RUSAGE_SELF)
    try:
        lines = pipeline(image, timings)
    except ValueError as error:
        print(f"{case:24} skipped: {error}")
        continue
    after = resource.getrusage(resource.RUSAGE_SELF)
    text = ppocr.assemble(lines)
    results.append({"id": case, "ms": timings["total"] * 1000, "det_ms": timings["det"] * 1000, "rec_ms": timings["rec"] * 1000,
                    "cpu_ms": ((after.ru_utime - usage.ru_utime) + (after.ru_stime - usage.ru_stime)) * 1000,
                    "lines": timings["lines"], "cer_l2": ppocr.content_cer(text, truth), "text": text})
    r = results[-1]
    print(f"{case:24} {r['ms']:7.0f} ms (det {r['det_ms']:5.0f}, rec {r['rec_ms']:5.0f}, cpu {r['cpu_ms']:6.0f}) lines {r['lines']:3}  CER {r['cer_l2']*100:5.1f}%", flush=True)

json.dump({"variant": variant, "units": units, "load_s": load_seconds, "first_call_s": first_call, "cases": results}, open(out_json, "w"), ensure_ascii=False, indent=1)
times = sorted(r["ms"] for r in results)
print(f"{variant}/{units}: load det {load_seconds[0]*1000:.0f} ms rec {load_seconds[1]*1000:.0f} ms, first call {first_call*1000:.0f} ms, "
      f"p50 {times[len(times)//2]:.0f} ms, p95 {times[int(round(0.95*(len(times)-1)))]:.0f} ms, cpu total {sum(r['cpu_ms'] for r in results)/1000:.1f} s over {len(results)} cases")
