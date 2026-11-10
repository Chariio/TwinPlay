#!/usr/bin/env python3
# Copyright (c) 2026 Charlie Rodriguez Garcia. All rights reserved.
"""Batch compatibility run: every .nds under a folder, headless, with scripted input.

usage: compat.py HEADLESS ROMDIR OUTDIR [-frames N] [-jobs J] [-only SUBSTR]
Writes OUTDIR/<game>/frameNNNN.png, OUTDIR/<game>/sheet.png and OUTDIR/results.json.
ROMs are only read; nothing is copied.
"""
import json, os, subprocess, sys, time, concurrent.futures as cf
from PIL import Image, ImageStat

def args():
    a = sys.argv[1:]
    opts = {"-frames": 3000, "-jobs": 4, "-only": ""}
    pos = []
    i = 0
    while i < len(a):
        if a[i] in opts: opts[a[i]] = type(opts[a[i]])(a[i + 1]); i += 2
        else: pos.append(a[i]); i += 1
    return pos, opts

def presses(frames):
    # Six-step cycle every 60 frames: Start, A, A, tap, horizontal drag, vertical drag.
    # The drags get touch-driven title screens (stylus games) past their first screen.
    p = []
    for f in range(240, frames - 200, 60):
        k = (f // 60) % 6
        if k == 3:   # 12-frame press (short taps are ignored by some games), centre then lower row
            y = 108 if (f // 360) % 2 == 0 else 150
            p += ["-drag", f"{f}:128:{y}:128:{y}:12"]
        elif k == 4: p += ["-drag", f"{f}:40:100:216:100:30"]
        elif k == 5: p += ["-drag", f"{f}:128:30:128:170:30"]
        else: p += ["-press", f"{f}:{'0x8' if k == 0 else '0x1'}"]
    return p

def screen_kind(img, top):
    box = (0, 0, 256, 192) if top else (0, 192, 256, 384)
    st = ImageStat.Stat(img.crop(box).convert("L"))
    mean, sd = st.mean[0], st.stddev[0]
    if sd < 2.0:
        return "white" if mean > 235 else "black" if mean < 20 else "flat"
    return "image"

def run(headless, rom, outdir, frames):
    name = os.path.splitext(os.path.basename(rom))[0]
    d = os.path.join(outdir, name.replace("/", "_"))
    os.makedirs(d, exist_ok=True)
    every = 500
    cmd = [headless, rom, "-frames", str(frames), "-every", str(every), "-out", d, "-notrace",
           "-save", os.path.join(d, "game.sav")] + presses(frames)
    t0 = time.time()
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=600)
        out, rc, timedout = r.stdout + r.stderr, r.returncode, False
    except subprocess.TimeoutExpired as e:
        out, rc, timedout = "", -1, True
    secs = time.time() - t0
    log = ""
    try: log = open(os.path.join(d, "trace.log"), errors="replace").read()
    except OSError: pass
    fault = next((l for l in log.splitlines() if "FAULT" in l), "")
    shots = sorted(f for f in os.listdir(d) if f.startswith("frame") and f.endswith(".png") and "_x" not in f)
    kinds, sigs = [], []
    for s in shots:
        im = Image.open(os.path.join(d, s)).convert("RGB")
        kinds.append((screen_kind(im, True), screen_kind(im, False)))
        sigs.append(im.resize((32, 48)).tobytes())
    if shots:
        sheet = Image.new("RGB", (256 * len(shots), 384))
        for k, s in enumerate(shots): sheet.paste(Image.open(os.path.join(d, s)), (256 * k, 0))
        sheet.save(os.path.join(d, "sheet.png"))
    save = next((l for l in out.splitlines() if l.startswith("save:")), "")
    if timedout: status = "timeout"
    elif fault: status = "crash"
    elif not kinds or all(k == ("white", "white") for k in kinds): status = "white screen"
    elif all(a != "image" and b != "image" for a, b in kinds): status = "blank screen"
    elif len(sigs) >= 3 and len(set(sigs[-3:])) == 1 and kinds[-1] != ("image", "image"): status = "stuck (static, partly blank)"
    elif len(sigs) >= 3 and len(set(sigs[-3:])) == 1: status = "static picture (menu or hang)"
    else: status = "running (picture changes)"
    return {"game": name, "status": status, "fault": fault.strip(), "seconds": round(secs, 1),
            "save": save.replace("save: ", ""), "screens": kinds, "dir": d}

def main():
    (headless, romdir, outdir), o = args()
    roms = []
    for root, _, files in os.walk(romdir):
        roms += [os.path.join(root, f) for f in files if f.lower().endswith(".nds") and o["-only"].lower() in f.lower()]
    roms.sort(key=lambda p: os.path.basename(p).lower())
    os.makedirs(outdir, exist_ok=True)
    res = []
    with cf.ThreadPoolExecutor(o["-jobs"]) as ex:
        for r in ex.map(lambda p: run(headless, p, outdir, o["-frames"]), roms):
            print(f"{r['status']:32s} {r['seconds']:6.1f}s  {r['game']}  {r['fault'][:80]}", flush=True)
            res.append(r)
    json.dump(res, open(os.path.join(outdir, "results.json"), "w"), indent=1)

main()
