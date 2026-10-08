"""PP-OCRv6 on ONNX Runtime over the benchmark corpus: time per image, CPU time, and content CER next
to L1's. Usage: run_ort.py SCRIPTS MODELS CORPUS L1_JSON OUT_JSON PROVIDER(cpu|coreml) SIZE(small|tiny)"""

import json
import os
import resource
import sys
import time

sys.path.insert(0, sys.argv[1])
import cv2  # noqa: E402
import numpy as np  # noqa: E402
import onnxruntime as ort  # noqa: E402

import ppocr  # noqa: E402

models, corpus, l1_json, out_json, provider, size = sys.argv[2:8]

if provider == "coreml":
    providers = [("CoreMLExecutionProvider", {"ModelFormat": "MLProgram", "MLComputeUnits": "ALL", "RequireStaticInputShapes": "0"}), "CPUExecutionProvider"]
else:
    providers = ["CPUExecutionProvider"]

options = ort.SessionOptions()
if os.environ.get("ORT_VERBOSE"):
    options.log_severity_level = 0

load_started = time.perf_counter()
det = ort.InferenceSession(os.path.join(models, f"PP-OCRv6_{size}_det_onnx/inference.onnx"), options, providers=providers)
rec = ort.InferenceSession(os.path.join(models, f"PP-OCRv6_{size}_rec_onnx/inference.onnx"), options, providers=providers)
load_seconds = time.perf_counter() - load_started
decoder = ppocr.Decoder(os.path.join(models, f"PP-OCRv6_{size}_rec_onnx/inference.yml"))
pipeline = ppocr.Pipeline(lambda x: det.run(None, {"x": x})[0], lambda x: rec.run(None, {"x": x})[0], decoder)

l1 = {c["id"]: c for c in json.load(open(l1_json))[0]["cases"]}
cases = sorted(n[:-4] for n in os.listdir(corpus) if n.endswith(".png"))

# The first call compiles and warms up; timed apart.
first = cv2.imread(os.path.join(corpus, cases[0] + ".png"))
warm_started = time.perf_counter()
pipeline(first)
first_call = time.perf_counter() - warm_started

results = []
for case in cases:
    image = cv2.imread(os.path.join(corpus, case + ".png"))
    truth = open(os.path.join(corpus, case + ".truth.txt")).read()
    l1_text = open(os.path.join(corpus, case + ".l1.txt")).read()
    timings = {}
    usage = resource.getrusage(resource.RUSAGE_SELF)
    lines = pipeline(image, timings)
    after = resource.getrusage(resource.RUSAGE_SELF)
    text = ppocr.assemble(lines)
    results.append({
        "id": case,
        "size": [image.shape[1], image.shape[0]],
        "ms": timings["total"] * 1000,
        "det_ms": timings["det"] * 1000,
        "rec_ms": timings["rec"] * 1000,
        "post_ms": timings["post"] * 1000,
        "cpu_ms": ((after.ru_utime - usage.ru_utime) + (after.ru_stime - usage.ru_stime)) * 1000,
        "lines": timings["lines"],
        "cer_l2": ppocr.content_cer(text, truth),
        "cer_l1_python": ppocr.content_cer(l1_text, truth),
        "cer_l1_bench": l1.get(case, {}).get("score", {}).get("cerContent"),
        "l1_ms": l1.get(case, {}).get("milliseconds"),
        "text": text,
    })
    print(f"{case:24} {results[-1]['ms']:7.0f} ms (det {results[-1]['det_ms']:5.0f}, rec {results[-1]['rec_ms']:5.0f}, cpu {results[-1]['cpu_ms']:6.0f}) "
          f"lines {timings['lines']:3}  CER L2 {results[-1]['cer_l2']*100:5.1f}%  L1 {results[-1]['cer_l1_python']*100:5.1f}% (bench {(results[-1]['cer_l1_bench'] or 0)*100:5.1f}%)", flush=True)

json.dump({"provider": provider, "size": size, "load_s": load_seconds, "first_call_s": first_call, "cases": results}, open(out_json, "w"), ensure_ascii=False, indent=1)
times = sorted(r["ms"] for r in results)
print(f"load {load_seconds*1000:.0f} ms, first call {first_call*1000:.0f} ms, p50 {times[len(times)//2]:.0f} ms, p95 {times[int(round(0.95*(len(times)-1)))]:.0f} ms")
