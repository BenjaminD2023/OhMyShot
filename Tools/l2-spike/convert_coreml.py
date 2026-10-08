"""PP-OCRv6 small (transformers' PyTorch implementation) to Core ML: parity with the ONNX models first,
then fp16 ML programs with flexible sizes (ranges) and with enumerated sizes.
Usage: convert_coreml.py MODELS OUT_DIR"""

import os
import sys
import time

import coremltools as ct
import numpy as np
import onnxruntime as ort
import torch
from transformers import PPOCRV6SmallDetForObjectDetection, PPOCRV6SmallRecForTextRecognition

models, out = sys.argv[1], sys.argv[2]
os.makedirs(out, exist_ok=True)
torch.set_grad_enabled(False)


class Det(torch.nn.Module):
    def __init__(self, model):
        super().__init__()
        self.model = model

    def forward(self, x):
        return self.model(pixel_values=x).last_hidden_state


class Rec(torch.nn.Module):
    def __init__(self, model, softmax):
        super().__init__()
        self.model = model
        self.softmax = softmax

    def forward(self, x):
        y = self.model(pixel_values=x).last_hidden_state
        return torch.softmax(y, dim=-1) if self.softmax else y


det_model = PPOCRV6SmallDetForObjectDetection.from_pretrained(os.path.join(models, "PP-OCRv6_small_det_safetensors")).eval()
rec_model = PPOCRV6SmallRecForTextRecognition.from_pretrained(os.path.join(models, "PP-OCRv6_small_rec_safetensors")).eval()

# Parity with the official ONNX exports, on random inputs of a realistic size.
rng = np.random.default_rng(0)
det_x = rng.standard_normal((1, 3, 736, 1312), dtype=np.float32)
rec_x = rng.standard_normal((2, 3, 48, 320), dtype=np.float32)
det_onnx = ort.InferenceSession(os.path.join(models, "PP-OCRv6_small_det_onnx/inference.onnx"), providers=["CPUExecutionProvider"])
rec_onnx = ort.InferenceSession(os.path.join(models, "PP-OCRv6_small_rec_onnx/inference.onnx"), providers=["CPUExecutionProvider"])
det_ref = det_onnx.run(None, {"x": det_x})[0]
rec_ref = rec_onnx.run(None, {"x": rec_x})[0]
det_torch = Det(det_model)(torch.from_numpy(det_x)).numpy()
rec_raw = rec_model(pixel_values=torch.from_numpy(rec_x)).last_hidden_state.numpy()
# The ONNX recognizer ends in a softmax; does the PyTorch head?
softmax_in_head = np.allclose(rec_raw.sum(-1), 1, atol=1e-3)
rec_torch = Rec(rec_model, not softmax_in_head)(torch.from_numpy(rec_x)).numpy()
print(f"det parity: shape {det_torch.shape} vs {det_ref.shape}, max abs diff {np.abs(det_torch - det_ref).max():.2e}")
print(f"rec parity: shape {rec_torch.shape} vs {rec_ref.shape}, max abs diff {np.abs(rec_torch - rec_ref).max():.2e}, softmax in head: {softmax_in_head}")

det_traced = torch.jit.trace(Det(det_model), torch.from_numpy(det_x))
rec_traced = torch.jit.trace(Rec(rec_model, not softmax_in_head), torch.from_numpy(rec_x[:1]))


def save(model, name):
    path = os.path.join(out, name + ".mlpackage")
    model.save(path)
    size = sum(os.path.getsize(os.path.join(root, f)) for root, _, files in os.walk(path) for f in files)
    print(f"saved {name}: {size / 1e6:.1f} MB")


common = dict(convert_to="mlprogram", compute_precision=ct.precision.FLOAT16, minimum_deployment_target=ct.target.macOS15)

# coremltools 9.0 casts a folded one-element array with int(), which NumPy 2.5 no longer allows.
from coremltools.converters.mil.frontend.torch import ops as torch_ops  # noqa: E402
from coremltools.converters.mil.mil import Builder as mb  # noqa: E402


def _cast(context, node, dtype, dtype_name):
    x = torch_ops._get_inputs(context, node, expected=1)[0]
    if not (len(x.shape) == 0 or np.all([d == 1 for d in x.shape])):
        raise ValueError("input to cast must be either a scalar or a length 1 tensor")
    if x.can_be_folded_to_const():
        res = x if isinstance(x.val, dtype) else mb.const(val=dtype(np.asarray(x.val).reshape(-1)[0]), name=node.name)
    elif len(x.shape) > 0:
        res = mb.cast(x=mb.squeeze(x=x, name=node.name + "_item"), dtype=dtype_name, name=node.name)
    else:
        res = mb.cast(x=x, dtype=dtype_name, name=node.name)
    context.add(res, node.name)


torch_ops._cast = _cast


def exists(name):
    return os.path.exists(os.path.join(out, name + ".mlpackage"))

started = time.perf_counter()
if not exists("det_small_range"):
  det_range = ct.convert(det_traced, inputs=[ct.TensorType(name="x", shape=(1, 3, ct.RangeDim(32, 4000, default=736), ct.RangeDim(32, 4000, default=1312)))], outputs=[ct.TensorType(name="prob")], **common)
  save(det_range, "det_small_range")
# Enumerated sizes: a fixed set the image is padded up to (here a grid of common region sizes).
det_sizes = [(h, w) for h in (736, 960, 1280, 1600) for w in (736, 960, 1280, 1600, 2048, 2560)]
if not exists("det_small_enum"):
  det_enum = ct.convert(det_traced, inputs=[ct.TensorType(name="x", shape=ct.EnumeratedShapes(shapes=[(1, 3, h, w) for h, w in det_sizes], default=(1, 3, 736, 1280)))], outputs=[ct.TensorType(name="prob")], **common)
  save(det_enum, "det_small_enum")

rec_range = ct.convert(rec_traced, inputs=[ct.TensorType(name="x", shape=(ct.RangeDim(1, 16, default=1), 3, 48, ct.RangeDim(48, 4000, default=320)))], outputs=[ct.TensorType(name="probs")], **common)
save(rec_range, "rec_small_range")
rec_widths = [160, 320, 480, 640, 800, 960, 1280, 1600, 2000, 2400, 3200]
rec_enum = ct.convert(rec_traced, inputs=[ct.TensorType(name="x", shape=ct.EnumeratedShapes(shapes=[(1, 3, 48, w) for w in rec_widths], default=(1, 3, 48, 320)))], outputs=[ct.TensorType(name="probs")], **common)
save(rec_enum, "rec_small_enum")
print(f"conversion took {time.perf_counter() - started:.0f} s; softmax_in_head={softmax_in_head}")
open(os.path.join(out, "rec_widths.txt"), "w").write(" ".join(map(str, rec_widths)))
open(os.path.join(out, "det_sizes.txt"), "w").write(" ".join(f"{h}x{w}" for h, w in det_sizes))
