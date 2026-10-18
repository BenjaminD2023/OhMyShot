# L3 spike

How the L3 choices were measured (Docs/ocr.md › L3 spike): formula recognition (PP-FormulaNet_plus-L on Core ML) and
document VLMs (PaddleOCR-VL-1.6 and GLM-OCR on MLX, and PaddleOCR-VL's language model on Core ML), for size,
accuracy, latency, memory, and energy. Nothing here is built into the app; the models, the corpus's pictures, and the
Python environment stay outside the repository. `Tools/model-packs/formula_pack.py` reads the formula corpus through
`render.py` and `score.py`.

## Setup

```sh
L3=/some/scratch/dir            # outside the repository
uv venv $L3/venv --python 3.13
uv pip install --python $L3/venv/bin/python --exclude-newer 2026-10-04 \
  torch==2.14.1 torchvision==0.29.1 transformers==5.18.0 coremltools==9.0 mlx==0.32.3 mlx-vlm==0.7.4 \
  ftfy==6.3.1 numpy pillow safetensors tokenizers "huggingface-hub==1.33.0" psutil opencv-python-headless
swiftc -O -o $L3/energy Tools/l3-spike/energy.swift -lIOReport
swiftc -O -o $L3/fprobe Tools/l3-spike/fprobe.swift
```

The models, each in its own folder under `$L3/models`, at these revisions (all checked against the Hub's SHA-256):

| Repository | Revision | License |
| --- | --- | --- |
| PaddlePaddle/PP-FormulaNet_plus-L_safetensors | 6cc004a8e91ea3f3819b05317f40b290cbe99c2b | Apache-2.0 |
| PaddlePaddle/PaddleOCR-VL-1.6 | c5630abae1d940eafe0697512a0325494b02ab42 | Apache-2.0 |
| zai-org/GLM-OCR | 2e85a62840ccac27daa451df36c736c4636b8628 | MIT |
| PaddlePaddle/PP-DocLayoutV3_safetensors | e4f489dc536556fc1be02b973ba06756e0d4a2ac | Apache-2.0 |

```sh
PY=$L3/venv/bin/python Tools/l3-spike/fetch.sh PaddlePaddle/PP-FormulaNet_plus-L_safetensors $L3/models/PaddlePaddle_PP-FormulaNet_plus-L_safetensors
```

`fetch.sh` takes the weights and configurations (no repository code) with curl, resuming each file until it has its
size, and checks the SHA-256 of the large ones. Hugging Face's own client stalled here (xet transfers stopped at a few
megabytes); a single connection ran at 1–3 MB/s with resets. `pfetch.py URL DEST SIZE SHA256 [PARTS]` finishes a large
file with parallel Range requests, keeping what `DEST` already holds.

The corpus, in `$L3/corpus`:

```sh
P="$L3/venv/bin/python -I"; T=Tools/l3-spike
$P $T/render.py $L3/corpus                   # f01_s1.png … f40_d2.png: formulas.txt at 1x, 2x, and 2x dark
$P $T/render_font.py $L3/corpus              # f01_x2.png …, f01_p2.png …: STIX Two Math, TeX Gyre Pagella Math
swift run -c release --package-path Tools/ocr-bench ocr-bench --engine l1 --save $L3/corpus/bench
$P $T/tables.py $L3/corpus/tables $L3/corpus/bench   # 4 screen-style tables at 1x and 2x, and the bench's 2
```

`render.py` needs a TeX installation with xelatex (the formulas are drawn as `$\displaystyle …$` in a standalone
document, CJK in Hiragino Sans GB) and pdftoppm and ImageMagick; `tables.py` needs Google Chrome.

## Runs

```sh
M=$L3/models/PaddlePaddle_PP-FormulaNet_plus-L_safetensors
$P $T/formula_torch.py $M $L3/corpus out.json mps                 # PyTorch, the reference
$P $T/formula_convert.py $M $L3/coreml/formula 1024              # Core ML: encoder, stateful decoder step, int8 copies
$P $T/formula_coreml.py $M $L3/coreml/formula $L3/corpus out.json cpu cpu _int8
$P $T/score.py $L3/corpus out.json --render --worst
$L3/fprobe compile $L3/coreml/formula/encoder.mlpackage $L3/coreml/c   # then decoder.mlpackage
$L3/fprobe $L3/coreml/c cpu cpu 60                                     # native loads, steps, peak memory
$P $T/formula_picture.py $L3/corpus "f*_*.png" $M                 # the app's preparation against the processor's
$P $T/formula_picture.py $L3/corpus "f0[1-6]_*.png" --dump $L3/parity   # for OMSOCRTests' FormulaTests

$P $T/mlx_convert.py $L3/models/PaddlePaddle_PaddleOCR-VL-1.6 $L3/mlx/paddle-8 8   # 16 for bf16, or 4
L3=$L3 $T/vlm_all.sh paddle-8                                      # text, tables, formulas, with energy
$P $T/vlm_text_coreml.py $L3/models/PaddlePaddle_PaddleOCR-VL-1.6 $L3/coreml/vlmtext
$P $T/vlm_text_speed.py $L3/coreml/vlmtext gpu
```

`energy -- COMMAND` runs a command and prints the whole machine's energy over it (IOReport), less the idle power of the
3 s before it; `usage.py` gives a Python process's own peak footprint, Neural Engine footprint, CPU time, and CPU
energy (`proc_pid_rusage`).

## Notes

- **Score.** `score.py` compares normalized LaTeX tokens (token error rate, exact match) and, with `--render`, draws
  each reading with the same preamble as its truth: "same render" counts readings whose pixels match the truth's.
  Readings that draw the same formula with other markup (`array` for `pmatrix`) count as errors in both.
- **Dark pictures.** PP-FormulaNet reads dark ink on light paper: 0% on the dark renders as they are, 95% inverted
  (`darkfix.py`, on the border's brightness). The VLMs read them as they are.
- **Core ML state.** coremltools 9.0 with torch 2.14 converts a KV cache held as Core ML state (`toy_state.py`);
  on macOS 27.2 beta it runs on every compute unit. `ctfix.py` is the NumPy 2.5 fix from Tools/l2-spike.
- **GLM-OCR's config.** Its `vision_config` now carries `rope_parameters`, which mlx-vlm 0.7.4 refuses; its theta
  (10000) is mlx-vlm's default, so the spike converted a copy of the folder with that key removed.
- **Quantizing.** coremltools 9.0 crashed (segmentation fault) quantizing PaddleOCR-VL's language model to 4-bit
  blocks; 8-bit per channel worked.
- **MLX's size.** The Python wheel's `libmlx.dylib` is 20.1 MB and `mlx.metallib` 181.5 MB. Building mlx-swift
  0.32.3 with xcodebuild needs Xcode's Metal Toolchain (`xcodebuild -downloadComponent MetalToolchain`), not installed
  here, so its own size wasn't measured.
- **Energy.** On macOS 27.2 beta IOReport's CPU and ANE energy channels read 0; only the GPU's counts. CPU energy is
  each process's own, from `usage.py`.
