// Copyright (c) 2026 Charlie Rodriguez Garcia. All rights reserved.
// Original clean-room Game Boy / Game Boy Color system model written from public hardware
// documentation (Pan Docs and the public test-ROM descriptions). No third-party emulator code.
// Boots without any boot ROM (post-boot register state); a user-provided boot ROM is optional.
#pragma once
#include "dscore/AudioRing.hpp"
#include "dscore/EmulatorCore.hpp"
#include <string>
#include <vector>

namespace dscore {

// Every piece of plain machine state lives here so save states are one block copy.
struct GBState {
    // CPU
    u8 A = 0, F = 0, B = 0, C = 0, D = 0, E = 0, H = 0, L = 0;
    u16 SP = 0, PC = 0;
    bool ime = false, halted = false, haltBug = false, stopped = false;
    int eiDelay = 0;
    // mode
    bool cgb = false;          // running in Game Boy Color mode
    bool dmgCompat = false;    // CGB hardware running a DMG game (boot ROM chose compat palettes)
    bool doubleSpeed = false;
    bool bootMapped = false;
    // memory
    u8 vram[0x4000] = {}, wram[0x8000] = {}, oam[0xA0] = {}, hram[0x7F] = {};
    u8 io[0x80] = {};
    u8 IE = 0;
    int vbk = 0, svbk = 1;
    u8 bgPal[64] = {}, objPal[64] = {};
    u8 bcps = 0, ocps = 0, key1 = 0, opri = 0, key0 = 0;
    u8 undoc[4] = {};
    // timer
    u16 divCounter = 0;
    int timaState = 0;
    // serial
    int serialBits = 0, serialCycles = 0;
    // OAM DMA
    bool dmaActive = false, dmaBusy = false; int dmaIndex = 0, dmaDelay = 0; u16 dmaSrc = 0;
    // HDMA
    bool hdmaActive = false, hdmaRequest = false; u16 hdmaSrc = 0, hdmaDst = 0; int hdmaLeft = 0;
    // PPU
    int lineDot = 0, mode = 2, mode3Len = 172, ly = 0, windowLine = 0, lcdOffDots = 0;
    bool statLine = false, wyHit = false, skipFirstFrame = false, frameDone = false;
    // joypad
    u32 buttons = 0;
    // mapper
    int mbc = 0;               // 0 none, 1 MBC1, 2 MBC2, 3 MBC3, 5 MBC5
    bool hasBattery = false, hasRTC = false, hasRumble = false;
    bool ramEnable = false; int romBank = 1, romBankHi = 0, ramBank = 0, mbc1Mode = 0;
    u8 rtc[5] = {}, rtcLatched[5] = {}; u8 rtcLatchPrev = 0xFF; s64 rtcCycles = 0;
    // APU
    bool apuOn = true;
    int seqStep = 0;
    struct Sq { bool on = false, dac = false; int timer = 0, pos = 0, len = 0, vol = 0, envTimer = 0, envPeriod = 0; bool envUp = false;
                bool sweepOn = false; int sweepTimer = 0, shadow = 0; bool sweepNegUsed = false; } sq[2];
    struct Wv { bool on = false, dac = false; int timer = 0, pos = 0, len = 0; u8 sample = 0; } wave;
    struct Ns { bool on = false, dac = false; int timer = 0, len = 0, vol = 0, envTimer = 0, envPeriod = 0; bool envUp = false; u16 lfsr = 0x7FFF; } noise;
    s64 sampleAcc = 0;
    float capL = 0, capR = 0;
    u64 frames = 0;
};

class GBSystem final : public EmulatorCore, private GBState {
public:
    static constexpr int W = 160, SH = 144;
    static constexpr int kClock = 4194304;

