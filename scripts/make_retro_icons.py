#!/usr/bin/env python3
"""Original TwinPlay home-screen icons. No console names, logos, or product photos."""
from pathlib import Path
from PIL import Image, ImageDraw, ImageFilter

ROOT = Path("/workspace/DSEmu/Resources/Assets.xcassets")
S = 1024  # draw size; icons are flattened opaque


def lerp(a, b, t):
    return tuple(int(a[i] + (b[i] - a[i]) * t) for i in range(3))


def gradient(size, top, bottom):
    img = Image.new("RGB", (size, size))
    px = img.load()
    for y in range(size):
        c = lerp(top, bottom, y / (size - 1))
        for x in range(size):
            px[x, y] = c
    return img


def rounded_mask(size, box, radius):
    m = Image.new("L", size, 0)
    ImageDraw.Draw(m).rounded_rectangle(box, radius=radius, fill=255)
    return m


def paste_shape(base, color, box, radius, alpha=255):
    layer = Image.new("RGBA", base.size, (0, 0, 0, 0))
    ImageDraw.Draw(layer).rounded_rectangle(box, radius=radius, fill=(*color, alpha))
    base.alpha_composite(layer)


def circle(base, color, cx, cy, r, alpha=255):
    layer = Image.new("RGBA", base.size, (0, 0, 0, 0))
    ImageDraw.Draw(layer).ellipse((cx - r, cy - r, cx + r, cy + r), fill=(*color, alpha))
    base.alpha_composite(layer)


