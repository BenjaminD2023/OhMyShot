"""Builds the PaddleOCR-VL-1.6 model pack, the VLM pack (Docs/ocr.md › L3 spike, › The VLM pack).

    python3 -I Tools/model-packs/vlm_pack.py convert MODELS OUT
        The model on MLX with 8-bit weights (mlx-vlm's conversion, groups of 64; the vision tower's second MLP layers,
        whose width 64 doesn't divide, stay 16-bit), from the pinned upstream revision in MODELS (its folder named as
        Tools/l3-spike/README.md fetches it); vocabulary.json, the tokenizer's tokens and added tokens by id; and
        prompts.json, each task's prompt around the picture's tokens, tokenized here so that the app needs no tokenizer.
    python3 -I Tools/model-packs/vlm_pack.py assemble OUT PACK --layout LAYOUT_MLPACKAGE --license LICENSE --checked CHECKED_JSON
        The pack's files in PACK: OUT's model and tokens, the layout model the formula pack holds (formula_pack.py
        layout) with layout.json naming its table and chart classes, LICENSE.txt (LICENSE: the upstream repository's,
        with what was changed before it), README.md (with the checks' results,
        CHECKED_JSON: {"text": {"cer": …, "pictures": …}, "tables": {"cells": …, "of": …, "shape": …, "pictures": …}}).

The checks themselves are the Swift reader's (Packages/OhMyShotVLM's vlm-check against Tools/l3-spike/vlm_score.py).
Run with the Python environment of Tools/l3-spike (its README), from outside the models' folder.
"""

import hashlib
import json
import os
import shutil
import sys

# The upstream revision the pack is made from (Hugging Face, PaddlePaddle organization, Apache-2.0).
UPSTREAM = {"PaddleOCR-VL-1.6": "c5630abae1d940eafe0697512a0325494b02ab42"}
# The layout model's own (formula_pack.py's UPSTREAM).
LAYOUT_UPSTREAM = {"PP-DocLayoutV3_safetensors": "e4f489dc536556fc1be02b973ba06756e0d4a2ac"}

BITS, GROUP = 8, 64

# The tasks, with their prompts as PaddleOCR-VL's README has them. The app reads tables and charts; "ocr" and
# "formula" are there for the text reader's own job and for checks.
TASKS = {"ocr": "OCR:", "table": "Table Recognition:", "formula": "Formula Recognition:", "chart": "Chart Recognition:"}

# The layout model's classes the VLM reads (PP-DocLayoutV3's 25, in its own order: 3 is "chart", 21 "table"), and the
# score a query needs, Paddle's own threshold, as for formulas.
LAYOUT_CLASSES = {"table": 21, "chart": 3}
LAYOUT_SIZE, LAYOUT_THRESHOLD = 800, 0.5


def convert(models, out):
    from mlx_vlm import convert as mlx_convert
    from transformers import AutoTokenizer

    source = os.path.join(models, "PaddlePaddle_PaddleOCR-VL-1.6")
    revision = open(os.path.join(source, "REVISION")).read().split()[-1]
    assert revision == UPSTREAM["PaddleOCR-VL-1.6"], f"{source} is at {revision}, not the pinned revision"
    mlx_convert(source, out, quantize=True, q_bits=BITS, q_group_size=GROUP, trust_remote_code=False)

    tokenizer = AutoTokenizer.from_pretrained(out, local_files_only=True)
    raw = json.load(open(os.path.join(out, "tokenizer.json"), encoding="utf-8"))
    vocabulary = {i: token for token, i in raw["model"]["vocab"].items()}
    vocabulary.update({added["id"]: added["content"] for added in raw["added_tokens"]})
    tokens = [vocabulary.get(i, "") for i in range(max(vocabulary) + 1)]
    with open(os.path.join(out, "vocabulary.json"), "w", encoding="utf-8") as f:
        json.dump(tokens, f, ensure_ascii=False)

    image = tokenizer.convert_tokens_to_ids("<|IMAGE_PLACEHOLDER|>")
    prompts = {}
    for key, task in TASKS.items():
        # chat_template.jinja for one user message holding the picture and the task, and the assistant's turn after.
        text = "<|begin_of_sentence|>User: <|IMAGE_START|><|IMAGE_PLACEHOLDER|><|IMAGE_END|>" + task + "\nAssistant:\n"
        ids = tokenizer(text, add_special_tokens=False)["input_ids"]
        at = ids.index(image)
        prompts[key] = {"before": ids[:at], "after": ids[at + 1:]}
    with open(os.path.join(out, "prompts.json"), "w") as f:
        json.dump(prompts, f, indent=1)
        f.write("\n")
    print(f"{len(tokens)} tokens; prompts: {', '.join(prompts)}")


