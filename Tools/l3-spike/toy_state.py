"""Does a stateful (KV cache) decoder convert and run on Core ML here, and on which compute units?"""
import time, sys
import numpy as np, torch, coremltools as ct
import ctfix  # noqa

L, H, D, MAX = 4, 8, 64, 256  # layers, heads, head dim, cache length
E = H * D

class Layer(torch.nn.Module):
    def __init__(self):
        super().__init__()
        self.qkv = torch.nn.Linear(E, 3 * E); self.o = torch.nn.Linear(E, E)
        self.ff = torch.nn.Sequential(torch.nn.Linear(E, 4 * E), torch.nn.GELU(), torch.nn.Linear(4 * E, E))
        self.n1 = torch.nn.LayerNorm(E); self.n2 = torch.nn.LayerNorm(E)

class Toy(torch.nn.Module):
    def __init__(self):
        super().__init__()
        self.emb = torch.nn.Embedding(1000, E)
        self.layers = torch.nn.ModuleList(Layer() for _ in range(L))
        self.head = torch.nn.Linear(E, 1000)
        self.register_buffer("k_cache", torch.zeros(L, 1, H, MAX, D, dtype=torch.float16))
        self.register_buffer("v_cache", torch.zeros(L, 1, H, MAX, D, dtype=torch.float16))

    def forward(self, ids, mask, pos):
        # ids: 1x1, mask: 1x1x1xMAX (0 or -inf), pos: 1 (int32) position to write
        x = self.emb(ids)
        p = pos[0]
        for i, l in enumerate(self.layers):
            h = l.n1(x)
            q, k, v = l.qkv(h).split(E, -1)
            q = q.view(1, 1, H, D).transpose(1, 2); k = k.view(1, 1, H, D).transpose(1, 2); v = v.view(1, 1, H, D).transpose(1, 2)
            self.k_cache[i:i + 1, :, :, p:p + 1, :] = k.half()
            self.v_cache[i:i + 1, :, :, p:p + 1, :] = v.half()
            K = self.k_cache[i].float(); V = self.v_cache[i].float()
            a = torch.nn.functional.scaled_dot_product_attention(q, K, V, attn_mask=mask)
            x = x + l.o(a.transpose(1, 2).reshape(1, 1, E))
            x = x + l.ff(l.n2(x))
        return self.head(x)

m = Toy().eval()
ids = torch.zeros(1, 1, dtype=torch.int32); mask = torch.zeros(1, 1, 1, MAX); pos = torch.zeros(1, dtype=torch.int32)
traced = torch.jit.trace(m, (ids, mask, pos))
mlm = ct.convert(traced, inputs=[ct.TensorType("ids", ids.shape, np.int32), ct.TensorType("mask", mask.shape, np.float16),
                                 ct.TensorType("pos", pos.shape, np.int32)],
                 outputs=[ct.TensorType(name="logits", dtype=np.float16)],
                 states=[ct.StateType(ct.TensorType(shape=m.k_cache.shape, dtype=np.float16), name="k_cache"),
                         ct.StateType(ct.TensorType(shape=m.v_cache.shape, dtype=np.float16), name="v_cache")],
                 minimum_deployment_target=ct.target.macOS15, compute_precision=ct.precision.FLOAT16)
mlm.save(sys.argv[1])
for cu in ("CPU_ONLY", "CPU_AND_GPU", "CPU_AND_NE", "ALL"):
    try:
        mm = ct.models.MLModel(sys.argv[1], compute_units=getattr(ct.ComputeUnit, cu))
        st = mm.make_state()
        t = time.perf_counter(); n = 64
        for i in range(n):
            mk = np.full((1, 1, 1, MAX), -np.inf, np.float16); mk[..., : i + 1] = 0
            out = mm.predict({"ids": np.array([[i % 1000]], np.int32), "mask": mk, "pos": np.array([i], np.int32)}, st)
        dt = (time.perf_counter() - t) / n
        print(f"{cu:12} ok  {dt*1000:.2f} ms/step  logits[0,0,:3]={out['logits'][0,0,:3]}")
    except Exception as e:
        print(f"{cu:12} FAILED {type(e).__name__}: {str(e)[:200]}")
