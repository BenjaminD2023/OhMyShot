"""Builds the PP-FormulaNet_plus-L model pack (Docs/ocr.md › L3 spike, › The formula pack) and checks it.

    python3 -I Tools/model-packs/formula_pack.py convert MODELS OUT
        Core ML ML programs with 8-bit weights, from the pinned upstream revision in MODELS (its folder named as
        Tools/l3-spike/README.md fetches it): an encoder from a 768 × 768 picture to the keys and values each decoder
        layer's cross-attention reads, and one decoder step that keeps the self-attention keys and values as Core ML
        state and gives the next token. Each is checked against transformers' model first. tokens.txt: the
        tokenizer's tokens in id order.
    python3 -I Tools/model-packs/formula_pack.py check OUT MODELS CORPUS OUT_JSON
        Reads the formula corpus (Tools/l3-spike's render.py and render_font.py) through OUT's models on the CPU,
        decoding and tidying the LaTeX as the app will, and scores each reading by its render (Tools/l3-spike/score.py).
    python3 -I Tools/model-packs/formula_pack.py assemble OUT PACK --license PADDLEOCR_LICENSE --checked CHECK_JSON
        The pack's files in PACK: the two models, tokens.txt, config.json, LICENSE.txt, README.md (with the check's
        scores).

Run with the Python environment of Tools/l3-spike (its README), from outside the models' folder.
"""

import hashlib
import json
import os
import re
import shutil
import sys
import time

import numpy as np

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "l3-spike"))

# The upstream revision the pack is made from (Hugging Face, PaddlePaddle organization, Apache-2.0).
UPSTREAM = {"PP-FormulaNet_plus-L_safetensors": "6cc004a8e91ea3f3819b05317f40b290cbe99c2b"}

# The encoder reads a 768 × 768 picture; its 144 tokens (12 × 12) are what each decoder layer's cross-attention reads.
SIZE = 768
# The decoder keeps the keys and values of this many steps: a formula ends within CACHE - 1 tokens. The longest in
# the corpus took 156; upstream's generation allows 1536, which no screenshot of a formula comes near.
CACHE = 1024
# Decoding starts from START and ends at END (both "</s>", as upstream's generation_config.json has it); ids below
# SPECIAL are the tokenizer's special tokens, left out of the text.
START, END, SPECIAL = 2, 2, 23
# A reading that repeats one run of at most REPEAT_LONGEST tokens REPEAT_TIMES times over is a model reading
# something that isn't a formula: it stops there. Dark pictures read without inversion did this, in runs of up to 28
# tokens, one to the cache's end (8 s); the corpus's right readings repeat a run 6 times at most.
REPEAT_TIMES, REPEAT_LONGEST = 8, 64
# The picture, as transformers' PPFormulaNetImageProcessor prepares it.
MEAN, STD = [0.7931] * 3, [0.1738] * 3
CROP_GRAY = 200
# A picture whose border is darker than this (0-255, mean of its gray) is inverted first: the model reads dark ink on
# light paper (Tools/l3-spike/darkfix.py; Docs/ocr.md › L3 spike).
DARK_BORDER = 128


def load_model(models):
    import torch
    from transformers import PPFormulaNetForConditionalGeneration

    torch.set_grad_enabled(False)
    model = PPFormulaNetForConditionalGeneration.from_pretrained(os.path.join(models, "PP-FormulaNet_plus-L_safetensors"), dtype=torch.float32)
    model.eval().requires_grad_(False)
    model.config._attn_implementation = "eager"
    return model


