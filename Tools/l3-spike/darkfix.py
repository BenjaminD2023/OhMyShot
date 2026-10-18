"""Formula models read dark ink on light paper: invert a picture whose background is dark."""
from PIL import Image, ImageOps, ImageStat

def light(image: Image.Image) -> Image.Image:
    gray = image.convert("L")
    # The border is the background in a cropped formula.
    w, h = gray.size
    border = [gray.getpixel((x, y)) for x in range(0, w, max(1, w // 32)) for y in (0, h - 1)] + \
             [gray.getpixel((x, y)) for y in range(0, h, max(1, h // 32)) for x in (0, w - 1)]
    return ImageOps.invert(image.convert("RGB")) if sum(border) / len(border) < 128 else image.convert("RGB")
