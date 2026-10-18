"""PP-FormulaNet_plus-L to Core ML: an encoder (768² → the decoder's cross-attention keys and values) and a
stateful decoder step (self-attention KV cache as Core ML state, greedy next token computed in the model).

formula_convert.py MODEL_DIR OUT_DIR [MAX_TOKENS]
"""
import os, sys, time
from pathlib import Path
import numpy as np, torch, coremltools as ct

sys.path.insert(0, str(Path(__file__).parent))
import ctfix  # noqa: F401
from transformers import PPFormulaNetForConditionalGeneration

model_dir, out = sys.argv[1], Path(sys.argv[2])
MAX = int(sys.argv[3]) if len(sys.argv) > 3 else 1024
out.mkdir(parents=True, exist_ok=True)
torch.set_grad_enabled(False)
m = PPFormulaNetForConditionalGeneration.from_pretrained(model_dir, dtype=torch.float32).eval().requires_grad_(False)
m.config._attn_implementation = "eager"
dec = m.model.decoder
L = len(dec.layers); H = dec.layers[0].self_attn.num_heads; D = dec.layers[0].self_attn.head_dim; E = H * D


class Encoder(torch.nn.Module):
    def __init__(self):
        super().__init__()
        self.enc = m.model.encoder

    def forward(self, pixel_values):
        h = self.enc(pixel_values).pooler_output  # 1 x N x E
        n = h.shape[1]
        ks, vs = [], []
        for l in dec.layers:
            a = l.encoder_attn
            ks.append(a.k_proj(h).view(1, n, H, D).transpose(1, 2))
            vs.append(a.v_proj(h).view(1, n, H, D).transpose(1, 2))
        return torch.stack(ks), torch.stack(vs)  # L x 1 x H x N x D


class Step(torch.nn.Module):
    def __init__(self):
        super().__init__()
        self.register_buffer("k_cache", torch.zeros(L, 1, H, MAX, D, dtype=torch.float16))
        self.register_buffer("v_cache", torch.zeros(L, 1, H, MAX, D, dtype=torch.float16))

    def forward(self, ids, pos, mask, cross_k, cross_v):
        p = pos[0]
        x = dec.embed_tokens(ids) + dec.embed_positions.weight[pos + 2].unsqueeze(0)
        x = dec.layernorm_embedding(x)
        for i, l in enumerate(dec.layers):
            a = l.self_attn
            h = l.self_attn_layer_norm(x)
            q = a.q_proj(h).view(1, 1, H, D).transpose(1, 2)
            k = a.k_proj(h).view(1, 1, H, D).transpose(1, 2)
            v = a.v_proj(h).view(1, 1, H, D).transpose(1, 2)
            self.k_cache[i:i + 1, :, :, p:p + 1, :] = k.half()
            self.v_cache[i:i + 1, :, :, p:p + 1, :] = v.half()
            w = torch.softmax(q @ self.k_cache[i].float().transpose(-1, -2) * a.scaling + mask, -1)
            x = x + a.out_proj((w @ self.v_cache[i].float()).transpose(1, 2).reshape(1, 1, E))
            e = l.encoder_attn
            h = l.encoder_attn_layer_norm(x)
            q = e.q_proj(h).view(1, 1, H, D).transpose(1, 2)
            w = torch.softmax(q @ cross_k[i].transpose(-1, -2) * e.scaling, -1)
            x = x + e.out_proj((w @ cross_v[i]).transpose(1, 2).reshape(1, 1, E))
            h = l.final_layer_norm(x)
            x = x + l.fc2(l.activation_fn(l.fc1(h)))
        logits = m.lm_head(dec.layer_norm(x))
        return torch.argmax(logits, -1).to(torch.int32), logits


def size(path):
    return sum(os.path.getsize(os.path.join(r, f)) for r, _, fs in os.walk(path) for f in fs) / 1e6


pix = torch.randn(1, 3, 768, 768)
enc = Encoder().eval()
ck, cv = enc(pix)
N = ck.shape[3]
print(f"decoder: {L} layers, {H} heads x {D}; encoder tokens {N}; cache {MAX}")

t = time.perf_counter()
enc_ml = ct.convert(torch.jit.trace(enc, pix), inputs=[ct.TensorType(name="pixel_values", shape=pix.shape)],
                    outputs=[ct.TensorType(name="cross_k", dtype=np.float16), ct.TensorType(name="cross_v", dtype=np.float16)],
                    minimum_deployment_target=ct.target.macOS15, compute_precision=ct.precision.FLOAT16)
enc_ml.save(out / "encoder.mlpackage")
print(f"encoder converted in {time.perf_counter()-t:.0f} s, {size(out / 'encoder.mlpackage'):.1f} MB")

step = Step().eval()
ids = torch.tensor([[2]], dtype=torch.int32); pos = torch.tensor([0], dtype=torch.int32)
mask = torch.zeros(1, 1, 1, MAX)
t = time.perf_counter()
traced = torch.jit.trace(step, (ids, pos, mask, ck, cv))
step_ml = ct.convert(traced, inputs=[ct.TensorType(name="ids", shape=ids.shape, dtype=np.int32),
                                     ct.TensorType(name="pos", shape=pos.shape, dtype=np.int32),
                                     ct.TensorType(name="mask", shape=mask.shape, dtype=np.float16),
                                     ct.TensorType(name="cross_k", shape=ck.shape, dtype=np.float16),
                                     ct.TensorType(name="cross_v", shape=cv.shape, dtype=np.float16)],
                     outputs=[ct.TensorType(name="next", dtype=np.int32), ct.TensorType(name="logits", dtype=np.float16)],
                     states=[ct.StateType(ct.TensorType(shape=step.k_cache.shape, dtype=np.float16), name="k_cache"),
                             ct.StateType(ct.TensorType(shape=step.v_cache.shape, dtype=np.float16), name="v_cache")],
                     minimum_deployment_target=ct.target.macOS15, compute_precision=ct.precision.FLOAT16)
step_ml.save(out / "decoder.mlpackage")
print(f"decoder converted in {time.perf_counter()-t:.0f} s, {size(out / 'decoder.mlpackage'):.1f} MB")

# Weight-only 8-bit copies, to see what quantizing costs.
from coremltools.optimize.coreml import OpLinearQuantizerConfig, OptimizationConfig, linear_quantize_weights
cfg = OptimizationConfig(global_config=OpLinearQuantizerConfig(mode="linear_symmetric", dtype="int8", granularity="per_channel"))
for name, mm in (("encoder", enc_ml), ("decoder", step_ml)):
    q = linear_quantize_weights(mm, cfg)
    q.save(out / f"{name}_int8.mlpackage")
    print(f"{name} int8: {size(out / f'{name}_int8.mlpackage'):.1f} MB")
