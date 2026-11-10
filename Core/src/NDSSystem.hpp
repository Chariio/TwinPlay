// Copyright (c) 2026 Charlie Rodriguez Garcia. All rights reserved.
// Original clean-room DS system model written from public GBATEK documentation.
#pragma once
#include <cstdlib>
#include "dscore/ARMCPU.hpp"
#include "dscore/AudioRing.hpp"
#include "dscore/EmulatorCore.hpp"
#include "GPU2D.hpp"
#include "SPI.hpp"
#include "Wifi.hpp"
#include "SPU.hpp"
#include "GPU3D.hpp"
#include "RTC.hpp"
#include "CartCrypto.hpp"
#include "SaveMemory.hpp"
#include "VRAM.hpp"
#include <array>
#include <deque>
#include <map>
#include <vector>

namespace dscore {

class NDSSystem;

// One CPU's view of the address space.
class CPUBus final : public Bus {
public:
    CPUBus(NDSSystem& sys, bool arm9) : sys_(sys), arm9_(arm9) {}
    u8 read8(u32 a) override;   u16 read16(u32 a) override;   u32 read32(u32 a) override;
    void write8(u32 a, u8 v) override; void write16(u32 a, u16 v) override; void write32(u32 a, u32 v) override;
private:
    NDSSystem& sys_;
    bool arm9_;
};

struct Timer { u16 reload = 0, control = 0; u32 counter = 0; u32 accum = 0; };
struct DMAChannel { u32 src = 0, dst = 0, cnt = 0; };

// Optional debugging hooks (headless runner / tests). All calls are skipped when unset.
struct DebugHooks {
    virtual ~DebugHooks() = default;
    virtual void io(bool /*arm9*/, u32 /*addr*/, int /*size*/, bool /*write*/, u32 /*value*/) {}
    virtual void swi(bool /*arm9*/, u32 /*number*/, u32 /*pc*/) {}
    virtual void sample(u32 /*pc9*/, u32 /*pc7*/) {}
    virtual void note(const char* /*text*/) {}
};

class NDSSystem final : public EmulatorCore {
public:
    u32 wifiAccesses() const { return wifi_.accesses(); }
    NDSSystem();
    bool loadROM(const u8* data, size_t size, std::string& error) override;
    void reset() override;
    void runFrame() override;
    void setFrameSkip(int n) override { frameSkip_ = n < 0 ? 0 : (n > 9 ? 9 : n); }
    // Cheats: ARM9 bus, memory only (I/O is skipped so FIFOs and IRQ flags are untouched).
    u32 cheatRead(u32 a, int size) override { return (a >> 24) == 0x04 ? 0 : read(true, a, size); }
    void cheatWrite(u32 a, u32 v, int size) override { if ((a >> 24) != 0x04) write(true, a, v, size); }
    u32 achievementRead(u32 a, u8* b, u32 n) override {
        for (u32 i = 0; i < n; ++i) {
            u32 x = a + i;
            if (x < 0x400000u) b[i] = mainRAM_[x];
            else if (x < 0x1000000u) b[i] = 0;                       // DSi-only RAM (padding)
            else if (x < 0x1004000u) b[i] = dtcm_[x - 0x1000000u];
            else return i;
        }
        return n;
    }
    void setRenderThreads(int n) override { gpu3d_.setRenderThreads(n); }
    bool frameDrawn() const override { return lastDrawn_; }
    void setRenderScale(int n) override;
    void setAudioInterpolation(int mode) override { spu_.setInterpolation(mode); }
    void setEnhancements(int aa, bool texFilter, bool wide) override {
        gpu3d_.setAntiAlias(GPU3D::AntiAlias(aa < 0 || aa > 2 ? 0 : aa));
        gpu3d_.setTextureFilter(texFilter); gpu3d_.setWidescreen(wide);
    }
    int renderScale() const override { return renderScale_; }
    u64 polygonsSubmitted() const override { return gpu3d_.stats.submitted; }
    int stuckFrames() const override { return stuckFrames_; }
    std::string freezeReport() override;
    u64 irqLivelockRecoveries() const override { return irqLivelocks_; }
    u64 renderPoolStalls() const override { return gpu3d_.poolStalls(); }
    bool captureInUse() const override { return captureRecent_ > 0; }
    const u32* framebufferHiRes(int s) const override {
        if (renderScale_ == 1) return framebuffer(s);
        return s == 0 ? hiTop_.data() : hiBottom_.data();
    }
    const u32* framebuffer(int s) const override { return s == 0 ? top_.data() : bottom_.data(); }
    void setButtons(u32 m) override { buttons_ = m; }
    void setTouch(bool d, int x, int y) override { touchDown_ = d; touchX_ = x; touchY_ = y; spi_.setTouch(d, x, y); }
    size_t readAudio(s16* out, size_t n) override { return audio_.pop(out, n); }
    size_t audioBuffered() const override { return audio_.size(); }
    const RomInfo& romInfo() const override { return info_; }
    std::string statusText() const override;
    bool saveDataDirty() const override { return save_.dirty(); }
    std::vector<u8> saveData() const override { return save_.data(); }
    void clearSaveDataDirty() override { save_.clearDirty(); }
    void loadSaveData(const std::vector<u8>& d) override { save_.load(d); }
    SaveMemory& saveMemory() { return save_; }
    void setSaveTypeOverride(int o) override { userSaveOverride_ = o < 0 || o > 9 ? 0 : o; applySaveOverride(); }
    // Known save chips by game code (first 3 letters, all regions). Used when the user's
    // override is Auto; unknown games use probe-based detection.
    static SaveMemory::Override saveTypeForGame(const std::string& gameCode);
    void applySaveOverride() {
        SaveMemory::Override o = SaveMemory::Override(userSaveOverride_);
        if (o == SaveMemory::Override::Auto) o = saveTypeForGame(info_.gameCode);
        save_.setOverride(o);
    }
    bool loadedSaveRejected() const override { return save_.loadedSaveRejected(); }
    std::string saveTypeDescription() const override {
        switch (save_.type()) {
        case SaveMemory::Type::Unknown: return "not detected yet";
        case SaveMemory::Type::EEPROM512: return "EEPROM 0.5 KB";
        case SaveMemory::Type::EEPROM: return save_.capacity() <= 0x2000 ? "EEPROM 8 KB" : "EEPROM 64 KB";
        case SaveMemory::Type::FRAM: return "FRAM 32 KB";
        case SaveMemory::Type::Flash: return (save_.capacity() == 0x20000 ? "EEPROM " : "Flash ") + std::to_string(save_.capacity() / 1024) + " KB";
        }
        return {};
    }
    std::vector<u8> saveState() override;
    bool loadState(const std::vector<u8>& data) override;
    void setARM7BIOS(const std::vector<u8>& bios) override;
    bool setLLEBIOS(const std::vector<u8>& bios9, const std::vector<u8>& bios7,
                    const std::vector<u8>& firmware, bool bootFirmware) override;
    bool usingLLEBIOS() const override { return lle_; }
    std::vector<u8> bios9_, bios7_;
    bool lle_ = false, bootFirmware_ = false;
    GPU3D& gpu3d() { return gpu3d_; }
    GPU2D& gpuA() { return gpuA_; }
    RTC& rtc() { return rtc_; }
    SecureArea secureAreaStatus() const { return secureArea_; }

