"""PP-FormulaNet_plus-L in PyTorch (transformers): the reference reading of the formula corpus.

formula_torch.py MODEL_DIR CORPUS_DIR OUT.json [cpu|mps] [GLOB]
Dark pictures are inverted first (darkfix.py): the model reads dark ink on light paper.
"""
import json, sys, time
from pathlib import Path
import torch
from PIL import Image
from transformers import AutoProcessor, PPFormulaNetForConditionalGeneration

sys.path.insert(0, str(Path(__file__).parent))
from usage import usage
from darkfix import light

model_dir, corpus, out = sys.argv[1], Path(sys.argv[2]), Path(sys.argv[3])
device = sys.argv[4] if len(sys.argv) > 4 else "cpu"
torch.set_grad_enabled(False)
processor = AutoProcessor.from_pretrained(model_dir)
model = PPFormulaNetForConditionalGeneration.from_pretrained(model_dir, dtype=torch.float32).to(device).eval()
preds, times, tokens = {}, {}, {}
pattern = sys.argv[5] if len(sys.argv) > 5 else "f*_*.png"
for png in sorted(corpus.glob(pattern)):
    image = light(Image.open(png))
    t = time.perf_counter()
    inputs = processor(images=image, return_tensors="pt").to(device)
    ids = model.generate(**inputs, max_new_tokens=1024, do_sample=False)
    text = processor.post_process(ids)[0]
    times[png.stem] = time.perf_counter() - t
    tokens[png.stem] = int(ids.shape[-1])
    preds[png.stem] = text
    print(f"{png.stem}: {times[png.stem]*1000:.0f} ms, {tokens[png.stem]} tokens: {text}", flush=True)
out.write_text(json.dumps(preds, ensure_ascii=False, indent=0))
ts = sorted(times.values())
print(f"p50 {ts[len(ts)//2]*1000:.0f} ms, p95 {ts[int(len(ts)*0.95)]*1000:.0f} ms, mean tokens {sum(tokens.values())/len(tokens):.1f}")
print(usage())
print("pixel_values", tuple(inputs["pixel_values"].shape), inputs["pixel_values"].dtype)
