"""Decode and prefill speed of the Core ML text model per compute unit.

vlm_text_speed.py COREML_DIR UNITS [SUFFIX]   (UNITS cpu|gpu|ne|all; SUFFIX "" or "_int8")
"""
import sys, time
from pathlib import Path
import numpy as np, coremltools as ct

sys.path.insert(0, str(Path(__file__).parent))
from usage import usage

UNITS = {"cpu": ct.ComputeUnit.CPU_ONLY, "gpu": ct.ComputeUnit.CPU_AND_GPU, "ne": ct.ComputeUnit.CPU_AND_NE, "all": ct.ComputeUnit.ALL}
d, u = Path(sys.argv[1]), sys.argv[2]
suffix = sys.argv[3] if len(sys.argv) > 3 else ""
MAX, E, D = 2048, 1024, 128
rng = np.random.default_rng(0)

def inputs(T, start):
    mask = np.full((1, 1, T, MAX), -np.inf, np.float16)
    for r in range(T):
        mask[0, 0, r, : start + r + 1] = 0
    ang = (np.arange(start, start + T)[:, None] * (1 / 500000 ** (np.arange(0, D, 2) / D))[None]).astype(np.float32)
    ang = np.concatenate([ang, ang], -1)[None]
    return {"embeds": (rng.standard_normal((1, T, E)) * 0.02).astype(np.float16), "cos": np.cos(ang).astype(np.float16),
            "sin": np.sin(ang).astype(np.float16), "mask": mask, "pos": np.array([start], np.int32)}

t = time.perf_counter()
dec = ct.models.MLModel(str(d / f"text_t1{suffix}.mlpackage"), compute_units=UNITS[u])
load1 = time.perf_counter() - t
st = dec.make_state()
times = []
for i in range(160):
    x = inputs(1, i)
    t = time.perf_counter(); dec.predict(x, st); times.append(time.perf_counter() - t)
step = float(np.median(times[10:]))
line = f"[{u}{suffix}] decode load {load1:.1f} s, step p50 {1000*step:.2f} ms = {1/step:.0f} tok/s"
if not suffix:
    t = time.perf_counter()
    pre = ct.models.MLModel(str(d / "text_t64.mlpackage"), compute_units=UNITS[u])
    load64 = time.perf_counter() - t
    st = pre.make_state()
    pre.predict(inputs(64, 0), st)  # warm
    st = pre.make_state()
    t = time.perf_counter()
    for c in range(16):  # 1024 prompt tokens
        pre.predict(inputs(64, 64 * c), st)
    pf = time.perf_counter() - t
    line += f"; prefill load {load64:.1f} s, 1024 tokens in {pf:.2f} s = {1024/pf:.0f} tok/s"
print(line)
print(usage())