    GBSystem();
    bool loadROM(const u8* data, size_t size, std::string& error) override;
    void reset() override;
    void runFrame() override;
    const u32* framebuffer(int s) const override { return s == 0 ? frame_.data() : blank_.data(); }
    void setButtons(u32 m) override;
    void setTouch(bool, int, int) override {}
    size_t readAudio(s16* out, size_t n) override { return audio_.pop(out, n); }
    size_t audioBuffered() const override { return audio_.size(); }
    std::vector<u8> saveState() override;
    bool loadState(const std::vector<u8>& d) override;
    bool saveDataDirty() const override { return saveDirty_; }
    std::vector<u8> saveData() const override;
    void clearSaveDataDirty() override { saveDirty_ = false; }
    void loadSaveData(const std::vector<u8>& d) override;
    std::string saveTypeDescription() const override;
    void setFrameSkip(int n) override { frameSkip_ = n < 0 ? 0 : (n > 9 ? 9 : n); }
    // Cheats: CPU bus (8-bit). Game Genie patches are applied to ROM reads.
    u32 cheatRead(u32 a, int) override { return busRead(u16(a)); }
    u32 achievementRead(u32 a, u8* b, u32 n) override {
        for (u32 i = 0; i < n; ++i) {
            u32 x = a + i;
            if (x >= 0xFF00u && x < 0xFF80u) b[i] = io[x - 0xFF00u];   // registers: no read side effects
            else if (x < 0x10000u) b[i] = busRead(u16(x));
            else if (x < 0x16000u) b[i] = cgb ? wram[0x2000u + (x - 0x10000u)] : 0;
            else if (x < 0x34000u) { size_t k = 0x2000u + (x - 0x16000u); b[i] = k < eram_.size() ? eram_[k] : 0; }
            else return i;
        }
        return n;
    }
    void cheatWrite(u32 a, u32 v, int) override { if (u16(a) >= 0x8000) busWrite(u16(a), u8(v)); }
    void setRomPatches(const std::vector<RomPatch>& p) override { patches_ = p; }
    bool frameDrawn() const override { return lastDrawn_; }
    const RomInfo& romInfo() const override { return info_; }
    std::string statusText() const override;
    int system() const override { return cgb ? 3 : 2; }
    int screenWidth() const override { return W; }
    int screenHeight() const override { return SH; }
    int screenCount() const override { return 1; }
    bool setLLEBIOS(const std::vector<u8>& bios, const std::vector<u8>&, const std::vector<u8>&, bool) override;
    bool usingLLEBIOS() const override { return !boot_.empty(); }
    void setVideoOptions(int dmgPalette, bool colorCorrect) override;
    int stuckFrames() const override { return 0; }

    // test hooks
    const std::string& serialLog() const { return serial_; }
    u8 peek(u16 a) { return busRead(a); }
    u16 pc() const { return PC; }
    bool isCGBMode() const { return cgb; }
    u64 frameCount() const { return frames; }

private:
    RomInfo info_;
    std::vector<u8> rom_, eram_, boot_;
    std::vector<u32> frame_, blank_;
    AudioRing audio_{8192};
    std::vector<s16> sampleBuf_;
    std::string serial_;
    bool saveDirty_ = false;
    bool cartCGB_ = false;
    int frameSkip_ = 0, skipCounter_ = 0; bool lastDrawn_ = true, drawing_ = true;
    int dmgPalette_ = 0; bool colorCorrect_ = true;
    u32 cgbLut_[32768];
    u8 lineBg_[W], lineAttr_[W];

    // CPU
    void step();
    void cycle();
    u8 rd(u16 a) { cycle(); return busRead(a); }
    void wr(u16 a, u8 v) { cycle(); busWrite(a, v); }
    u8 fetch() { return rd(PC++); }
    u16 fetch16() { u8 lo = fetch(); return u16(lo | (fetch() << 8)); }
    void push(u16 v) { wr(--SP, u8(v >> 8)); wr(--SP, u8(v)); }
    u16 pop() { u8 lo = rd(SP++); return u16(lo | (rd(SP++) << 8)); }
    u8 getR(int i);
    void setR(int i, u8 v);
    u16 BC() const { return u16(B << 8 | C); } u16 DE() const { return u16(D << 8 | E); } u16 HL() const { return u16(H << 8 | L); }
    void setHL(u16 v) { H = u8(v >> 8); L = u8(v); }
    void alu(int op, u8 v);
    u8 inc8(u8 v); u8 dec8(u8 v);
    void execCB();
    bool cond(int c) const;
    void interrupt();

    // bus
    u8 busRead(u16 a);
    void busWrite(u16 a, u8 v);
    std::vector<RomPatch> patches_;   // Game Genie
    u8 ioRead(u16 a);
    void ioWrite(u16 a, u8 v);
    bool vramBlocked() const { return (io[0x40] & 0x80) && mode == 3; }
    bool oamBlocked() const { return (io[0x40] & 0x80) && (mode == 2 || mode == 3); }
    // mapper
    u8 romRead(u16 a) const;
    void mapperWrite(u16 a, u8 v);
    u8 eramRead(u16 a);
    void eramWrite(u16 a, u8 v);
    void rtcTick();
    // timer, PPU, APU
    void timerTick();
    void ppuTick(int dots);
    void updateStat();
    void renderLine();
    u32 dmgColor(int shade) const;
    u32 cgbColor(const u8* pal, int idx) const;
    void hdmaBlock();
    void apuTick(int dots);
    void apuSequencer();
    void apuWrite(u16 a, u8 v);
    u8 apuRead(u16 a);
    void trigger(int ch);
    void mixSample();
    int sweepCalc();
    void buildLut();
    void applyBootState();
};

} // namespace dscore