    // Memory access used by CPUBus. size = 1, 2 or 4.
    u32 read(bool arm9, u32 addr, int size);
    void write(bool arm9, u32 addr, u32 value, int size);

    void setDebugHooks(DebugHooks* d) { debug_ = d; }
    ARMCPU& arm9() { return arm9_; }
    ARMCPU& arm7() { return arm7_; }
    VRAM& vram() { return vram_; }
    SPIBus& spi() { return spi_; }
    u32 vcount() const { return vcount_; }

private:
    friend class CPUBus;
    struct CpuState {
        std::array<u8, 0x2000> io{};
        u32 ie = 0, iflags = 0, ime = 0;
        Timer timers[4];
        DMAChannel dma[4];
        std::deque<u32> fifoRecv;     // words received from the other CPU
        u16 fifoCnt = 0x0101;        // send empty + recv empty
        u32 lastFifoWord = 0;
        u16 ipcSync = 0;
    };

    u8* memoryPointer(bool arm9, u32 addr, u32& mask);
    u16 ioRead16(bool arm9, u32 off);
    void ioWrite16(bool arm9, u32 off, u16 v, u16 byteMask);
    u32 ioRead32(bool arm9, u32 off);
    void ioWrite32(bool arm9, u32 off, u32 v);

    void requestIRQ(bool arm9, int bit) { (arm9 ? s9_ : s7_).iflags |= (1u << bit); }
    void checkIRQ(ARMCPU& cpu, CpuState& st);
    // Debug only: DSEMU_BREAK7=<hex pc> logs ARM7 visits to that address.
    u32 dbgBreak7_ = std::getenv("DSEMU_BREAK7") ? u32(std::strtoul(std::getenv("DSEMU_BREAK7"), nullptr, 16)) : 0;
    int dbgHits_ = 0;
    u32 dbgBreak9_ = std::getenv("DSEMU_BREAK9") ? u32(std::strtoul(std::getenv("DSEMU_BREAK9"), nullptr, 16)) : 0;
    int dbgHits9_ = 0;
    void runCpus(int budget9);
    void runCpuChunk(ARMCPU& cpu, CpuState& s, u32 irqReturnMagic, int n, const int& burn);
    void afterUnmask(ARMCPU& cpu, CpuState& s);
    void irqWatchdogFrame();
    u32 maskedWakes_[2] = {}, irqTaken_[2] = {}; int livelockFrames_[2] = {}; int preciseIrqFrames_ = 0; u64 irqLivelocks_ = 0;
    void startLine(int line);
    void stepTimers(CpuState& st, bool arm9, u32 ticks);
    void runDMA(bool arm9, int ch);
    bool triggerDMAs(bool arm9, u32 timing);
    void romTransferStart();
    u32 romReadData();
    void divUpdate();
    void sqrtUpdate();
    void renderLine(int line);
    void rebuildPageTables();
    static u8 spuRead(void* ctx, u32 addr) { return u8(static_cast<NDSSystem*>(ctx)->read(false, addr, 1)); }
    static void spuWrite(void* ctx, u32 addr, u16 v) { static_cast<NDSSystem*>(ctx)->write(false, addr, v, 2); }
    void mixAudioLine();
    void mixAudioChunk(int n);
    static constexpr int kFrameAudioMax = 2048;
    s16 frameBuf_[kFrameAudioMax * 2] = {};
    int frameAudio_ = 0;
    u32 vramRead(bool arm9, u32 addr, int size);
    void vramWrite(bool arm9, u32 addr, u32 v, int size);
    void handleSWI(ARMCPU& cpu, u32 comment);
    void handleIRQEntry(ARMCPU& cpu);
    bool handleIRQReturn(ARMCPU& cpu);
    void directBoot();
    void firmwareBoot();
    void serialize(StateIO& s);
    bool decompressSWI(ARMCPU& c, bool is9, u32 n);
    u32 callbackRead(ARMCPU& c, bool is9, u32 cbStruct, int which, u32 src);
    u32 irqCheckAddress(bool arm9) const { return arm9 ? dtcmBase_ + 0x3FF8 : 0x0380FFF8; }

