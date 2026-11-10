// Copyright (c) 2026 Charlie Rodriguez Garcia. All rights reserved.
// Original clean-room 2D graphics engine (engines A and B), from GBATEK.
// Not yet implemented: mosaic, main-memory display FIFO,
// exact OBJ priority/limits. See README roadmap.
#include "GPU2D.hpp"
#include <algorithm>
#include <cstring>

namespace dscore {

namespace {
constexpr u32 kOpaque = 0x80000000u;

inline int sext9(u32 v) { v &= 0x1FF; return v & 0x100 ? int(v) - 512 : int(v); }
inline s32 sext28(u32 v) { return s32(v << 4) >> 4; }
} // namespace

GPU2D::GPU2D(bool engineA, const u8* io, const u8* palette, const u8* oam, VRAM& vram)
    : isA_(engineA), io_(io), palette_(palette), oam_(oam), vram_(vram),
      bgRegion_(engineA ? VRAM::ABG : VRAM::BBG), objRegion_(engineA ? VRAM::AOBJ : VRAM::BOBJ) {
    reset();
}

u32 GPU2D::toARGB(u16 c) {
    u32 r = c & 31, g = (c >> 5) & 31, b = (c >> 10) & 31;
    r = (r << 3) | (r >> 2); g = (g << 3) | (g >> 2); b = (b << 3) | (b >> 2);
    return 0xFF000000u | (r << 16) | (g << 8) | b;
}

void GPU2D::reset() { refX_[0] = refX_[1] = refY_[0] = refY_[1] = 0; }

void GPU2D::startFrame() { affineRegisterWritten(2); affineRegisterWritten(3); }

void GPU2D::affineRegisterWritten(int bg) {
    int i = bg - 2;
    if (i < 0 || i > 1) return;
    refX_[i] = sext28(io32(0x28 + i * 0x10));
    refY_[i] = sext28(io32(0x2C + i * 0x10));
}

u16 GPU2D::blendAlpha(u16 a, u16 b, u32 eva, u32 evb) {
    eva = std::min(eva, 16u); evb = std::min(evb, 16u);
    u16 out = 0;
    for (int s = 0; s < 15; s += 5) {
        u32 c = (((a >> s) & 31) * eva + ((b >> s) & 31) * evb) >> 4;
        out |= u16(std::min(c, 31u) << s);
    }
    return out;
}
u16 GPU2D::brighten(u16 c, u32 evy) {
    evy = std::min(evy, 16u); u16 out = 0;
    for (int s = 0; s < 15; s += 5) { u32 v = (c >> s) & 31; v += ((31 - v) * evy) >> 4; out |= u16(v << s); }
    return out;
}
u16 GPU2D::darken(u16 c, u32 evy) {
    evy = std::min(evy, 16u); u16 out = 0;
    for (int s = 0; s < 15; s += 5) { u32 v = (c >> s) & 31; v -= (v * evy) >> 4; out |= u16(v << s); }
    return out;
}

void GPU2D::renderLine(int y, u32* out) {
    u32 dispcnt = io32(0x00);
    u32 mode = (dispcnt >> 16) & 3;
    if (!isA_) mode &= 1;
    u16 line[256];
    std::fill(pure3D_, pure3D_ + 256, u8(0));
    // Capture source A is the BG/3D/OBJ composition even while the screen shows VRAM or is off.
    composedValid_ = false;
    if (isA_ && captureActive_ && mode != 1) { composeLine(y, dispcnt, composed_); composedValid_ = true; }
    switch (mode) {
    case 0: std::fill(line, line + 256, u16(0x7FFF)); break;            // display off: white
    case 2: {                                                             // VRAM display (engine A)
        const u8* bank = vram_.bankData(int((dispcnt >> 18) & 3));
        for (int x = 0; x < 256; ++x) { u32 o = (u32(y) * 256 + u32(x)) * 2; line[x] = u16((bank[o] | (bank[o + 1] << 8)) & 0x7FFF); }
        break;
    }
    case 3: std::fill(line, line + 256, u16(0)); break;                 // main memory FIFO: TODO
    default:
        composeLine(y, dispcnt, line);
        if (isA_ && captureActive_) { std::memcpy(composed_, line, sizeof line); composedValid_ = true; }
        break;
    }
    // Master brightness
    u16 mb = io16(0x6C);
    u32 mbMode = (mb >> 14) & 3, factor = mb & 31;
    if (mode != 0 && factor) {
        if (mbMode == 1) for (auto& c : line) c = brighten(c, factor);
        else if (mbMode == 2) for (auto& c : line) c = darken(c, factor);
        if (mbMode == 1 || mbMode == 2) std::fill(pure3D_, pure3D_ + 256, u8(0));
    }
    for (int x = 0; x < 256; ++x) out[x] = toARGB(line[x]);
}

void GPU2D::captureLine(int y, u32 cap) {
    if (!isA_) return;
    int w = captureWidth(cap);
    // Hardware only writes the capture into a bank that is mapped to LCDC (enabled, MST 0).
    // Mario Kart DS leaves capture pointed at bank D while bank D holds ARM7 code (WRAM mode);
    // writing it anyway overwrote that code with black pixels, crashed the ARM7 (sound and
    // wireless CPU) after every race and froze the game with a looping buzz.
    int bank = int((cap >> 16) & 3);
    if ((vram_.control(bank) & 0x87) != 0x80) { ++captureBlocked; return; }
    u8* dst = vram_.bankDataMut(bank);
    u32 wOff = ((cap >> 18) & 3) * 0x8000u;
    u32 rOff = ((cap >> 26) & 3) * 0x8000u;
    u32 dispcnt = io32(0x00);
    const u8* srcB = vram_.bankData(int((dispcnt >> 18) & 3));
    u32 src = (cap >> 29) & 3;
    bool aIs3D = cap & (1u << 24);
    u32 eva = std::min(cap & 31, 16u), evb = std::min((cap >> 8) & 31, 16u);
    const u32* row3d = threeD_ ? threeD_ + size_t(y) * 256 : nullptr;
    for (int x = 0; x < w; ++x) {
        // Source A: graphics screen (always opaque) or the 3D layer alone (its own alpha).
        u16 a; bool aa;
        if (aIs3D) { u32 px = row3d ? row3d[x] : 0; aa = ((px >> 16) & 31) != 0; a = u16(px & 0x7FFF); }
        else { a = composedValid_ ? composed_[x] : 0; aa = composedValid_; }
        u16 b = 0; bool ba = false;
        if (src != 0 && !(cap & (1u << 25))) {             // source B: VRAM (main-memory FIFO unsupported)
            u32 o = (rOff + u32(y * w + x) * 2) & 0x1FFFF;
            u16 v = u16(srcB[o] | (srcB[o + 1] << 8));
            b = v & 0x7FFF; ba = v & 0x8000;
        }
        u16 out;
        switch (src) {
        case 0: out = u16(a | (aa ? 0x8000 : 0)); break;
        case 1: out = u16(b | (ba ? 0x8000 : 0)); break;
        default: {                                          // A+B blend weighted by alpha
            u32 fa = aa ? eva : 0, fb = ba ? evb : 0, r = 0;
            for (int s = 0; s < 15; s += 5) {
                u32 c = (((a >> s) & 31) * fa + ((b >> s) & 31) * fb + 8) >> 4;
                r |= std::min(c, 31u) << s;
            }
            out = u16(r | ((aa && eva) || (ba && evb) ? 0x8000 : 0));
            break;
        }
        }
        u32 o = (wOff + u32(y * w + x) * 2) & 0x1FFFF;
        dst[o] = u8(out); dst[o + 1] = u8(out >> 8);
    }
}

void GPU2D::skipLine(int) {
    u32 dispcnt = io32(0x00);
    u32 mode = (dispcnt >> 16) & 3;
    if (!isA_) mode &= 1;
    if (mode != 1 || (dispcnt & 0x80)) return;              // composeLine would not run either
    static const u8 affine[8] = {0x0, 0x8, 0xC, 0x8, 0xC, 0xC, 0x4, 0x0};   // BGs 2/3 that are affine/ext/bitmap
    u8 m = affine[dispcnt & 7];
    if (!isA_ && (dispcnt & 7) == 6) m = 0;
    for (int bg = 2; bg < 4; ++bg)
        if (m & (1 << bg)) { refX_[bg - 2] += s16(io16(0x22 + (bg - 2) * 0x10)); refY_[bg - 2] += s16(io16(0x26 + (bg - 2) * 0x10)); }
}

void GPU2D::composeLine(int y, u32 dispcnt, u16* out) {
    if (dispcnt & 0x80) { std::fill(out, out + 256, u16(0x7FFF)); return; }   // forced blank

    u32 bgMode = dispcnt & 7;
    // Layer kinds per BG: 0 none, 1 text, 2 affine, 3 extended, 4 large bitmap
    static const u8 kinds[8][4] = {
        {1, 1, 1, 1}, {1, 1, 1, 2}, {1, 1, 2, 2}, {1, 1, 1, 3},
        {1, 1, 2, 3}, {1, 1, 3, 3}, {1, 0, 4, 0}, {1, 1, 0, 0},
    };
    bool enabled[4];
    for (int bg = 0; bg < 4; ++bg) {
        enabled[bg] = (dispcnt >> (8 + bg)) & 1;
        u8 kind = kinds[bgMode][bg];
        if (!isA_ && kind == 4) kind = 0;
        bool is3D = bg == 0 && isA_ && (dispcnt & 0x08);
        if (bg == 0) bg0Is3D_ = is3D && threeD_;
        if (is3D) {                                                    // BG0 = 3D layer
            if (!enabled[0] || !threeD_) { enabled[0] = false; continue; }
            const u32* src = threeD_ + size_t(y) * 256;
            int hofs = sext9(io16(0x10));
            bg0Scroll_ = hofs;
            for (int x = 0; x < 256; ++x) {
                int sx = x + hofs;
                u32 px = (sx >= 0 && sx < 256) ? src[sx] : 0;
                u32 a = (px >> 16) & 31;
                alpha3D_[x] = u8(a);
                bg_[0].color[x] = a ? (kOpaque | (px & 0x7FFF)) : 0;
            }
            continue;
        }
        if (kind == 0) enabled[bg] = false;
        if (!enabled[bg]) {
            if (kind == 2 || kind == 3 || kind == 4) { refX_[bg - 2] += s16(io16(0x22 + (bg - 2) * 0x10)); refY_[bg - 2] += s16(io16(0x26 + (bg - 2) * 0x10)); }
            continue;
        }
        if (kind == 1) renderText(bg, y, dispcnt, bg_[bg]);
        else renderAffine(bg, dispcnt, bg_[bg], kind == 2 ? 0 : (kind == 3 ? 1 : 2));
    }
    bool objOn = (dispcnt >> 12) & 1;
    if (objOn || (dispcnt & 0x8000)) renderObjects(y, dispcnt);
    else { std::fill(objColor_, objColor_ + 256, 0u); std::fill(objWindow_, objWindow_ + 256, false); }

    // Windows
    bool win0 = dispcnt & 0x2000, win1 = dispcnt & 0x4000, winObj = dispcnt & 0x8000;
    bool anyWin = win0 || win1 || winObj;
    // Window bounds read once per line (not per pixel); the vertical test is per line too.
    int wx1[2], wx2[2]; bool wInY[2];
    for (int w = 0; w < 2; ++w) {
        u16 h = io16(0x40 + w * 2), v = io16(0x44 + w * 2);
        wx1[w] = h >> 8; wx2[w] = h & 0xFF;
        int y1 = v >> 8, y2 = v & 0xFF;
        wInY[w] = y1 <= y2 ? (y >= y1 && y < y2) : (y >= y1 || y < y2);
    }
    auto inside = [&](int w, int x) {
        if (!wInY[w]) return false;
        int x1 = wx1[w], x2 = wx2[w];
        return x1 <= x2 ? (x >= x1 && x < x2) : (x >= x1 || x < x2);
    };
    u16 winin = io16(0x48), winout = io16(0x4A);
    u8 winMask[256];
    if (anyWin) {
        for (int x = 0; x < 256; ++x) {
            if (win0 && inside(0, x)) winMask[x] = winin & 0x3F;
            else if (win1 && inside(1, x)) winMask[x] = (winin >> 8) & 0x3F;
            else if (winObj && objWindow_[x]) winMask[x] = (winout >> 8) & 0x3F;
            else winMask[x] = winout & 0x3F;
        }
    }
    // Background order by priority (stable by BG number), computed once per line.
    int order[4], nOrder = 0; u8 orderPrio[4];
    for (int p = 0; p < 4; ++p)
        for (int bg = 0; bg < 4; ++bg)
            if (enabled[bg] && (io16(0x08 + bg * 2) & 3) == p) { order[nOrder] = bg; orderPrio[nOrder] = u8(p); ++nOrder; }

    u16 bldcnt = io16(0x50), bldalpha = io16(0x52);
    u32 eva = bldalpha & 31, evb = (bldalpha >> 8) & 31, evy = io16(0x54) & 31;
    u32 effect = (bldcnt >> 6) & 3;
    u16 backdrop = pal(0) & 0x7FFF;

    for (int x = 0; x < 256; ++x) {
        u8 mask = anyWin ? winMask[x] : 0x3F;
        // Find the two front-most layers. Layer ids: 0-3 BG, 4 OBJ, 5 backdrop.
        int ids[2] = {5, 5}; u16 cols[2] = {backdrop, backdrop}; int found = 0;
        bool objHere = (mask & 0x10) && (objColor_[x] & kOpaque);
        bool objDone = !objHere;
        for (int k = 0; k <= nOrder && found < 2; ++k) {
            int prio = k < nOrder ? orderPrio[k] : 4;
            if (!objDone && objPrio_[x] <= prio) {
                ids[found] = 4; cols[found] = u16(objColor_[x] & 0x7FFF); ++found; objDone = true;
                if (found == 2) break;
            }
            if (k == nOrder) break;
            int bg = order[k];
            if (!(mask & (1 << bg)) || !(bg_[bg].color[x] & kOpaque)) continue;
            ids[found] = bg; cols[found] = u16(bg_[bg].color[x] & 0x7FFF); ++found;
        }
        u16 c = cols[0];
        bool firstTarget = (bldcnt >> ids[0]) & 1;
        bool secondTarget = (bldcnt >> (8 + ids[1])) & 1;
        if (ids[0] == 0 && bg0Is3D_ && secondTarget) {
            // The 3D layer always blends with its own per-pixel alpha (BLDALPHA EVA/EVB are not
            // used); fully opaque 3D pixels stay opaque even when BLDCNT selects alpha blending.
            if (alpha3D_[x] < 31) { u32 a = (alpha3D_[x] + 1u) / 2; c = blendAlpha(cols[0], cols[1], a, 16 - a); }
        } else if (ids[0] == 4 && (objMode_[x] == 1 || objMode_[x] == 3) && secondTarget) {
            if (objMode_[x] == 3) { u32 a = objAlpha_[x] + 1u; c = blendAlpha(cols[0], cols[1], a, 16 - a); }
            else c = blendAlpha(cols[0], cols[1], eva, evb);
        } else if ((mask & 0x20) && firstTarget) {
            if (effect == 1 && secondTarget) c = blendAlpha(cols[0], cols[1], eva, evb);
            else if (effect == 2) c = brighten(c, evy);
            else if (effect == 3) c = darken(c, evy);
        }
        out[x] = c;
        pure3D_[x] = u8(ids[0] == 0 && bg0Is3D_ && alpha3D_[x] == 31 && c == cols[0]);
    }
}

void GPU2D::renderText(int bg, int y, u32 dispcnt, Layer& L) {
    u16 cnt = io16(0x08 + bg * 2);
    u32 hofs = io16(0x10 + bg * 4) & 0x1FF, vofs = io16(0x12 + bg * 4) & 0x1FF;
    u32 charBase = ((cnt >> 2) & 15) * 0x4000u, screenBase = ((cnt >> 8) & 31) * 0x800u;
    if (isA_) { charBase += ((dispcnt >> 24) & 7) * 0x10000u; screenBase += ((dispcnt >> 27) & 7) * 0x10000u; }
    u32 size = (cnt >> 14) & 3;
    u32 w = (size & 1) ? 512 : 256, h = (size & 2) ? 512 : 256;
    bool bpp8 = cnt & 0x80;
    bool extPal = bpp8 && (dispcnt & 0x40000000u);
    int slot = bg; if (bg < 2 && (cnt & 0x2000)) slot += 2;
    const u8* ext = extPal ? vram_.bgExtPalette(isA_, slot) : nullptr;

    u32 yy = (u32(y) + vofs) & (h - 1);
    // Tile-at-a-time: one map fetch and one tile-row fetch per 8 pixels.
    int x = 0;
    while (x < 256) {
        u32 xx = (u32(x) + hofs) & (w - 1);
        u32 block = (xx >> 8) + (yy >> 8) * (w >> 8);
        u16 e = bg16(screenBase + block * 0x800 + ((yy & 255) >> 3) * 64 + ((xx & 255) >> 3) * 2);
        u32 tile = e & 0x3FF, py = yy & 7;
        if (e & 0x800) py = 7 - py;
        bool hflip = e & 0x400;
        u8 row[8];
        if (bpp8) {
            u32 base = charBase + tile * 64 + py * 8;
            if (const u8* p = vram_.page(bgRegion_, base); p && ((base & 0x3FFF) <= 0x3FF8)) std::memcpy(row, p + (base & 0x3FFF), 8);
            else for (int k = 0; k < 8; ++k) row[k] = bg8(base + u32(k));
        } else {
            u32 base = charBase + tile * 32 + py * 4;
            u8 b4[4];
            if (const u8* p = vram_.page(bgRegion_, base); p && ((base & 0x3FFF) <= 0x3FFC)) std::memcpy(b4, p + (base & 0x3FFF), 4);
            else for (int k = 0; k < 4; ++k) b4[k] = bg8(base + u32(k));
            for (int k = 0; k < 4; ++k) { row[k * 2] = b4[k] & 15; row[k * 2 + 1] = b4[k] >> 4; }
        }
        u32 palBase = bpp8 ? 0 : (e >> 12) * 16u;
        for (u32 px = xx & 7; px < 8 && x < 256; ++px, ++x) {
            u8 idx = row[hflip ? 7 - px : px];
            u32 color = 0;
            if (idx) {
                if (extPal) {
                    u32 o = ((e >> 12) * 256u + idx) * 2;
                    color = ext ? (kOpaque | ext[o] | (ext[o + 1] << 8)) : kOpaque;
                } else color = kOpaque | pal(palBase + idx);
            }
            L.color[x] = color;
        }
    }
}

void GPU2D::renderAffine(int bg, u32 dispcnt, Layer& L, int kind) {
    int i = bg - 2;
    u16 cnt = io16(0x08 + bg * 2);
    s32 pa = s16(io16(0x20 + i * 0x10)), pb = s16(io16(0x22 + i * 0x10));
    s32 pc = s16(io16(0x24 + i * 0x10)), pd = s16(io16(0x26 + i * 0x10));
    bool wrap = cnt & 0x2000;
    u32 size = (cnt >> 14) & 3;
    u32 charBase = ((cnt >> 2) & 15) * 0x4000u, screenBase = ((cnt >> 8) & 31) * 0x800u;
    if (isA_) { charBase += ((dispcnt >> 24) & 7) * 0x10000u; screenBase += ((dispcnt >> 27) & 7) * 0x10000u; }

    // Determine geometry
    u32 w, h; int sub = 0;   // sub: 0 classic map, 1 ext 16-bit map, 2 256-colour bitmap, 3 direct bitmap, 4 large
    if (kind == 0) { w = h = 128u << size; sub = 0; }
    else if (kind == 2) { w = (size & 1) ? 1024 : 512; h = (size & 1) ? 512 : 1024; sub = 4; }
    else if (!(cnt & 0x80)) { w = h = 128u << size; sub = 1; }
    else {
        static const u32 bw[4] = {128, 256, 512, 512}, bh[4] = {128, 256, 256, 512};
        w = bw[size]; h = bh[size]; sub = (cnt & 0x04) ? 3 : 2;
    }
    bool extPal = (dispcnt & 0x40000000u) != 0;
    const u8* ext = vram_.bgExtPalette(isA_, bg);
    u32 bmpBase = ((cnt >> 8) & 31) * 0x4000u;

    s32 tx = refX_[i], ty = refY_[i];
    for (int x = 0; x < 256; ++x, tx += pa, ty += pc) {
        s32 ix = tx >> 8, iy = ty >> 8;
        if (wrap) { ix &= s32(w - 1); iy &= s32(h - 1); }
        else if (ix < 0 || iy < 0 || ix >= s32(w) || iy >= s32(h)) { L.color[x] = 0; continue; }
        u32 ux = u32(ix), uy = u32(iy), color = 0;
        switch (sub) {
        case 0: {
            u8 tile = bg8(screenBase + (uy >> 3) * (w >> 3) + (ux >> 3));
            u8 idx = bg8(charBase + tile * 64u + (uy & 7) * 8 + (ux & 7));
            if (idx) color = kOpaque | pal(idx);
            break;
        }
        case 1: {
            u16 e = bg16(screenBase + ((uy >> 3) * (w >> 3) + (ux >> 3)) * 2);
            u32 px = ux & 7, py = uy & 7;
            if (e & 0x400) px = 7 - px;
            if (e & 0x800) py = 7 - py;
            u8 idx = bg8(charBase + (e & 0x3FFu) * 64 + py * 8 + px);
            if (idx) {
                if (extPal) { u32 o = ((e >> 12) * 256u + idx) * 2; color = ext ? (kOpaque | ext[o] | (ext[o + 1] << 8)) : kOpaque; }
                else color = kOpaque | pal(idx);
            }
            break;
        }
        case 2: case 4: {
            u32 base = (sub == 4) ? 0 : bmpBase;
            u8 idx = bg8(base + uy * w + ux);
            if (idx) color = kOpaque | pal(idx);
            break;
        }
        default: {
            u16 c = bg16(bmpBase + (uy * w + ux) * 2);
            if (c & 0x8000) color = kOpaque | (c & 0x7FFF);
            break;
        }
        }
        L.color[x] = color;
    }
    refX_[i] += pb; refY_[i] += pd;
}

void GPU2D::renderObjects(int y, u32 dispcnt) {
    std::fill(objColor_, objColor_ + 256, 0u);
    std::fill(objWindow_, objWindow_ + 256, false);
    std::fill(objPrio_, objPrio_ + 256, u8(4));
    std::fill(objMode_, objMode_ + 256, u8(0));
    if (!((dispcnt >> 12) & 1)) return;
    static const u8 sizes[3][4][2] = {
        {{8, 8}, {16, 16}, {32, 32}, {64, 64}},
        {{16, 8}, {32, 8}, {32, 16}, {64, 32}},
        {{8, 16}, {8, 32}, {16, 32}, {32, 64}},
    };
    auto rd16 = [&](u32 o) { return u16(oam_[o] | (oam_[o + 1] << 8)); };
    bool oneD = dispcnt & 0x10;
    u32 tileBoundary = 32u << ((dispcnt >> 20) & 3);
    const u8* objExt = (dispcnt & 0x80000000u) ? vram_.objExtPalette(isA_) : nullptr;

    for (int n = 0; n < 128; ++n) {
        u16 a0 = rd16(n * 8), a1 = rd16(n * 8 + 2), a2 = rd16(n * 8 + 4);
        bool affine = a0 & 0x100;
        if (!affine && (a0 & 0x200)) continue;           // disabled
        u32 shape = (a0 >> 14) & 3;
        if (shape == 3) continue;
        u32 mode = (a0 >> 10) & 3;
        int w = sizes[shape][(a1 >> 14) & 3][0], h = sizes[shape][(a1 >> 14) & 3][1];
        bool dbl = affine && (a0 & 0x200);
        int bw = dbl ? w * 2 : w, bh = dbl ? h * 2 : h;
        int row = (y - (a0 & 0xFF)) & 0xFF;
        if (row >= bh) continue;
        int ox = a1 & 0x1FF; if (ox >= 256) ox -= 512;
        u32 prio = (a2 >> 10) & 3;
        u32 tile = a2 & 0x3FF;
        bool bpp8 = a0 & 0x2000;
        s32 pa = 256, pb = 0, pc = 0, pd = 256;
        if (affine) {
            u32 g = ((a1 >> 9) & 31) * 32;
            pa = s16(rd16(g + 6)); pb = s16(rd16(g + 14)); pc = s16(rd16(g + 22)); pd = s16(rd16(g + 30));
        }
        for (int sx = 0; sx < bw; ++sx) {
            int x = ox + sx;
            if (x < 0 || x >= 256) continue;
            int texX, texY;
            if (affine) {
                int dx = sx - bw / 2, dy = row - bh / 2;
                texX = ((pa * dx + pb * dy) >> 8) + w / 2;
                texY = ((pc * dx + pd * dy) >> 8) + h / 2;
                if (texX < 0 || texY < 0 || texX >= w || texY >= h) continue;
            } else {
                texX = (a1 & 0x1000) ? w - 1 - sx : sx;
                texY = (a1 & 0x2000) ? h - 1 - row : row;
            }
            u32 color = 0;
            if (mode == 3) {                              // bitmap OBJ
                u32 addr;
                if (dispcnt & 0x40) addr = tile * (128u << ((dispcnt >> 22) & 1)) + u32(texY * w + texX) * 2;
                else if (dispcnt & 0x20) addr = (tile & 0x1F) * 0x10 + (tile & 0x3E0) * 0x80 + u32(texY) * 512 + u32(texX) * 2;
                else addr = (tile & 0x0F) * 0x10 + (tile & 0x3F0) * 0x80 + u32(texY) * 256 + u32(texX) * 2;
                u16 c = obj16(addr);
                if ((c & 0x8000) && (a2 >> 12)) color = kOpaque | (c & 0x7FFF);
            } else {
                u32 tx = u32(texX) >> 3, ty = u32(texY) >> 3, px = u32(texX) & 7, py = u32(texY) & 7;
                u32 addr;
                if (oneD) addr = tile * tileBoundary + (ty * u32(w / 8) + tx) * (bpp8 ? 64 : 32);
                else addr = (tile + ty * 32 + tx * (bpp8 ? 2 : 1)) * 32;
                if (bpp8) {
                    u8 idx = obj8(addr + py * 8 + px);
                    if (idx) {
                        if (dispcnt & 0x80000000u) { u32 o = ((a2 >> 12) * 256u + idx) * 2; color = objExt ? (kOpaque | objExt[o] | (objExt[o + 1] << 8)) : kOpaque; }
                        else color = kOpaque | objPal(idx);
                    }
                } else {
                    u8 b = obj8(addr + py * 4 + px / 2);
                    u8 idx = (px & 1) ? (b >> 4) : (b & 15);
                    if (idx) color = kOpaque | objPal((a2 >> 12) * 16 + idx);
                }
            }
            if (!(color & kOpaque)) continue;
            if (mode == 2) { objWindow_[x] = true; continue; }
            if (!(objColor_[x] & kOpaque) || prio < objPrio_[x]) {
                objColor_[x] = color; objPrio_[x] = u8(prio); objMode_[x] = u8(mode); objAlpha_[x] = u8(a2 >> 12);
            }
        }
    }
}

} // namespace dscore
