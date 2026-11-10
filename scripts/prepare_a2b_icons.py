#!/usr/bin/env python3
"""Crop TwinPlay concept icons to the squircle and write opaque 1024 PNGs.

Source JPEGs are full squircles on a white or light margin. iOS masks the
icon itself, so the art has to meet the square's edges. This script drops
that margin, scales to 1024, and writes RGB PNGs (no alpha) plus 240px
picker previews. It does not copy the JPEGs into the repo.
"""
import sys
from pathlib import Path
from PIL import Image

ROOT = Path(__file__).resolve().parents[1]
ASSETS = ROOT / "DSEmu/Resources/Assets.xcassets"

# filename, asset catalog name, primary (replaces AppIcon)
ICONS = [
    ("A2b-glass-purple.jpg", "AppIcon", True),
    ("A2b.jpg", "AppIcon-Violet", False),
    ("A2b-blue.jpg", "AppIcon-A2bOcean", False),
    ("A2b-red.jpg", "AppIcon-Fire", False),
    ("A2b-green.jpg", "AppIcon-A2bLime", False),
    ("A2b-dark.jpg", "AppIcon-NeonDark", False),
    ("A2b-glass-clear.jpg", "AppIcon-ClearGlass", False),
]

APPICON_JSON = """{
  "images" : [
    {
      "filename" : "%s",
      "idiom" : "universal",
      "platform" : "ios",
      "size" : "1024x1024"
    }
  ],
  "info" : { "author" : "xcode", "version" : 1 }
}
"""

PREVIEW_JSON = """{
  "images": [
    {
      "filename": "preview.png",
      "idiom": "universal",
      "scale": "2x"
    }
  ],
  "info": {
    "author": "xcode",
    "version": 1
  }
}
"""


def _inset(px, w, h, axis, window=150, band=24):
    """How many pixels of flat margin sit outside the squircle on one side.

    The page colour is not one flat value (the dark and clear-glass sheets
    vignette), so this follows the strongest step in the outer band instead
    of a distance from the corner colour.
    """
    grads = [0] * window
    if axis in ("L", "R"):
        y0, y1 = h // 2 - band, h // 2 + band
        for y in range(y0, y1):
            if axis == "L":
                lums = [sum(px[x, y]) for x in range(window + 1)]
            else:
                lums = [sum(px[w - 1 - x, y]) for x in range(window + 1)]
            for i in range(window):
                grads[i] += abs(lums[i + 1] - lums[i])
    else:
        x0, x1 = w // 2 - band, w // 2 + band
        for x in range(x0, x1):
            if axis == "T":
                lums = [sum(px[x, y]) for y in range(window + 1)]
            else:
                lums = [sum(px[x, h - 1 - y]) for y in range(window + 1)]
            for i in range(window):
                grads[i] += abs(lums[i + 1] - lums[i])
    return max(range(window), key=grads.__getitem__)


def content_box(im: Image.Image):
    """Crop to the squircle so its rim meets the square. iOS masks the corners."""
    rgb = im.convert("RGB")
    w, h = rgb.size
    px = rgb.load()
    left = _inset(px, w, h, "L")
    right = _inset(px, w, h, "R")
    top = _inset(px, w, h, "T")
    bottom = _inset(px, w, h, "B")
    # A squircle is square. Clip the longer side instead of pulling margin back in.
    bw, bh = w - left - right, h - top - bottom
    side = min(bw, bh)
    cx = left + bw / 2
    cy = top + bh / 2
    x0 = int(round(cx - side / 2))
    y0 = int(round(cy - side / 2))
    x0 = max(0, min(x0, w - side))
    y0 = max(0, min(y0, h - side))
    box = (left, top, w - right - 1, h - bottom - 1)
    return rgb.crop((x0, y0, x0 + side, y0 + side)), box, (left, right, top, bottom)


def write_png(im: Image.Image, path: Path, size: int):
    out = im.resize((size, size), Image.Resampling.LANCZOS).convert("RGB")
    path.parent.mkdir(parents=True, exist_ok=True)
    out.save(path, "PNG")
    check = Image.open(path)
    if check.mode != "RGB" or check.size != (size, size):
        raise SystemExit(f"{path} is {check.mode} {check.size}, want RGB {size}")


def main():
    src = Path(sys.argv[1] if len(sys.argv) > 1 else "/workspace/uploads")
    missing = [name for name, _, _ in ICONS if not (src / name).is_file()]
    if missing:
        raise SystemExit(f"missing in {src}: {', '.join(missing)}")
    for name, asset, _primary in ICONS:
        im = Image.open(src / name)
        cropped, box, bg = content_box(im)
        print(f"{name}: {im.size} margin {bg} art {box} -> {cropped.size}")
        icon_name = "AppIcon-1024.png" if asset == "AppIcon" else f"{asset}-1024.png"
        icon_dir = ASSETS / f"{asset}.appiconset"
        write_png(cropped, icon_dir / icon_name, 1024)
        (icon_dir / "Contents.json").write_text(APPICON_JSON % icon_name)
        prev = ASSETS / f"IconPreview-{asset}.imageset"
        write_png(cropped, prev / "preview.png", 240)
        (prev / "Contents.json").write_text(PREVIEW_JSON)
    print("wrote", len(ICONS), "icons")


if __name__ == "__main__":
    main()