    CPUBus bus9_, bus7_;
    ARMCPU arm9_, arm7_;
    CpuState s9_, s7_;

    std::vector<u8> rom_;
    RomInfo info_;
    bool romLoaded_ = false;

    std::vector<u8> mainRAM_, sharedWRAM_, arm7WRAM_, itcm_, dtcm_, palette_, oam_;
    VRAM vram_;
    GPU2D gpuA_, gpuB_;
    SPIBus spi_;
    WifiChip wifi_;
    SaveMemory save_;
    u8 saveOut_ = 0xFF;
    SPU spu_;
    GPU3D gpu3d_;
    RTC rtc_;
    std::vector<u8> key1Table_;
    SecureArea secureArea_ = SecureArea::None;
    int cartMode_ = 2;                              // 0 raw, 1 KEY1, 2 main data (KEY2)
    double audioFrac_ = 0;
    std::vector<u8*> pages9r_, pages9w_, pages7r_, pages7w_;
    u32 itcmSize_ = 0x02000000;
    bool itcmOn_ = true, dtcmOn_ = true;
    u32 dtcmBase_ = 0x00800000;
    u8 wramCnt_ = 3;
    u16 powcnt1_ = 0x820F;
    u16 dispstat9_ = 0, dispstat7_ = 0;
    u32 vcount_ = 0;
    std::map<u32, u32> cp15_;