def modules(model):
    """The encoder and the decoder step as the pack holds them, in PyTorch."""
    import torch

    decoder = model.model.decoder
    layers = decoder.layers
    heads, dim = layers[0].self_attn.num_heads, layers[0].self_attn.head_dim
    width = heads * dim

    class Encoder(torch.nn.Module):
        def __init__(self):
            super().__init__()
            self.vision = model.model.encoder
            self.layers = layers

        def forward(self, pixel_values):
            states = self.vision(pixel_values).pooler_output  # 1 × tokens × width
            tokens = states.shape[1]
            keys, values = [], []
            for layer in self.layers:
                attention = layer.encoder_attn
                keys.append(attention.k_proj(states).view(1, tokens, heads, dim).transpose(1, 2))
                values.append(attention.v_proj(states).view(1, tokens, heads, dim).transpose(1, 2))
            return torch.stack(keys), torch.stack(values)  # layers × 1 × heads × tokens × dim

    class Step(torch.nn.Module):
        def __init__(self):
            super().__init__()
            self.decoder = decoder
            self.head = model.lm_head
            self.register_buffer("k_cache", torch.zeros(len(layers), 1, heads, CACHE, dim, dtype=torch.float16))
            self.register_buffer("v_cache", torch.zeros(len(layers), 1, heads, CACHE, dim, dtype=torch.float16))

        def forward(self, ids, pos, mask, cross_k, cross_v):
            p = pos[0]
            # Learned positions start 2 into their table (PPFormulaNetLearnedPositionalEmbedding's offset).
            x = self.decoder.embed_tokens(ids) + self.decoder.embed_positions.weight[pos + 2].unsqueeze(0)
            x = self.decoder.layernorm_embedding(x)
            for i, layer in enumerate(self.decoder.layers):
                attention = layer.self_attn
                h = layer.self_attn_layer_norm(x)
                q = attention.q_proj(h).view(1, 1, heads, dim).transpose(1, 2)
                k = attention.k_proj(h).view(1, 1, heads, dim).transpose(1, 2)
                v = attention.v_proj(h).view(1, 1, heads, dim).transpose(1, 2)
                self.k_cache[i:i + 1, :, :, p:p + 1, :] = k.half()
                self.v_cache[i:i + 1, :, :, p:p + 1, :] = v.half()
                w = torch.softmax(q @ self.k_cache[i].float().transpose(-1, -2) * attention.scaling + mask, -1)
                x = x + attention.out_proj((w @ self.v_cache[i].float()).transpose(1, 2).reshape(1, 1, width))
                cross = layer.encoder_attn
                h = layer.encoder_attn_layer_norm(x)
                q = cross.q_proj(h).view(1, 1, heads, dim).transpose(1, 2)
                w = torch.softmax(q @ cross_k[i].transpose(-1, -2) * cross.scaling, -1)
                x = x + cross.out_proj((w @ cross_v[i]).transpose(1, 2).reshape(1, 1, width))
                x = x + layer.fc2(layer.activation_fn(layer.fc1(layer.final_layer_norm(x))))
            logits = self.head(self.decoder.layer_norm(x))
            return torch.argmax(logits, -1).to(torch.int32), logits

    return Encoder().eval(), Step().eval()


def step_inputs(token, position, cross_k, cross_v):
    mask = np.full((1, 1, 1, CACHE), -np.inf, np.float32)
    mask[..., : position + 1] = 0
    return {"ids": np.array([[token]], np.int32), "pos": np.array([position], np.int32), "mask": mask, "cross_k": cross_k, "cross_v": cross_v}


