"""Read images with a document VLM on MLX (mlx-vlm), greedy.

vlm_mlx.py MODEL_PATH PROMPT OUT.json IMAGE...
Records per image: text, prompt tokens, generated tokens, prefill and decode speed, wall time.
"""
import json, sys, time
from pathlib import Path
import mlx.core as mx
from mlx_vlm import load, generate
from mlx_vlm.prompt_utils import apply_chat_template

sys.path.insert(0, str(Path(__file__).parent))
from usage import usage

model_path, task, out = sys.argv[1], sys.argv[2], Path(sys.argv[3])
images = sys.argv[4:]
t = time.perf_counter()
model, processor = load(model_path)
load_s = time.perf_counter() - t
config = model.config
prompt = apply_chat_template(processor, config, task, num_images=1)
results = {}
# One unscored warm-up so the first image doesn't carry Metal's kernel compilation.
generate(model, processor, prompt, image=[images[0]], max_tokens=8, temperature=0.0, verbose=False)
for path in images:
    mx.reset_peak_memory()
    t = time.perf_counter()
    r = generate(model, processor, prompt, image=[path], max_tokens=2048, temperature=0.0, verbose=False)
    wall = time.perf_counter() - t
    results[Path(path).stem] = {"text": r.text, "prompt_tokens": r.prompt_tokens, "tokens": r.generation_tokens,
                                "prefill_tps": r.prompt_tps, "decode_tps": r.generation_tps, "wall": wall,
                                "peak_gb": r.peak_memory}
    print(f"{Path(path).stem}: {wall:.2f} s, prompt {r.prompt_tokens} tok at {r.prompt_tps:.0f}/s, "
          f"{r.generation_tokens} tok at {r.generation_tps:.0f}/s: {r.text[:120]!r}", flush=True)
out.write_text(json.dumps(results, ensure_ascii=False, indent=0))
u = usage()
walls = sorted(v["wall"] for v in results.values())
print(f"[{Path(model_path).name} {task}] load {load_s:.1f} s; wall p50 {walls[len(walls)//2]:.2f} s p95 {walls[int(len(walls)*0.95)]:.2f} s; "
      f"decode {sum(v['tokens'] for v in results.values())/sum(v['tokens']/max(v['decode_tps'],1e-9) for v in results.values()):.0f} tok/s; "
      f"mlx peak {mx.get_peak_memory()/2**30:.2f} GB; footprint peak {u['peak_footprint_mb']:.0f} MB; cpu {u['cpu_s']:.1f} s, "
      f"cpu energy {u['cpu_energy_j']:.0f} J")
