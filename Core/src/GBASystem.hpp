// Copyright (c) 2026 Charlie Rodriguez Garcia. All rights reserved.
// Original clean-room Game Boy Advance system model written from public hardware
// documentation (GBATEK). Reuses the NDSU ARM7TDMI interpreter. No third-party code,
// no Nintendo BIOS: the BIOS calls are implemented in C++ (HLE) plus a tiny original
// IRQ dispatcher stub.
#pragma once
#include "dscore/ARMCPU.hpp"
#include "dscore/AudioRing.hpp"
#include "dscore/EmulatorCore.hpp"
#include <array>
#include <string>
#include <vector>

namespace dscore {

class GBASystem final : public EmulatorCore, public Bus {
public:
    static constexpr int W = 240, H = 160;
    enum class SaveType : u8 { None, SRAM, Flash64, Flash128, EEPROM512, EEPROM8K, EEPROMUnknown };

    GBASystem();
    bool loadROM(const u8* data, size_t size, std::string& error) override;
    void reset() override;
    void runFrame() override;
    // 240x160 picture in the top-left corner of the 256x192 buffer (screen 0); screen 1 is blank.
    const u32* framebuffer(int s) const override { return s == 0 ? frame_.data() : blank_.data(); }
    void setButtons(u32 m) override { buttons_ = m & 0x3FF; }
    void setTouch(bool, int, int) override {}
    size_t readAudio(s16* out, size_t n) override { return audio_.pop(out, n); }
    size_t audioBuffered() const override { return audio_.size(); }
    std::vector<u8> saveState() override;
    bool loadState(const std::vector<u8>& d) override;
    bool saveDataDirty() const override { return saveDirty_; }
    std::vector<u8> saveData() const override { return saveType_ == SaveType::None ? std::vector<u8>{} : save_; }
    void clearSaveDataDirty() override { saveDirty_ = false; }
    void loadSaveData(const std::vector<u8>& d) override;
    void setSaveTypeOverride(int o) override { saveOverride_ = o; if (!rom_.empty()) detectSave(); }
    std::string saveTypeDescription() const override;
    bool loadedSaveRejected() const override { return saveRejected_; }
    void setFrameSkip(int n) override { frameSkip_ = n < 0 ? 0 : (n > 9 ? 9 : n); }
    // Cheats: system bus, memory only (I/O is skipped).
    u32 cheatRead(u32 a, int size) override {
        if ((a >> 24) == 0x04) return 0;
        return size == 1 ? read8(a) : size == 2 ? read16(a & ~1u) : read32(a & ~3u);
    }
    void cheatWrite(u32 a, u32 v, int size) override {
        if ((a >> 24) == 0x04) return;
        if (size == 1) write8(a, u8(v)); else if (size == 2) write16(a & ~1u, u16(v)); else write32(a & ~3u, v);
    }
    u32 achievementRead(u32 a, u8* b, u32 n) override {
        for (u32 i = 0; i < n; ++i) {
            u32 x = a + i;
            if (x < 0x8000u) b[i] = x < iwram_.size() ? iwram_[x] : 0;
            else if (x < 0x48000u) b[i] = (x - 0x8000u) < ewram_.size() ? ewram_[x - 0x8000u] : 0;
            else if (x < 0x58000u) b[i] = 0;                         // Game Pak SRAM (not mapped here)
            else return i;
        }
        return n;
    }
    bool frameDrawn() const override { return lastDrawn_; }
    const RomInfo& romInfo() const override { return info_; }
    std::string statusText() const override;
    int system() const override { return 1; }
    int screenWidth() const override { return W; }
    int screenHeight() const override { return H; }
    int screenCount() const override { return 1; }

    // Bus (the CPU's view of memory)
    u8 read8(u32 a) override; u16 read16(u32 a) override; u32 read32(u32 a) override;
    void write8(u32 a, u8 v) override; void write16(u32 a, u16 v) override; void write32(u32 a, u32 v) override;

