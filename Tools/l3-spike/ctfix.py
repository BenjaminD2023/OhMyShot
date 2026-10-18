"""coremltools 9.0 + NumPy 2.5: the one-element cast fix from Tools/l2-spike/convert_coreml.py."""
import numpy as np
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
