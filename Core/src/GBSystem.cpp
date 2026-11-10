// Copyright (c) 2026 Charlie Rodriguez Garcia. All rights reserved.
// Original clean-room Game Boy / Game Boy Color core. Written from public hardware
// documentation; contains no third-party emulator code and no boot ROM.
#include "GBSystem.hpp"
#include "dscore/StateIO.hpp"
#include <algorithm>
#include <cmath>
#include <cstring>
#include <ctime>

namespace dscore {

bool isGBImage(const u8* d, size_t n) {
    if (n < 0x150) return false;
    u8 sum = 0;
    for (int i = 0x134; i <= 0x14C; ++i) sum = u8(sum - d[i] - 1);
    return sum == d[0x14D];
}

std::unique_ptr<EmulatorCore> createGBCore() { return std::make_unique<GBSystem>(); }

namespace {
enum { FZ = 0x80, FN = 0x40, FH = 0x20, FC = 0x10 };
const u8 kDuty[4][8] = {{0,0,0,0,0,0,0,1},{1,0,0,0,0,0,0,1},{1,0,0,0,0,1,1,1},{0,1,1,1,1,1,1,0}};
const u32 kGreen[4] = {0xFFC4CFA1, 0xFF8B956D, 0xFF4D533C, 0xFF1F1F1F};
const u32 kGray[4]  = {0xFFFFFFFF, 0xFFAAAAAA, 0xFF555555, 0xFF000000};
// APU read-back masks (unused bits read as 1), FF10-FF2F.
const u8 kApuMask[0x20] = {0x80,0x3F,0x00,0xFF,0xBF, 0xFF,0x3F,0x00,0xFF,0xBF, 0x7F,0xFF,0x9F,0xFF,0xBF,
                           0xFF,0xFF,0x00,0x00,0xBF, 0x00,0x00,0x70, 0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF};
}

GBSystem::GBSystem() {
    frame_.assign(kScreenPixels, 0xFFFFFFFF);
    blank_.assign(kScreenPixels, 0xFF000000);
    buildLut();
}

void GBSystem::buildLut() {
    for (int c = 0; c < 32768; ++c) {
        int r = c & 31, g = (c >> 5) & 31, b = (c >> 10) & 31;
        int R, G, Bc;
        if (colorCorrect_) {
            // Approximates the washed-out, slightly mixed colours of the GBC's reflective LCD.
            double fr = std::pow(r / 31.0, 2.2), fg = std::pow(g / 31.0, 2.2), fb = std::pow(b / 31.0, 2.2);
            double nr = 0.82 * fr + 0.125 * fg + 0.055 * fb;
            double ng = 0.06 * fr + 0.76 * fg + 0.18 * fb;
            double nb = 0.055 * fr + 0.175 * fg + 0.77 * fb;
            auto out = [](double v) { v = std::pow(std::min(1.0, std::max(0.0, v)), 1 / 2.2); return int(v * 240 + 12); };
            R = out(nr); G = out(ng); Bc = out(nb);
        } else {
            R = (r << 3) | (r >> 2); G = (g << 3) | (g >> 2); Bc = (b << 3) | (b >> 2);
        }
        cgbLut_[c] = 0xFF000000u | u32(R) << 16 | u32(G) << 8 | u32(Bc);
    }
}

void GBSystem::setVideoOptions(int p, bool cc) {
    dmgPalette_ = p == 1 ? 1 : 0;
    if (cc != colorCorrect_) { colorCorrect_ = cc; buildLut(); }
}

bool GBSystem::setLLEBIOS(const std::vector<u8>& b, const std::vector<u8>&, const std::vector<u8>&, bool) {
    if (b.empty()) { boot_.clear(); return true; }
    if (b.size() != 0x100 && b.size() != 0x900) return false;
    boot_ = b;
    return true;
}

bool GBSystem::loadROM(const u8* d, size_t n, std::string& err) {
    if (n < 0x150 || n > (8u << 20)) { err = "Not a Game Boy cartridge image."; return false; }
    u8 type = d[0x147];
    GBState fresh; static_cast<GBState&>(*this) = fresh;
    switch (type) {
        case 0x00: case 0x08: case 0x09: mbc = 0; hasBattery = type == 0x09; break;
        case 0x01: case 0x02: case 0x03: mbc = 1; hasBattery = type == 0x03; break;
        case 0x05: case 0x06: mbc = 2; hasBattery = type == 0x06; break;
        case 0x0F: case 0x10: case 0x11: case 0x12: case 0x13:
            mbc = 3; hasRTC = type <= 0x10; hasBattery = type == 0x0F || type == 0x10 || type == 0x13; break;
        case 0x19: case 0x1A: case 0x1B: case 0x1C: case 0x1D: case 0x1E:
            mbc = 5; hasBattery = type == 0x1B || type == 0x1E; hasRumble = type >= 0x1C; break;
        default: {
            char buf[80]; snprintf(buf, sizeof buf, "Unsupported cartridge type 0x%02X.", type);
            err = buf; return false;
        }
    }
    size_t romSize = 0x8000;
    while (romSize < n) romSize <<= 1;
    rom_.assign(romSize, 0xFF);
    std::memcpy(rom_.data(), d, n);
    static const u32 ramSizes[6] = {0, 0x800, 0x2000, 0x8000, 0x20000, 0x10000};
    u32 ram = d[0x149] < 6 ? ramSizes[d[0x149]] : 0;
    if (mbc == 2) ram = 0x200;
    if (mbc == 1 && ram > 0x8000) ram = 0x8000;
    eram_.assign(ram, 0xFF);
    cartCGB_ = (d[0x143] & 0x80) != 0;
    info_ = RomInfo{};
    int tl = cartCGB_ ? 15 : 16;
    for (int i = 0; i < tl; ++i) { char c = char(d[0x134 + i]); if (c < 0x20 || c > 0x7E) break; info_.title += c; }
    while (!info_.title.empty() && info_.title.back() == ' ') info_.title.pop_back();
    if (cartCGB_) {
        bool ok = true;
        for (int i = 0; i < 4; ++i) { char c = char(d[0x13F + i]); if (c < 'A' || c > 'Z') ok = false; }
        if (ok) info_.gameCode.assign(reinterpret_cast<const char*>(d + 0x13F), 4);
    }
    info_.makerCode.assign(reinterpret_cast<const char*>(d + 0x144), 2);
    info_.headerCrcValid = isGBImage(d, n);
    reset();
    return true;
}

void GBSystem::applyBootState() {
    if (cgb) { A = 0x11; F = 0x80; B = 0x00; C = 0x00; D = 0xFF; E = 0x56; H = 0x00; L = 0x0D; divCounter = 0x1EA0; }
    else { A = 0x01; F = 0xB0; B = 0x00; C = 0x13; D = 0x00; E = 0xD8; H = 0x01; L = 0x4D; divCounter = 0xABCC; }
    SP = 0xFFFE; PC = 0x0100;
    io[0x00] = 0xCF; io[0x05] = 0; io[0x06] = 0; io[0x07] = 0xF8; io[0x0F] = 0xE1;
    io[0x40] = 0x91; io[0x41] = 0x85; io[0x42] = 0; io[0x43] = 0; io[0x45] = 0;
    io[0x47] = 0xFC; io[0x48] = 0xFF; io[0x49] = 0xFF; io[0x4A] = 0; io[0x4B] = 0;
    // APU after boot: channel 1 was used for the start-up chime.
    const u8 apu[0x17] = {0x80,0xBF,0xF3,0xFF,0xBF, 0xFF,0x3F,0x00,0xFF,0xBF, 0x7F,0xFF,0x9F,0xFF,0xBF, 0xFF,0xFF,0x00,0x00,0xBF, 0x77,0xF3,0xF1};
    std::memcpy(io + 0x10, apu, sizeof apu);
    sq[0].on = true; sq[0].dac = true;
    sq[1].dac = false; wave.dac = false; noise.dac = false;
    for (int i = 0; i < 64; ++i) bgPal[i] = 0xFF;
    ly = 0; lineDot = 0; mode = 2;
}

void GBSystem::reset() {
    std::vector<u8> keepRom; // state reset keeps the cartridge and battery RAM
    int keepMbc = mbc; bool b = hasBattery, r = hasRTC, ru = hasRumble;
    u8 keepRtc[5]; std::memcpy(keepRtc, rtc, 5);
    GBState fresh; static_cast<GBState&>(*this) = fresh;
    mbc = keepMbc; hasBattery = b; hasRTC = r; hasRumble = ru; std::memcpy(rtc, keepRtc, 5);
    cgb = cartCGB_ || boot_.size() == 0x900;
    if (!boot_.empty()) {
        if (boot_.size() == 0x100) cgb = false;
        bootMapped = true; PC = 0; SP = 0;
        io[0x40] = 0; io[0x0F] = 0xE0; io[0x00] = 0xCF;
        // a CGB boot ROM picks DMG compatibility itself (writes KEY0 before unmapping).
    } else {
        applyBootState();
    }
    std::fill(frame_.begin(), frame_.end(), 0xFF000000);
    for (int y = 0; y < SH; ++y) for (int x = 0; x < W; ++x) frame_[y * kScreenWidth + x] = cgb ? 0xFFFFFFFF : dmgColor(0);
    serial_.clear();
    audio_.clear();
}

void GBSystem::setButtons(u32 m) {
    u32 old = buttons;
    buttons = m & 0xFF;
    if (buttons & ~old) { io[0x0F] |= 0x10; if (stopped) stopped = false; }
}

// ---------------------------------------------------------------- frame loop

void GBSystem::runFrame() {
    drawing_ = skipCounter_ == 0;
    lastDrawn_ = drawing_;
    skipCounter_ = skipCounter_ >= frameSkip_ ? 0 : skipCounter_ + 1;
    frameDone = false;
    // A frame is 70224 dots; with the LCD on, the frame ends at the start of v-blank.
    long guard = 0;
    while (!frameDone && guard < 200000) { step(); ++guard; }
    ++frames;
    if (!sampleBuf_.empty()) { audio_.push(sampleBuf_.data(), sampleBuf_.size() / 2); sampleBuf_.clear(); }
}

#ifndef DMA_DELAY
#define DMA_DELAY 2
#endif
void GBSystem::cycle() {
    // One machine cycle: 4 clocks for the CPU and timer; the PPU/APU see 4 (2 in double speed).
    int dots = doubleSpeed ? 2 : 4;
    timerTick();
    if (dmaActive) {
        // The first byte is copied two M-cycles after the FF46 write; the CPU loses the bus one
        // cycle before that (mooneye oam_dma_start / oam_dma_timing / oam_dma_restart).
        if (dmaDelay > 0) { if (--dmaDelay == 0) dmaBusy = true; }
        else {
            u16 src = u16(dmaSrc + dmaIndex);
            // Read the source directly: going through busRead() would hit the "CPU bus busy during
            // OAM DMA" lockout and return 0xFF for every WRAM byte (which hid all sprites in games
            // that keep their shadow OAM in WRAM, e.g. Link's Awakening DX). 0xE000+ mirrors WRAM.
            u16 s2 = src >= 0xE000 ? u16(src - 0x2000) : src;
            u8 v;
            if (s2 < 0x8000) v = (bootMapped && s2 < 0x100) ? boot_[s2] : romRead(s2);
            else if (s2 < 0xA000) v = vram[vbk * 0x2000 + (s2 - 0x8000)];
            else if (s2 < 0xC000) v = eramRead(s2);
            else if (s2 < 0xD000) v = wram[s2 - 0xC000];
            else v = wram[(cgb ? svbk : 1) * 0x1000 + (s2 - 0xD000)];
            oam[dmaIndex] = v;
            if (++dmaIndex >= 0xA0) { dmaActive = false; dmaBusy = false; }
        }
    }
    if (io[0x02] & 0x80 && io[0x02] & 0x01) {
        serialCycles += 4;
        int period = (cgb && (io[0x02] & 2)) ? 16 : 512;
        if (doubleSpeed) period /= 1;
        while (serialCycles >= period) {
            serialCycles -= period;
            io[0x01] = u8(io[0x01] << 1 | 1);
            if (++serialBits == 8) { serialBits = 0; io[0x02] &= 0x7F; io[0x0F] |= 0x08; break; }
        }
    }
    if (hasRTC) { rtcCycles += dots; if (rtcCycles >= kClock) { rtcCycles -= kClock; rtcTick(); } }
    ppuTick(dots);
    apuTick(dots);
}

void GBSystem::timerTick() {
    if (timaState == 1) { io[0x05] = io[0x06]; io[0x0F] |= 0x04; timaState = 2; }
    else if (timaState == 2) timaState = 0;
    u16 old = divCounter;
    divCounter = u16(divCounter + 4);
    static const u16 bits[4] = {1 << 9, 1 << 3, 1 << 5, 1 << 7};
    if (io[0x07] & 4) {
        u16 m = bits[io[0x07] & 3];
        if ((old & m) && !(divCounter & m)) {
            if (++io[0x05] == 0) timaState = 1;
        }
    }
    u16 am = doubleSpeed ? (1 << 13) : (1 << 12);
    if ((old & am) && !(divCounter & am)) apuSequencer();
}

// ---------------------------------------------------------------- CPU

bool GBSystem::cond(int c) const {
    switch (c & 3) { case 0: return !(F & FZ); case 1: return F & FZ; case 2: return !(F & FC); default: return F & FC; }
}

u8 GBSystem::getR(int i) {
    switch (i) { case 0: return B; case 1: return C; case 2: return D; case 3: return E; case 4: return H; case 5: return L; case 6: return rd(HL()); default: return A; }
}
void GBSystem::setR(int i, u8 v) {
    switch (i) { case 0: B = v; break; case 1: C = v; break; case 2: D = v; break; case 3: E = v; break; case 4: H = v; break; case 5: L = v; break; case 6: wr(HL(), v); break; default: A = v; }
}

void GBSystem::alu(int op, u8 v) {
    int r;
    switch (op) {
        case 0: r = A + v; F = u8(((r & 0xFF) ? 0 : FZ) | (((A & 0xF) + (v & 0xF)) > 0xF ? FH : 0) | (r > 0xFF ? FC : 0)); A = u8(r); break;
        case 1: { int c = (F & FC) ? 1 : 0; r = A + v + c; F = u8(((r & 0xFF) ? 0 : FZ) | (((A & 0xF) + (v & 0xF) + c) > 0xF ? FH : 0) | (r > 0xFF ? FC : 0)); A = u8(r); break; }
        case 2: r = A - v; F = u8(((r & 0xFF) ? 0 : FZ) | FN | ((A & 0xF) < (v & 0xF) ? FH : 0) | (r < 0 ? FC : 0)); A = u8(r); break;
        case 3: { int c = (F & FC) ? 1 : 0; r = A - v - c; F = u8(((r & 0xFF) ? 0 : FZ) | FN | (((A & 0xF) - (v & 0xF) - c) < 0 ? FH : 0) | (r < 0 ? FC : 0)); A = u8(r); break; }
        case 4: A &= v; F = u8((A ? 0 : FZ) | FH); break;
        case 5: A ^= v; F = A ? 0 : FZ; break;
        case 6: A |= v; F = A ? 0 : FZ; break;
        default: r = A - v; F = u8(((r & 0xFF) ? 0 : FZ) | FN | ((A & 0xF) < (v & 0xF) ? FH : 0) | (r < 0 ? FC : 0)); break;
    }
}
u8 GBSystem::inc8(u8 v) { u8 r = u8(v + 1); F = u8((F & FC) | (r ? 0 : FZ) | ((v & 0xF) == 0xF ? FH : 0)); return r; }
u8 GBSystem::dec8(u8 v) { u8 r = u8(v - 1); F = u8((F & FC) | (r ? 0 : FZ) | FN | ((v & 0xF) == 0 ? FH : 0)); return r; }

void GBSystem::interrupt() {
    cycle(); cycle();
    wr(--SP, u8(PC >> 8));
    u8 pending = IE & io[0x0F] & 0x1F;       // IE can be overwritten by the high-byte push
    wr(--SP, u8(PC));
    ime = false;
    if (!pending) { PC = 0; }
    else { int bit = 0; while (!(pending & (1 << bit))) ++bit; io[0x0F] &= u8(~(1 << bit)); PC = u16(0x40 + bit * 8); }
    cycle();
}

void GBSystem::hdmaBlock() {
    for (int i = 0; i < 16; ++i) {
        u16 s = u16(hdmaSrc + i);
        u8 v = s < 0x8000 ? romRead(s) : (s >= 0xA000 && s < 0xC000) ? eramRead(s) : busRead(s);
        vram[vbk * 0x2000 + ((hdmaDst + i) & 0x1FFF)] = v;
    }
    hdmaSrc = u16(hdmaSrc + 16); hdmaDst = u16((hdmaDst + 16) & 0x1FF0);
    for (int i = 0; i < (doubleSpeed ? 16 : 8); ++i) cycle();
}

void GBSystem::step() {
    if (hdmaRequest) {
        hdmaRequest = false;
        if (hdmaActive) { hdmaBlock(); if (--hdmaLeft < 0) { hdmaActive = false; hdmaLeft = 0x7F; } }
    }
    if (stopped) { cycle(); return; }
    if (halted) {
        cycle();
        if (!(IE & io[0x0F] & 0x1F)) return;
        halted = false;
    }
    if (ime && (IE & io[0x0F] & 0x1F)) { interrupt(); return; }
    u8 op = fetch();
    if (haltBug) { haltBug = false; --PC; }
    int ei = eiDelay;
    switch (op) {
        case 0x00: break;
        case 0x01: C = fetch(); B = fetch(); break;
        case 0x11: E = fetch(); D = fetch(); break;
        case 0x21: L = fetch(); H = fetch(); break;
        case 0x31: SP = fetch16(); break;
        case 0x02: wr(BC(), A); break;
        case 0x12: wr(DE(), A); break;
        case 0x22: wr(HL(), A); setHL(u16(HL() + 1)); break;
        case 0x32: wr(HL(), A); setHL(u16(HL() - 1)); break;
        case 0x0A: A = rd(BC()); break;
        case 0x1A: A = rd(DE()); break;
        case 0x2A: A = rd(HL()); setHL(u16(HL() + 1)); break;
        case 0x3A: A = rd(HL()); setHL(u16(HL() - 1)); break;
        case 0x03: { u16 v = u16(BC() + 1); B = u8(v >> 8); C = u8(v); cycle(); break; }
        case 0x13: { u16 v = u16(DE() + 1); D = u8(v >> 8); E = u8(v); cycle(); break; }
        case 0x23: setHL(u16(HL() + 1)); cycle(); break;
        case 0x33: ++SP; cycle(); break;
        case 0x0B: { u16 v = u16(BC() - 1); B = u8(v >> 8); C = u8(v); cycle(); break; }
        case 0x1B: { u16 v = u16(DE() - 1); D = u8(v >> 8); E = u8(v); cycle(); break; }
        case 0x2B: setHL(u16(HL() - 1)); cycle(); break;
        case 0x3B: --SP; cycle(); break;
        case 0x09: case 0x19: case 0x29: case 0x39: {
            u16 v = op == 0x09 ? BC() : op == 0x19 ? DE() : op == 0x29 ? HL() : SP;
            u32 r = HL() + v;
            F = u8((F & FZ) | (((HL() & 0xFFF) + (v & 0xFFF)) > 0xFFF ? FH : 0) | (r > 0xFFFF ? FC : 0));
            setHL(u16(r)); cycle(); break;
        }
        case 0x34: { u8 v = rd(HL()); wr(HL(), inc8(v)); break; }
        case 0x35: { u8 v = rd(HL()); wr(HL(), dec8(v)); break; }
        case 0x36: { u8 v = fetch(); wr(HL(), v); break; }
        case 0x07: { u8 c = A >> 7; A = u8(A << 1 | c); F = c ? FC : 0; break; }
        case 0x0F: { u8 c = A & 1; A = u8(A >> 1 | c << 7); F = c ? FC : 0; break; }
        case 0x17: { u8 c = A >> 7; A = u8(A << 1 | ((F & FC) ? 1 : 0)); F = c ? FC : 0; break; }
        case 0x1F: { u8 c = A & 1; A = u8(A >> 1 | ((F & FC) ? 0x80 : 0)); F = c ? FC : 0; break; }
        case 0x08: { u16 a = fetch16(); wr(a, u8(SP)); wr(u16(a + 1), u8(SP >> 8)); break; }
        case 0x10: {
            fetch();
            if (cgb && (key1 & 1)) {
                doubleSpeed = !doubleSpeed; key1 = 0; divCounter = 0;
                for (int i = 0; i < 2050; ++i) cycle();   // the clock switch stalls the CPU
            } else { stopped = true; divCounter = 0; }
            break;
        }
        case 0x18: { s8 e = s8(fetch()); PC = u16(PC + e); cycle(); break; }
        case 0x20: case 0x28: case 0x30: case 0x38: { s8 e = s8(fetch()); if (cond((op >> 3) & 3)) { PC = u16(PC + e); cycle(); } break; }
        case 0x27: {
            int a = A;
            if (!(F & FN)) { if ((F & FC) || a > 0x99) { a += 0x60; F |= FC; } if ((F & FH) || (a & 0xF) > 9) a += 6; }
            else { if (F & FC) a -= 0x60; if (F & FH) a -= 6; }
            A = u8(a); F = u8((F & (FN | FC)) | (A ? 0 : FZ)); break;
        }
        case 0x2F: A = u8(~A); F |= FN | FH; break;
        case 0x37: F = u8((F & FZ) | FC); break;
        case 0x3F: F = u8((F & FZ) | ((F & FC) ? 0 : FC)); break;
        case 0x76:
            if (!ime && (IE & io[0x0F] & 0x1F)) haltBug = true;
            else halted = true;
            break;
        case 0xC0: case 0xC8: case 0xD0: case 0xD8: cycle(); if (cond((op >> 3) & 3)) { PC = pop(); cycle(); } break;
        case 0xC9: PC = pop(); cycle(); break;
        case 0xD9: PC = pop(); cycle(); ime = true; break;
        case 0xC1: { u16 v = pop(); B = u8(v >> 8); C = u8(v); break; }
        case 0xD1: { u16 v = pop(); D = u8(v >> 8); E = u8(v); break; }
        case 0xE1: setHL(pop()); break;
        case 0xF1: { u16 v = pop(); A = u8(v >> 8); F = u8(v) & 0xF0; break; }
        case 0xC5: cycle(); push(BC()); break;
        case 0xD5: cycle(); push(DE()); break;
        case 0xE5: cycle(); push(HL()); break;
        case 0xF5: cycle(); push(u16(A << 8 | F)); break;
        case 0xC3: { u16 a = fetch16(); PC = a; cycle(); break; }
        case 0xC2: case 0xCA: case 0xD2: case 0xDA: { u16 a = fetch16(); if (cond((op >> 3) & 3)) { PC = a; cycle(); } break; }
        case 0xE9: PC = HL(); break;
        case 0xCD: { u16 a = fetch16(); cycle(); push(PC); PC = a; break; }
        case 0xC4: case 0xCC: case 0xD4: case 0xDC: { u16 a = fetch16(); if (cond((op >> 3) & 3)) { cycle(); push(PC); PC = a; } break; }
        case 0xC7: case 0xCF: case 0xD7: case 0xDF: case 0xE7: case 0xEF: case 0xF7: case 0xFF: cycle(); push(PC); PC = u16(op & 0x38); break;
        case 0xE0: { u8 n = fetch(); wr(u16(0xFF00 | n), A); break; }
        case 0xF0: { u8 n = fetch(); A = rd(u16(0xFF00 | n)); break; }
        case 0xE2: wr(u16(0xFF00 | C), A); break;
        case 0xF2: A = rd(u16(0xFF00 | C)); break;
        case 0xEA: { u16 a = fetch16(); wr(a, A); break; }
        case 0xFA: { u16 a = fetch16(); A = rd(a); break; }
        case 0xE8: { s8 e = s8(fetch()); F = u8((((SP & 0xF) + (u8(e) & 0xF)) > 0xF ? FH : 0) | (((SP & 0xFF) + u8(e)) > 0xFF ? FC : 0)); SP = u16(SP + e); cycle(); cycle(); break; }
        case 0xF8: { s8 e = s8(fetch()); F = u8((((SP & 0xF) + (u8(e) & 0xF)) > 0xF ? FH : 0) | (((SP & 0xFF) + u8(e)) > 0xFF ? FC : 0)); setHL(u16(SP + e)); cycle(); break; }
        case 0xF9: SP = HL(); cycle(); break;
        case 0xF3: ime = false; eiDelay = 0; ei = 0; break;
        case 0xFB: eiDelay = 2; ei = 0; break;
        case 0xCB: execCB(); break;
        case 0xD3: case 0xDB: case 0xDD: case 0xE3: case 0xE4: case 0xEB: case 0xEC: case 0xED: case 0xF4: case 0xFC: case 0xFD:
            stopped = true; break;   // illegal opcode: the CPU locks up
        default:
            if (op >= 0x40 && op < 0x80) { setR((op >> 3) & 7, getR(op & 7)); }
            else if (op >= 0x80 && op < 0xC0) { alu((op >> 3) & 7, getR(op & 7)); }
            else if ((op & 0xC7) == 0xC6) { alu((op >> 3) & 7, fetch()); }
            else if ((op & 0xC7) == 0x04) { int r = (op >> 3) & 7; setR(r, inc8(getR(r))); }
            else if ((op & 0xC7) == 0x05) { int r = (op >> 3) & 7; setR(r, dec8(getR(r))); }
            else if ((op & 0xC7) == 0x06) { int r = (op >> 3) & 7; setR(r, fetch()); }
            break;
    }
    (void)ei;
    if (eiDelay && --eiDelay == 0) ime = true;
}

void GBSystem::execCB() {
    u8 op = fetch();
    int r = op & 7, b = (op >> 3) & 7;
    u8 v = getR(r);
    switch (op >> 6) {
        case 0: {
            u8 c = 0;
            switch (b) {
                case 0: c = v >> 7; v = u8(v << 1 | c); break;
                case 1: c = v & 1; v = u8(v >> 1 | c << 7); break;
                case 2: c = v >> 7; v = u8(v << 1 | ((F & FC) ? 1 : 0)); break;
                case 3: c = v & 1; v = u8(v >> 1 | ((F & FC) ? 0x80 : 0)); break;
                case 4: c = v >> 7; v = u8(v << 1); break;
                case 5: c = v & 1; v = u8((v >> 1) | (v & 0x80)); break;
                case 6: c = 0; v = u8(v << 4 | v >> 4); break;
                default: c = v & 1; v = u8(v >> 1); break;
            }
            F = u8((v ? 0 : FZ) | (c ? FC : 0));
            setR(r, v); break;
        }
        case 1: F = u8((F & FC) | FH | ((v & (1 << b)) ? 0 : FZ)); break;
        case 2: setR(r, u8(v & ~(1 << b))); break;
        default: setR(r, u8(v | (1 << b))); break;
    }
}

// ---------------------------------------------------------------- bus

u8 GBSystem::romRead(u16 a) const {
    if (a < 0x4000) {
        size_t bank = 0;
        if (mbc == 1 && mbc1Mode) bank = size_t(romBankHi << 5);
        return rom_[(bank * 0x4000 + a) & (rom_.size() - 1)];
    }
    size_t bank;
    switch (mbc) {
        case 1: bank = size_t((romBankHi << 5) | romBank); break;
        case 5: bank = size_t(romBank); break;
        case 0: bank = 1; break;
        default: bank = size_t(romBank); break;
    }
    return rom_[(bank * 0x4000 + (a - 0x4000)) & (rom_.size() - 1)];
}

void GBSystem::mapperWrite(u16 a, u8 v) {
    switch (mbc) {
        case 1:
            if (a < 0x2000) ramEnable = (v & 0xF) == 0xA;
            else if (a < 0x4000) { romBank = v & 0x1F; if (!romBank) romBank = 1; }
            else if (a < 0x6000) romBankHi = v & 3;
            else mbc1Mode = v & 1;
            break;
        case 2:
            if (a < 0x4000) {
                if (a & 0x100) { romBank = v & 0xF; if (!romBank) romBank = 1; }
                else ramEnable = (v & 0xF) == 0xA;
            }
            break;
        case 3:
            if (a < 0x2000) ramEnable = (v & 0xF) == 0xA;
            else if (a < 0x4000) { romBank = v & 0x7F; if (!romBank) romBank = 1; }
            else if (a < 0x6000) ramBank = v;
            else {
                if (rtcLatchPrev == 0 && v == 1) std::memcpy(rtcLatched, rtc, 5);
                rtcLatchPrev = v;
            }
            break;
        case 5:
            if (a < 0x2000) ramEnable = (v & 0xF) == 0xA;
            else if (a < 0x3000) romBank = (romBank & 0x100) | v;
            else if (a < 0x4000) romBank = (romBank & 0xFF) | ((v & 1) << 8);
            else if (a < 0x6000) ramBank = hasRumble ? (v & 7) : (v & 0xF);
            break;
        default: break;
    }
}

u8 GBSystem::eramRead(u16 a) {
    if (!ramEnable && mbc != 0) return 0xFF;
    if (mbc == 2) return eram_.empty() ? 0xFF : u8(0xF0 | eram_[a & 0x1FF]);
    if (mbc == 3 && ramBank >= 8) {
        if (!hasRTC || ramBank > 0x0C) return 0xFF;
        static const u8 m[5] = {0x3F, 0x3F, 0x1F, 0xFF, 0xC1};
        return u8(rtcLatched[ramBank - 8] & m[ramBank - 8]);
    }
    if (eram_.empty()) return 0xFF;
    size_t bank = mbc == 1 ? (mbc1Mode ? size_t(romBankHi) : 0) : size_t(ramBank & 0xF);
    return eram_[(bank * 0x2000 + (a - 0xA000)) % eram_.size()];
}

void GBSystem::eramWrite(u16 a, u8 v) {
    if (!ramEnable && mbc != 0) return;
    if (mbc == 2) { if (!eram_.empty()) { eram_[a & 0x1FF] = v & 0xF; saveDirty_ = hasBattery; } return; }
    if (mbc == 3 && ramBank >= 8) {
        if (!hasRTC || ramBank > 0x0C) return;
        rtc[ramBank - 8] = v; if (ramBank == 8) rtcCycles = 0;
        rtcLatched[ramBank - 8] = v; saveDirty_ = hasBattery;
        return;
    }
    if (eram_.empty()) return;
    size_t bank = mbc == 1 ? (mbc1Mode ? size_t(romBankHi) : 0) : size_t(ramBank & 0xF);
    eram_[(bank * 0x2000 + (a - 0xA000)) % eram_.size()] = v;
    if (hasBattery) saveDirty_ = true;
}

void GBSystem::rtcTick() {
    if (rtc[4] & 0x40) return;
    if (++rtc[0] == 60) {
        rtc[0] = 0;
        if (++rtc[1] == 60) {
            rtc[1] = 0;
            if (++rtc[2] == 24) {
                rtc[2] = 0;
                int day = rtc[3] | ((rtc[4] & 1) << 8);
                ++day;
                if (day > 511) { day = 0; rtc[4] |= 0x80; }
                rtc[3] = u8(day); rtc[4] = u8((rtc[4] & 0xFE) | (day >> 8));
            }
        }
    }
    rtc[0] &= 0x3F; rtc[1] &= 0x3F; rtc[2] &= 0x1F;
}

u8 GBSystem::busRead(u16 a) {
    if (dmaBusy && a < 0xFF00) return 0xFF;
    if (a < 0x8000) {
        if (bootMapped && (a < 0x100 || (boot_.size() == 0x900 && a >= 0x200 && a < 0x900))) return boot_[a];
        u8 v = romRead(a);
        for (const RomPatch& p : patches_)
            if (p.addr == a && (p.compare < 0 || p.compare == v)) return p.value;
        return v;
    }
    if (a < 0xA000) return vramBlocked() ? 0xFF : vram[vbk * 0x2000 + (a - 0x8000)];
    if (a < 0xC000) return eramRead(a);
    if (a < 0xD000) return wram[a - 0xC000];
    if (a < 0xE000) return wram[(cgb ? svbk : 1) * 0x1000 + (a - 0xD000)];
    if (a < 0xFE00) return busRead(u16(a - 0x2000));
    if (a < 0xFEA0) return oamBlocked() ? 0xFF : oam[a - 0xFE00];
    if (a < 0xFF00) return cgb ? 0x00 : 0xFF;
    if (a < 0xFF80) return ioRead(a);
    if (a < 0xFFFF) return hram[a - 0xFF80];
    return IE;
}

void GBSystem::busWrite(u16 a, u8 v) {
    if (dmaBusy && a < 0xFF00) return;
    if (a < 0x8000) { mapperWrite(a, v); return; }
    if (a < 0xA000) { if (!vramBlocked()) vram[vbk * 0x2000 + (a - 0x8000)] = v; return; }
    if (a < 0xC000) { eramWrite(a, v); return; }
    if (a < 0xD000) { wram[a - 0xC000] = v; return; }
    if (a < 0xE000) { wram[(cgb ? svbk : 1) * 0x1000 + (a - 0xD000)] = v; return; }
    if (a < 0xFE00) { busWrite(u16(a - 0x2000), v); return; }
    if (a < 0xFEA0) { if (!oamBlocked()) oam[a - 0xFE00] = v; return; }
    if (a < 0xFF00) return;
    if (a < 0xFF80) { ioWrite(a, v); return; }
    if (a < 0xFFFF) { hram[a - 0xFF80] = v; return; }
    IE = v;
}

u8 GBSystem::ioRead(u16 a) {
    u8 r = u8(a & 0x7F);
    if (r >= 0x10 && r < 0x40) return apuRead(a);
    switch (r) {
        case 0x00: {
            u8 v = io[0] | 0xCF;
            if (!(io[0] & 0x10)) v &= u8(~(((buttons & BtnRight) ? 1 : 0) | ((buttons & BtnLeft) ? 2 : 0) | ((buttons & BtnUp) ? 4 : 0) | ((buttons & BtnDown) ? 8 : 0)));
            if (!(io[0] & 0x20)) v &= u8(~(((buttons & BtnA) ? 1 : 0) | ((buttons & BtnB) ? 2 : 0) | ((buttons & BtnSelect) ? 4 : 0) | ((buttons & BtnStart) ? 8 : 0)));
            return v;
        }
        case 0x01: return io[1];
        case 0x02: return u8(io[2] | (cgb ? 0x7C : 0x7E));
        case 0x04: return u8(divCounter >> 8);
        case 0x05: case 0x06: return io[r];
        case 0x07: return io[7] | 0xF8;
        case 0x0F: return io[0x0F] | 0xE0;
        case 0x40: return io[0x40];
        case 0x41: return u8(0x80 | (io[0x41] & 0x78) | ((io[0x40] & 0x80) ? ((ly == io[0x45] ? 4 : 0) | mode) : 0));
        case 0x44: return u8(ly);
        case 0x42: case 0x43: case 0x45: case 0x47: case 0x48: case 0x49: case 0x4A: case 0x4B: case 0x46: return io[r];
        case 0x4D: return cgb ? u8(0x7E | (doubleSpeed ? 0x80 : 0) | (key1 & 1)) : 0xFF;
        case 0x4F: return cgb ? u8(0xFE | vbk) : 0xFF;
        case 0x55: return cgb ? u8((hdmaActive ? 0 : 0x80) | (hdmaLeft & 0x7F)) : 0xFF;
        case 0x68: return cgb ? u8(bcps | 0x40) : 0xFF;
        case 0x69: return cgb ? bgPal[bcps & 0x3F] : 0xFF;
        case 0x6A: return cgb ? u8(ocps | 0x40) : 0xFF;
        case 0x6B: return cgb ? objPal[ocps & 0x3F] : 0xFF;
        case 0x6C: return cgb ? u8(0xFE | opri) : 0xFF;
        case 0x70: return cgb ? u8(0xF8 | svbk) : 0xFF;
        case 0x72: case 0x73: return cgb ? undoc[r - 0x72] : 0xFF;
        case 0x74: return cgb && !dmgCompat ? undoc[2] : 0xFF;
        case 0x75: return cgb ? u8(0x8F | undoc[3]) : 0xFF;
        case 0x76: case 0x77: return cgb ? 0x00 : 0xFF;
        default: return 0xFF;
    }
}

void GBSystem::ioWrite(u16 a, u8 v) {
    u8 r = u8(a & 0x7F);
    if (r >= 0x10 && r < 0x40) { apuWrite(a, v); return; }
    switch (r) {
        case 0x00: io[0] = v & 0x30; break;
        case 0x01: io[1] = v; break;
        case 0x02:
            io[2] = v;
            if (v & 0x80) { serialBits = 0; serialCycles = 0; if (v & 1) serial_ += char(io[1]); }
            break;
        case 0x04: {
            u16 old = divCounter; divCounter = 0;
            static const u16 bits[4] = {1 << 9, 1 << 3, 1 << 5, 1 << 7};
            if ((io[7] & 4) && (old & bits[io[7] & 3])) { if (++io[5] == 0) timaState = 1; }
            u16 am = doubleSpeed ? (1 << 13) : (1 << 12);
            if (old & am) apuSequencer();
            break;
        }
        case 0x05:
            if (timaState == 1) { timaState = 0; io[5] = v; }
            else if (timaState != 2) io[5] = v;
            break;
        case 0x06: io[6] = v; if (timaState == 2) io[5] = v; break;
        case 0x07: {
            static const u16 bits[4] = {1 << 9, 1 << 3, 1 << 5, 1 << 7};
            bool oldBit = (io[7] & 4) && (divCounter & bits[io[7] & 3]);
            io[7] = v & 7;
            bool newBit = (io[7] & 4) && (divCounter & bits[io[7] & 3]);
            if (oldBit && !newBit) { if (++io[5] == 0) timaState = 1; }
            break;
        }
        case 0x0F: io[0x0F] = v & 0x1F; break;
        case 0x40: {
            bool was = io[0x40] & 0x80;
            io[0x40] = v;
            if (was && !(v & 0x80)) {
                ly = 0; lineDot = 0; mode = 0; windowLine = 0; wyHit = false;
                for (int y = 0; y < SH; ++y) for (int x = 0; x < W; ++x) frame_[y * kScreenWidth + x] = cgb && !dmgCompat ? 0xFFFFFFFF : dmgColor(0);
            } else if (!was && (v & 0x80)) {
                ly = 0; lineDot = 4; mode = 0; windowLine = 0; wyHit = false; lcdOffDots = 0;
                skipFirstFrame = true; statLine = false; updateStat();
            }
            break;
        }
        case 0x41: io[0x41] = v & 0x78; updateStat(); break;
        case 0x44: break;
        case 0x45: io[0x45] = v; updateStat(); break;
        case 0x46: io[0x46] = v; dmaSrc = u16(v << 8); dmaIndex = 0; dmaDelay = DMA_DELAY; dmaActive = true; break;
        case 0x42: case 0x43: case 0x47: case 0x48: case 0x49: case 0x4A: case 0x4B: io[r] = v; break;
        case 0x4C: if (bootMapped && cgb) { key0 = v; if (v & 0x04) dmgCompat = true; } break;
        case 0x4D: if (cgb) key1 = v & 1; break;
        case 0x4F: if (cgb) vbk = v & 1; break;
        case 0x50: if (v & 1) bootMapped = false; break;
        case 0x51: if (cgb) hdmaSrc = u16((hdmaSrc & 0x00F0) | (v << 8)); break;
        case 0x52: if (cgb) hdmaSrc = u16((hdmaSrc & 0xFF00) | (v & 0xF0)); break;
        case 0x53: if (cgb) hdmaDst = u16((hdmaDst & 0x00F0) | ((v & 0x1F) << 8)); break;
        case 0x54: if (cgb) hdmaDst = u16((hdmaDst & 0x1F00) | (v & 0xF0)); break;
        case 0x55:
            if (!cgb) break;
            if (hdmaActive && !(v & 0x80)) { hdmaActive = false; hdmaLeft = v & 0x7F; break; }
            if (v & 0x80) { hdmaActive = true; hdmaLeft = v & 0x7F; if (mode == 0 && (io[0x40] & 0x80) == 0) hdmaRequest = true; }
            else {
                int blocks = (v & 0x7F) + 1;
                for (int i = 0; i < blocks; ++i) hdmaBlock();
                hdmaLeft = 0x7F; hdmaActive = false;
            }
            break;
        case 0x68: if (cgb) bcps = v & 0xBF; break;
        case 0x69:
            if (!cgb) break;
            bgPal[bcps & 0x3F] = v;
            if (bcps & 0x80) bcps = u8(0x80 | ((bcps + 1) & 0x3F));
            break;
        case 0x6A: if (cgb) ocps = v & 0xBF; break;
        case 0x6B:
            if (!cgb) break;
            objPal[ocps & 0x3F] = v;
            if (ocps & 0x80) ocps = u8(0x80 | ((ocps + 1) & 0x3F));
            break;
        case 0x6C: if (cgb) opri = v & 1; break;
        case 0x70: if (cgb) { svbk = v & 7; if (!svbk) svbk = 1; } break;
        case 0x72: case 0x73: case 0x74: if (cgb) undoc[r - 0x72] = v; break;
        case 0x75: if (cgb) undoc[3] = v & 0x70; break;
        default: break;
    }
}

// ---------------------------------------------------------------- PPU

void GBSystem::updateStat() {
    bool line = false;
    if (io[0x40] & 0x80) {
        u8 s = io[0x41];
        if ((s & 0x40) && ly == io[0x45]) line = true;
        if ((s & 0x08) && mode == 0) line = true;
        if ((s & 0x10) && mode == 1) line = true;
        if ((s & 0x20) && mode == 2) line = true;
    }
    if (line && !statLine) io[0x0F] |= 0x02;
    statLine = line;
}

void GBSystem::ppuTick(int dots) {
    if (!(io[0x40] & 0x80)) {
        lcdOffDots += dots;
        if (lcdOffDots >= 70224) { lcdOffDots -= 70224; frameDone = true; }
        return;
    }
    lineDot += dots;
    if (ly < 144) {
        if (mode == 2 && lineDot >= 80) {
            mode = 3;
            // Mode 3 grows with fine scroll, the window and sprites on the line.
            int sprites = 0, h = (io[0x40] & 4) ? 16 : 8;
            for (int i = 0; i < 40 && sprites < 10; ++i) { int y = oam[i * 4] - 16; if (ly >= y && ly < y + h) ++sprites; }
            mode3Len = 172 + (io[0x43] & 7) + sprites * 6;
            if (drawing_ && !skipFirstFrame) renderLine();
            else if ((io[0x40] & 0x20) && wyHit && io[0x4B] <= 166) ++windowLine;
            updateStat();
        } else if (mode == 0 && lineDot < 80 && lineDot >= 4 && ly < 144) {
            // first line after enabling the LCD has no OAM scan
        }
        if (mode == 3 && lineDot >= 80 + mode3Len) {
            mode = 0;
            if (hdmaActive) hdmaRequest = true;
            updateStat();
        }
        if (mode == 0 && lineDot >= 76 && lineDot < 80 + mode3Len && ly == 0 && skipFirstFrame && lineDot < 80) {
            mode = 2;
        }
    }
    if (lineDot >= 456) {
        lineDot -= 456;
        ++ly;
        if (ly == 144) {
            mode = 1;
            io[0x0F] |= 0x01;
            if (skipFirstFrame) skipFirstFrame = false;
            frameDone = true;
        } else if (ly == 154) {
            ly = 0; windowLine = 0; wyHit = false;
        }
        if (ly < 144) { mode = 2; if (ly == io[0x4A]) wyHit = true; }
        if (ly == 0 && io[0x4A] == 0) wyHit = true;
        updateStat();
    }
}

u32 GBSystem::dmgColor(int shade) const { return (dmgPalette_ == 1 ? kGray : kGreen)[shade & 3]; }
u32 GBSystem::cgbColor(const u8* pal, int idx) const { int c = pal[idx * 2] | (pal[idx * 2 + 1] << 8); return cgbLut_[c & 0x7FFF]; }

void GBSystem::renderLine() {
    const u8 lcdc = io[0x40];
    u32* out = frame_.data() + ly * kScreenWidth;
    const bool colorMode = cgb && !dmgCompat;
    const bool bgOn = colorMode || (lcdc & 1);
    // ---- background + window
    int winX = int(io[0x4B]) - 7;
    bool winOn = (lcdc & 0x20) && wyHit && io[0x4B] <= 166 && (colorMode || (lcdc & 1));
    for (int x = 0; x < W; ++x) {
        if (!bgOn) { lineBg_[x] = 0; lineAttr_[x] = 0; continue; }
        int mapBase, px, py;
        if (winOn && x >= winX) { mapBase = (lcdc & 0x40) ? 0x1C00 : 0x1800; px = x - winX; py = windowLine; }
        else { mapBase = (lcdc & 0x08) ? 0x1C00 : 0x1800; px = (x + io[0x43]) & 0xFF; py = (ly + io[0x42]) & 0xFF; }
        int mapAddr = mapBase + (py >> 3) * 32 + (px >> 3);
        u8 tile = vram[mapAddr];
        u8 attr = colorMode ? vram[0x2000 + mapAddr] : 0;
        int row = py & 7, col = px & 7;
        if (attr & 0x40) row = 7 - row;
        if (attr & 0x20) col = 7 - col;
        int addr = (lcdc & 0x10) ? tile * 16 : 0x1000 + s8(tile) * 16;
        addr += row * 2 + ((attr & 0x08) ? 0x2000 : 0);
        u8 lo = vram[addr], hi = vram[addr + 1];
        int bit = 7 - col;
        lineBg_[x] = u8(((lo >> bit) & 1) | (((hi >> bit) & 1) << 1));
        lineAttr_[x] = attr;
    }
    if (winOn && winX < W) ++windowLine;
    for (int x = 0; x < W; ++x) {
        if (colorMode) out[x] = cgbColor(bgPal, (lineAttr_[x] & 7) * 4 + lineBg_[x]);
        else {
            int shade = (io[0x47] >> (lineBg_[x] * 2)) & 3;
            out[x] = dmgCompat ? cgbColor(bgPal, shade) : dmgColor(shade);
        }
    }
    // ---- sprites
    if (!(lcdc & 0x02)) return;
    int h = (lcdc & 0x04) ? 16 : 8;
    int list[10], count = 0;
    for (int i = 0; i < 40 && count < 10; ++i) { int y = oam[i * 4] - 16; if (ly >= y && ly < y + h) list[count++] = i; }
    // Priority: DMG (or OPRI=1) lower X first then OAM index; CGB by OAM index only.
    bool xPriority = !colorMode || (opri & 1);
    if (xPriority) std::stable_sort(list, list + count, [&](int a, int b) { return oam[a * 4 + 1] < oam[b * 4 + 1]; });
    u8 drawn[W]; std::memset(drawn, 0, sizeof drawn);
    for (int k = 0; k < count; ++k) {
        const u8* s = oam + list[k] * 4;
        int sy = s[0] - 16, sx = s[1] - 8; u8 tile = s[2], at = s[3];
        int row = ly - sy;
        if (at & 0x40) row = h - 1 - row;
        if (h == 16) tile &= 0xFE;
        int addr = tile * 16 + row * 2 + ((colorMode && (at & 0x08)) ? 0x2000 : 0);
        u8 lo = vram[addr], hi = vram[addr + 1];
        for (int c = 0; c < 8; ++c) {
            int x = sx + c;
            if (x < 0 || x >= W || drawn[x]) continue;
            int bit = (at & 0x20) ? c : 7 - c;
            int ci = ((lo >> bit) & 1) | (((hi >> bit) & 1) << 1);
            if (!ci) continue;
            drawn[x] = 1;
            if (colorMode) {
                if ((lcdc & 1) && lineBg_[x] && ((at & 0x80) || (lineAttr_[x] & 0x80))) continue;
                out[x] = cgbColor(objPal, (at & 7) * 4 + ci);
            } else {
                if ((at & 0x80) && lineBg_[x]) continue;
                int shade = ((at & 0x10 ? io[0x49] : io[0x48]) >> (ci * 2)) & 3;
                out[x] = dmgCompat ? cgbColor(objPal, ((at & 0x10) ? 4 : 0) + shade) : dmgColor(shade);
            }
        }
    }
}

// ---------------------------------------------------------------- APU

u8 GBSystem::apuRead(u16 a) {
    u8 r = u8(a & 0xFF);
    if (r >= 0x30) return wave.on ? io[0x30 + (wave.pos >> 1)] : io[r & 0x7F];
    if (r == 0x26) return u8((apuOn ? 0x80 : 0) | 0x70 | (sq[0].on ? 1 : 0) | (sq[1].on ? 2 : 0) | (wave.on ? 4 : 0) | (noise.on ? 8 : 0));
    return u8(io[r & 0x7F] | kApuMask[r - 0x10]);
}

int GBSystem::sweepCalc() {
    int d = sq[0].shadow >> (io[0x10] & 7);
    int f;
    if (io[0x10] & 8) { f = sq[0].shadow - d; sq[0].sweepNegUsed = true; } else f = sq[0].shadow + d;
    if (f > 2047) sq[0].on = false;
    return f;
}

void GBSystem::trigger(int ch) {
    if (ch < 2) {
        Sq& s = sq[ch]; int base = 0x10 + ch * 5;
        s.on = s.dac;
        if (!s.len) s.len = 64;
        int freq = io[base + 3] | ((io[base + 4] & 7) << 8);
        s.timer = (2048 - freq) * 4;
        s.vol = io[base + 2] >> 4; s.envUp = io[base + 2] & 8; s.envPeriod = io[base + 2] & 7; s.envTimer = s.envPeriod ? s.envPeriod : 8;
        if (ch == 0) {
            s.shadow = freq; s.sweepNegUsed = false;
            int per = (io[0x10] >> 4) & 7; s.sweepTimer = per ? per : 8;
            s.sweepOn = per || (io[0x10] & 7);
            if (io[0x10] & 7) sweepCalc();
        }
    } else if (ch == 2) {
        wave.on = wave.dac; if (!wave.len) wave.len = 256;
        int freq = io[0x1D] | ((io[0x1E] & 7) << 8);
        wave.timer = (2048 - freq) * 2 + 6; wave.pos = 0;
    } else {
        noise.on = noise.dac; if (!noise.len) noise.len = 64;
        noise.vol = io[0x21] >> 4; noise.envUp = io[0x21] & 8; noise.envPeriod = io[0x21] & 7; noise.envTimer = noise.envPeriod ? noise.envPeriod : 8;
        noise.lfsr = 0x7FFF;
        static const int div[8] = {8, 16, 32, 48, 64, 80, 96, 112};
        noise.timer = div[io[0x22] & 7] << (io[0x22] >> 4);
    }
}

void GBSystem::apuWrite(u16 a, u8 v) {
    u8 r = u8(a & 0xFF);
    if (r >= 0x30) { if (wave.on) io[0x30 + (wave.pos >> 1)] = v; else io[r & 0x7F] = v; return; }
    if (r == 0x26) {
        bool on = v & 0x80;
        if (apuOn && !on) {
            for (int i = 0x10; i < 0x26; ++i) io[i] = 0;
            sq[0] = Sq{}; sq[1] = Sq{}; wave = Wv{}; noise = Ns{};
        }
        if (!apuOn && on) seqStep = 0;
        apuOn = on;
        return;
    }
    if (!apuOn) {
        // On DMG the length counters stay writable while powered off.
        if (!cgb) { if (r == 0x11) sq[0].len = 64 - (v & 63); else if (r == 0x16) sq[1].len = 64 - (v & 63); else if (r == 0x1B) wave.len = 256 - v; else if (r == 0x20) noise.len = 64 - (v & 63); }
        return;
    }
    io[r & 0x7F] = v;
    bool lengthStepNext = (seqStep & 1) == 0;   // the next sequencer step will not clock length
    switch (r) {
        case 0x10: if (!(v & 8) && sq[0].sweepNegUsed) sq[0].on = false; break;
        case 0x11: sq[0].len = 64 - (v & 63); break;
        case 0x16: sq[1].len = 64 - (v & 63); break;
        case 0x12: case 0x17: { Sq& s = sq[r == 0x12 ? 0 : 1]; s.dac = (v & 0xF8) != 0; if (!s.dac) s.on = false; break; }
        case 0x1A: wave.dac = v & 0x80; if (!wave.dac) wave.on = false; break;
        case 0x1B: wave.len = 256 - v; break;
        case 0x20: noise.len = 64 - (v & 63); break;
        case 0x21: noise.dac = (v & 0xF8) != 0; if (!noise.dac) noise.on = false; break;
        case 0x14: case 0x19: case 0x1E: case 0x23: {
            int ch = r == 0x14 ? 0 : r == 0x19 ? 1 : r == 0x1E ? 2 : 3;
            int* len = ch < 2 ? &sq[ch].len : ch == 2 ? &wave.len : &noise.len;
            bool* on = ch < 2 ? &sq[ch].on : ch == 2 ? &wave.on : &noise.on;
            int maxLen = ch == 2 ? 256 : 64;
            // extra length clock when enabling length in the first half of a length period
            if (!lengthStepNext && (v & 0x40) && *len) { if (--*len == 0 && !(v & 0x80)) *on = false; }
            if (v & 0x80) {
                bool wasZero = *len == 0;
                trigger(ch);
                if (wasZero && !lengthStepNext && (v & 0x40)) *len = maxLen - 1;
            }
            break;
        }
        default: break;
    }
}

void GBSystem::apuSequencer() {
    if (!apuOn) return;
    int s = seqStep; seqStep = (seqStep + 1) & 7;
    if (!(s & 1)) {   // length at 0,2,4,6
        if ((io[0x14] & 0x40) && sq[0].len && --sq[0].len == 0) sq[0].on = false;
        if ((io[0x19] & 0x40) && sq[1].len && --sq[1].len == 0) sq[1].on = false;
        if ((io[0x1E] & 0x40) && wave.len && --wave.len == 0) wave.on = false;
        if ((io[0x23] & 0x40) && noise.len && --noise.len == 0) noise.on = false;
    }
    if (s == 2 || s == 6) {
        Sq& c = sq[0];
        if (--c.sweepTimer <= 0) {
            int per = (io[0x10] >> 4) & 7;
            c.sweepTimer = per ? per : 8;
            if (c.sweepOn && per) {
                int f = sweepCalc();
                if (f <= 2047 && (io[0x10] & 7)) {
                    c.shadow = f; io[0x13] = u8(f); io[0x14] = u8((io[0x14] & 0xF8) | (f >> 8));
                    sweepCalc();
                }
            }
        }
    }
    if (s == 7) {
        auto env = [](int& vol, int& timer, int period, bool up) {
            if (!period) return;
            if (--timer <= 0) { timer = period; if (up && vol < 15) ++vol; else if (!up && vol > 0) --vol; }
        };
        env(sq[0].vol, sq[0].envTimer, sq[0].envPeriod, sq[0].envUp);
        env(sq[1].vol, sq[1].envTimer, sq[1].envPeriod, sq[1].envUp);
        env(noise.vol, noise.envTimer, noise.envPeriod, noise.envUp);
    }
}

void GBSystem::apuTick(int dots) {
    for (int c = 0; c < 2; ++c) {
        Sq& s = sq[c]; s.timer -= dots;
        while (s.timer <= 0) { int base = 0x10 + c * 5; s.timer += (2048 - (io[base + 3] | ((io[base + 4] & 7) << 8))) * 4; s.pos = (s.pos + 1) & 7; }
    }
    wave.timer -= dots;
    while (wave.timer <= 0) {
        wave.timer += (2048 - (io[0x1D] | ((io[0x1E] & 7) << 8))) * 2;
        wave.pos = (wave.pos + 1) & 31;
        u8 b = io[0x30 + (wave.pos >> 1)];
        wave.sample = (wave.pos & 1) ? (b & 0xF) : (b >> 4);
    }
    noise.timer -= dots;
    while (noise.timer <= 0) {
        static const int div[8] = {8, 16, 32, 48, 64, 80, 96, 112};
        noise.timer += div[io[0x22] & 7] << (io[0x22] >> 4);
        if ((io[0x22] >> 4) >= 14) continue;
        u16 x = u16((noise.lfsr ^ (noise.lfsr >> 1)) & 1);
        noise.lfsr = u16((noise.lfsr >> 1) | (x << 14));
        if (io[0x22] & 8) noise.lfsr = u16((noise.lfsr & ~0x40) | (x << 6));
    }
    sampleAcc += s64(dots) * kAudioSampleRate;
    while (sampleAcc >= kClock) { sampleAcc -= kClock; mixSample(); }
}

void GBSystem::mixSample() {
    float ch[4] = {0, 0, 0, 0};
    auto dac = [](int v) { return v / 7.5f - 1.0f; };
    for (int c = 0; c < 2; ++c) if (sq[c].dac) ch[c] = dac(sq[c].on ? (kDuty[io[0x11 + c * 5] >> 6][sq[c].pos] ? sq[c].vol : 0) : 0);
    if (wave.dac) { static const int sh[4] = {4, 0, 1, 2}; ch[2] = dac(wave.on ? (wave.sample >> sh[(io[0x1C] >> 5) & 3]) : 0); }
    if (noise.dac) ch[3] = dac(noise.on ? ((~noise.lfsr & 1) ? noise.vol : 0) : 0);
    float l = 0, r = 0;
    u8 pan = io[0x25];
    for (int c = 0; c < 4; ++c) { if (pan & (0x10 << c)) l += ch[c]; if (pan & (1 << c)) r += ch[c]; }
    l *= ((io[0x24] >> 4) & 7) + 1; r *= (io[0x24] & 7) + 1;
    l /= 32.f; r /= 32.f;
    if (!apuOn) { l = r = 0; }
    float ol = l - capL, orr = r - capR;
    capL = l - ol * 0.996f; capR = r - orr * 0.996f;
    auto clip = [](float v) { int s = int(v * 26000.f); return s16(s > 32767 ? 32767 : (s < -32768 ? -32768 : s)); };
    sampleBuf_.push_back(clip(ol)); sampleBuf_.push_back(clip(orr));
}

// ---------------------------------------------------------------- saves

std::vector<u8> GBSystem::saveData() const {
    if (!hasBattery) return {};
    std::vector<u8> d = eram_;
    if (hasRTC) {
        // 48-byte clock trailer: current and latched registers (u32 each) and a Unix timestamp.
        auto put32 = [&](u32 v) { for (int i = 0; i < 4; ++i) d.push_back(u8(v >> (i * 8))); };
        for (int i = 0; i < 5; ++i) put32(rtc[i]);
        for (int i = 0; i < 5; ++i) put32(rtcLatched[i]);
        u64 t = u64(std::time(nullptr));
        for (int i = 0; i < 8; ++i) d.push_back(u8(t >> (i * 8)));
    }
    return d;
}

void GBSystem::loadSaveData(const std::vector<u8>& d) {
    if (d.empty()) return;
    size_t n = std::min(d.size(), eram_.size());
    std::memcpy(eram_.data(), d.data(), n);
    if (hasRTC && d.size() >= eram_.size() + 48) {
        const u8* p = d.data() + eram_.size();
        auto get32 = [&](int i) { return u32(p[i * 4]) | u32(p[i * 4 + 1]) << 8 | u32(p[i * 4 + 2]) << 16 | u32(p[i * 4 + 3]) << 24; };
        for (int i = 0; i < 5; ++i) { rtc[i] = u8(get32(i)); rtcLatched[i] = u8(get32(5 + i)); }
        u64 t = 0; for (int i = 0; i < 8; ++i) t |= u64(p[40 + i]) << (i * 8);
        s64 now = s64(std::time(nullptr)), elapsed = now - s64(t);
        if (elapsed > 0 && elapsed < 10LL * 365 * 86400) for (s64 i = 0; i < std::min<s64>(elapsed, 512LL * 86400); ++i) rtcTick();
    }
}

std::string GBSystem::saveTypeDescription() const {
    if (!hasBattery) return "None";
    std::string s = mbc == 2 ? "MBC2 RAM 512 B" : (std::to_string(eram_.size() / 1024) + " KB battery RAM");
    if (hasRTC) s += " + clock";
    return s;
}

std::string GBSystem::statusText() const {
    char b[96]; snprintf(b, sizeof b, "%s  MBC%d  %s", cgb ? (dmgCompat ? "GBC (DMG mode)" : "GBC") : "GB", mbc, doubleSpeed ? "2x" : "1x");
    return b;
}

std::vector<u8> GBSystem::saveState() {
    StateIO s;
    s.tag(0x47424331);
    GBState& st = *this;
    s.pod(st);
    s.vec(eram_);
    s.vec(frame_);
    return std::move(s.output());
}

bool GBSystem::loadState(const std::vector<u8>& d) {
    StateIO s(d);
    s.tag(0x47424331);
    if (!s.ok()) return false;
    GBState backup = *this;
    std::vector<u8> eb = eram_;
    GBState& st = *this;
    s.pod(st);
    size_t es = eram_.size();
    s.vec(eram_);
    s.vec(frame_);
    if (!s.ok() || eram_.size() != es || frame_.size() != size_t(kScreenPixels)) {
        st = backup; eram_ = eb; frame_.assign(kScreenPixels, 0xFF000000); return false;
    }
    audio_.clear();
    return true;
}

} // namespace dscore
