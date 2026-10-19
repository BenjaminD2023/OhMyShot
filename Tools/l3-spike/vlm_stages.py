"""Every stage of PaddleOCR-VL reading one picture on MLX (mlx-vlm), for the Swift port to compare against.

vlm_stages.py MODEL_DIR IMAGE PROMPT OUT.safetensors [MAX_TOKENS] [cpu]
Writes pixel_values, grid_thw, input_ids, the vision tower's stages (patch embeddings, interpolated position
embeddings, the first layer's output, after the last layer's norm, the projector's output), the language model's
position ids and rope delta, the first step's logits, and the greedy tokens; prints the decoded text. "cpu" runs on
MLX's CPU device. The repository's own code is never run.
"""
import sys
import mlx.core as mx
import numpy as np
from PIL import Image
from mlx_vlm import load
from mlx_vlm.prompt_utils import apply_chat_template

model_dir, image_path, task, out = sys.argv[1:5]
max_tokens = int(sys.argv[5]) if len(sys.argv) > 5 else 256
if len(sys.argv) > 6 and sys.argv[6] == "cpu":
    mx.set_default_device(mx.cpu)

model, processor = load(model_dir)
prompt = apply_chat_template(processor, model.config, task, num_images=1)
inputs = processor(images=[Image.open(image_path).convert("RGB")], text=[prompt])
input_ids = mx.array(np.array(inputs["input_ids"]))
pixel_values = np.array(inputs["pixel_values"])
grid = mx.array(np.array(inputs["image_grid_thw"]))
stages = {"input_ids": input_ids.astype(mx.int32), "grid_thw": grid.astype(mx.int32),
          "pixel_values": mx.array(pixel_values.astype(np.float32))}

visual = model.visual
dtype = visual.embeddings.patch_embedding.weight.dtype
pixels = mx.array(pixel_values, dtype=dtype)
stages["pixels_model_dtype"] = pixels.astype(mx.float32)
patches = visual.embeddings._patch_embed(pixels)
t, h, w = grid[0].tolist()
position = visual.embeddings.interpolate_pos_encoding(h, w)
stages["patch_embeddings"] = patches.astype(mx.float32)
stages["position_embeddings"] = position.astype(mx.float32)
hidden = visual.embeddings(pixels, grid)
stages["embeddings"] = hidden.astype(mx.float32)
rotary = visual.rot_pos_emb(grid)
stages["vision_rotary"] = rotary.astype(mx.float32)
cu = visual._build_cu_seqlens(grid)
for i, layer in enumerate(visual.layers):
    hidden = layer(hidden, cu_seqlens=cu, rotary_pos_emb=rotary)
    if i == 0:
        stages["layer0"] = hidden.astype(mx.float32)
hidden = visual.post_layernorm(hidden)
stages["post_layernorm"] = hidden.astype(mx.float32)
features = visual.projector(hidden, grid)
stages["projector"] = features.astype(mx.float32)
whole = visual(pixels, grid, output_hidden_states=False)
stages["vision_whole"] = whole.astype(mx.float32)

position_ids, rope_deltas = model.language_model.get_rope_index(input_ids, grid, None, None)
stages["position_ids"] = position_ids.astype(mx.int32)
stages["rope_deltas"] = mx.array(rope_deltas).astype(mx.int32)

# Greedy, with a fresh KV cache, as mlx-vlm's generate does it.
from mlx_vlm.models.cache import KVCache
cache = [KVCache() for _ in model.language_model.layers]
# The language model is called directly after the first step, as mlx-vlm's generate does: the whole model would
# forget the image's position offsets.
embedded = model.get_input_embeddings(input_ids, pixels, image_grid_thw=grid).inputs_embeds
stages["inputs_embeds"] = embedded.astype(mx.float32)
logits = model.language_model(input_ids, inputs_embeds=embedded, cache=cache, image_grid_thw=grid).logits
stages["first_logits"] = logits[0, -1].astype(mx.float32)
tokens = []
token = mx.argmax(logits[0, -1]).item()
while len(tokens) < max_tokens:
    tokens.append(token)
    if token == 2:
        break
    logits = model.language_model(mx.array([[token]]), cache=cache, image_grid_thw=grid).logits
    if len(tokens) == 1:
        stages["second_logits"] = logits[0, -1].astype(mx.float32)
    token = mx.argmax(logits[0, -1]).item()
stages["tokens"] = mx.array(tokens, dtype=mx.int32)
mx.save_safetensors(out, stages)
text = processor.tokenizer.decode([t for t in tokens if t != 2])
print(f"{len(tokens)} tokens, grid {t}x{h}x{w}, prompt {input_ids.shape[1]} ids")
print(text)
