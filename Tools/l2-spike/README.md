# L2 runtime spike

How the L2 decision was measured (Docs/ocr.md › L2 runtime): PP-OCRv6 small on ONNX Runtime, on ONNX
Runtime's Core ML provider, and as native Core ML, over the OCR benchmark's corpus. Nothing here is
built into the app; the models and the Python environment stay outside the repository.

## Setup

```sh
L2=/some/scratch/dir            # outside the repository
uv venv $L2/venv --python 3.13
uv pip install --python $L2/venv/bin/python --exclude-newer 2026-09-25 \
  torch==2.14.0 onnxruntime==1.30.0 opencv-python-headless==5.0.0.93 transformers==5.17.0 coremltools==9.0 \
  numpy pillow pyclipper safetensors tokenizers "huggingface-hub<2"
```

The models, from the PaddlePaddle organization on Hugging Face (Apache-2.0), each repository in its
own folder under `$L2/models`: `PP-OCRv6_{small,tiny}_{det,rec}_onnx` (`inference.onnx`,
`inference.yml`) and `PP-OCRv6_small_{det,rec}_safetensors` (`model.safetensors`, `config.json`,
`preprocessor_config.json`), fetched from `https://huggingface.co/PaddlePaddle/<repo>/resolve/main/<file>`.

The corpus with ground truth and L1's output:

```sh
swift run -c release --package-path Tools/ocr-bench ocr-bench --engine l1 [--real DIR] --save $L2/corpus --json $L2/l1.json
```

## Runs

Run Python with `-I`, from outside the models folder:

```sh
P="$L2/venv/bin/python -I"; T=Tools/l2-spike
$P $T/run_ort.py $T $L2/models $L2/corpus $L2/l1.json out.json cpu small      # or coreml, or tiny
$P $T/convert_coreml.py $L2/models $L2/coreml                                 # fp16 ML programs
$P $T/run_coreml.py $T $L2/models $L2/coreml $L2/corpus out.json enum cpu_ne  # range|enum, all|cpu_ne|cpu
swiftc -O -o probe $T/probe.swift && ./probe $L2/coreml/det_small_enum.mlpackage $L2/compiled cpu_ne 1x3x736x1280
```

`DET_LIMIT=736` makes detection upscale the shorter side to 736, as transformers' preprocessor does
(the default here is 64, as PaddleX does for PP-OCRv5 and v6).

## Notes

- coremltools 9.0 is tested with torch 2.7 and fails on NumPy 2.5 when it folds a one-element cast;
  `convert_coreml.py` patches that one function.
- On macOS 27.2 beta, Core ML's GPU path asserts on these models (`shape for TensorData is not
  static`), with flexible and enumerated sizes alike: use `.cpuAndNeuralEngine` or `.cpuOnly`, never
  `.all`.
- The Neural Engine compiles every enumerated size when a model is first loaded (15 s for the
  detector's 24 sizes, 6 s for the recognizer's 11) and the system keeps the result for that compiled
  model's path: a second process loads in 40 ms. coremltools compiles to a new temporary path on each
  load, so its loads never hit that cache; `probe.swift` loads as the app would.
- The pipeline orders boxes top to bottom, left to right, so vertical Chinese comes out in reverse
  column order; its text is right.
