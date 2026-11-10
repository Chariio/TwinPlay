// Copyright (c) 2026 Charlie Rodriguez Garcia. All rights reserved.
// Original clean-room Game Boy Advance picture processor (scanline renderer):
// tile modes 0-2 (text and affine backgrounds), bitmap modes 3-5, sprites
// (regular, affine, double size, semi-transparent, OBJ window), windows,
// alpha blending / brightness and mosaic. Written from GBATEK.
#include "GBASystem.hpp"
#include <cstring>

namespace dscore {

namespace {
constexpr u16 kTransparent = 0x8000;
inline u32 toARGB(u16 c) {
    u32 r = c & 31, g = (c >> 5) & 31, b = (c >> 10) & 31;
    return 0xFF000000u | (((r << 3) | (r >> 2)) << 16) | (((g << 3) | (g >> 2)) << 8) | ((b << 3) | (b >> 2));
}
inline u16 blendAlpha(u16 a, u16 b, u32 eva, u32 evb) {
    u32 r = ((a & 31) * eva + (b & 31) * evb) >> 4, g = (((a >> 5) & 31) * eva + ((b >> 5) & 31) * evb) >> 4,
        bl = (((a >> 10) & 31) * eva + ((b >> 10) & 31) * evb) >> 4;
    if (r > 31) r = 31; if (g > 31) g = 31; if (bl > 31) bl = 31;
    return u16(r | (g << 5) | (bl << 10));
}
inline u16 brighten(u16 a, u32 evy) {
    u32 r = a & 31, g = (a >> 5) & 31, b = (a >> 10) & 31;
    r += ((31 - r) * evy) >> 4; g += ((31 - g) * evy) >> 4; b += ((31 - b) * evy) >> 4;
    return u16(r | (g << 5) | (b << 10));
}
inline u16 darken(u16 a, u32 evy) {
    u32 r = a & 31, g = (a >> 5) & 31, b = (a >> 10) & 31;
    r -= (r * evy) >> 4; g -= (g * evy) >> 4; b -= (b * evy) >> 4;
    return u16(r | (g << 5) | (b << 10));
}
const u8 kObjSize[3][4][2] = {
    {{8, 8}, {16, 16}, {32, 32}, {64, 64}},
    {{16, 8}, {32, 8}, {32, 16}, {64, 32}},
    {{8, 16}, {8, 32}, {16, 32}, {32, 64}},
};
}

void GBASystem::renderLine(int y) {
    const u16 dispcnt = io_[0];
    u32* dst = frame_.data() + y * kScreenWidth;
    if (dispcnt & 0x80) { for (int x = 0; x < W; ++x) dst[x] = 0xFFFFFFFFu; return; }
    const int mode = dispcnt & 7;
    auto pal16 = [&](u32 idx) { u16 v; std::memcpy(&v, &pal_[(idx & 0x1FF) * 2], 2); return u16(v & 0x7FFF); };
    auto vram8 = [&](u32 o) -> u8 { return o < 0x18000 ? vram_[o] : 0; };
    const u16 mosaic = io_[0x4C / 2];
    const int mosBH = (mosaic & 15) + 1, mosBV = ((mosaic >> 4) & 15) + 1, mosOH = ((mosaic >> 8) & 15) + 1, mosOV = ((mosaic >> 12) & 15) + 1;

    static thread_local u16 bg[4][W];
    bool bgOn[4] = {};
    for (int i = 0; i < 4; ++i) for (int x = 0; x < W; ++x) bg[i][x] = kTransparent;

    auto textBG = [&](int i) {
        u16 cnt = io_[(0x08 + 2 * i) / 2];
        u32 charBase = ((cnt >> 2) & 3) * 0x4000, screenBase = ((cnt >> 8) & 31) * 0x800;
        bool c256 = cnt & 0x80;
        int wTiles = (cnt & 0x4000) ? 64 : 32, hTiles = (cnt & 0x8000) ? 64 : 32;
        int hofs = io_[(0x10 + 4 * i) / 2] & 0x1FF, vofs = io_[(0x12 + 4 * i) / 2] & 0x1FF;
        int yy = (cnt & 0x40) ? y - y % mosBV : y;
        int py = (yy + vofs) & (hTiles * 8 - 1);
        for (int x = 0; x < W; ++x) {
            int xx = (cnt & 0x40) ? x - x % mosBH : x;
            int px = (xx + hofs) & (wTiles * 8 - 1);
            u32 sb = u32(px >> 8) + u32(py >> 8) * u32(wTiles >> 5);
            u32 ea = screenBase + sb * 0x800 + u32(((py & 255) >> 3) * 32 + ((px & 255) >> 3)) * 2;
            u16 e = u16(vram8(ea) | (vram8(ea + 1) << 8));
            int tx = px & 7, ty = py & 7;
            if (e & 0x400) tx = 7 - tx;
            if (e & 0x800) ty = 7 - ty;
            u32 tile = e & 0x3FF;
            if (c256) {
                u32 a = charBase + tile * 64 + u32(ty * 8 + tx);
                if (a >= 0x10000) continue;
                u8 idx = vram8(a); if (idx) bg[i][x] = pal16(idx);
            } else {
                u32 a = charBase + tile * 32 + u32(ty * 4 + (tx >> 1));
                if (a >= 0x10000) continue;
                u8 b = vram8(a); u8 idx = (tx & 1) ? (b >> 4) : (b & 15);
                if (idx) bg[i][x] = pal16(((e >> 12) << 4) | idx);
            }
        }
    };
    auto affineBG = [&](int i, int kind) {   // kind 0 tiles, 3/4/5 bitmap modes
        int k = i - 2;
        u16 cnt = io_[(0x08 + 2 * i) / 2];
        s32 pa = s16(io_[(0x20 + k * 0x10) / 2]), pc = s16(io_[(0x24 + k * 0x10) / 2]);
        s32 rx = bgRefX_[k], ry = bgRefY_[k];
        u32 frameBase = (dispcnt & 0x10) ? 0xA000 : 0;
        for (int x = 0; x < W; ++x) {
            int xx = (cnt & 0x40) ? x - x % mosBH : x;
            s32 tx = (rx + pa * xx) >> 8, ty = (ry + pc * xx) >> 8;
            if (kind == 0) {
                int size = 128 << ((cnt >> 14) & 3);
                if (cnt & 0x2000) { tx &= size - 1; ty &= size - 1; }
                else if (tx < 0 || ty < 0 || tx >= size || ty >= size) continue;
                u32 charBase = ((cnt >> 2) & 3) * 0x4000, screenBase = ((cnt >> 8) & 31) * 0x800;
                u8 tile = vram8(screenBase + u32((ty >> 3) * (size >> 3) + (tx >> 3)));
                u8 idx = vram8(charBase + u32(tile) * 64 + u32((ty & 7) * 8 + (tx & 7)));
                if (idx) bg[i][x] = pal16(idx);
            } else if (kind == 3) {
                if (tx < 0 || ty < 0 || tx >= 240 || ty >= 160) continue;
                u32 a = u32(ty * 240 + tx) * 2; bg[i][x] = u16((vram_[a] | (vram_[a + 1] << 8)) & 0x7FFF);
            } else if (kind == 4) {
                if (tx < 0 || ty < 0 || tx >= 240 || ty >= 160) continue;
                u8 idx = vram_[frameBase + u32(ty * 240 + tx)]; if (idx) bg[i][x] = pal16(idx);
            } else {
                if (tx < 0 || ty < 0 || tx >= 160 || ty >= 128) continue;
                u32 a = frameBase + u32(ty * 160 + tx) * 2; bg[i][x] = u16((vram_[a] | (vram_[a + 1] << 8)) & 0x7FFF);
            }
        }
    };

    switch (mode) {
    case 0: for (int i = 0; i < 4; ++i) if (dispcnt & (0x100 << i)) { bgOn[i] = true; textBG(i); } break;
    case 1:
        for (int i = 0; i < 2; ++i) if (dispcnt & (0x100 << i)) { bgOn[i] = true; textBG(i); }
        if (dispcnt & 0x400) { bgOn[2] = true; affineBG(2, 0); }
        break;
    case 2: for (int i = 2; i < 4; ++i) if (dispcnt & (0x100 << i)) { bgOn[i] = true; affineBG(i, 0); } break;
    case 3: case 4: case 5: if (dispcnt & 0x400) { bgOn[2] = true; affineBG(2, mode); } break;
    default: break;
    }

    // ---- sprites
    static thread_local u16 obj[W]; static thread_local u8 objPrio[W], objSemi[W], objWin[W];
    for (int x = 0; x < W; ++x) { obj[x] = kTransparent; objPrio[x] = 4; objSemi[x] = 0; objWin[x] = 0; }
    if (dispcnt & 0x1000) {
        const bool map1D = dispcnt & 0x40;
        for (int n = 0; n < 128; ++n) {
            u16 a0 = u16(oam_[n * 8] | (oam_[n * 8 + 1] << 8)), a1 = u16(oam_[n * 8 + 2] | (oam_[n * 8 + 3] << 8)),
                a2 = u16(oam_[n * 8 + 4] | (oam_[n * 8 + 5] << 8));
            bool affine = a0 & 0x100;
            if (!affine && (a0 & 0x200)) continue;
            int shape = (a0 >> 14) & 3; if (shape == 3) continue;
            int objMode = (a0 >> 10) & 3; if (objMode == 3) continue;
            int w = kObjSize[shape][(a1 >> 14) & 3][0], h = kObjSize[shape][(a1 >> 14) & 3][1];
            int bw = w, bh = h;
            if (affine && (a0 & 0x200)) { bw *= 2; bh *= 2; }
            int sy = a0 & 0xFF; int iy = (y - sy) & 0xFF;
            if (iy >= bh) continue;
            if (a0 & 0x1000) iy -= iy % mosOV;
            int sx = a1 & 0x1FF; if (sx >= 240) sx -= 512;
            u32 tile = a2 & 0x3FF; int prio = (a2 >> 10) & 3; u32 palBank = a2 >> 12;
            bool c256 = a0 & 0x2000;
            if (mode >= 3 && tile < 512) continue;
            s32 pa = 256, pb = 0, pc = 0, pd = 256;
            if (affine) {
                u32 g = ((a1 >> 9) & 31) * 32;
                pa = s16(oam_[g + 6] | (oam_[g + 7] << 8)); pb = s16(oam_[g + 14] | (oam_[g + 15] << 8));
                pc = s16(oam_[g + 22] | (oam_[g + 23] << 8)); pd = s16(oam_[g + 30] | (oam_[g + 31] << 8));
            }
            for (int ix = 0; ix < bw; ++ix) {
                int x = sx + ix; if (x < 0 || x >= W) continue;
                int tx, ty;
                if (affine) {
                    int dx = ix - bw / 2, dy = iy - bh / 2;
                    tx = ((pa * dx + pb * dy) >> 8) + w / 2; ty = ((pc * dx + pd * dy) >> 8) + h / 2;
                    if (tx < 0 || ty < 0 || tx >= w || ty >= h) continue;
                } else {
                    tx = ix; ty = iy;
                    if (a1 & 0x1000) tx = w - 1 - tx;
                    if (a1 & 0x2000) ty = h - 1 - ty;
                }
                if (a0 & 0x1000) tx -= tx % mosOH;
                u32 t; u8 idx;
                if (c256) {
                    t = map1D ? tile + u32(((ty >> 3) * (w >> 3) + (tx >> 3)) * 2) : (tile & ~1u) + u32((ty >> 3) * 32 + (tx >> 3) * 2);
                    idx = vram_[0x10000 + ((t & 0x3FF) * 32 + u32((ty & 7) * 8 + (tx & 7))) % 0x8000];
                    if (!idx) continue;
                } else {
                    t = map1D ? tile + u32((ty >> 3) * (w >> 3) + (tx >> 3)) : tile + u32((ty >> 3) * 32 + (tx >> 3));
                    u8 b = vram_[0x10000 + ((t & 0x3FF) * 32 + u32((ty & 7) * 4 + ((tx & 7) >> 1))) % 0x8000];
                    idx = (tx & 1) ? (b >> 4) : (b & 15);
                    if (!idx) continue;
                }
                if (objMode == 2) { objWin[x] = 1; continue; }
                if (prio < objPrio[x]) {
                    obj[x] = pal16(0x100 + (c256 ? idx : (palBank << 4 | idx)));
                    objPrio[x] = u8(prio); objSemi[x] = objMode == 1;
                }
            }
        }
    }

    // ---- windows
    const bool win0 = dispcnt & 0x2000, win1 = dispcnt & 0x4000, winObj = dispcnt & 0x8000;
    const bool anyWin = win0 || win1 || winObj;
    auto inWinV = [&](u16 v) { int y1 = v >> 8, y2 = v & 0xFF; return y1 <= y2 ? (y >= y1 && y < y2) : (y >= y1 || y < y2); };
    auto inWinH = [&](u16 v, int x) { int x1 = v >> 8, x2 = v & 0xFF; if (x2 > 240) x2 = 240; return x1 <= x2 ? (x >= x1 && x < x2) : (x >= x1 || x < x2); };
    const bool w0v = win0 && inWinV(io_[0x44 / 2]), w1v = win1 && inWinV(io_[0x46 / 2]);
    const u16 winin = io_[0x48 / 2], winout = io_[0x4A / 2];

    // ---- composition
    const u16 bldcnt = io_[0x50 / 2];
    const int bmode = (bldcnt >> 6) & 3;
    u32 eva = io_[0x52 / 2] & 31, evb = (io_[0x52 / 2] >> 8) & 31, evy = io_[0x54 / 2] & 31;
    if (eva > 16) eva = 16; if (evb > 16) evb = 16; if (evy > 16) evy = 16;
    const u16 backdrop = pal16(0);
    int bgPrio[4]; for (int i = 0; i < 4; ++i) bgPrio[i] = io_[(0x08 + 2 * i) / 2] & 3;

    for (int x = 0; x < W; ++x) {
        u8 mask = 0x3F;
        if (anyWin) {
            if (w0v && inWinH(io_[0x40 / 2], x)) mask = winin & 0x3F;
            else if (w1v && inWinH(io_[0x42 / 2], x)) mask = (winin >> 8) & 0x3F;
            else if (winObj && objWin[x]) mask = (winout >> 8) & 0x3F;
            else mask = winout & 0x3F;
        }
        // Top two layers: layer ids 0-3 BG, 4 OBJ, 5 backdrop.
        u16 col[2] = {backdrop, backdrop}; int id[2] = {5, 5}; int found = 0;
        for (int p = 0; p < 4 && found < 2; ++p) {
            if ((mask & 0x10) && obj[x] != kTransparent && objPrio[x] == p) { col[found] = obj[x]; id[found] = 4; ++found; if (found == 2) break; }
            for (int i = 0; i < 4 && found < 2; ++i)
                if (bgOn[i] && (mask & (1 << i)) && bgPrio[i] == p && bg[i][x] != kTransparent) { col[found] = bg[i][x]; id[found] = i; ++found; }
        }
        u16 out = col[0];
        bool firstT = bldcnt & (1 << id[0]), secondT = bldcnt & (0x100 << id[1]);
        if (id[0] == 4 && objSemi[x] && secondT) out = blendAlpha(col[0], col[1], eva, evb);
        else if ((mask & 0x20) && firstT) {
            if (bmode == 1 && secondT) out = blendAlpha(col[0], col[1], eva, evb);
            else if (bmode == 2) out = brighten(col[0], evy);
            else if (bmode == 3) out = darken(col[0], evy);
        }
        dst[x] = toARGB(out);
    }
}

// ------------------------------------------------------------------ audio

namespace { constexpr double kCyclesPerSample = 16777216.0 / kAudioSampleRate; }

void GBASystem::audioTick(u32 cycles) {
    seqCycles_ += cycles;
    while (seqCycles_ >= 32768) { seqCycles_ -= 32768; audioSequencer(); }
    sampleAccum_ += cycles;
    while (sampleAccum_ >= kCyclesPerSample) { sampleAccum_ -= kCyclesPerSample; mixSample(); }
}

void GBASystem::audioSequencer() {
    int step = seqStep_; seqStep_ = (seqStep_ + 1) & 7;
    if ((step & 1) == 0) {                                               // length counters, 256 Hz
        if ((io_[0x64 / 2] & 0x4000) && sq_[0].len > 0 && --sq_[0].len == 0) sq_[0].on = false;
        if ((io_[0x6C / 2] & 0x4000) && sq_[1].len > 0 && --sq_[1].len == 0) sq_[1].on = false;
        if ((io_[0x74 / 2] & 0x4000) && wave_.len > 0 && --wave_.len == 0) wave_.on = false;
        if ((io_[0x7C / 2] & 0x4000) && noise_.len > 0 && --noise_.len == 0) noise_.on = false;
    }
    if (step == 2 || step == 6) {                                        // sweep, 128 Hz
        u16 sw = io_[0x60 / 2]; int period = (sw >> 4) & 7, shift = sw & 7;
        Square& s = sq_[0];
        if (s.on && period && --s.sweepTimer <= 0) {
            s.sweepTimer = period;
            u32 delta = s.shadow >> shift;
            u32 nf = (sw & 8) ? s.shadow - delta : s.shadow + delta;
            if (nf > 2047) s.on = false;
            else if (shift) { s.shadow = nf; io_[0x64 / 2] = u16((io_[0x64 / 2] & ~0x7FF) | nf); }
        }
    }
    if (step == 7) {                                                     // envelopes, 64 Hz
        auto env = [](int& vol, int& timer, u16 reg) {
            int period = (reg >> 8) & 7; if (!period) return;
            if (--timer > 0) return; timer = period;
            if (reg & 0x800) { if (vol < 15) ++vol; } else if (vol > 0) --vol;
        };
        env(sq_[0].vol, sq_[0].envTimer, io_[0x62 / 2]);
        env(sq_[1].vol, sq_[1].envTimer, io_[0x68 / 2]);
        env(noise_.vol, noise_.envTimer, io_[0x78 / 2]);
    }
}

void GBASystem::mixSample() {
    static const u8 duty[4][8] = {{0,0,0,0,0,0,0,1}, {1,0,0,0,0,0,0,1}, {1,0,0,0,0,1,1,1}, {0,1,1,1,1,1,1,0}};
    const u32 C = u32(kCyclesPerSample);
    int out[4] = {};
    for (int c = 0; c < 2; ++c) {
        Square& s = sq_[c];
        if (!s.on) continue;
        u16 freqReg = io_[(c ? 0x6C : 0x64) / 2] & 0x7FF;
        u32 period = (2048 - freqReg) * 16u;
        s.timer += C;
        while (s.timer >= period) { s.timer -= period; s.pos = (s.pos + 1) & 7; }
        int d = (io_[(c ? 0x68 : 0x62) / 2] >> 6) & 3;
        out[c] = duty[d][s.pos] ? s.vol : -s.vol;
    }
    if (wave_.on) {
        u16 l = io_[0x70 / 2], h = io_[0x72 / 2];
        u32 period = (2048 - (io_[0x74 / 2] & 0x7FF)) * 8u;
        int samples = (l & 0x20) ? 64 : 32;
        wave_.timer += C;
        while (wave_.timer >= period) { wave_.timer -= period; wave_.pos = (wave_.pos + 1) % samples; }
        int bank = (l & 0x20) ? 0 : ((l & 0x40) ? 16 : 0);
        int idx = (bank * 2 + wave_.pos) % 64;
        u8 b = waveRam_[idx >> 1]; int smp = (idx & 1) ? (b & 15) : (b >> 4);
        int v = smp - 8;
        int vol = (h >> 13) & 3;
        if (h & 0x8000) v = v * 3 / 4; else if (vol == 0) v = 0; else v >>= (vol - 1);
        out[2] = v * 2;
    }
    if (noise_.on) {
        u16 r = io_[0x7C / 2];
        u32 div = r & 7, sh = (r >> 4) & 15;
        u32 period = (div ? div * 32u : 16u) << (sh + 1);
        noise_.timer += C;
        while (noise_.timer >= period) {
            noise_.timer -= period;
            u16 x = u16((noise_.lfsr ^ (noise_.lfsr >> 1)) & 1);
            noise_.lfsr = u16(noise_.lfsr >> 1);
            if (r & 8) noise_.lfsr = u16((noise_.lfsr & ~0x40) | (x << 6)); else noise_.lfsr = u16((noise_.lfsr & ~0x4000) | (x << 14));
        }
        out[3] = (noise_.lfsr & 1) ? -noise_.vol : noise_.vol;
    }
    s32 L = 0, R = 0;
    if (io_[0x84 / 2] & 0x80) {
        u16 cl = io_[0x80 / 2], ch = io_[0x82 / 2];
        s32 psgL = 0, psgR = 0;
        for (int i = 0; i < 4; ++i) { if (cl & (0x1000 << i)) psgL += out[i]; if (cl & (0x100 << i)) psgR += out[i]; }
        psgL = psgL * (((cl >> 4) & 7) + 1) / 8; psgR = psgR * ((cl & 7) + 1) / 8;
        int ratio = ch & 3; int mul = ratio == 0 ? 1 : (ratio == 1 ? 2 : 4);
        L = psgL * mul * 2; R = psgR * mul * 2;
        for (int f = 0; f < 2; ++f) {
            s32 v = fifoSample_[f] * ((ch & (4 << f)) ? 4 : 2);
            if (ch & (0x200 << (f * 4))) L += v;
            if (ch & (0x100 << (f * 4))) R += v;
        }
    }
    auto clamp = [](s32 v) { v *= 40; return s16(v > 32767 ? 32767 : (v < -32768 ? -32768 : v)); };
    sampleBuf_.push_back(clamp(L)); sampleBuf_.push_back(clamp(R));
}

} // namespace dscore