def convert(models, out):
    import coremltools as ct
    import torch

    import ctfix  # noqa: F401  coremltools 9.0 with NumPy 2.5
    from coremltools.optimize.coreml import OpLinearQuantizerConfig, OptimizationConfig, linear_quantize_weights

    os.makedirs(out, exist_ok=True)
    model = load_model(models)
    encoder, step = modules(model)
    rng = np.random.default_rng(0)
    pixels = torch.from_numpy(rng.standard_normal((1, 3, SIZE, SIZE), dtype=np.float32))
    # Teacher-forced: the same tokens through transformers' model at once, and through the step one at a time.
    tokens = [START] + [int(t) for t in rng.integers(SPECIAL, 50_000, 15)]
    reference = model(pixel_values=pixels, decoder_input_ids=torch.tensor([tokens])).logits[0].numpy()
    cross_k, cross_v = encoder(pixels)
    mine = []
    for i, token in enumerate(tokens):
        x = {k: torch.from_numpy(v) for k, v in step_inputs(token, i, cross_k.numpy(), cross_v.numpy()).items()}
        mine.append(step(x["ids"], x["pos"], x["mask"], x["cross_k"], x["cross_v"])[1][0, 0].numpy())
    mine = np.stack(mine)
    diff = float(np.abs(mine - reference).max())
    same = bool((mine.argmax(-1) == reference.argmax(-1)).all())
    print(f"the encoder and the step against transformers' model: max logit difference {diff:.3f} (16-bit cache), same tokens {same}")
    assert same and diff < 0.5

    # Quantizing warns of an invalid value in a cast: an output channel of zeros has a scale of 0. These two are
    # (the padding token's embedding, the last learned position), neither ever read, and they stay zeros.
    zeros = {name: [int(i) for i in np.where(p.detach().reshape(p.shape[0], -1).abs().amax(1).numpy() == 0)[0]]
             for name, p in model.named_parameters() if p.ndim >= 2}
    zeros = {name: rows for name, rows in zeros.items() if rows}
    assert zeros == {"model.decoder.embed_tokens.weight": [1], "model.decoder.embed_positions.weight": [2561]}, zeros

    common = dict(convert_to="mlprogram", compute_precision=ct.precision.FLOAT16, minimum_deployment_target=ct.target.macOS15)
    eight_bit = OptimizationConfig(global_config=OpLinearQuantizerConfig(mode="linear_symmetric", dtype="int8", granularity="per_channel"))
    started = time.perf_counter()
    encoder_ml = ct.convert(
        torch.jit.trace(encoder, pixels), inputs=[ct.TensorType(name="pixel_values", shape=pixels.shape)],
        outputs=[ct.TensorType(name="cross_k", dtype=np.float16), ct.TensorType(name="cross_v", dtype=np.float16)], **common,
    )
    encoder_ml = linear_quantize_weights(encoder_ml, eight_bit)
    encoder_ml.short_description = "PP-FormulaNet_plus-L's encoder (to its decoder's cross-attention keys and values), converted to Core ML for OhMyShot"
    encoder_ml.license = "Apache-2.0"
    encoder_ml.save(os.path.join(out, "encoder.mlpackage"))
    x = step_inputs(START, 0, cross_k.numpy(), cross_v.numpy())
    example = tuple(torch.from_numpy(x[k]) for k in ("ids", "pos", "mask", "cross_k", "cross_v"))
    step_ml = ct.convert(
        torch.jit.trace(step, example),
        inputs=[ct.TensorType(name="ids", shape=(1, 1), dtype=np.int32), ct.TensorType(name="pos", shape=(1,), dtype=np.int32),
                ct.TensorType(name="mask", shape=(1, 1, 1, CACHE), dtype=np.float16),
                ct.TensorType(name="cross_k", shape=cross_k.shape, dtype=np.float16), ct.TensorType(name="cross_v", shape=cross_v.shape, dtype=np.float16)],
        outputs=[ct.TensorType(name="next", dtype=np.int32), ct.TensorType(name="logits", dtype=np.float16)],
        states=[ct.StateType(ct.TensorType(shape=step.k_cache.shape, dtype=np.float16), name="k_cache"),
                ct.StateType(ct.TensorType(shape=step.v_cache.shape, dtype=np.float16), name="v_cache")],
        **common,
    )
    step_ml = linear_quantize_weights(step_ml, eight_bit)
    step_ml.short_description = "PP-FormulaNet_plus-L's decoder, one step with its keys and values as state, converted to Core ML for OhMyShot"
    step_ml.license = "Apache-2.0"
    step_ml.save(os.path.join(out, "decoder.mlpackage"))
    print(f"converted in {time.perf_counter() - started:.0f} s")

    # The Core ML models, 8-bit, against the PyTorch ones: the same teacher-forced tokens.
    encoder_cm = ct.models.MLModel(os.path.join(out, "encoder.mlpackage"), compute_units=ct.ComputeUnit.CPU_ONLY)
    step_cm = ct.models.MLModel(os.path.join(out, "decoder.mlpackage"), compute_units=ct.ComputeUnit.CPU_ONLY)
    e = encoder_cm.predict({"pixel_values": pixels.numpy()})
    k = cross_k.numpy().ravel()
    cosine = float(np.dot(e["cross_k"].ravel(), k) / np.linalg.norm(e["cross_k"].ravel()) / np.linalg.norm(k))
    state = step_cm.make_state()
    agree = 0
    for i, token in enumerate(tokens):
        x = step_inputs(token, i, e["cross_k"], e["cross_v"])
        x["mask"] = x["mask"].astype(np.float16)
        agree += int(step_cm.predict(x, state)["next"].reshape(-1)[0] == mine[i].argmax())
    print(f"Core ML, 8-bit, on the CPU: cross-attention keys' cosine {cosine:.4f}, the step's token as PyTorch's at {agree} of {len(tokens)}")
    assert cosine > 0.99 and agree >= len(tokens) - 1

    from transformers import AutoTokenizer
    tokenizer = AutoTokenizer.from_pretrained(os.path.join(models, "PP-FormulaNet_plus-L_safetensors"))
    vocabulary = tokenizer.get_vocab()
    by_id = sorted(vocabulary.items(), key=lambda item: item[1])
    assert [i for _, i in by_id] == list(range(len(by_id))), "the token ids have gaps"
    assert all("\n" not in t for t, _ in by_id)
    # Decoding leaves out every added token marked special (<s>, <pad>, </s>, <unk>, and 19 markup tokens).
    added = json.load(open(os.path.join(models, "PP-FormulaNet_plus-L_safetensors", "tokenizer.json")))["added_tokens"]
    special = sorted(a["id"] for a in added if a["special"])
    assert special == list(range(SPECIAL)), f"special ids {special}"
    with open(os.path.join(out, "tokens.txt"), "w", encoding="utf-8") as f:
        f.write("\n".join(t for t, _ in by_id) + "\n")
    print(f"{len(by_id)} tokens, the first {SPECIAL} special")