def plus(base, color, cx, cy, arm, thick):
    layer = Image.new("RGBA", base.size, (0, 0, 0, 0))
    d = ImageDraw.Draw(layer)
    d.rounded_rectangle((cx - thick, cy - arm, cx + thick, cy + arm), radius=thick // 3, fill=color)
    d.rounded_rectangle((cx - arm, cy - thick, cx + arm, cy + thick), radius=thick // 3, fill=color)
    base.alpha_composite(layer)


def shadow(base, box, radius, blur=28, alpha=90, dy=18):
    layer = Image.new("RGBA", base.size, (0, 0, 0, 0))
    shifted = (box[0], box[1] + dy, box[2], box[3] + dy)
    ImageDraw.Draw(layer).rounded_rectangle(shifted, radius=radius, fill=(0, 0, 0, alpha))
    layer = layer.filter(ImageFilter.GaussianBlur(blur))
    base.alpha_composite(layer)


def bars(base, color, cx, cy, w, h, gap):
    layer = Image.new("RGBA", base.size, (0, 0, 0, 0))
    d = ImageDraw.Draw(layer)
    r, g, b, a = color
    d.rounded_rectangle((cx - w // 2, cy - gap - h, cx + w // 2, cy - gap), radius=max(4, h // 2), fill=(r, g, b, a))
    d.rounded_rectangle((cx - int(w * 0.72) // 2, cy + gap, cx + int(w * 0.72) // 2, cy + gap + h), radius=max(4, h // 2), fill=(r, g, b, int(a * 0.75)))
    base.alpha_composite(layer)


def eight_bit(bg_top, bg_bot, body, trim, screen, bezel, dpad, buttons, button_rim):
    img = gradient(S, bg_top, bg_bot).convert("RGBA")
    body_box = (150, 250, 874, 790)
    shadow(img, body_box, 48)
    paste_shape(img, body, body_box, 48)
    # thin lighter lip along the top edge
    paste_shape(img, trim, (174, 268, 850, 330), 28, alpha=180)
    screen_box = (250, 300, 774, 530)
    paste_shape(img, bezel, (230, 284, 794, 548), 28)
    paste_shape(img, screen, screen_box, 18)
    bars(img, (255, 255, 255, 230), 512, 410, 220, 28, 16)
    plus(img, (*dpad, 255), 300, 660, 78, 28)
    circle(img, button_rim, 690, 620, 52)
    circle(img, buttons, 690, 620, 42)
    circle(img, button_rim, 780, 710, 46)
    circle(img, buttons, 780, 710, 36)
    # two small slots, original, not a logo
    paste_shape(img, bezel, (430, 700, 500, 724), 8)
    paste_shape(img, bezel, (524, 700, 594, 724), 8)
    return img.convert("RGB")


def sixteen_bit(bg_top, bg_bot, body, body_alpha, screen, bezel, dpad, gems, gloss):
    img = gradient(S, bg_top, bg_bot).convert("RGBA")
    body_box = (110, 300, 914, 760)
    shadow(img, body_box, 150)
    # shoulder bumps
    paste_shape(img, body, (150, 250, 360, 360), 40, alpha=body_alpha)
    paste_shape(img, body, (664, 250, 874, 360), 40, alpha=body_alpha)
    paste_shape(img, body, body_box, 150, alpha=body_alpha)
    if gloss:
        paste_shape(img, gloss, (160, 330, 864, 470), 80, alpha=70)
    paste_shape(img, bezel, (248, 360, 590, 680), 36)
    paste_shape(img, screen, (268, 380, 570, 660), 24)
    bars(img, (255, 255, 255, 235), 419, 515, 150, 26, 14)
    plus(img, (*dpad, 255), 175, 590, 46, 16)
    # four gems in a diamond, clear of the screen
    positions = [(788, 452), (868, 548), (788, 644), (708, 548)]
    for (cx, cy), color in zip(positions, gems):
        circle(img, (255, 255, 255), cx, cy, 46, alpha=40)
        circle(img, color, cx, cy, 40)
    return img.convert("RGB")


ICONS = {
    "AppIcon-Retro8Gray": lambda: eight_bit(
        (42, 46, 52), (22, 24, 28), (196, 198, 202), (230, 232, 235),
        (32, 168, 176), (18, 20, 24), (70, 74, 80), (214, 54, 54), (90, 20, 22)),
    "AppIcon-Retro8Red": lambda: eight_bit(
        (74, 22, 16), (36, 10, 8), (176, 42, 36), (230, 186, 84),
        (28, 16, 14), (48, 12, 10), (92, 22, 18), (244, 214, 120), (120, 78, 24)),
    "AppIcon-Retro8Black": lambda: eight_bit(
        (16, 16, 18), (6, 6, 8), (28, 28, 32), (60, 60, 66),
        (18, 18, 22), (8, 8, 10), (70, 70, 76), (214, 48, 48), (80, 16, 16)),
    "AppIcon-Retro8White": lambda: eight_bit(
        (214, 220, 226), (168, 176, 186), (246, 247, 249), (255, 255, 255),
        (36, 120, 168), (30, 34, 40), (90, 96, 104), (36, 40, 48), (20, 22, 26)),
    "AppIcon-Retro8Blue": lambda: eight_bit(
        (16, 40, 78), (8, 20, 44), (36, 92, 168), (120, 176, 230),
        (14, 28, 52), (10, 22, 44), (16, 40, 72), (236, 240, 246), (180, 190, 206)),
    "AppIcon-Retro16Gray": lambda: sixteen_bit(
        (46, 40, 56), (24, 22, 32), (186, 188, 194), 255,
        (92, 64, 168), (28, 24, 36), (72, 70, 80),
        [(124, 84, 210), (90, 96, 110), (150, 154, 162), (70, 74, 84)],
        (255, 255, 255)),
    "AppIcon-Retro16Color": lambda: sixteen_bit(
        (232, 220, 206), (186, 170, 156), (236, 232, 224), 255,
        (48, 56, 72), (36, 32, 40), (88, 84, 80),
        [(61, 202, 106), (61, 125, 255), (242, 193, 78), (226, 75, 75)],
        (255, 255, 255)),
    "AppIcon-Retro16Black": lambda: sixteen_bit(
        (18, 18, 22), (8, 8, 10), (24, 24, 28), 255,
        (16, 16, 20), (8, 8, 10), (70, 72, 78),
        [(61, 180, 100), (70, 120, 220), (220, 176, 70), (200, 70, 70)],
        (80, 80, 90)),
    "AppIcon-Retro16Purple": lambda: sixteen_bit(
        (48, 24, 78), (22, 10, 40), (132, 78, 196), 230,
        (210, 170, 255), (40, 16, 64), (70, 40, 100),
        [(186, 140, 255), (120, 80, 190), (90, 50, 150), (160, 110, 220)],
        (255, 230, 255)),
    "AppIcon-Retro16Teal": lambda: sixteen_bit(
        (10, 56, 60), (4, 28, 34), (42, 160, 158), 230,
        (186, 255, 246), (8, 40, 42), (16, 70, 72),
        [(120, 230, 210), (40, 140, 150), (20, 90, 100), (80, 190, 180)],
        (220, 255, 250)),
}


def write_set(name, image):
    icon_dir = ROOT / f"{name}.appiconset"
    icon_dir.mkdir(parents=True, exist_ok=True)
    image.save(icon_dir / f"{name}-1024.png", "PNG")
    (icon_dir / "Contents.json").write_text(f'''{{
  "images": [
    {{
      "filename": "{name}-1024.png",
      "idiom": "universal",
      "platform": "ios",
      "size": "1024x1024"
    }}
  ],
  "info": {{ "author": "xcode", "version": 1 }}
}}
''')
    preview_dir = ROOT / f"IconPreview-{name}.imageset"
    preview_dir.mkdir(parents=True, exist_ok=True)
    image.resize((512, 512), Image.Resampling.LANCZOS).save(preview_dir / "preview.png", "PNG")
    (preview_dir / "Contents.json").write_text('''{
  "images": [
    { "filename": "preview.png", "idiom": "universal", "scale": "2x" }
  ],
  "info": { "author": "xcode", "version": 1 }
}
''')


def main():
    for name, make in ICONS.items():
        write_set(name, make())
        print(name)


if __name__ == "__main__":
    main()
