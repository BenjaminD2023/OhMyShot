"""PP-OCRv6 detection + recognition with a pluggable runner, following PaddleOCR's own pre- and
post-processing (DBPostProcess, get_rotate_crop_image, CTCLabelDecode). The runner is any callable
that takes an NCHW float32 array and returns the model's output array, so the same pipeline runs on
ONNX Runtime (CPU or its Core ML provider) and on a converted Core ML model."""

import math
import time
import unicodedata

import cv2
import numpy as np
import pyclipper
import yaml


# ---------------------------------------------------------------- detection

def det_resize(image, limit_side_len=64, max_side_limit=4000):
    """DetResizeForTest as PaddleX runs it for PP-OCRv5/v6: the shorter side at least 64, neither side
    over 4000, both multiples of 32."""
    h, w = image.shape[:2]
    ratio = 1.0
    if min(h, w) < limit_side_len:
        ratio = limit_side_len / min(h, w)
    rh, rw = h * ratio, w * ratio
    if max(rh, rw) > max_side_limit:
        scale = max_side_limit / max(rh, rw)
        rh, rw = rh * scale, rw * scale
    rh = max(int(round(rh / 32) * 32), 32)
    rw = max(int(round(rw / 32) * 32), 32)
    resized = cv2.resize(image, (rw, rh))
    return resized, (rh / h, rw / w)


def det_normalize(image):
    # The image is BGR, normalized with ImageNet's means in that order, as PaddleOCR does.
    mean = np.array([0.485, 0.456, 0.406], dtype=np.float32)
    std = np.array([0.229, 0.224, 0.225], dtype=np.float32)
    x = (image.astype(np.float32) / 255.0 - mean) / std
    return x.transpose(2, 0, 1)[None].astype(np.float32)


def get_mini_boxes(contour):
    bounding_box = cv2.minAreaRect(contour)
    points = sorted(list(cv2.boxPoints(bounding_box)), key=lambda x: x[0])
    if points[1][1] > points[0][1]:
        i1, i4 = 0, 1
    else:
        i1, i4 = 1, 0
    if points[3][1] > points[2][1]:
        i2, i3 = 2, 3
    else:
        i2, i3 = 3, 2
    return [points[i1], points[i2], points[i3], points[i4]], min(bounding_box[1])


def box_score_fast(bitmap, box):
    h, w = bitmap.shape[:2]
    box = box.copy()
    xmin = int(np.clip(np.floor(box[:, 0].min()), 0, w - 1))
    xmax = int(np.clip(np.ceil(box[:, 0].max()), 0, w - 1))
    ymin = int(np.clip(np.floor(box[:, 1].min()), 0, h - 1))
    ymax = int(np.clip(np.ceil(box[:, 1].max()), 0, h - 1))
    mask = np.zeros((ymax - ymin + 1, xmax - xmin + 1), dtype=np.uint8)
    box[:, 0] -= xmin
    box[:, 1] -= ymin
    cv2.fillPoly(mask, box.reshape(1, -1, 2).astype(np.int32), 1)
    return cv2.mean(bitmap[ymin:ymax + 1, xmin:xmax + 1], mask)[0]


def unclip(box, ratio):
    # Shoelace area and perimeter in place of shapely's Polygon.
    x, y = box[:, 0], box[:, 1]
    area = 0.5 * abs(np.dot(x, np.roll(y, 1)) - np.dot(y, np.roll(x, 1)))
    length = np.sum(np.sqrt(np.sum((box - np.roll(box, 1, axis=0)) ** 2, axis=1)))
    distance = area * ratio / max(length, 1e-6)
    offset = pyclipper.PyclipperOffset()
    offset.AddPath([tuple(p) for p in box.astype(np.int64)], pyclipper.JT_ROUND, pyclipper.ET_CLOSEDPOLYGON)
    return np.array(offset.Execute(distance))


def db_postprocess(pred, scale, src_shape, thresh=0.2, box_thresh=0.45, unclip_ratio=1.4, max_candidates=3000, min_size=3):
    bitmap = pred > thresh
    height, width = bitmap.shape
    contours, _ = cv2.findContours((bitmap * 255).astype(np.uint8), cv2.RETR_LIST, cv2.CHAIN_APPROX_SIMPLE)
    boxes = []
    src_h, src_w = src_shape
    for contour in contours[:max_candidates]:
        points, sside = get_mini_boxes(contour)
        if sside < min_size:
            continue
        points = np.array(points)
        score = box_score_fast(pred, points.reshape(-1, 2))
        if score < box_thresh:
            continue
        expanded = unclip(points, unclip_ratio)
        if len(expanded) == 0:
            continue
        box, sside = get_mini_boxes(expanded.reshape(-1, 1, 2).astype(np.float32))
        if sside < min_size + 2:
            continue
        box = np.array(box)
        box[:, 0] = np.clip(np.round(box[:, 0] / width * src_w), 0, src_w)
        box[:, 1] = np.clip(np.round(box[:, 1] / height * src_h), 0, src_h)
        boxes.append(box.astype(np.float32))
    return boxes


def sorted_boxes(boxes):
    """PaddleOCR's order: top to bottom, and left to right within a line (tops within 10 px)."""
    boxes = sorted(boxes, key=lambda b: (b[0][1], b[0][0]))
    for i in range(len(boxes) - 1):
        for j in range(i, -1, -1):
            if abs(boxes[j + 1][0][1] - boxes[j][0][1]) < 10 and boxes[j + 1][0][0] < boxes[j][0][0]:
                boxes[j], boxes[j + 1] = boxes[j + 1], boxes[j]
            else:
                break
    return boxes