# ---------------------------------------------------------------- decoding and tidying, as the app will

def byte_decoder():
    """GPT-2's byte-level alphabet, back to bytes: each byte has a printable character standing in for it."""
    printable = list(range(ord("!"), ord("~") + 1)) + list(range(ord("¡"), ord("¬") + 1)) + list(range(ord("®"), ord("ÿ") + 1))
    characters = printable[:]
    extra = 0
    for b in range(256):
        if b not in printable:
            printable.append(b)
            characters.append(256 + extra)
            extra += 1
    return {chr(c): b for b, c in zip(printable, characters)}


BYTES = byte_decoder()
TEXT_COMMAND = re.compile(r"(\\(operatorname|mathrm|text|mathbf)\s?\*? {.*?})")
MACRO = re.compile(r"(\\[a-zA-Z]+)\s(?=\w)|\\[a-zA-Z]+\s(?=})")
PROTECTED = {"\\operatorname", "\\mathrm", "\\text", "\\mathbf"}
NOLETTER_NOLETTER = re.compile(r"(?!\\ )([\W_^\d])\s+?([\W_^\d])")
NOLETTER_LETTER = re.compile(r"(?!\\ )([\W_^\d])\s+?([a-zA-Z])")
LETTER_NOLETTER = re.compile(r"([a-zA-Z])\s+?([\W_^\d])")
CHINESE_TEXT = re.compile(r"\\text\s*{([^{}]*[\u4e00-\u9fff]+[^{}]*)}")


def decode(ids, tokens):
    """The text of token ids: special ones left out, the byte-level characters back to UTF-8 (invalid bytes as U+FFFD)."""
    text = "".join(tokens[i] for i in ids if i >= SPECIAL)
    return bytes(BYTES[c] for c in text).decode("utf-8", errors="replace")


def tidy(text):
    """PPFormulaNetProcessor.post_process_generation without ftfy (`check` shows it changes nothing here): Chinese
    unwrapped from \\text{}, quotes dropped, and the spaces between tokens taken out but for those a command needs."""
    text = CHINESE_TEXT.sub(lambda m: m.group(1), text).replace('"', "")
    names = []
    for match in TEXT_COMMAND.findall(text):
        for macro in MACRO.findall(match[0]):
            if macro not in PROTECTED and macro.strip() != "":
                text = text.replace(macro, macro + "XXXXXXX")
                text = text.replace(" ", "")
                names.append(text)
    if names:
        text = TEXT_COMMAND.sub(lambda m: str(names.pop(0)), text)
    while True:
        new = NOLETTER_NOLETTER.sub(r"\1\2", text)
        new = NOLETTER_LETTER.sub(r"\1\2", new)
        new = LETTER_NOLETTER.sub(r"\1\2", new)
        if new == text:
            break
        text = new
    return text.replace("XXXXXXX", " ")


def repeats(ids):
    """Whether the reading ends in one run of tokens repeated REPEAT_TIMES times over."""
    for length in range(1, REPEAT_LONGEST + 1):
        span = length * REPEAT_TIMES
        if len(ids) >= span:
            tail = ids[-span:]
            if all(tail[i] == tail[i % length] for i in range(span)):
                return True
    return False