    // Cartridge bus
    u32 romCtrl_ = 0;
    u16 auxSpiCnt_ = 0;
    u8 romCmd_[8] = {};
    u32 romAddr_ = 0, romRemaining_ = 0; u8 romCmdKind_ = 0;

    // Math hardware (ARM9)
    u16 divCnt_ = 0, sqrtCnt_ = 0;
    s64 divNumer_ = 0, divDenom_ = 0, divResult_ = 0, divRem_ = 0;
    u64 sqrtParam_ = 0; u32 sqrtResult_ = 0;

    std::vector<u32> top_, bottom_;
    std::vector<u32> hiTop_, hiBottom_;                 // only used when renderScale_ > 1
    int renderScale_ = 1;
    int pendingScale_ = 0;
    u64 lastWrites_ = 0; int stuckFrames_ = 0;          // frames in a row with no CPU memory writes (game frozen)                              // applied at the next frame start (frame boundary)
    void applyRenderScale(int n);
    void upscaleLine(int line, bool engineA, const u32* src, std::vector<u32>& dst);
    u32 buttons_ = 0;
    bool touchDown_ = false; int touchX_ = 0, touchY_ = 0;
    AudioRing audio_;
    bool intrWaiting9_ = false, intrWaiting7_ = false;
    int burn9_ = 0, burn7_ = 0;
    int userSaveOverride_ = 0;
    // Card chip ID: maker C2h, byte 1 = size in MB - 1 (from the ROM's capacity field).
    u32 chipId() const {
        u32 cap = rom_.size() > 0x14 ? rom_[0x14] : 0;          // 128 KB << n
        u32 mb = cap >= 3 && cap < 16 ? (1u << (cap - 3)) : 1u;
        if (mb > 0x80) mb = 0x80;
        return 0xC2u | ((mb - 1) << 8);
    }                    // instructions left in an HLE WaitByLoop
    u32 intrWaitMask9_ = 0, intrWaitMask7_ = 0;
    u64 frameCount_ = 0;
    int frameSkip_ = 0;
    bool lastDrawn_ = true;
    // Games using display capture draw alternate screens on alternate frames: never skip those.
    bool drawFrame(u64 n) const { return frameSkip_ == 0 || captureRecent_ > 0 || n % u64(frameSkip_ + 1) == u64(frameSkip_); }
    void finishCaptureLine(int line);
    bool captureThisFrame_ = false;
    u32 captureLatch_ = 0;
    int captureRecent_ = 0;
    std::string lastNotice_;
    DebugHooks* debug_ = nullptr;
};

} // namespace dscore