    ARMCPU& cpu() { return cpu_; }
    std::vector<u32>* pcTrace = nullptr;
    std::vector<std::pair<u32, u32>>* ioTrace = nullptr;   // debugging: (address | write<<31? no: addr, value) of I/O accesses     // debugging: every executed PC is appended when set
    SaveType saveType() const { return saveType_; }
    u64 frameCount() const { return frames_; }
    u32 swiCount(u32 n) const { return n < 256 ? swiCounts_[n] : 0; }
    std::string lastNotice() const { return notice_; }

private:
    // ---- state
    ARMCPU cpu_;
    RomInfo info_;
    std::vector<u8> rom_;
    u32 romMask_ = 0;
    std::array<u8, 0x4000> bios_{};
    std::vector<u8> ewram_, iwram_, vram_, pal_, oam_;
    std::array<u16, 0x200> io_{};               // raw I/O registers (halfwords, 0x04000000-0x040003FF)
    std::vector<u32> frame_, blank_;
    std::vector<u8*> pagesRd_, pagesWr_;
    AudioRing audio_{8192};
    u32 buttons_ = 0;
    u64 frames_ = 0;
    int frameSkip_ = 0, skipCounter_ = 0; bool lastDrawn_ = true;
    u32 swiCounts_[256] = {};
    std::string notice_;

    // timing
    int line_ = 0;
    s64 lineCycles_ = 0;
    bool intrWaiting_ = false; u16 intrWaitMask_ = 0;

    struct Timer { u16 reload = 0, ctl = 0; u32 counter = 0; u32 accum = 0; };
    Timer timers_[4];
    struct Dma { u32 src = 0, dst = 0, count = 0; u16 ctl = 0; u32 isrc = 0, idst = 0; };
    Dma dma_[4];
    s32 bgRefX_[2] = {}, bgRefY_[2] = {};       // internal affine reference points (BG2, BG3)

    // audio
    struct Square { u32 timer = 0; int duty = 0, pos = 0; int vol = 0, envTimer = 0; int len = 0; bool on = false; int sweepTimer = 0; u32 shadow = 0; };
    Square sq_[2];
    struct Wave { u32 timer = 0; int pos = 0, len = 0; bool on = false; } wave_;
    struct Noise { u32 timer = 0; u16 lfsr = 0x7FFF; int vol = 0, envTimer = 0, len = 0; bool on = false; } noise_;
    u8 waveRam_[32] = {};                       // two banks of 16 bytes
    s8 fifo_[2][32] = {}; int fifoCount_[2] = {}, fifoRead_[2] = {}; s8 fifoSample_[2] = {};
    s64 seqCycles_ = 0; int seqStep_ = 0;
    double sampleAccum_ = 0;
    std::vector<s16> sampleBuf_;

    // save memory
    SaveType saveType_ = SaveType::None;
    int saveOverride_ = 0;
    std::vector<u8> save_;
    bool saveDirty_ = false, saveRejected_ = false;
    int flashState_ = 0; bool flashId_ = false, flashErase_ = false, flashWrite_ = false, flashBankSel_ = false; int flashBank_ = 0;
    // EEPROM serial state
    u64 eeBits_ = 0; int eeCount_ = 0; int eeMode_ = 0;  // 0 cmd, 1 reading out
    u32 eeAddr_ = 0; int eeCmd_ = 0; int eeReadPos_ = 0; u64 eeReadData_ = 0;
    int eeAddrBits() const { return saveType_ == SaveType::EEPROM512 ? 6 : 14; }
    bool isEepromAddr(u32 a) const { return (saveType_ == SaveType::EEPROM512 || saveType_ == SaveType::EEPROM8K || saveType_ == SaveType::EEPROMUnknown) && ((a >> 24) == 0x0D) && (rom_.size() <= 0x1000000 || (a & 0x00FFFF00) == 0x00FFFF00); }

    // ---- helpers
    void buildBios();
public:
    bool setLLEBIOS(const std::vector<u8>& bios, const std::vector<u8>&, const std::vector<u8>&, bool) override;
    bool usingLLEBIOS() const override { return lle_; }
private:
    bool lle_ = false;
    void detectSave();
    void setSaveType(SaveType t);
    void stepCycles(s64 cycles);
    void tickTimers(u32 cycles);
    void timerOverflow(int i);
    void raise(int bit) { io_[0x202 / 2] |= u16(1u << bit); }
    void checkIRQ();
    void startLine();
    void enterHBlank();
    void runDma(int ch);
    void triggerDma(int timing);
    void fifoPush(int f, u32 value, int bytes);
    void fifoPop(int f);
    void audioTick(u32 cycles);
    void audioSequencer();
    void mixSample();
    void renderLine(int y);
    void handleSWI(ARMCPU& c, u32 n);
    u16 ioRead16(u32 off);
    void ioWrite16(u32 off, u16 v, u16 mask = 0xFFFF);
    u32 biosRead(u32 a);
    u32 openBus(u32 a);
    u32 biosLatch_ = 0xE129F000;
    u8 saveRead(u32 a);
    void saveWrite(u32 a, u8 v);
    u16 eepromRead();
    void eepromWrite(u16 v);
    void serialize(StateIO& s);
};

} // namespace dscore
