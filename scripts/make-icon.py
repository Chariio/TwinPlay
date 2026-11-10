#!/usr/bin/env python3
# Copyright (c) 2026 Charlie Rodriguez Garcia. All rights reserved.
# Generates the original TwinPlay app icon (1024x1024): a stylized gray dual-screen handheld.
# Needs Pillow. Usage: python3 scripts/make-icon.py OUT.png
import sys
from PIL import Image, ImageDraw, ImageFilter, ImageFont

S = 4096                                    # supersampled canvas, downscaled to 1024
def sc(v): return int(v * S / 1024)

img = Image.new("RGB", (S, S))
d = ImageDraw.Draw(img)
# Background: vertical gradient, deep indigo to teal.
top, bot = (34, 40, 74), (18, 120, 140)
for y in range(S):
    t = y / (S - 1)
    d.line([(0, y), (S, y)], fill=tuple(int(top[i] + (bot[i] - top[i]) * t) for i in range(3)))

def rrect(draw, box, r, fill, outline=None, width=0):
    draw.rounded_rectangle([sc(v) for v in box], radius=sc(r), fill=fill, outline=outline, width=sc(width) if width else 0)

# Soft drop shadow for the device.
shadow = Image.new("L", (S, S), 0)
ImageDraw.Draw(shadow).rounded_rectangle([sc(232), sc(150), sc(812), sc(910)], radius=sc(70), fill=150)
shadow = shadow.filter(ImageFilter.GaussianBlur(sc(28)))
img.paste((10, 14, 30), (0, sc(18)), shadow)
d = ImageDraw.Draw(img)

# Upper lid and lower body (light gray shell), hinge between them.
rrect(d, (222, 120, 802, 488), 64, (214, 216, 220), (160, 163, 170), 4)
rrect(d, (222, 520, 802, 890), 64, (198, 200, 205), (150, 153, 160), 4)
rrect(d, (250, 478, 774, 530), 26, (170, 173, 180), (140, 143, 150), 3)
for x in (330, 694):                                   # hinge caps
    rrect(d, (x - 34, 474, x + 34, 534), 22, (186, 189, 195), (140, 143, 150), 3)

# Screens with dark bezels.
rrect(d, (290, 168, 734, 452), 26, (44, 46, 54))
rrect(d, (318, 192, 706, 428), 12, (20, 150, 170))
rrect(d, (390, 556, 634, 742), 20, (44, 46, 54))
rrect(d, (408, 572, 616, 726), 10, (230, 236, 240))

# Top screen: simple glowing wordmark "TwinPlay" (original lettering, not a logo of any company).
font = None
for path in ("/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf", "/System/Library/Fonts/Helvetica.ttc"):
    try:
        font = ImageFont.truetype(path, sc(96)); break
    except OSError:
        pass
if font is None: font = ImageFont.load_default()
text = "TwinPlay"
bb = d.textbbox((0, 0), text, font=font)
tw, th = bb[2] - bb[0], bb[3] - bb[1]
tx, ty = (S - tw) // 2 - bb[0], sc(310) - th // 2 - bb[1]
glow = Image.new("L", (S, S), 0)
ImageDraw.Draw(glow).text((tx, ty), text, font=font, fill=255)
img.paste((140, 255, 255), (0, 0), glow.filter(ImageFilter.GaussianBlur(sc(10))))
d = ImageDraw.Draw(img)
d.text((tx, ty), text, font=font, fill=(245, 255, 255))

# Bottom screen: two stacked rectangles hinting at the dual-screen idea.
rrect(d, (436, 596, 588, 640), 8, (20, 150, 170))
rrect(d, (436, 656, 588, 700), 8, (34, 40, 74))

# Controls: dark-gray cross pad (left), four gray round buttons (right), two small pills.
cx, cy = 306, 650
rrect(d, (cx - 22, cy - 62, cx + 22, cy + 62), 10, (78, 80, 88))
rrect(d, (cx - 62, cy - 22, cx + 62, cy + 22), 10, (78, 80, 88))
bx, by, o, r = 718, 650, 44, 21
for dx, dy in ((0, -o), (0, o), (-o, 0), (o, 0)):
    d.ellipse([sc(bx + dx - r), sc(by + dy - r), sc(bx + dx + r), sc(by + dy + r)], fill=(150, 153, 160), outline=(110, 113, 120), width=sc(3))
for px in (468, 556):
    rrect(d, (px - 30, 790, px + 30, 812), 11, (140, 143, 150))
# Speaker dots on the lower body.
for i in range(3):
    for j in range(2):
        x, y = 296 + i * 22, 790 + j * 22
        d.ellipse([sc(x - 5), sc(y - 5), sc(x + 5), sc(y + 5)], fill=(150, 153, 160))

out = img.resize((1024, 1024), Image.LANCZOS)
out.save(sys.argv[1] if len(sys.argv) > 1 else "icon.png", optimize=True)