class Reader:
    def __init__(self, out, models):
        import coremltools as ct
        from transformers import AutoProcessor

        self.processor = AutoProcessor.from_pretrained(os.path.join(models, "PP-FormulaNet_plus-L_safetensors"))
        self.encoder = ct.models.MLModel(os.path.join(out, "encoder.mlpackage"), compute_units=ct.ComputeUnit.CPU_ONLY)
        self.step = ct.models.MLModel(os.path.join(out, "decoder.mlpackage"), compute_units=ct.ComputeUnit.CPU_ONLY)
        self.tokens = open(os.path.join(out, "tokens.txt"), encoding="utf-8").read().split("\n")[:-1]

    def __call__(self, image):
        """(token ids, whether it stopped on a repeat, upstream's post-processed text) of the picture."""
        from darkfix import light

        pixels = self.processor(images=light(image), return_tensors="np")["pixel_values"].astype(np.float32)
        e = self.encoder.predict({"pixel_values": pixels})
        state = self.step.make_state()
        mask = np.full((1, 1, 1, CACHE), -np.inf, np.float16)
        ids, token, repeated = [], START, False
        for position in range(CACHE):
            mask[..., position] = 0
            r = self.step.predict({"ids": np.array([[token]], np.int32), "pos": np.array([position], np.int32), "mask": mask,
                                   "cross_k": e["cross_k"], "cross_v": e["cross_v"]}, state)
            token = int(r["next"].reshape(-1)[0])
            if token == END:
                break
            ids.append(token)
            if repeats(ids):
                repeated = True
                break
        return ids, repeated, self.processor.post_process(np.array([ids]))[0]


def check(out, models, corpus, out_json):
    from PIL import Image

    import render
    import score

    reader = Reader(out, models)
    truth = dict(render.load())
    pictures = sorted(n[:-4] for n in os.listdir(corpus) if re.fullmatch(r"f\d\d_[a-z]\d\.png", n))
    keys, cases = {}, []
    for name in pictures:
        formula, variant = name.rsplit("_", 1)
        started = time.perf_counter()
        ids, repeated, upstream = reader(Image.open(os.path.join(corpus, name + ".png")))
        seconds = time.perf_counter() - started
        text = tidy(decode(ids, reader.tokens))
        # The app's decoding and tidying, against upstream's (ftfy included).
        assert text == upstream, f"{name}: {text!r} against upstream's {upstream!r}"
        t, q = score.tokens(truth[formula]), score.tokens(text)
        if formula not in keys:
            keys[formula] = render.render_key(truth[formula])
        same = t == q or render.render_key(text) == keys[formula]
        cases.append({"case": name, "variant": variant, "ids": ids, "text": text, "repeated": repeated, "ms": seconds * 1000,
                      "ter": score.edit(t, q) / max(1, len(t)), "same": same})
        print(f"{name:7} {seconds * 1000:5.0f} ms  {len(ids):4} tokens  {'same' if same else 'off '}  {text}")
    variants = {}
    for variant in sorted({c["variant"] for c in cases}):
        mine = [c for c in cases if c["variant"] == variant]
        variants[variant] = {"count": len(mine), "same": sum(c["same"] for c in mine) / len(mine), "ter": sum(c["ter"] for c in mine) / len(mine)}
        print(f"{variant}: same render {variants[variant]['same'] * 100:.1f}%, token error {variants[variant]['ter'] * 100:.1f}% ({len(mine)})")
    times = sorted(c["ms"] for c in cases)
    print(f"{len(cases)} pictures, p50 {times[len(times) // 2]:.0f} ms, p95 {times[int(len(times) * 0.95)]:.0f} ms, "
          f"longest {max(len(c['ids']) for c in cases)} tokens, {sum(c['repeated'] for c in cases)} stopped on a repeat; "
          "the app's decoding and tidying matched upstream's on every one")
    json.dump({"variants": variants, "cases": cases}, open(out_json, "w"), ensure_ascii=False, indent=1)


