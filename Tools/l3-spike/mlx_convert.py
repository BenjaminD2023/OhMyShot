"""A Hugging Face VLM folder to MLX with mlx-vlm: mlx_convert.py SRC DST BITS (16 for bfloat16, or 8 or 4, groups of
64; mlx-vlm leaves the vision tower unquantized). The repository's own code is never run."""
import sys
from mlx_vlm import convert
src, dst, bits = sys.argv[1], sys.argv[2], int(sys.argv[3])
if bits == 16:
    convert(src, dst, dtype="bfloat16", trust_remote_code=False)
else:
    convert(src, dst, quantize=True, q_bits=bits, q_group_size=64, trust_remote_code=False)
