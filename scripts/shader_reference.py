#!/usr/bin/env python3
# Copyright (c) 2026 Charlie Rodriguez Garcia. All rights reserved.
"""CPU reference of TwinPlay's Metal display shader (FramePresenter.swift), for comparison
screenshots and tests. Same maths as the shader: filters on the DS pixel grid, LCD colour
correction, then gamma / contrast / brightness / saturation.

render(tex, out_w, out_h, mode, lcd=False, color=(0,1,1,1)) -> HxWx3 float array
tex: HxWx3 float (0..1) texture covering ONE screen (256*s x 192*s).
mode: 0 nearest, 1 linear, 2 scanlines, 3 sharp bilinear, 4 edge-directed
"""
import numpy as np

def _sample_nearest(t, u, v):
    h, w, _ = t.shape
    x = np.clip((u * w).astype(int), 0, w - 1); y = np.clip((v * h).astype(int), 0, h - 1)
    return t[y, x]

def _sample_linear(t, u, v):
    h, w, _ = t.shape
    x = u * w - 0.5; y = v * h - 0.5
    x0 = np.floor(x).astype(int); y0 = np.floor(y).astype(int)
    fx = (x - x0)[..., None]; fy = (y - y0)[..., None]
    def g(yy, xx): return t[np.clip(yy, 0, h - 1), np.clip(xx, 0, w - 1)]
    return (g(y0, x0) * (1 - fx) * (1 - fy) + g(y0, x0 + 1) * fx * (1 - fy)
            + g(y0 + 1, x0) * (1 - fx) * fy + g(y0 + 1, x0 + 1) * fx * fy)

def _smoothstep(e0, e1, x):
    t = np.clip((x - e0) / (e1 - e0), 0, 1); return t * t * (3 - 2 * t)

def render(tex, out_w, out_h, mode, lcd=False, color=(0.0, 1.0, 1.0, 1.0)):
    DS = np.array([256.0, 192.0])
    ys, xs = np.mgrid[0:out_h, 0:out_w]
    u = (xs + 0.5) / out_w; v = (ys + 0.5) / out_h
    k = out_w / 256.0                                 # display pixels per DS pixel
    if mode == 3:
        px, py = u * DS[0], v * DS[1]
        ix, iy = np.floor(px), np.floor(py)
        fx = np.clip((px - ix - 0.5) * k + 0.5, 0, 1); fy = np.clip((py - iy - 0.5) * k + 0.5, 0, 1)
        c = _sample_linear(tex, (ix + fx) / DS[0], (iy + fy) / DS[1])
    elif mode == 4:
        px, py = u * DS[0], v * DS[1]
        ix, iy = np.floor(px), np.floor(py)
        def P(dx, dy):
            return _sample_nearest(tex, (np.clip(ix + dx, 0, 255) + 0.5) / DS[0], (np.clip(iy + dy, 0, 191) + 0.5) / DS[1])
        c = P(0, 0); up, dn, lf, rt = P(0, -1), P(0, 1), P(-1, 0), P(1, 0)
        gx, gy = (px - ix) - 0.5, (py - iy) - 0.5
        hv = np.where((gy < 0)[..., None], up, dn); hh = np.where((gx < 0)[..., None], lf, rt)
        ov = np.where((gy < 0)[..., None], dn, up); oh = np.where((gx < 0)[..., None], rt, lf)
        same = lambda a, b: np.all(np.abs(a - b) < 0.02, axis=-1)
        cond = same(hv, hh) & ~same(hv, c) & ~same(hv, ov) & ~same(hh, oh)
        aa = 1.5 / k
        w = _smoothstep(-aa, aa, np.abs(gx) + np.abs(gy) - 0.5)[..., None]
        c = np.where(cond[..., None], c * (1 - w) + hv * w, c)
    elif mode in (1, 2):
        c = _sample_linear(tex, u, v)
    else:
        c = _sample_nearest(tex, u, v)
    if mode == 2:
        row = np.modf(v * 192.0)[0]; col = np.modf(u * 256.0)[0]
        c = c * ((0.70 + 0.30 * np.sin(row * np.pi)) * (0.90 + 0.10 * np.sin(col * np.pi)) * 1.12)[..., None]
    if lcd:
        lin = np.power(np.maximum(c, 0), 2.2)
        m = np.array([[0.84, 0.13, 0.03], [0.09, 0.78, 0.13], [0.07, 0.13, 0.80]])   # rows = output channel
        lin = lin @ m.T
        c = np.power(np.maximum(lin, 0), 1 / 2.0) * 0.97 + 0.015
    b, ct, sat, gam = color
    c = np.power(np.maximum(c, 0), 1 / max(gam, 0.1))
    c = (c - 0.5) * ct + 0.5 + b
    luma = (c @ np.array([0.299, 0.587, 0.114]))[..., None]
    c = luma + (c - luma) * sat
    return np.clip(c, 0, 1)

def load_screen(path, screen, scale=1):
    from PIL import Image
    im = np.asarray(Image.open(path).convert("RGB"), dtype=np.float64) / 255.0
    h = 192 * scale
    return im[:h] if screen == 0 else im[h:2 * h]

def to_image(a):
    from PIL import Image
    return Image.fromarray((np.clip(a, 0, 1) * 255 + 0.5).astype(np.uint8))

if __name__ == "__main__":
    # Self-test: neutral settings leave nearest output unchanged; a staircase gets smoothed.
    t = np.zeros((192, 256, 3)); t[:96, :128] = 1.0
    out = render(t, 512, 384, 0)
    assert np.allclose(out[::2, ::2], t), "nearest must reproduce the source"
    st = np.zeros((192, 256, 3))
    for i in range(192): st[i, :min(256, i)] = 1.0                 # 45-degree staircase
    e = render(st, 768, 576, 4)
    n = render(st, 768, 576, 0)
    assert np.abs(e - n).sum() > 100 and len(np.unique(e)) > 2, "edge-directed must change diagonal edges"
    assert np.allclose(render(t, 256, 192, 3), t), "sharp bilinear at 1:1 is identity"
    lcd = render(np.full((192, 256, 3), [1.0, 0, 0]), 256, 192, 0, lcd=True)
    assert lcd[0, 0, 0] < 1.0 and lcd[0, 0, 1] > 0.0, "LCD correction desaturates"
    print("shader reference self-test passed")
