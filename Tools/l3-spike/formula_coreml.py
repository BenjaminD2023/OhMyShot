"""Read the formula corpus with the Core ML encoder + stateful decoder step (greedy).

formula_coreml.py MODEL_DIR COREML_DIR CORPUS_DIR OUT.json ENC_UNITS DEC_UNITS [SUFFIX] [GLOB]
units: cpu | gpu | ne | all ; SUFFIX "" or "_int8"
"""
import json, sys, time
from pathlib import Path
import numpy as np, coremltools as ct
from PIL import Image
from transformers import AutoProcessor

sys.path.insert(0, str(Path(__file__).parent))
from usage import usage
from darkfix import light

UNITS = {"cpu": ct.ComputeUnit.CPU_ONLY, "gpu": ct.ComputeUnit.CPU_AND_GPU, "ne": ct.ComputeUnit.CPU_AND_NE, "all": ct.ComputeUnit.ALL}
model_dir, cm, corpus, out = sys.argv[1], Path(sys.argv[2]), Path(sys.argv[3]), Path(sys.argv[4])
eu, du = sys.argv[5], sys.argv[6]
suffix = sys.argv[7] if len(sys.argv) > 7 else ""
pattern = sys.argv[8] if len(sys.argv) > 8 else "f*_*.png"
processor = AutoProcessor.from_pretrained(model_dir)
t = time.perf_counter()
enc = ct.models.MLModel(str(cm / f"encoder{suffix}.mlpackage"), compute_units=UNITS[eu])
dec = ct.models.MLModel(str(cm / f"decoder{suffix}.mlpackage"), compute_units=UNITS[du])
load = time.perf_counter() - t
MAX = dec.get_spec().description.input[2].type.multiArrayType.shape[-1]
EOS = 2

preds, rows = {}, []
for png in sorted(corpus.glob(pattern)):
    image = light(Image.open(png))
    t0 = time.perf_counter()
    pix = processor(images=image, return_tensors="np")["pixel_values"].astype(np.float32)
    t1 = time.perf_counter()
    e = enc.predict({"pixel_values": pix})
    t2 = time.perf_counter()
    state = dec.make_state()
    mask = np.full((1, 1, 1, MAX), -np.inf, np.float16)
    tok, out_ids = 2, []
    for i in range(MAX):
        mask[..., i] = 0
        r = dec.predict({"ids": np.array([[tok]], np.int32), "pos": np.array([i], np.int32), "mask": mask,
                         "cross_k": e["cross_k"], "cross_v": e["cross_v"]}, state)
        tok = int(r["next"].reshape(-1)[0])
        if tok == EOS:
            break
        out_ids.append(tok)
    t3 = time.perf_counter()
    text = processor.post_process(np.array([out_ids]))[0]
    preds[png.stem] = text
    n = len(out_ids) + 1
    rows.append((t1 - t0, t2 - t1, (t3 - t2) / n, t3 - t0, n))
    print(f"{png.stem}: enc {1000*(t2-t1):.0f} ms, {n} steps at {1000*(t3-t2)/n:.1f} ms, total {1000*(t3-t0):.0f} ms: {text}", flush=True)

out.write_text(json.dumps(preds, ensure_ascii=False, indent=0))
tot = sorted(r[3] for r in rows)
print(f"[{eu}/{du}{suffix}] load {load:.1f} s; encoder p50 {1000*np.median([r[1] for r in rows]):.0f} ms; "
      f"step p50 {1000*np.median([r[2] for r in rows]):.2f} ms; total p50 {1000*tot[len(tot)//2]:.0f} ms, "
      f"p95 {1000*tot[int(len(tot)*0.95)]:.0f} ms; mean steps {np.mean([r[4] for r in rows]):.1f}")
print(usage())