def versions():
    import mlx.core
    import mlx_vlm
    import transformers
    return {"mlx": mlx.core.__version__, "mlx_vlm": mlx_vlm.__version__, "transformers": transformers.__version__}


def assemble(out, pack, layout, license_file, checked):
    checks = json.load(open(checked))
    os.makedirs(pack, exist_ok=True)
    assert not os.path.exists(os.path.join(pack, "Compiled")), f"{pack} was read from"
    for name in ("config.json", "model.safetensors", "vocabulary.json", "prompts.json"):
        shutil.copyfile(os.path.join(out, name), os.path.join(pack, name))
    target = os.path.join(pack, "layout.mlpackage")
    if os.path.exists(target):
        shutil.rmtree(target)
    shutil.copytree(layout, target)
    with open(os.path.join(pack, "layout.json"), "w") as f:
        json.dump({
            # The picture (a tile of a large one) scaled to size × size whatever its aspect (bicubic, antialiased), then
            # value / 255. A query is a table or a chart where that class scores `threshold` or more through a
            # sigmoid. On the CPU, as in the formula pack.
            "layout": {
                "file": "layout.mlpackage", "input": "pixel_values", "size": LAYOUT_SIZE, "logits": "logits", "boxes": "boxes",
                "classes": LAYOUT_CLASSES, "threshold": LAYOUT_THRESHOLD,
            },
            "computeUnits": "cpuOnly",
        }, f, indent=2)
        f.write("\n")

    tools = versions()
    source = "\n".join(f"    https://huggingface.co/PaddlePaddle/{repo}/tree/{revision}" for repo, revision in {**UPSTREAM, **LAYOUT_UPSTREAM}.items())
    notice = f"""PaddleOCR-VL-1.6 on MLX, and PP-DocLayoutV3 converted to Core ML, for OhMyShot

The models in this repository are PaddlePaddle's PaddleOCR-VL-1.6 document parsing model and PP-DocLayoutV3 layout
detection model, Copyright (c) 2016 PaddlePaddle Authors, licensed under the Apache License, Version 2.0, below.

What was changed (Apache License 2.0, section 4(b)): the weights of

{source}

were converted: PaddleOCR-VL-1.6's to MLX with {BITS}-bit weights in groups of {GROUP} (affine; the vision tower's second MLP
layers stay 16-bit), by mlx-vlm {tools["mlx_vlm"]} (mlx {tools["mlx"]}, transformers {tools["transformers"]}), which also
renamed them and joined the vision attention's query, key, and value projections into one; PP-DocLayoutV3's to a Core ML
ML program with 8-bit weights, as in the OhMyShot formula pack (Tools/model-packs/formula_pack.py). The weights were not
trained or tuned. vocabulary.json is the tokenizer's tokens by id; prompts.json each task's prompt, tokenized;
layout.json the layout model's input, classes, and threshold (Tools/model-packs/vlm_pack.py in
https://github.com/fzlzjerry/OhMyShot).

The license text below is PaddleOCR-VL-1.6's own (its repository's LICENSE).

--------------------------------------------------------------------------------

"""
    with open(os.path.join(pack, "LICENSE.txt"), "w", encoding="utf-8") as f:
        f.write(notice + open(license_file, encoding="utf-8").read())

    text, tables = checks["text"], checks["tables"]
    readme = f"""---
license: apache-2.0
library_name: mlx
pipeline_tag: image-to-text
tags:
  - ocr
  - table-recognition
  - chart-recognition
  - mlx
  - coreml
  - ohmyshot
base_model:
  - PaddlePaddle/PaddleOCR-VL-1.6
  - PaddlePaddle/PP-DocLayoutV3_safetensors
---

# PaddleOCR-VL-1.6 for MLX (OhMyShot model pack)

PaddlePaddle's [PaddleOCR-VL-1.6](https://huggingface.co/PaddlePaddle/PaddleOCR-VL-1.6), a 0.9B vision-language model
that reads text, tables, formulas, and charts in a picture, on MLX with {BITS}-bit weights, and
[PP-DocLayoutV3](https://huggingface.co/PaddlePaddle/PP-DocLayoutV3_safetensors), which finds the tables and charts, as
Core ML, for [OhMyShot](https://github.com/fzlzjerry/OhMyShot), a screenshot app for macOS, which downloads them as a
model pack: the text it recognizes then holds the tables and charts in a picture a row a line, cells apart by tabs, and
its Recognized Text window shows them as tables. The weights are PaddlePaddle's, quantized; see LICENSE.txt for the
license and what was changed. While it reads, the reading process peaks near 2.6 GB of memory.

| File | What it is |
| --- | --- |
| `config.json` | The model's configuration, as mlx-vlm writes it (`paddleocr_vl`; `quantization`: {BITS} bits, groups of {GROUP}). |
| `model.safetensors` | The weights, as mlx-vlm names them (`visual.*`, `language_model.*`); a module with `.scales` and `.biases` beside its `.weight` is quantized. |
| `vocabulary.json` | The tokens by id, a JSON array of strings: `▁` is a space, `<0xHH>` a byte of UTF-8 text. |
| `prompts.json` | Each task's prompt around the picture's tokens, as ids: `{{"table": {{"before": […], "after": […]}}, …}}`; the picture's tokens (id 100295) go between, one for each 2 × 2 patches of 14 pixels. |
| `layout.mlpackage` | PP-DocLayoutV3: input `pixel_values`, 1 × 3 × {LAYOUT_SIZE} × {LAYOUT_SIZE} (value / 255); outputs `logits`, 1 × 300 × 25, and `boxes`, 1 × 300 × 4. Class {LAYOUT_CLASSES["table"]} is a table, {LAYOUT_CLASSES["chart"]} a chart. |
| `layout.json` | The layout model's input, the classes read, and the threshold ({LAYOUT_THRESHOLD}). |
| `LICENSE.txt` | Apache License 2.0, with what was changed. |

A table reads as OTSL (`<fcel>` a cell, `<ecel>` an empty one, `<lcel>`/`<ucel>`/`<xcel>` merged, `<nl>` a row's end), a
chart as rows with cells apart by ` | `. Pictures are scaled with PIL's bicubic filter to whole 28-pixel blocks between
112,896 and 1,003,520 pixels; decoding is greedy and ends at token 2.

Made with `Tools/model-packs/vlm_pack.py` from these upstream revisions:

{source.replace("    ", "- ")}

Checked with OhMyShot's Swift reader (Packages/OhMyShotVLM), whose tokens match mlx-vlm's on the pictures compared:
text in the OhMyShot benchmark's {text["pictures"]} pictures read with "OCR:", content character error rate
{text["cer"]:.2f}%; {tables["pictures"]} screen-style tables read with "Table Recognition:", {tables["cells"]} of {tables["of"]} cells
right, {tables["shape"]} of {tables["pictures"]} in the right shape.
"""
    with open(os.path.join(pack, "README.md"), "w", encoding="utf-8") as f:
        f.write(readme)
    listing = []
    for root, _, files in os.walk(pack):
        for name in sorted(files):
            path = os.path.join(root, name)
            digest = hashlib.sha256()
            with open(path, "rb") as file:
                for block in iter(lambda: file.read(1 << 24), b""):
                    digest.update(block)
            listing.append({"path": os.path.relpath(path, pack), "size": os.path.getsize(path), "sha256": digest.hexdigest()})
    listing.sort(key=lambda f: f["path"])
    with open(os.path.join(out, "files.json"), "w") as f:
        json.dump(listing, f, indent=2)
    for item in listing:
        print(f"{item['size']:>10}  {item['sha256']}  {item['path']}")
    print(f"{sum(i['size'] for i in listing)} bytes in {len(listing)} files")


def main():
    command, args = sys.argv[1], sys.argv[2:]
    if command == "convert":
        convert(*args)
    elif command == "assemble":
        out, pack = args[0], args[1]
        options = dict(zip(args[2::2], args[3::2]))
        assemble(out, pack, options["--layout"], options["--license"], options["--checked"])
    else:
        sys.exit(__doc__)


if __name__ == "__main__":
    main()