def main():
    command = sys.argv[1]
    if command == "convert":
        convert(sys.argv[2], sys.argv[3])
    elif command == "check":
        check(sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5])
    elif command == "assemble":
        option = lambda name: sys.argv[sys.argv.index(name) + 1]
        assemble(sys.argv[2], sys.argv[3], option("--license"), option("--checked"))
    else:
        raise SystemExit(__doc__)


# Where the license text comes from: PaddleOCR's own LICENSE (Apache-2.0 with its copyright line; it has no NOTICE), as
# for the PP-OCRv6 pack (ppocr_pack.py). The upstream model's repository has no LICENSE file of its own.
PADDLEOCR_LICENSE = ("https://github.com/PaddlePaddle/PaddleOCR/blob/dab3fe35379033fdcb2d0e9572fac0b36c9a9ebf/LICENSE", "dab3fe35379033fdcb2d0e9572fac0b36c9a9ebf")


def config():
    return {
        "format": 1,
        "model": "PP-FormulaNet_plus-L",
        # The encoder on the Neural Engine took longer than on the CPU and held 817 MB there; the GPU's was faster
        # but held 1.16 GB (Docs/ocr.md › L3 spike).
        "computeUnits": "cpuOnly",
        "picture": {
            # In this order: a dark picture inverted; its margin cropped (the box of what is darker than cropGray,
            # 0-255, once the gray is stretched to 0-255); scaled so its shorter side is size (bilinear,
            # antialiased), then so it fits size × size (bicubic, antialiased) and centered in it, padded with
            # `padding`; then value / 255, (value - mean) / std for each RGB channel.
            "darkBorder": DARK_BORDER, "cropGray": CROP_GRAY, "size": SIZE, "padding": 0,
            "channels": "RGB", "mean": MEAN, "std": STD,
        },
        "encoder": {"file": "encoder.mlpackage", "input": "pixel_values", "keys": "cross_k", "values": "cross_v"},
        "decoder": {
            "file": "decoder.mlpackage", "token": "ids", "position": "pos", "mask": "mask", "keys": "cross_k", "values": "cross_v",
            "next": "next", "cache": CACHE, "start": START, "end": END,
            # A reading ending in one run of at most `longest` tokens repeated `times` times over stops there.
            "repeats": {"times": REPEAT_TIMES, "longest": REPEAT_LONGEST},
        },
        # One token a line, line n the token with id n - 1; ids below `special` are left out; the rest are GPT-2's
        # byte-level characters, each standing for a byte of the UTF-8 text.
        "tokens": {"file": "tokens.txt", "special": SPECIAL, "encoding": "byteLevel"},
    }


def versions():
    import coremltools
    import torch
    import transformers
    return {"coremltools": coremltools.__version__, "torch": torch.__version__, "transformers": transformers.__version__}