def rotate_crop(image, points):
    width = int(max(np.linalg.norm(points[0] - points[1]), np.linalg.norm(points[2] - points[3])))
    height = int(max(np.linalg.norm(points[0] - points[3]), np.linalg.norm(points[1] - points[2])))
    width, height = max(width, 1), max(height, 1)
    target = np.float32([[0, 0], [width, 0], [width, height], [0, height]])
    matrix = cv2.getPerspectiveTransform(points.astype(np.float32), target)
    crop = cv2.warpPerspective(image, matrix, (width, height), borderMode=cv2.BORDER_REPLICATE, flags=cv2.INTER_CUBIC)
    # A tall crop is vertical text: turned to lie as a line.
    if crop.shape[0] / crop.shape[1] >= 1.5:
        crop = np.rot90(crop)
    return crop


# ---------------------------------------------------------------- recognition

def rec_normalize(crops, height=48, base_width=320):
    """Each crop resized to the height, keeping its ratio, and padded to the widest in the batch."""
    max_ratio = max([base_width / height] + [c.shape[1] / c.shape[0] for c in crops])
    width = int(math.ceil(height * max_ratio))
    batch = np.zeros((len(crops), 3, height, width), dtype=np.float32)
    for i, crop in enumerate(crops):
        h, w = crop.shape[:2]
        resized_w = min(width, int(math.ceil(height * w / h)))
        resized = cv2.resize(crop, (resized_w, height)).astype(np.float32)
        resized = (resized / 255.0 - 0.5) / 0.5
        batch[i, :, :, :resized_w] = resized.transpose(2, 0, 1)
    return batch


class Decoder:
    def __init__(self, yml_path):
        post = yaml.safe_load(open(yml_path))["PostProcess"]
        characters = [str(c) for c in post["character_dict"]]
        # CTC: the blank first; a space after the dictionary.
        self.characters = ["blank"] + characters + [" "]

    def __call__(self, preds):
        indices = preds.argmax(axis=2)
        probabilities = preds.max(axis=2)
        results = []
        for row, probs in zip(indices, probabilities):
            keep = np.ones(len(row), dtype=bool)
            keep[1:] = row[1:] != row[:-1]
            keep &= row != 0
            text = "".join(self.characters[i] for i in row[keep] if i < len(self.characters))
            score = float(probs[keep].mean()) if keep.any() else 0.0
            results.append((text, score))
        return results


# ---------------------------------------------------------------- pipeline

class Pipeline:
    def __init__(self, det, rec, decoder, rec_batch=6):
        self.det = det
        self.rec = rec
        self.decoder = decoder
        self.rec_batch = rec_batch

    def __call__(self, image_bgr, timings=None):
        started = time.perf_counter()
        import os
        resized, _ = det_resize(image_bgr, limit_side_len=int(os.environ.get("DET_LIMIT", "64")))
        x = det_normalize(resized)
        t0 = time.perf_counter()
        pred = self.det(x)[0, 0]
        t1 = time.perf_counter()
        boxes = sorted_boxes(db_postprocess(pred, None, image_bgr.shape[:2]))
        crops = [rotate_crop(image_bgr, b) for b in boxes]
        t2 = time.perf_counter()
        results = [("", 0.0)] * len(crops)
        order = np.argsort([c.shape[1] / c.shape[0] for c in crops])
        rec_time = 0.0
        for start in range(0, len(order), self.rec_batch):
            chunk = order[start:start + self.rec_batch]
            batch = rec_normalize([crops[i] for i in chunk])
            r0 = time.perf_counter()
            preds = self.rec(batch)
            rec_time += time.perf_counter() - r0
            for i, decoded in zip(chunk, self.decoder(preds)):
                results[i] = decoded
        finished = time.perf_counter()
        if timings is not None:
            timings.update(total=finished - started, det=t1 - t0, rec=rec_time, post=t2 - t1, lines=len(crops))
        return [(text, score, box) for (text, score), box in zip(results, boxes)]


def assemble(lines):
    """One line of text per detected line, in reading order (the boxes come sorted)."""
    return "\n".join(text for text, _, _ in lines if text.strip())


# ---------------------------------------------------------------- the benchmark's content error rate

PUNCTUATION = {
    "，": ",", "、": ",", "。": ".", "：": ":", "；": ";", "！": "!", "？": "?",
    "（": "(", "）": ")", "【": "[", "】": "]", "「": '"', "」": '"', "『": '"', "』": '"',
    "“": '"', "”": '"', "‘": "'", "’": "'", "～": "~", "—": "-", "–": "-", "−": "-", "…": "...",
}


def is_emoji(ch):
    v = ord(ch)
    return v >= 0x1F000 or 0x2600 <= v <= 0x27BF or 0x2B00 <= v <= 0x2BFF or v in (0xFE0F, 0x200D) or 0x2300 < v <= 0x23FF and v > 0x238C


def content(text):
    out = []
    for ch in unicodedata.normalize("NFC", text):
        if ch.isspace() or is_emoji(ch):
            continue
        if ch in PUNCTUATION:
            out.extend(PUNCTUATION[ch])
        elif 0xFF01 <= ord(ch) <= 0xFF5E:
            out.append(chr(ord(ch) - 0xFEE0))
        else:
            out.append(ch)
    return out


def edit_distance(a, b):
    if not a:
        return len(b)
    if not b:
        return len(a)
    previous = list(range(len(b) + 1))
    for i in range(1, len(a) + 1):
        current = [i] + [0] * len(b)
        for j in range(1, len(b) + 1):
            current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (a[i - 1] != b[j - 1]))
        previous = current
    return previous[-1]


def content_cer(output, truth):
    t = content(truth)
    o = content(output)
    if not t:
        return 0.0 if not o else 1.0
    return edit_distance(o, t) / len(t)
