"""PaddleOCR-VL-1.6's language model (ERNIE-4.5-0.3B) as stateful Core ML: parity with transformers, sizes,
and decode / prefill speed per compute unit. The vision tower is not part of this.

vlm_text_coreml.py MODEL_DIR OUT_DIR
"""
import os, sys, time
from pathlib import Path
import numpy as np, torch, coremltools as ct

sys.path.insert(0, str(Path(__file__).parent))
import ctfix  # noqa: F401
from usage import usage
from transformers import PaddleOCRVLForConditionalGeneration

model_dir, out = sys.argv[1], Path(sys.argv[2])
out.mkdir(parents=True, exist_ok=True)
MAX = 2048
torch.set_grad_enabled(False)
full = PaddleOCRVLForConditionalGeneration.from_pretrained(model_dir, dtype=torch.float32).eval().requires_grad_(False)
lm = full.model.language_model
head = full.lm_head
cfg = lm.config
L, H, KV, D, E = cfg.num_hidden_layers, cfg.num_attention_heads, cfg.num_key_value_heads, cfg.head_dim, cfg.hidden_size
G = H // KV
print(f"text model: {L} layers, {H} heads / {KV} kv x {D}, hidden {E}, vocab {cfg.vocab_size}")


def rope(position_ids):  # 3 x 1 x T  ->  cos, sin  1 x T x D
    x = torch.zeros(1, 1, E)
    return lm.rotary_emb(x, position_ids)


def rot(x):
    a, b = x[..., : D // 2], x[..., D // 2:]
    return torch.cat((-b, a), -1)


class Step(torch.nn.Module):
    def __init__(self, T):
        super().__init__()
        self.T = T
        self.lm, self.head = lm, head
        self.register_buffer("k_cache", torch.zeros(L, 1, KV, MAX, D, dtype=torch.float16))
        self.register_buffer("v_cache", torch.zeros(L, 1, KV, MAX, D, dtype=torch.float16))

    def forward(self, embeds, cos, sin, mask, pos):
        T = self.T
        p = pos[0]
        x = embeds.float()
        c = cos.unsqueeze(1); s = sin.unsqueeze(1)
        for i, layer in enumerate(self.lm.layers):
            a = layer.self_attn
            h = layer.input_layernorm(x)
            q = a.q_proj(h).view(1, T, H, D).transpose(1, 2)
            k = a.k_proj(h).view(1, T, KV, D).transpose(1, 2)
            v = a.v_proj(h).view(1, T, KV, D).transpose(1, 2)
            q = q * c + rot(q) * s
            k = k * c + rot(k) * s
            self.k_cache[i:i + 1, :, :, p:p + T, :] = k.half()
            self.v_cache[i:i + 1, :, :, p:p + T, :] = v.half()
            K = self.k_cache[i].float(); V = self.v_cache[i].float()          # 1 x KV x MAX x D
            qg = q.reshape(1, KV, G * T, D)                                          # query heads grouped by kv head
            w = torch.softmax(qg @ K.transpose(-1, -2) * a.scaling + mask.repeat(1, 1, G, 1), -1)
            o = (w @ V).reshape(1, H, T, D).transpose(1, 2).reshape(1, T, H * D)
            x = x + a.o_proj(o)
            x = x + layer.mlp(layer.post_attention_layernorm(x))
        logits = self.head(self.lm.norm(x[:, -1:, :]))
        return torch.argmax(logits, -1).to(torch.int32), logits


def size(path):
    return sum(os.path.getsize(os.path.join(r, f)) for r, _, fs in os.walk(path) for f in fs) / 1e6


# Parity of the wrapper against transformers, 12 tokens at once.
T0 = 12
emb = torch.randn(1, T0, E) * 0.02
pid = torch.arange(T0).view(1, 1, T0).expand(3, 1, T0)
ref = head(lm(inputs_embeds=emb, position_ids=pid).last_hidden_state)[:, -1]
cos, sin = rope(pid)
mask = torch.full((1, 1, T0, MAX), float("-inf")); mask[..., :T0] = torch.triu(torch.full((T0, T0), float("-inf")), 1)
w = Step(T0)
mine = w(emb.half(), cos, sin, mask, torch.tensor([0], dtype=torch.int32))[1][:, -1]
print(f"wrapper vs transformers: max |dlogit| {float((mine - ref).abs().max()):.3e}, argmax equal {bool(mine.argmax() == ref.argmax())}")

models = {}
for T in (1, 64):
    st = Step(T).eval()
    ex = (torch.zeros(1, T, E, dtype=torch.float16), torch.zeros(1, T, D), torch.zeros(1, T, D), torch.zeros(1, 1, T, MAX), torch.zeros(1, dtype=torch.int32))
    t = time.perf_counter()
    ml = ct.convert(torch.jit.trace(st, ex),
                    inputs=[ct.TensorType(name="embeds", shape=(1, T, E), dtype=np.float16),
                            ct.TensorType(name="cos", shape=(1, T, D), dtype=np.float16),
                            ct.TensorType(name="sin", shape=(1, T, D), dtype=np.float16),
                            ct.TensorType(name="mask", shape=(1, 1, T, MAX), dtype=np.float16),
                            ct.TensorType(name="pos", shape=(1,), dtype=np.int32)],
                    outputs=[ct.TensorType(name="next", dtype=np.int32), ct.TensorType(name="logits", dtype=np.float16)],
                    states=[ct.StateType(ct.TensorType(shape=st.k_cache.shape, dtype=np.float16), name="k_cache"),
                            ct.StateType(ct.TensorType(shape=st.v_cache.shape, dtype=np.float16), name="v_cache")],
                    minimum_deployment_target=ct.target.macOS15, compute_precision=ct.precision.FLOAT16)
    p = out / f"text_t{T}.mlpackage"; ml.save(p); models[T] = ml
    print(f"T={T}: converted in {time.perf_counter()-t:.0f} s, {size(p):.0f} MB")

from coremltools.optimize.coreml import OpLinearQuantizerConfig, OptimizationConfig, linear_quantize_weights
for name, qc in (("int8", OpLinearQuantizerConfig(mode="linear_symmetric", dtype="int8", granularity="per_channel")),
                 ("int4", OpLinearQuantizerConfig(mode="linear_symmetric", dtype="int4", granularity="per_block", block_size=32))):
    q = linear_quantize_weights(models[1], OptimizationConfig(global_config=qc))
    p = out / f"text_t1_{name}.mlpackage"; q.save(p)
    print(f"T=1 {name}: {size(p):.0f} MB")

# Core ML vs the wrapper on the 12-token check, through the T=1 model one token at a time.
ml1 = ct.models.MLModel(str(out / "text_t1.mlpackage"), compute_units=ct.ComputeUnit.CPU_ONLY)
state = ml1.make_state()
m1 = np.full((1, 1, 1, MAX), -np.inf, np.float16)
for i in range(T0):
    m1[..., i] = 0
    r = ml1.predict({"embeds": emb[:, i:i + 1].half().numpy(), "cos": cos[:, i:i + 1].numpy().astype(np.float16),
                     "sin": sin[:, i:i + 1].numpy().astype(np.float16), "mask": m1, "pos": np.array([i], np.int32)}, state)
cm = torch.from_numpy(r["logits"].astype(np.float32)).view(-1)
print(f"Core ML (cpu, fp16) vs transformers: max |dlogit| {float((cm - ref.view(-1)).abs().max()):.3e}, "
      f"argmax equal {bool(cm.argmax() == ref.argmax())}, cosine {float(torch.nn.functional.cosine_similarity(cm, ref.view(-1), 0)):.5f}")