def assemble(out, pack, license_file, checked):
    variants = json.load(open(checked))["variants"]
    os.makedirs(pack, exist_ok=True)
    # A reader compiles the models into the folder it loads (Compiled/): never into the pack that is published.
    assert not os.path.exists(os.path.join(pack, "Compiled")), f"{pack} was read from"
    for name in ("encoder.mlpackage", "decoder.mlpackage"):
        target = os.path.join(pack, name)
        if os.path.exists(target):
            shutil.rmtree(target)
        shutil.copytree(os.path.join(out, name), target)
    shutil.copyfile(os.path.join(out, "tokens.txt"), os.path.join(pack, "tokens.txt"))
    with open(os.path.join(pack, "config.json"), "w") as f:
        json.dump(config(), f, indent=2)
        f.write("\n")
    tools = versions()
    source = "\n".join(f"    https://huggingface.co/PaddlePaddle/{repo}/tree/{revision}" for repo, revision in UPSTREAM.items())
    notice = f"""PP-FormulaNet_plus-L, converted to Core ML for OhMyShot

The models in this repository are PaddlePaddle's PP-FormulaNet_plus-L formula recognition model, Copyright (c) 2016
PaddlePaddle Authors, licensed under the Apache License, Version 2.0, below.

What was changed (Apache License 2.0, section 4(b)): the PyTorch (safetensors) weights of

{source}

were converted to Core ML ML programs with 8-bit weights (linear, symmetric, one scale for each output channel) and
16-bit floating point computation (Tools/model-packs/formula_pack.py in https://github.com/fzlzjerry/OhMyShot, with
coremltools {tools["coremltools"]}, torch {tools["torch"]}, transformers {tools["transformers"]}), after checking that
they give the tokens transformers' model gives. The model was split in two: encoder.mlpackage holds the image encoder
and, from each decoder layer, the projections of its cross-attention keys and values; decoder.mlpackage holds one
decoding step, which keeps the self-attention keys and values of up to {CACHE} steps as Core ML state and gives the
likeliest next token. The weights were not trained or tuned. tokens.txt is the tokenizer's vocabulary in id order.
config.json describes the reading the app does with them.

The license text below is PaddleOCR's own ({PADDLEOCR_LICENSE[0]}).

--------------------------------------------------------------------------------

"""
    with open(os.path.join(pack, "LICENSE.txt"), "w", encoding="utf-8") as f:
        f.write(notice + open(license_file, encoding="utf-8").read())

    def scored(variant):
        v = variants[variant]
        return f"{v['same'] * 100:.1f}%"

    readme = f"""---
license: apache-2.0
library_name: coreml
pipeline_tag: image-to-text
tags:
  - ocr
  - latex
  - formula-recognition
  - coreml
  - ohmyshot
base_model:
  - PaddlePaddle/PP-FormulaNet_plus-L_safetensors
---

# PP-FormulaNet_plus-L for Core ML (OhMyShot model pack)

PaddlePaddle's [PP-FormulaNet_plus-L](https://huggingface.co/PaddlePaddle/PP-FormulaNet_plus-L_safetensors), which
reads a picture of a formula as LaTeX, converted to Core ML ML programs with 8-bit weights for
[OhMyShot](https://github.com/fzlzjerry/OhMyShot), a screenshot app for macOS, which downloads them as a model pack to
copy the formula in a selection as LaTeX. The weights are PaddlePaddle's, quantized; see LICENSE.txt for the license and
what was changed.

| File | What it is |
| --- | --- |
| `encoder.mlpackage` | Input `pixel_values`, 1 × 3 × {SIZE} × {SIZE}; outputs `cross_k` and `cross_v`, 8 × 1 × 16 × 144 × 32: each decoder layer's cross-attention keys and values. |
| `decoder.mlpackage` | One step: inputs `ids` (1 × 1, the last token), `pos` (1, its position), `mask` (1 × 1 × 1 × {CACHE}, 0 for positions up to `pos`, -∞ after), `cross_k`, `cross_v`; output `next`, the likeliest next token, and `logits`. States `k_cache` and `v_cache` hold the self-attention keys and values. |
| `tokens.txt` | The tokenizer's tokens, one a line in id order (GPT-2 byte-level characters); ids below {SPECIAL} are special. |
| `config.json` | Pre- and post-processing: inversion of dark pictures, cropping, scaling, normalization, the start and end tokens. |
| `LICENSE.txt` | Apache License 2.0, with what was changed. |

Decoding starts from token {START} at position 0 and ends when the decoder gives {END}. Run on the CPU (`.cpuOnly`).

Made with `Tools/model-packs/formula_pack.py` from this upstream revision:

{source.replace("    ", "- ")}

Checked against the OhMyShot formula corpus (Tools/l3-spike: 40 formulas drawn with LaTeX): read through these models
on the CPU, with the app's own decoding, the share whose LaTeX draws exactly the formula drawn, by picture: {scored("s2")} at
2x (192 dpi), {scored("s1")} at 1x (96 dpi), {scored("d2")} in dark mode (inverted first, as config.json has it), {scored("x2")} in STIX Two Math, and
{scored("p2")} in TeX Gyre Pagella Math.
"""
    with open(os.path.join(pack, "README.md"), "w", encoding="utf-8") as f:
        f.write(readme)
    listing = []
    for root, _, files in os.walk(pack):
        for name in sorted(files):
            path = os.path.join(root, name)
            listing.append({"path": os.path.relpath(path, pack), "size": os.path.getsize(path), "sha256": hashlib.sha256(open(path, "rb").read()).hexdigest()})
    listing.sort(key=lambda f: f["path"])
    with open(os.path.join(out, "files.json"), "w") as f:
        json.dump(listing, f, indent=2)
    for item in listing:
        print(f"{item['size']:>10}  {item['sha256']}  {item['path']}")
    print(f"{sum(i['size'] for i in listing)} bytes in {len(listing)} files")


if __name__ == "__main__":
    main()
