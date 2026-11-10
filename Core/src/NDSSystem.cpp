// Copyright (c) 2026 Charlie Rodriguez Garcia. All rights reserved.
// Original clean-room DS system model written from public GBATEK documentation.
// Status: early skeleton. See README "Roadmap" for what is missing.
#include <cstdio>
#include <cstdlib>
#include "NDSSystem.hpp"
#include "SPI.hpp"
#include <algorithm>
#include <cstring>
#include <cstdio>
#include <cmath>

namespace dscore {

namespace {
constexpr u32 kIrqReturnMagic9 = 0xFFFF0200u;   // inside the (absent) ARM9 BIOS area
constexpr u32 kIrqReturnMagic7 = 0x00003FF0u;   // inside the (absent) ARM7 BIOS area
constexpr int kCyclesPerLine9 = 2130;           // simplified: ARM9 instructions per scanline
constexpr int kLines = 263;

inline u32 ld(const u8* p, int size) {
    if (size == 1) return p[0];
    if (size == 2) return u32(p[0]) | (u32(p[1]) << 8);
    return u32(p[0]) | (u32(p[1]) << 8) | (u32(p[2]) << 16) | (u32(p[3]) << 24);
}
inline void st(u8* p, u32 v, int size) { for (int i = 0; i < size; ++i) p[i] = u8(v >> (8 * i)); }
} // namespace

// ------------------------------------------------------------------ CPUBus
u8  CPUBus::read8(u32 a)  { return u8(sys_.read(arm9_, a, 1)); }
u16 CPUBus::read16(u32 a) { return u16(sys_.read(arm9_, a & ~1u, 2)); }
u32 CPUBus::read32(u32 a) { return sys_.read(arm9_, a & ~3u, 4); }
void CPUBus::write8(u32 a, u8 v)   { sys_.write(arm9_, a, v, 1); }
void CPUBus::write16(u32 a, u16 v) { sys_.write(arm9_, a & ~1u, v, 2); }
void CPUBus::write32(u32 a, u32 v) { sys_.write(arm9_, a & ~3u, v, 4); }

// --------------------------------------------------------------- NDSSystem
NDSSystem::NDSSystem()
    : bus9_(*this, true), bus7_(*this, false),
      arm9_(ARMCPU::Arch::ARMv5TE, bus9_), arm7_(ARMCPU::Arch::ARMv4T, bus7_),
      mainRAM_(4 << 20), sharedWRAM_(32 << 10), arm7WRAM_(64 << 10), itcm_(32 << 10), dtcm_(16 << 10),
      palette_(2 << 10), oam_(2 << 10),
      gpuA_(true, &s9_.io[0], &palette_[0], &oam_[0], vram_), gpuB_(false, &s9_.io[0x1000], &palette_[0x400], &oam_[0x400], vram_),
      spu_(&s7_.io[0x400], &NDSSystem::spuRead, this, &NDSSystem::spuWrite),
      gpu3d_(&s9_.io[0], vram_),
      pages9r_(ARMCPU::kFastLimit >> ARMCPU::kPageShift), pages9w_(ARMCPU::kFastLimit >> ARMCPU::kPageShift),
      pages7r_(ARMCPU::kFastLimit >> ARMCPU::kPageShift), pages7w_(ARMCPU::kFastLimit >> ARMCPU::kPageShift),
      top_(kScreenPixels, 0xFF000000u), bottom_(kScreenPixels, 0xFF000000u) {
    gpuA_.set3DSource(gpu3d_.output());
    arm9_.setFastPages(pages9r_.data(), pages9w_.data());
    arm7_.setFastPages(pages7r_.data(), pages7w_.data());
    arm9_.onSWI = [this](ARMCPU& c, u32 n) { handleSWI(c, n); };
    arm7_.onSWI = [this](ARMCPU& c, u32 n) { handleSWI(c, n); };
    arm9_.onIRQ = [this](ARMCPU& c) { handleIRQEntry(c); };
    arm7_.onIRQ = [this](ARMCPU& c) { handleIRQEntry(c); };
    arm9_.onMRC = [this](u32 cn, u32 cm, u32 op2) {
        auto it = cp15_.find((cn << 8) | (cm << 4) | op2);
        return it == cp15_.end() ? 0u : it->second;
    };
    arm9_.onMCR = [this](u32 cn, u32 cm, u32 op2, u32 v) {
        cp15_[(cn << 8) | (cm << 4) | op2] = v;
        if (cn == 9 && cm == 1 && op2 == 0) dtcmBase_ = v & 0xFFFFF000u;       // DTCM region
        if (cn == 9 && cm == 1 && op2 == 1) itcmSize_ = 512u << ((v >> 1) & 31);  // ITCM virtual size
        if (cn == 1 && cm == 0 && op2 == 0) { dtcmOn_ = v & (1u << 16); itcmOn_ = v & (1u << 18); }
        if (cn == 9 || cn == 1) rebuildPageTables();
        if (cn == 7 && ((cm == 0 && op2 == 4) || (cm == 8 && op2 == 2))) arm9_.halted = true; // wait for IRQ
    };
}

bool NDSSystem::setLLEBIOS(const std::vector<u8>& bios9, const std::vector<u8>& bios7,
                           const std::vector<u8>& firmware, bool bootFirmware) {
    bool ok = bios9.size() == 0x1000 && bios7.size() == 0x4000;
    if (!ok) {                                                             // back to HLE
        lle_ = bootFirmware_ = false; bios9_.clear(); bios7_.clear();
        arm9_.onSWI = [this](ARMCPU& c, u32 n) { handleSWI(c, n); };
        arm7_.onSWI = [this](ARMCPU& c, u32 n) { handleSWI(c, n); };
        arm9_.onIRQ = [this](ARMCPU& c) { handleIRQEntry(c); };
        arm7_.onIRQ = [this](ARMCPU& c) { handleIRQEntry(c); };
        return bios9.empty() && bios7.empty();
    }
    bios9_ = bios9; bios7_ = bios7; lle_ = true;
    setARM7BIOS(bios7);                                                    // KEY1 table too
    arm9_.onSWI = nullptr; arm7_.onSWI = nullptr;                          // SWIs/IRQs go through the real vectors
    arm9_.onIRQ = nullptr; arm7_.onIRQ = nullptr;
    bool fwOK = firmware.size() == 0x40000 || firmware.size() == 0x80000;
    if (fwOK) spi_.setFirmware(firmware);
    bootFirmware_ = bootFirmware && fwOK;
    return true;
}

void NDSSystem::setARM7BIOS(const std::vector<u8>& bios) {
    if (bios.size() >= 0x30 + Key1::kTableBytes) key1Table_.assign(bios.begin() + 0x30, bios.begin() + 0x30 + long(Key1::kTableBytes));
    else key1Table_.clear();
}

std::string NDSSystem::statusText() const {
    if (arm9_.faulted) return arm9_.faultMessage;
    if (arm7_.faulted) return arm7_.faultMessage;
    if (!lastNotice_.empty()) return lastNotice_;
    char b[96]; std::snprintf(b, sizeof b, "Experimental core · frame %llu", (unsigned long long)frameCount_);
    return b;
}

namespace {
// Debug logs for the headless runner, enabled by environment variable (read once).
bool traceOn(const char* name) {
    static const bool save = std::getenv("DSEMU_SAVETRACE"), ipc = std::getenv("DSEMU_IPCTRACE"), card = std::getenv("DSEMU_CARDTRACE");
    return name[6] == 'S' ? save : name[6] == 'I' ? ipc : card;
}
}

SaveMemory::Override NDSSystem::saveTypeForGame(const std::string& code) {
    using O = SaveMemory::Override;
    // Built from headless runs of the user's own cartridges (AUXSPI command logs).
    struct Entry { const char* code3; O type; };
    static const Entry db[] = {
        {"AMC", O::Flash256K},     // Mario Kart DS
        {"A2D", O::EEPROM8K},      // New Super Mario Bros.
        {"CPU", O::Flash512K},     // Pokemon Platinum
        {"ACV", O::EEPROM8K},      // Castlevania: Dawn of Sorrow
        {"ACB", O::EEPROM64K},     // Castlevania: Portrait of Ruin
        {"YCT", O::EEPROM512},     // Contra 4
        {"AWD", O::Flash256K},     // Diddy Kong Racing DS
        {"YGL", O::EEPROM8K},      // Geometry Wars: Galaxies
        {"YKG", O::EEPROM64K},     // Kingdom Hearts 358/2 Days
        {"AZE", O::Flash512K},     // Zelda: Phantom Hourglass
        {"AMT", O::EEPROM8K},      // Meteos
        {"AP2", O::EEPROM512},     // Metroid Prime Pinball
        {"YLT", O::EEPROM8K},      // Professor Layton and the Diabolical Box
        {"ASP", O::EEPROM64K},     // Super Princess Peach
        {"ATR", O::EEPROM8K},      // Tetris DS
        {"AYI", O::EEPROM512},     // Yoshi Touch & Go
        {"TRZ", O::EEPROM8K},      // Zuma's Revenge
        {"IPK", O::Flash512K},     // Pokemon HeartGold (IR)
        {"IPG", O::Flash512K},     // Pokemon SoulSilver (IR)
        {"IRB", O::Flash512K},     // Pokemon Black (IR)
        {"IRA", O::Flash512K},     // Pokemon White (IR)
        {"IRE", O::Flash512K},     // Pokemon Black 2 (IR)
        {"IRD", O::Flash512K},     // Pokemon White 2 (IR)
    };
    if (code.size() < 3) return O::Auto;
    for (const auto& e : db) if (code.compare(0, 3, e.code3) == 0) return e.type;
    return O::Auto;
}

bool NDSSystem::loadROM(const u8* data, size_t size, std::string& error) {
    RomInfo ri;
    if (!parseRomHeader(data, size, ri, error)) return false;
    rom_.assign(data, data + size);
    secureArea_ = prepareSecureArea(rom_, key1Table_.empty() ? nullptr : key1Table_.data());
    save_.clear(); burn9_ = burn7_ = 0;
    info_ = ri;
    applySaveOverride(); save_.clearDirty();
    {   const std::string& gc = info_.gameCode;
        save_.setInfrared(gc.size() >= 3 && (gc.compare(0, 2, "IR") == 0 || gc.compare(0, 3, "IPK") == 0 || gc.compare(0, 3, "IPG") == 0)); }
    romLoaded_ = true;
    reset();
    return true;
}

void NDSSystem::reset() {
    for (auto* v : {&mainRAM_, &sharedWRAM_, &arm7WRAM_, &itcm_, &dtcm_, &palette_, &oam_})
        std::fill(v->begin(), v->end(), 0);
    s9_ = CpuState{}; s7_ = CpuState{};
    cp15_.clear();
    cp15_[0x000] = 0x41059461u;   // main ID (ARM946E-S)
    cp15_[0x001] = 0x0F0D2112u;   // cache type
    cp15_[0x002] = 0x00140180u;   // TCM size
    cp15_[0x100] = 0x0005707Du;   // control register (ITCM + DTCM enabled)
    cp15_[0x911] = 0x00000020u;   // ITCM region: base 0, virtual size 32 MB
    itcmSize_ = 0x02000000u; itcmOn_ = dtcmOn_ = true;
    vram_.reset(); spi_.reset(); wifi_.reset(); gpuA_.reset(); gpuB_.reset();
    spi_.setTouch(touchDown_, touchX_, touchY_);
    dtcmBase_ = 0x00800000u;
    wramCnt_ = 3; powcnt1_ = 0x820F; dispstat9_ = dispstat7_ = 0; vcount_ = 0;
    romCtrl_ = 0; auxSpiCnt_ = 0; romRemaining_ = 0;
    divCnt_ = sqrtCnt_ = 0; divNumer_ = divDenom_ = divResult_ = divRem_ = 0; sqrtParam_ = 0; sqrtResult_ = 0;
    frameCount_ = 0; lastNotice_.clear();
    gpu3d_.reset(); rtc_.reset(); cartMode_ = 2;
    if (secureArea_ == SecureArea::EncryptedNoKey) lastNotice_ = "Encrypted secure area: import your own ARM7 BIOS (biosnds7.bin) to decrypt it";
    if (secureArea_ == SecureArea::BadKey) lastNotice_ = "Secure area could not be decrypted (wrong ARM7 BIOS?)";
    intrWaiting9_ = intrWaiting7_ = false;
    audio_.clear();
    spu_.reset(); audioFrac_ = 0; saveOut_ = 0xFF;
    rebuildPageTables();
    if (romLoaded_ && lle_ && bootFirmware_) firmwareBoot();
    else if (romLoaded_) directBoot();
    else { arm9_.reset(0); arm9_.halted = true; arm7_.reset(0); arm7_.halted = true; }
}

// Low-level boot through the user's own BIOS + firmware: both CPUs start at their reset
// vectors and the firmware shows its boot screen / menu. Experimental.
void NDSSystem::firmwareBoot() {
    s9_.io[0x300] = 0; s7_.io[0x300] = 0;
    cp15_[0x100] = 0x00012078u;                                           // reset value: high vectors, TCMs off
    itcmOn_ = dtcmOn_ = false; rebuildPageTables();
    cartMode_ = 0;                                                        // cartridge starts unencrypted (KEY1 phase)
    arm9_.reset(0xFFFF0000u, false);
    arm7_.reset(0x00000000u, false);
}

// Emulates what the real boot ROM leaves behind ("direct boot"), so no
// Nintendo BIOS/firmware file is needed. Values from GBATEK.
void NDSSystem::directBoot() {
    const u8* h = rom_.data();
    for (u32 i = 0; i < info_.arm9Size; ++i) write(true, info_.arm9RamAddress + i, h[info_.arm9RomOffset + i], 1);
    for (u32 i = 0; i < info_.arm7Size; ++i) write(false, info_.arm7RamAddress + i, h[info_.arm7RomOffset + i], 1);
    for (u32 i = 0; i < 0x170; ++i) mainRAM_[(0x027FFE00u + i) & 0x3FFFFF] = h[i];   // header copy
    for (u32 a : {0x027FF800u, 0x027FF804u, 0x027FFC00u, 0x027FFC04u}) st(&mainRAM_[a & 0x3FFFFF], chipId(), 4); // chip ID
    st(&mainRAM_[0x027FFC40u & 0x3FFFFF], 1, 2);  // boot indicator: cartridge
    // POSTFLG: the boot firmware leaves bit 0 set on both CPUs. SDK reset code
    // (e.g. Pokemon B2/W2) only does its PXI handshake when it reads 1.
    s9_.io[0x300] = 1; s7_.io[0x300] = 1;

    // Firmware user settings copy at 0x027FFC80 (generic, user-neutral values).
    buildUserSettings(&mainRAM_[0x027FFC80u & 0x3FFFFF]);

    arm9_.reset(info_.arm9Entry, false);
    arm7_.reset(info_.arm7Entry, false);
    arm9_.setBankedSP(ARMCPU::SVC, 0x00803FC0u); arm9_.setBankedSP(ARMCPU::IRQ, 0x00803FA0u);
    arm9_.setReg(13, 0x00803EC0u);
    arm7_.setBankedSP(ARMCPU::SVC, 0x0380FFDCu); arm7_.setBankedSP(ARMCPU::IRQ, 0x0380FFB0u);
    arm7_.setReg(13, 0x0380FF00u);
    arm9_.setReg(12, info_.arm9Entry); arm9_.setReg(14, info_.arm9Entry);
    arm7_.setReg(12, info_.arm7Entry); arm7_.setReg(14, info_.arm7Entry);
}

// ------------------------------------------------------------------ memory
u8* NDSSystem::memoryPointer(bool arm9, u32 a, u32& /*unused*/) {
    if (arm9 && dtcmOn_ && a >= dtcmBase_ && a < dtcmBase_ + 0x4000) return &dtcm_[a - dtcmBase_];
    if (arm9 && itcmOn_ && a < itcmSize_ && a < 0x02000000u) return &itcm_[a & 0x7FFF];
    switch (a >> 24) {
    case 0x00: case 0x01:                                                 // ARM7 BIOS (only with the user's dump)
        return (!arm9 && lle_ && a < 0x4000) ? &bios7_[a] : nullptr;
    case 0xFF:                                                            // ARM9 BIOS at 0xFFFF0000 (4 KB, mirrored)
        return (arm9 && lle_ && a >= 0xFFFF0000u) ? &bios9_[a & 0xFFF] : nullptr;
    case 0x02: return &mainRAM_[a & 0x3FFFFF];
    case 0x03:
        if (!arm9 && a >= 0x03800000u) return &arm7WRAM_[a & 0xFFFF];
        if (arm9) {
            switch (wramCnt_ & 3) {
            case 0: return &sharedWRAM_[a & 0x7FFF];
            case 1: return &sharedWRAM_[0x4000 + (a & 0x3FFF)];
            case 2: return &sharedWRAM_[a & 0x3FFF];
            default: return nullptr;
            }
        }
        switch (wramCnt_ & 3) {
        case 0: return &arm7WRAM_[a & 0xFFFF];
        case 1: return &sharedWRAM_[a & 0x3FFF];
        case 2: return &sharedWRAM_[0x4000 + (a & 0x3FFF)];
        default: return &sharedWRAM_[a & 0x7FFF];
        }
    case 0x05: return arm9 ? &palette_[a & 0x7FF] : nullptr;
    case 0x07: return arm9 ? &oam_[a & 0x7FF] : nullptr;
    default: return nullptr;
    }
}

u32 NDSSystem::read(bool arm9, u32 a, int size) {
    if ((a >> 24) == 0x04) {
        if (debug_) debug_->io(arm9, a, size, false, 0);
        if (a == 0x04100000u) {                                               // IPC FIFO receive
            CpuState& me = arm9 ? s9_ : s7_; CpuState& other = arm9 ? s7_ : s9_;
            if (me.fifoRecv.empty()) { me.fifoCnt |= 0x4000; return me.lastFifoWord; }
            me.lastFifoWord = me.fifoRecv.front(); me.fifoRecv.pop_front();
            if (me.fifoRecv.empty() && (other.fifoCnt & 0x0004)) requestIRQ(!arm9, 17);  // other's send-empty
            return me.lastFifoWord;
        }
        if (a == 0x04100010u) return romReadData();
        u32 off = a & 0x00FFFFFFu;
        if (!arm9 && off >= 0x800000u && off < 0x810000u) {                  // wireless chip
            if (size == 4) return wifi_.read16(off) | (u32(wifi_.read16(off + 2)) << 16);
            u16 w = wifi_.read16(off & ~1u);
            return size == 2 ? w : ((off & 1) ? (w >> 8) : (w & 0xFF));
        }
        if (off >= 0x2000) return 0;
        if (arm9 && GPU3D::handles(off)) return gpu3d_.read(off, size);
        if (size == 4) return ioRead32(arm9, off);
        u16 v = ioRead16(arm9, off & ~1u);
        return size == 2 ? v : ((off & 1) ? (v >> 8) : (v & 0xFF));
    }
    if ((a >> 24) == 0x06) return vramRead(arm9, a, size);
    if ((a >> 24) >= 0x08 && (a >> 24) <= 0x0A) return size == 1 ? 0xFF : (size == 2 ? 0xFFFF : 0xFFFFFFFFu); // no GBA cart
    u32 m;
    u8* p = memoryPointer(arm9, a, m);
    return p ? ld(p, size) : 0;
}

void NDSSystem::write(bool arm9, u32 a, u32 v, int size) {
    if ((a >> 24) == 0x04) {
        if (debug_) debug_->io(arm9, a, size, true, v);
        u32 off = a & 0x00FFFFFFu;
        if (!arm9 && off >= 0x800000u && off < 0x810000u) {                  // wireless chip
            if (size == 4) { wifi_.write16(off, u16(v)); wifi_.write16(off + 2, u16(v >> 16)); }
            else if (size == 2) wifi_.write16(off, u16(v));
            if (wifi_.takeIRQ()) requestIRQ(false, 24);
            return;
        }
        if (off >= 0x2000) return;
        if (arm9 && GPU3D::handles(off)) { gpu3d_.write(off, v, size); return; }
        if (size == 4) { ioWrite32(arm9, off, v); return; }
        if (size == 2) { if (off == 0x188) ioWrite32(arm9, off, v); else ioWrite16(arm9, off, u16(v), 0xFFFF); return; }
        u32 sh = (off & 1) * 8;
        ioWrite16(arm9, off & ~1u, u16((v & 0xFF) << sh), u16(0xFF << sh));
        return;
    }
    if ((a >> 24) == 0x06) { vramWrite(arm9, a, v, size); return; }
    if (size == 1 && arm9 && ((a >> 24) == 0x05 || (a >> 24) == 0x07)) return;   // 8-bit palette/OAM writes ignored
    if (lle_ && (((a >> 24) == 0xFF && arm9) || ((a >> 24) <= 0x01 && !arm9))) return;   // BIOS is read-only
    u32 m;
    u8* p = memoryPointer(arm9, a, m);
    if (p) st(p, v, size);
}

void NDSSystem::rebuildPageTables() {
    for (int k = 0; k < 2; ++k) {
        bool is9 = k == 0;
        std::vector<u8*>& rd = is9 ? pages9r_ : pages7r_;
        std::vector<u8*>& wr = is9 ? pages9w_ : pages7w_;
        for (size_t i = 0; i < rd.size(); ++i) {
            u32 a = u32(i) << ARMCPU::kPageShift, m;
            u8* p = nullptr;
            if ((a >> 24) <= 0x03) {
                u8* first = memoryPointer(is9, a, m);
                u8* last = memoryPointer(is9, a + 0x3FFF, m);
                bool linear = first && last == first + 0x3FFF;
                if (is9 && dtcmOn_) {                      // DTCM must cover the page fully or not at all
                    bool overlaps = dtcmBase_ < a + 0x4000 && a < dtcmBase_ + 0x4000;
                    if (overlaps && dtcmBase_ != a) linear = false;
                }
                if (is9 && itcmOn_ && a < itcmSize_ && a + 0x4000 > itcmSize_) linear = false;
                if (linear) p = first;
            }
            rd[i] = p; wr[i] = (!is9 && (a >> 24) <= 0x01) ? nullptr : p;   // ARM7 BIOS page is read-only
        }
    }
    arm9_.fastPagesChanged(); arm7_.fastPagesChanged();
}

static bool vramRegion(bool arm9, u32 a, VRAM::Region& r, u32& off) {
    if (!arm9) { r = VRAM::ARM7; off = a & 0x3FFFF; return true; }
    switch ((a >> 21) & 7) {
    case 0: r = VRAM::ABG; off = a & 0x7FFFF; return true;
    case 1: r = VRAM::BBG; off = a & 0x1FFFF; return true;
    case 2: r = VRAM::AOBJ; off = a & 0x3FFFF; return true;
    case 3: r = VRAM::BOBJ; off = a & 0x1FFFF; return true;
    default: r = VRAM::LCDC; off = (a - 0x06800000u) & 0xFFFFF; return true;
    }
}

u32 NDSSystem::vramRead(bool arm9, u32 a, int size) {
    VRAM::Region r; u32 off;
    if (!vramRegion(arm9, a, r, off)) return 0;
    u32 v = 0;
    for (int i = 0; i < size; ++i) v |= u32(vram_.read8(r, off + u32(i))) << (8 * i);
    return v;
}

void NDSSystem::vramWrite(bool arm9, u32 a, u32 v, int size) {
    VRAM::Region r; u32 off;
    if (!vramRegion(arm9, a, r, off)) return;
    for (int i = 0; i < size; ++i) vram_.write8(r, off + u32(i), u8(v >> (8 * i)));
}

u32 NDSSystem::ioRead32(bool arm9, u32 off) {
    return u32(ioRead16(arm9, off)) | (u32(ioRead16(arm9, off + 2)) << 16);
}

void NDSSystem::ioWrite32(bool arm9, u32 off, u32 v) {
    if (off == 0x188) {                                                       // IPC FIFO send
        CpuState& me = arm9 ? s9_ : s7_; CpuState& other = arm9 ? s7_ : s9_;
        if (!(me.fifoCnt & 0x8000)) return;
        if (other.fifoRecv.size() >= 16) { me.fifoCnt |= 0x4000; return; }
        bool wasEmpty = other.fifoRecv.empty();
        other.fifoRecv.push_back(v);
        if (wasEmpty && (other.fifoCnt & 0x0400)) requestIRQ(!arm9, 18);      // other's recv-not-empty
        return;
    }
    ioWrite16(arm9, off, u16(v), 0xFFFF);
    ioWrite16(arm9, off + 2, u16(v >> 16), 0xFFFF);
}

u16 NDSSystem::ioRead16(bool arm9, u32 off) {
    CpuState& me = arm9 ? s9_ : s7_;
    CpuState& other = arm9 ? s7_ : s9_;
    auto raw = [&](u32 o) { return u16(me.io[o] | (me.io[o + 1] << 8)); };
    if (off >= 0x100 && off < 0x110) {
        const Timer& t = me.timers[(off - 0x100) / 4];
        return (off & 2) ? t.control : u16(t.counter);
    }
    switch (off) {
    case 0x004: return arm9 ? dispstat9_ : dispstat7_;
    case 0x006: return u16(vcount_);
    case 0x130: return u16(~buttons_ & 0x3FF);
    case 0x136: {
        if (arm9) return 0;
        u16 v = 0x007F;
        if (buttons_ & BtnX) v &= ~1u;
        if (buttons_ & BtnY) v &= ~2u;
        if (touchDown_) v &= ~0x40u;
        return v;
    }
    case 0x180: {
        u16 v = u16(((other.ipcSync >> 8) & 0xF) | (me.ipcSync & 0x4F00));
        if (!arm9 && traceOn("DSEMU_IPCTRACE")) std::fprintf(stderr, "7 read %X burn=%d\n", unsigned(v & 15), burn7_);
        return v;
    }
    case 0x184: {
        u16 v = me.fifoCnt & 0xC404;
        if (other.fifoRecv.empty()) v |= 0x0001;
        if (other.fifoRecv.size() >= 16) v |= 0x0002;
        if (me.fifoRecv.empty()) v |= 0x0100;
        if (me.fifoRecv.size() >= 16) v |= 0x0200;
        return v;
    }
    case 0x138: return arm9 ? raw(off) : rtc_.read();
    case 0x1A0: return auxSpiCnt_;
    case 0x1A2: return saveOut_;
    case 0x1A4: return u16(romCtrl_);
    case 0x1A6: return u16(romCtrl_ >> 16);
    case 0x208: return u16(me.ime);
    case 0x210: return u16(me.ie);   case 0x212: return u16(me.ie >> 16);
    case 0x214: return u16(me.iflags); case 0x216: return u16(me.iflags >> 16);
    case 0x240: return arm9 ? u16(vram_.control(0) | (vram_.control(1) << 8)) : u16(vram_.arm7Status() | (wramCnt_ << 8));
    case 0x246: return arm9 ? u16(vram_.control(6) | (wramCnt_ << 8)) : raw(off);
    case 0x1C0: return arm9 ? raw(off) : spi_.readCnt();
    case 0x1C2: return arm9 ? raw(off) : spi_.readData();
    default: break;
    }
    if (arm9) {
        switch (off) {
        case 0x242: return u16(vram_.control(2) | (vram_.control(3) << 8));
        case 0x244: return u16(vram_.control(4) | (vram_.control(5) << 8));
        case 0x248: return u16(vram_.control(7) | (vram_.control(8) << 8));
        case 0x280: return divCnt_;
        case 0x2A0: case 0x2A2: case 0x2A4: case 0x2A6: return u16(u64(divResult_) >> ((off - 0x2A0) * 8));
        case 0x2A8: case 0x2AA: case 0x2AC: case 0x2AE: return u16(u64(divRem_) >> ((off - 0x2A8) * 8));
        case 0x2B0: return sqrtCnt_;
        case 0x2B4: return u16(sqrtResult_); case 0x2B6: return u16(sqrtResult_ >> 16);
        case 0x304: return powcnt1_;
        default: break;
        }
    }
    return raw(off);
}

void NDSSystem::ioWrite16(bool arm9, u32 off, u16 v, u16 mask) {
    CpuState& me = arm9 ? s9_ : s7_;
    CpuState& other = arm9 ? s7_ : s9_;
    u16 old = u16(me.io[off] | (me.io[off + 1] << 8));
    u16 nv = u16((old & ~mask) | (v & mask));
    me.io[off] = u8(nv); me.io[off + 1] = u8(nv >> 8);

    if (off >= 0x100 && off < 0x110) {
        Timer& t = me.timers[(off - 0x100) / 4];
        if (!(off & 2)) t.reload = nv;
        else { bool start = !(t.control & 0x80) && (nv & 0x80); t.control = nv; if (start) { t.counter = t.reload; t.accum = 0; } }
        return;
    }
    if (off >= 0xB0 && off < 0xE0) {                                          // DMA channels
        int ch = int(off - 0xB0) / 12;
        if (off == 0xBA + u32(ch) * 12 && (nv & 0x8000) && !(old & 0x8000)) {
            DMAChannel& d = me.dma[ch];
            u32 base = 0xB0 + ch * 12;
            d.src = me.io[base] | (me.io[base + 1] << 8) | (me.io[base + 2] << 16) | (u32(me.io[base + 3]) << 24);
            d.dst = me.io[base + 4] | (me.io[base + 5] << 8) | (me.io[base + 6] << 16) | (u32(me.io[base + 7]) << 24);
            u32 timing = arm9 ? ((nv >> 11) & 7) : ((nv >> 12) & 3);
            if (timing == 0) runDMA(arm9, ch);
        }
        return;
    }
    switch (off) {
    case 0x004: {
        u16& ds = arm9 ? dispstat9_ : dispstat7_;
        ds = u16((ds & 0x0007) | (nv & 0xFFB8));
        return;
    }
    case 0x180: {
        me.ipcSync = nv & 0x4F00;
        if (traceOn("DSEMU_IPCTRACE")) std::fprintf(stderr, "%d sync %X\n", arm9 ? 9 : 7, unsigned((nv >> 8) & 15));
        if ((nv & 0x2000) && (other.ipcSync & 0x4000)) requestIRQ(!arm9, 16);
        return;
    }
    case 0x184: {
        bool sendIrqWasOn = me.fifoCnt & 0x0004, recvIrqWasOn = me.fifoCnt & 0x0400;
        if (nv & 0x0008) other.fifoRecv.clear();
        me.fifoCnt = u16((me.fifoCnt & ~0x8404) | (nv & 0x8404));
        if (nv & 0x4000) me.fifoCnt &= ~0x4000;
        if (!sendIrqWasOn && (me.fifoCnt & 0x0004) && other.fifoRecv.empty()) requestIRQ(arm9, 17);
        if (!recvIrqWasOn && (me.fifoCnt & 0x0400) && !me.fifoRecv.empty()) requestIRQ(arm9, 18);
        return;
    }
    case 0x1A0: auxSpiCnt_ = nv; if (!(nv & 0x8000)) save_.release(); return;
    case 0x1A2:
        if ((mask & 0xFF) && (auxSpiCnt_ & 0xA000) == 0xA000) {          // enabled + SPI (backup) mode
            saveOut_ = save_.transfer(u8(nv));
            if (traceOn("DSEMU_SAVETRACE")) std::fprintf(stderr, "spi %02X>%02X%s\n", unsigned(nv & 0xFF), unsigned(saveOut_), (auxSpiCnt_ & 0x40) ? "" : " |");
            if (!(auxSpiCnt_ & 0x40)) save_.release();                   // chip select not held
        }
        return;
    case 0x1A4: romCtrl_ = (romCtrl_ & 0xFFFF0000u) | nv; return;
    case 0x1A6: {
        bool start = (nv & 0x8000) && !(romCtrl_ & 0x80000000u);
        romCtrl_ = (romCtrl_ & 0xFFFFu) | (u32(nv & ~0x0080) << 16);          // bit23 is read-only
        if (start) romTransferStart();
        return;
    }
    case 0x1A8: case 0x1AA: case 0x1AC: case 0x1AE:
        if (mask & 0x00FF) romCmd_[off - 0x1A8] = u8(nv);
        if (mask & 0xFF00) romCmd_[off - 0x1A8 + 1] = u8(nv >> 8);
        return;
    case 0x208: me.ime = nv & 1; return;
    case 0x210: me.ie = (me.ie & 0xFFFF0000u) | nv; return;
    case 0x212: me.ie = (me.ie & 0x0000FFFFu) | (u32(nv) << 16); return;
    case 0x214: me.iflags &= ~u32(v & mask); return;                           // write 1 to acknowledge
    case 0x216: me.iflags &= ~(u32(v & mask) << 16); return;
    case 0x1C0: if (!arm9) spi_.writeCnt(nv); return;
    case 0x138: if (!arm9) rtc_.write(nv); return;
    default:
        if (!arm9 && off >= 0x400 && off < 0x500 && (off & 0xF) == 2) { spu_.channelControlWritten(int((off - 0x400) >> 4), old & 0x8000); return; }
        break;
    }
    switch (off) {
    case 0x1C2: if (!arm9 && (mask & 0xFF)) { if (spi_.writeData(u8(nv))) requestIRQ(false, 23); } return;
    case 0x300:
        if (!arm9 && (mask & 0xFF00) && ((nv >> 8) & 0xC0) == 0x80) arm7_.halted = true;   // HALTCNT
        if (!arm9) { me.io[0x301] = 0; }
        return;
    default: break;
    }
    if (arm9) {
        if (off >= 0x240 && off < 0x24A) {
            for (int b = 0; b < 2; ++b) {
                if (!(mask & (0xFF << (b * 8)))) continue;
                u32 o = off + b; u8 val = u8(nv >> (b * 8));
                if (o == 0x247) { wramCnt_ = val & 3; rebuildPageTables(); }
                else if (o < 0x247) vram_.setControl(int(o - 0x240), val);
                else vram_.setControl(int(o - 0x241), val);     // 0x248 -> H, 0x249 -> I
            }
            return;
        }
        if (off == 0x280) { divCnt_ = nv & 3; divUpdate(); return; }
        if (off >= 0x290 && off < 0x2A0) {
            u64 n = 0, d = 0;
            for (int i = 0; i < 8; ++i) { n |= u64(me.io[0x290 + i]) << (8 * i); d |= u64(me.io[0x298 + i]) << (8 * i); }
            divNumer_ = s64(n); divDenom_ = s64(d); divUpdate(); return;
        }
        if (off == 0x2B0) { sqrtCnt_ = nv & 1; sqrtUpdate(); return; }
        if (off >= 0x2B8 && off < 0x2C0) {
            u64 p = 0; for (int i = 0; i < 8; ++i) p |= u64(me.io[0x2B8 + i]) << (8 * i);
            sqrtParam_ = p; sqrtUpdate(); return;
        }
        if (off == 0x304) { powcnt1_ = nv; return; }
        if ((off >= 0x28 && off < 0x30) || (off >= 0x38 && off < 0x40)) { gpuA_.affineRegisterWritten(off < 0x30 ? 2 : 3); return; }
        if ((off >= 0x1028 && off < 0x1030) || (off >= 0x1038 && off < 0x1040)) { gpuB_.affineRegisterWritten(off < 0x1030 ? 2 : 3); return; }
    }
}

// ----------------------------------------------------------- math hardware
void NDSSystem::divUpdate() {
    s64 n, d;
    switch (divCnt_ & 3) {
    case 0: n = s32(u32(divNumer_)); d = s32(u32(divDenom_)); break;
    case 1: n = divNumer_; d = s32(u32(divDenom_)); break;
    default: n = divNumer_; d = divDenom_; break;
    }
    if (divDenom_ == 0) divCnt_ |= 0x4000; else divCnt_ &= ~0x4000;
    if (d == 0) { divResult_ = (n < 0) ? 1 : -1; divRem_ = n; return; }
    if (n == INT64_MIN && d == -1) { divResult_ = n; divRem_ = 0; return; }
    divResult_ = n / d; divRem_ = n % d;
}

void NDSSystem::sqrtUpdate() {
    u64 v = (sqrtCnt_ & 1) ? sqrtParam_ : (sqrtParam_ & 0xFFFFFFFFu);
    u64 res = 0, bitv = u64(1) << 62;
    while (bitv > v) bitv >>= 2;
    while (bitv) {
        if (v >= res + bitv) { v -= res + bitv; res = (res >> 1) + bitv; } else res >>= 1;
        bitv >>= 2;
    }
    sqrtResult_ = u32(res);
}

// ------------------------------------------------------------ DMA / timers
void NDSSystem::runDMA(bool arm9, int ch) {
    CpuState& me = arm9 ? s9_ : s7_;
    DMAChannel& d = me.dma[ch];
    u32 base = 0xB0 + ch * 12;
    u32 cnt = me.io[base + 8] | (me.io[base + 9] << 8) | (me.io[base + 10] << 16) | (u32(me.io[base + 11]) << 24);
    u32 count = cnt & (arm9 ? 0x1FFFFFu : (ch == 3 ? 0xFFFFu : 0x3FFFu));
    if (count == 0) count = arm9 ? 0x200000u : (ch == 3 ? 0x10000u : 0x4000u);
    u32 ctl = cnt >> 16;
    bool word = ctl & 0x0400;
    int unit = word ? 4 : 2;
    int dstStep = 0, srcStep = 0;
    switch ((ctl >> 5) & 3) { case 0: case 3: dstStep = unit; break; case 1: dstStep = -unit; break; default: break; }
    switch ((ctl >> 7) & 3) { case 0: srcStep = unit; break; case 1: srcStep = -unit; break; default: break; }
    for (u32 i = 0; i < count; ++i) {
        u32 val = read(arm9, d.src & ~u32(unit - 1), unit);
        write(arm9, d.dst & ~u32(unit - 1), val, unit);
        d.src += u32(srcStep); d.dst += u32(dstStep);
    }
    if (((ctl >> 5) & 3) == 3) {
        d.dst = me.io[base + 4] | (me.io[base + 5] << 8) | (me.io[base + 6] << 16) | (u32(me.io[base + 7]) << 24);
    }
    u32 timing = arm9 ? ((ctl >> 11) & 7) : ((ctl >> 12) & 3);
    if (!(ctl & 0x0200) || timing == 0) me.io[base + 11] &= 0x7F;            // clear enable
    if (ctl & 0x4000) requestIRQ(arm9, 8 + ch);
    arm9_.wake(); arm7_.wake();
}

bool NDSSystem::triggerDMAs(bool arm9, u32 timing) {
    CpuState& me = arm9 ? s9_ : s7_;
    bool ran = false;
    for (int ch = 0; ch < 4; ++ch) {
        u32 base = 0xB0 + ch * 12;
        u16 ctl = u16(me.io[base + 10] | (me.io[base + 11] << 8));
        if (!(ctl & 0x8000)) continue;
        u32 t = arm9 ? ((ctl >> 11) & 7) : ((ctl >> 12) & 3);
        if (t == timing) { runDMA(arm9, ch); ran = true; }
    }
    return ran;
}

void NDSSystem::stepTimers(CpuState& s, bool arm9, u32 ticks) {
    static const u32 prescale[4] = {1, 64, 256, 1024};
    u32 overflowsPrev = 0;
    for (int i = 0; i < 4; ++i) {
        Timer& t = s.timers[i];
        u32 overflows = 0;
        if (t.control & 0x80) {
            u32 incs;
            if (i > 0 && (t.control & 0x04)) incs = overflowsPrev;            // count-up (cascade)
            else { t.accum += ticks; incs = t.accum / prescale[t.control & 3]; t.accum %= prescale[t.control & 3]; }
            while (incs) {
                u32 room = 0x10000u - t.counter;
                if (incs >= room) { incs -= room; t.counter = t.reload; ++overflows; if (t.control & 0x40) requestIRQ(arm9, 3 + i); }
                else { t.counter += incs; incs = 0; }
                if (t.reload == 0xFFFF && overflows > 0x10000) break;         // pathological reload
            }
        }
        overflowsPrev = overflows;
    }
}

// --------------------------------------------------------------- cartridge
// Cartridge protocol. After direct boot the card is in "main data" mode, where
// KEY2 scrambling is applied symmetrically by the console and the card, so it is
// transparent to software and not modelled. Raw-mode and KEY1-mode commands are
// supported for games that re-initialise the card (KEY1 needs the user's BIOS).
void NDSSystem::romTransferStart() {
    u32 code = (romCtrl_ >> 24) & 7;
    romRemaining_ = code == 0 ? 0 : (code == 7 ? 4 : (0x100u << code));
    u8 cmd[8]; std::memcpy(cmd, romCmd_, 8);
    if (cartMode_ == 1 && !key1Table_.empty()) {               // KEY1 commands are Blowfish-encrypted
        u32 w[2] = {(u32(cmd[4]) << 24) | (u32(cmd[5]) << 16) | (u32(cmd[6]) << 8) | cmd[7],
                    (u32(cmd[0]) << 24) | (u32(cmd[1]) << 16) | (u32(cmd[2]) << 8) | cmd[3]};
        Key1 k; k.init(key1Table_.data(), u32(rom_[0x0C]) | (u32(rom_[0x0D]) << 8) | (u32(rom_[0x0E]) << 16) | (u32(rom_[0x0F]) << 24), 2, 8);
        k.decrypt(w);
        for (int i = 0; i < 4; ++i) { cmd[i] = u8(w[1] >> (24 - 8 * i)); cmd[4 + i] = u8(w[0] >> (24 - 8 * i)); }
    }
    romCmdKind_ = cmd[0];
    if (traceOn("DSEMU_CARDTRACE"))
        std::fprintf(stderr, "card %02X%02X%02X%02X%02X%02X%02X%02X ctrl=%08X aux=%04X mode=%d\n", cmd[0], cmd[1], cmd[2], cmd[3], cmd[4], cmd[5], cmd[6], cmd[7], romCtrl_, auxSpiCnt_, cartMode_);
    if (cartMode_ == 0) {
        if (cmd[0] == 0x3C) cartMode_ = 1;                     // activate KEY1
        if (cmd[0] == 0x00) { romCmdKind_ = 0xF0; romAddr_ = 0; }   // header read (internal kind)
    } else if (cartMode_ == 1) {
        u8 hi = cmd[0] >> 4;
        if (hi == 0xA) cartMode_ = 2;                          // enter main data mode
        if (hi == 0x1) romCmdKind_ = 0x90;                     // chip ID
        if (hi == 0x2) {                                       // secure area block (4 KB)
            romCmdKind_ = 0xF1;
            romAddr_ = ((u32(cmd[1] & 0xF0) << 8) | (u32(cmd[2]) << 4)) & 0x7000u;
            if (romAddr_ < 0x4000) romAddr_ = 0x4000;
        }
    }
    if (romCmdKind_ == 0xB7 && cartMode_ == 2) {
        romAddr_ = (u32(cmd[1]) << 24) | (u32(cmd[2]) << 16) | (u32(cmd[3]) << 8) | cmd[4];
        if (romAddr_ < 0x8000) romAddr_ = 0x8000 + (romAddr_ & 0x1FF);
    }
    if (romRemaining_ == 0) {
        romCtrl_ &= ~0x80800000u;
        if (auxSpiCnt_ & 0x4000) requestIRQ(true, 19);
        return;
    }
    romCtrl_ |= 0x00800000u;                                                  // data ready
    // Card DMA is requested once per data word: games commonly program count = 1 with
    // repeat, so keep triggering until the transfer ends or no channel is waiting.
    for (int guard = 0; romRemaining_ > 0 && guard < 0x10000; ++guard) {
        u32 before = romRemaining_;
        bool ran = triggerDMAs(true, 5);
        ran = triggerDMAs(false, 2) || ran;
        if (!ran || romRemaining_ == before) break;
    }
}

u32 NDSSystem::romReadData() {
    if (romRemaining_ == 0) return 0;
    u32 v = 0xFFFFFFFFu;
    auto romWord = [&](u32 a) {
        u32 w = 0;
        for (int i = 0; i < 4; ++i) w |= u32(a + u32(i) < rom_.size() ? rom_[a + u32(i)] : 0xFF) << (8 * i);
        return w;
    };
    if (romCmdKind_ == 0xB7) {
        v = romWord(romAddr_);
        romAddr_ = (romAddr_ & ~0xFFFu) | ((romAddr_ + 4) & 0xFFFu);         // wraps inside 4 KB page
    } else if (romCmdKind_ == 0xF0) {
        v = romWord(romAddr_ & 0xFFF); romAddr_ += 4;                         // header, repeated every 4 KB
    } else if (romCmdKind_ == 0xF1) {
        v = romWord(romAddr_); romAddr_ += 4;
    } else if (romCmdKind_ == 0xB8 || romCmdKind_ == 0x90) {
        v = chipId();
    }
    romRemaining_ -= 4;
    if (romRemaining_ == 0) {
        romCtrl_ &= ~0x80800000u;
        if (auxSpiCnt_ & 0x4000) { requestIRQ(true, 19); }
    }
    return v;
}

// ---------------------------------------------------------- HLE BIOS
void NDSSystem::handleIRQEntry(ARMCPU& c) {
    bool is9 = &c == &arm9_;
    u32 sp = c.reg(13) - 24;
    const int saved[6] = {0, 1, 2, 3, 12, 14};
    for (int i = 0; i < 6; ++i) write(is9, sp + u32(i) * 4, c.reg(saved[i]), 4);
    c.setReg(13, sp);
    c.setReg(0, 0x04000000u);
    c.setReg(14, is9 ? kIrqReturnMagic9 : kIrqReturnMagic7);
    u32 handler = read(is9, is9 ? dtcmBase_ + 0x3FFC : 0x0380FFFCu, 4);
    c.branchTo(handler, handler & 1);
}

bool NDSSystem::handleIRQReturn(ARMCPU& c) {
    bool is9 = &c == &arm9_;
    if (c.thumb() || c.pc() != (is9 ? kIrqReturnMagic9 : kIrqReturnMagic7)) return false;
    u32 sp = c.reg(13);
    const int saved[6] = {0, 1, 2, 3, 12, 14};
    for (int i = 0; i < 6; ++i) c.setReg(saved[i], read(is9, sp + u32(i) * 4, 4));
    c.setReg(13, sp + 24);
    u32 ret = c.reg(14) - 4;
    u32 s = c.spsr();
    c.setCPSR(s);
    c.branchTo(ret, s & ARMCPU::FlagT);
    return true;
}

void NDSSystem::handleSWI(ARMCPU& c, u32 n) {
    bool is9 = &c == &arm9_;
    CpuState& me = is9 ? s9_ : s7_;
    auto R = [&](int i) { return c.reg(i); };
    if (debug_) debug_->swi(is9, n, c.pc());
    auto reexecuteAndHalt = [&] { c.branchTo(c.pc() - (c.thumb() ? 4 : 8), c.thumb()); c.halted = true; };
    switch (n) {
    case 0x03: {                                                              // WaitByLoop
        // The BIOS loop takes ~4 cycles per count; the other CPU keeps running meanwhile
        // (games use this delay in IPC handshakes, e.g. Pokemon Platinum's PXI start-up).
        int n = int(std::min<u32>(R(0), 0x01000000u)) * 2;
        (is9 ? burn9_ : burn7_) = n;
        return;
    }
    case 0x04: case 0x05: {                                                   // IntrWait / VBlankIntrWait
        // The SWI is re-executed after every wake-up until a requested flag appears.
        bool& waiting = is9 ? intrWaiting9_ : intrWaiting7_;
        u32& waitMask = is9 ? intrWaitMask9_ : intrWaitMask7_;
        me.ime = 1;
        u32 addr = irqCheckAddress(is9);
        u32 flags = read(is9, addr, 4);
        if (!waiting) {
            waitMask = (n == 0x05) ? 1u : R(1);
            bool discard = (n == 0x05) || R(0) != 0;
            if (discard) { flags &= ~waitMask; write(is9, addr, flags, 4); }
            else if (flags & waitMask) { write(is9, addr, flags & ~waitMask, 4); return; }
            waiting = true;
            reexecuteAndHalt();
            return;
        }
        if (flags & waitMask) { write(is9, addr, flags & ~waitMask, 4); waiting = false; return; }
        reexecuteAndHalt();
        return;
    }
    case 0x06: case 0x07: c.halted = true; return;                            // Halt / Sleep
    case 0x09: {                                                              // Div
        s32 a = s32(R(0)), b = s32(R(1));
        if (b == 0) { lastNotice_ = "SWI Div by zero"; return; }
        s32 q = (a == INT32_MIN && b == -1) ? a : a / b, r = (a == INT32_MIN && b == -1) ? 0 : a % b;
        c.setReg(0, u32(q)); c.setReg(1, u32(r)); c.setReg(3, u32(q < 0 ? -s64(q) : q));
        return;
    }
    case 0x0B: {                                                              // CpuSet
        u32 src = R(0), dst = R(1), ctl = R(2), cnt = ctl & 0x1FFFFF;
        bool fill = ctl & (1u << 24), word = ctl & (1u << 26);
        int unit = word ? 4 : 2;
        u32 fillv = read(is9, src & ~u32(unit - 1), unit);
        for (u32 i = 0; i < cnt; ++i) {
            u32 v = fill ? fillv : read(is9, (src + i * unit) & ~u32(unit - 1), unit);
            write(is9, (dst + i * unit) & ~u32(unit - 1), v, unit);
        }
        return;
    }
    case 0x0C: {                                                              // CpuFastSet
        u32 src = R(0) & ~3u, dst = R(1) & ~3u, ctl = R(2), cnt;
        cnt = ((ctl & 0x1FFFFF) + 7) & ~7u;
        bool fill = ctl & (1u << 24);
        u32 fillv = read(is9, src, 4);
        for (u32 i = 0; i < cnt; ++i) write(is9, dst + i * 4, fill ? fillv : read(is9, src + i * 4, 4), 4);
        return;
    }
    case 0x0D: {                                                              // Sqrt
        u32 v = R(0), res = 0, b = 1u << 30;
        while (b > v) b >>= 2;
        while (b) { if (v >= res + b) { v -= res + b; res = (res >> 1) + b; } else res >>= 1; b >>= 2; }
        c.setReg(0, res);
        return;
    }
    case 0x0E: {                                                              // GetCRC16
        u32 crc = R(0) & 0xFFFF, addr = R(1), len = R(2);
        std::vector<u8> buf(len);
        for (u32 i = 0; i < len; ++i) buf[i] = u8(read(is9, addr + i, 1));
        c.setReg(0, crc16(buf.data(), buf.size(), u16(crc)));
        return;
    }
    case 0x0F: c.setReg(0, 0); return;                                        // IsDebugger
    case 0x10: case 0x11: case 0x12: case 0x13: case 0x14: case 0x15: case 0x16: case 0x18:
        if (decompressSWI(c, is9, n)) return;
        break;
    case 0x1A:                                                                // GetSineTable (ARM7)
        if (!is9) { c.setReg(0, u32(s32(std::lround(std::sin((R(0) & 63) * 3.14159265358979 / 128.0) * 32768.0)) & 0xFFFF)); return; }
        break;
    case 0x1B:                                                                // GetPitchTable (ARM7)
        if (!is9) { c.setReg(0, u32(std::lround((std::pow(2.0, (R(0) % 768) / 768.0) - 1.0) * 65536.0)) & 0xFFFF); return; }
        break;
    case 0x1C:                                                                // GetVolumeTable (ARM7)
        if (!is9) {
            // Computed, not copied: 0.1 dB steps from -72.3 dB (index 0) to 0 dB (index 723),
            // scaled per attenuation range so each entry is a 7-bit volume.
            int i = int(R(0) % 724);
            double amp = std::pow(10.0, (i - 723) / 200.0);
            double m = i >= 663 ? 1 : i >= 603 ? 2 : i >= 483 ? 4 : 16;
            c.setReg(0, u32(std::min(127L, std::lround(127.0 * amp * m))));
            return;
        }
        break;
    default: break;
    }
    {
        char b[64]; std::snprintf(b, sizeof b, "%s SWI 0x%02X not implemented (HLE)", is9 ? "ARM9" : "ARM7", n);
        lastNotice_ = b;
    }
}

u32 NDSSystem::callbackRead(ARMCPU& c, bool, u32 cb, int which, u32 src) {
    u32 fn = read(c.arch() == ARMCPU::Arch::ARMv5TE, cb + u32(which) * 4, 4);
    return fn ? c.callGuest(fn, src) : 0;
}

// BIOS decompression and unfilter functions (formats from GBATEK).
bool NDSSystem::decompressSWI(ARMCPU& c, bool is9, u32 n) {
    u32 src = c.reg(0), dst = c.reg(1), user = c.reg(2), cb = c.reg(3);
    bool viaCallback = (n == 0x12 || n == 0x13 || n == 0x15) && cb >= 0x01000000u && cb < 0x10000000u;
    bool write16 = (n == 0x12 || n == 0x13 || n == 0x15 || n == 0x18);
    u32 header;
    if (viaCallback) {
        u32 open = read(is9, cb, 4);
        header = open ? c.callGuest(open, src, dst, user) : read(is9, src, 4);
        src += 4;
    } else if (n == 0x10) {
        header = 0;
    } else { header = read(is9, src, 4); src += 4; }
    auto get8 = [&]() -> u8 {
        u8 v = viaCallback ? u8(callbackRead(c, is9, cb, 2, src)) : u8(read(is9, src, 1));
        ++src; return v;
    };
    std::vector<u8> out;
    switch (n) {
    case 0x10: {                                                              // BitUnPack
        u32 info = c.reg(2);
        u32 len = read(is9, info, 2), srcW = read(is9, info + 2, 1), dstW = read(is9, info + 3, 1), ofs = read(is9, info + 4, 4);
        bool zeroToo = ofs & 0x80000000u; ofs &= 0x7FFFFFFFu;
        if (!(srcW == 1 || srcW == 2 || srcW == 4 || srcW == 8) || !(dstW == 1 || dstW == 2 || dstW == 4 || dstW == 8 || dstW == 16 || dstW == 32)) return false;
        u32 acc = 0; int accBits = 0;
        for (u32 i = 0; i < len; ++i) {
            u8 b = u8(read(is9, src + i, 1));
            for (u32 bit = 0; bit < 8; bit += srcW) {
                u32 v = (b >> bit) & ((1u << srcW) - 1);
                if (v || zeroToo) v += ofs;
                acc |= (v & (dstW == 32 ? 0xFFFFFFFFu : ((1u << dstW) - 1))) << accBits;
                accBits += int(dstW);
                if (accBits >= 32) { write(is9, dst & ~3u, acc, 4); dst += 4; acc = 0; accBits = 0; }
            }
        }
        return true;
    }
    case 0x11: case 0x12: {                                                   // LZ77
        u32 size = header >> 8;
        out.reserve(size);
        while (out.size() < size) {
            u8 flags = get8();
            for (int k = 0; k < 8 && out.size() < size; ++k, flags <<= 1) {
                if (flags & 0x80) {
                    u8 b0 = get8(), b1 = get8();
                    u32 len = (b0 >> 4) + 3u, disp = ((u32(b0 & 15) << 8) | b1) + 1u;
                    for (u32 j = 0; j < len && out.size() < size; ++j) out.push_back(disp <= out.size() ? out[out.size() - disp] : 0);
                } else out.push_back(get8());
            }
        }
        break;
    }
    case 0x13: {                                                              // Huffman
        u32 size = header >> 8, bits = header & 15;
        if (bits != 4 && bits != 8) return false;
        u32 treeSize = (u32(get8()) + 1) * 2;
        u32 treeStart = src - 1;                                              // tree base (size byte)
        std::vector<u8> tree(treeSize);
        tree[0] = u8(((treeSize / 2) - 1));
        for (u32 i = 1; i < treeSize; ++i) tree[i] = get8();
        (void)treeStart;
        u32 outAcc = 0; int outBits = 0;
        u32 nodeOff = 1;                                                      // root node at tree[1]
        while (out.size() < size) {
            u32 word = 0; for (int k = 0; k < 4; ++k) word |= u32(get8()) << (8 * k);
            for (int bit = 31; bit >= 0 && out.size() < size; --bit) {
                u8 node = tree[nodeOff];
                u32 childBase = (nodeOff & ~1u) + (node & 0x3F) * 2 + 2;
                bool right = (word >> bit) & 1;
                u32 child = childBase + (right ? 1 : 0);
                bool leaf = right ? (node & 0x40) : (node & 0x80);
                if (child >= treeSize) return false;
                if (leaf) {
                    outAcc |= u32(tree[child] & ((1u << bits) - 1)) << outBits; outBits += int(bits);
                    if (outBits >= 8) { out.push_back(u8(outAcc)); outAcc >>= 8; outBits -= 8; }
                    nodeOff = 1;
                } else nodeOff = child;
            }
        }
        break;
    }
    case 0x14: case 0x15: {                                                   // RLE
        u32 size = header >> 8;
        while (out.size() < size) {
            u8 f = get8();
            if (f & 0x80) { u8 v = get8(); for (u32 j = 0; j < (f & 0x7Fu) + 3 && out.size() < size; ++j) out.push_back(v); }
            else for (u32 j = 0; j < (f & 0x7Fu) + 1 && out.size() < size; ++j) out.push_back(get8());
        }
        break;
    }
    case 0x16: {                                                              // Diff8bitUnFilter
        u32 size = header >> 8; u8 acc = 0;
        for (u32 i = 0; i < size; ++i) { acc = u8(acc + get8()); out.push_back(acc); }
        break;
    }
    default: {                                                                // 0x18 Diff16bitUnFilter
        u32 size = header >> 8; u16 acc = 0;
        for (u32 i = 0; i + 1 < size + 1 && out.size() < size; i += 2) {
            u16 d = u16(get8()); d = u16(d | (get8() << 8)); acc = u16(acc + d);
            out.push_back(u8(acc)); out.push_back(u8(acc >> 8));
        }
        break;
    }
    }
    if (write16) {
        for (size_t i = 0; i < out.size(); i += 2) {
            u16 v = u16(out[i] | ((i + 1 < out.size() ? out[i + 1] : 0) << 8));
            write(is9, (dst + u32(i)) & ~1u, v, 2);
        }
    } else for (size_t i = 0; i < out.size(); ++i) write(is9, dst + u32(i), out[i], 1);
    return true;
}

// ---------------------------------------------------------------- frame loop
void NDSSystem::checkIRQ(ARMCPU& cpu, CpuState& s) {
    // IPC FIFO "receive not empty" is a level condition: it stays requested while words are
    // waiting. Edge-only signalling deadlocked the PXI start-up of some games (Pokemon B2/W2)
    // when the real BIOS's IntrWait acknowledged the IRQ before the handler drained the FIFO.
    if ((s.fifoCnt & 0x0400) && !s.fifoRecv.empty() && (s.fifoCnt & 0x8000)) s.iflags |= 1u << 18;
    if (s.ie & s.iflags) {
        bool wasHalted = cpu.halted;
        cpu.halted = false;
        if (s.ime & 1) {
            int k = &cpu == &arm9_ ? 0 : 1;
            if (cpu.raiseIRQ()) ++irqTaken_[k];
            else if (wasHalted) ++maskedWakes_[k];   // woke from halt, IRQ pending but CPSR.I set
        }
    }
}

// IRQ livelock watchdog: a CPU that keeps waking from halt with an interrupt pending but masked,
// and never takes one, for a whole second is stuck in a wait loop whose IRQ-enable window the
// interpreter misses. Recover by checking IRQs after every instruction (exact, only slower) for
// two seconds. The MSR fix above handles the known case; this is the safety net.
void NDSSystem::irqWatchdogFrame() {
    for (int k = 0; k < 2; ++k) {
        if (maskedWakes_[k] >= 30 && irqTaken_[k] == 0) ++livelockFrames_[k]; else livelockFrames_[k] = 0;
        if (livelockFrames_[k] >= 60) {
            livelockFrames_[k] = 0;
            preciseIrqFrames_ = 120;
            ++irqLivelocks_;
            std::fprintf(stderr, "dscore: IRQ livelock on %s (pc %08X), precise IRQ checks on\n",
                         k ? "ARM7" : "ARM9", (k ? arm7_ : arm9_).pc());
        }
        maskedWakes_[k] = irqTaken_[k] = 0;
    }
    if (preciseIrqFrames_) --preciseIrqFrames_;
}

// Same steps as the debug loop above without the breakpoint checks. Once the CPU sleeps
// (halt / idle loop / fault) the remaining steps of the chunk are no-ops, so stop early; the
// IRQ-return address is still handled first because handleIRQReturn runs even while asleep.
// An MSR that re-enables IRQs takes a pending interrupt right away (as the hardware does), not at
// the next chunk boundary: Pokemon B2/W2 (Pokemon Center) waits with "halt; enable IRQs; disable
// IRQs; check flag" and the few-instruction window never lined up with a chunk boundary, so the
// VBlank IRQ was never taken and the game froze with the music still playing.
inline void NDSSystem::afterUnmask(ARMCPU& cpu, CpuState& s) {
    cpu.irqUnmasked = false;
    checkIRQ(cpu, s);
}

inline void NDSSystem::runCpuChunk(ARMCPU& cpu, CpuState& s, u32 irqReturnMagic, int n, const int& burn) {
    for (int i = 0; i < n && burn <= 0; ++i) {
        if (cpu.pc() == irqReturnMagic) { if (handleIRQReturn(cpu)) continue; }
        else if (cpu.sleeping()) return;
        cpu.step();
        if (cpu.irqUnmasked || (preciseIrqFrames_ && !(cpu.cpsr() & ARMCPU::FlagI))) afterUnmask(cpu, s);
    }
}

void NDSSystem::runCpus(int budget9) {
    constexpr int kChunk = 32;
    for (int done = 0; done < budget9; done += kChunk) {
        checkIRQ(arm9_, s9_);
        checkIRQ(arm7_, s7_);
        if (debug_) debug_->sample(arm9_.sleeping() ? 0xFFFFFFFFu : arm9_.pc(), arm7_.sleeping() ? 0xFFFFFFFFu : arm7_.pc());
        if (arm9_.sleeping() && arm7_.sleeping()) break;            // nothing can change until the next event
        u64 w9 = arm9_.writes(), w7 = arm7_.writes();
        // The IRQ-return check is a single compare on the hot path; the full handler runs only on a match.
        if (burn9_ > 0) burn9_ -= kChunk;
        else if (!arm9_.sleeping()) {
            if (dbgBreak9_) for (int i = 0; i < kChunk && burn9_ <= 0; ++i) { if (arm9_.pc() == dbgBreak9_ && dbgHits9_ < 4) { ++dbgHits9_; std::fprintf(stderr, "BREAK9 pc %08X lr %08X sp %08X r0 %08X r1 %08X r2 %08X\n stack:", arm9_.pc(), arm9_.reg(14), arm9_.reg(13), arm9_.reg(0), arm9_.reg(1), arm9_.reg(2)); for (int k = 0; k < 48; ++k) std::fprintf(stderr, " %08X", read(true, arm9_.reg(13) + 4 * k, 4)); std::fprintf(stderr, "\n"); }
                if (arm9_.pc() != kIrqReturnMagic9 || !handleIRQReturn(arm9_)) { arm9_.step(); if (arm9_.irqUnmasked) afterUnmask(arm9_, s9_); } }
            else runCpuChunk(arm9_, s9_, kIrqReturnMagic9, kChunk, burn9_);
        }
        if (burn7_ > 0) burn7_ -= kChunk / 2;
        else if (!arm7_.sleeping()) {
            if (dbgBreak7_) for (int i = 0; i < kChunk / 2 && burn7_ <= 0; ++i) { if (arm7_.pc() == dbgBreak7_ && dbgHits_ < 8) { ++dbgHits_; std::fprintf(stderr, "BREAK7 pc %08X lr %08X sp %08X r0 %08X r1 %08X\n", arm7_.pc(), arm7_.reg(14), arm7_.reg(13), arm7_.reg(0), arm7_.reg(1)); }
                if (arm7_.pc() != kIrqReturnMagic7 || !handleIRQReturn(arm7_)) { arm7_.step(); if (arm7_.irqUnmasked) afterUnmask(arm7_, s7_); } }
            else runCpuChunk(arm7_, s7_, kIrqReturnMagic7, kChunk / 2, burn7_);
        }
        if (arm9_.writes() != w9) arm7_.wake();                      // the other CPU may be polling shared memory
        if (arm7_.writes() != w7) arm9_.wake();
    }
}

void NDSSystem::startLine(int line) {
    vcount_ = u32(line);
    arm9_.wake(); arm7_.wake();
    for (int k = 0; k < 2; ++k) {
        bool is9 = k == 0;
        u16& ds = is9 ? dispstat9_ : dispstat7_;
        if (line == 192) { ds |= 1; if (ds & 0x08) requestIRQ(is9, 0); }
        if (line == 262) ds &= ~1;
        u32 match = (ds >> 8) | ((ds & 0x80) << 1);
        if (u32(line) == match) { ds |= 4; if (ds & 0x20) requestIRQ(is9, 2); } else ds &= ~4;
    }
    if (line == 0) {
        gpuA_.startFrame(); gpuB_.startFrame();
        // Display capture is armed by DISPCAPCNT bit 31 and runs for one frame from line 0.
        u32 cap = u32(s9_.io[0x64]) | (u32(s9_.io[0x65]) << 8) | (u32(s9_.io[0x66]) << 16) | (u32(s9_.io[0x67]) << 24);
        captureThisFrame_ = (cap & 0x80000000u) != 0;
        captureLatch_ = cap;
        if (captureThisFrame_) captureRecent_ = 120;      // keep frame skip off while a game uses capture
        else if (captureRecent_) --captureRecent_;
        gpuA_.setCaptureActive(captureThisFrame_);
    }
    if (line == 192) { gpu3d_.vblank(); triggerDMAs(true, 1); triggerDMAs(false, 1); }
    if (gpu3d_.irqPending()) requestIRQ(true, 21);                           // GXFIFO (always drained)
    if (!gpu3d_.swapPending()) triggerDMAs(true, 7);                         // geometry FIFO DMA
}

void NDSSystem::runFrame() {
    if (pendingScale_) applyRenderScale(pendingScale_);
    if (!romLoaded_) {
        std::fill(top_.begin(), top_.end(), 0xFF101010u);
        std::fill(bottom_.begin(), bottom_.end(), 0xFF101010u);
    } else {
        for (int line = 0; line < kLines; ++line) {
            startLine(line);
            runCpus(kCyclesPerLine9 * 256 / 355);                              // visible dots
            if (line < 192) renderLine(line);
            if (line == GPU3D::kRenderLine) gpu3d_.renderPending(!drawFrame(frameCount_ + 1));   // feeds the next frame
            for (int k = 0; k < 2; ++k) {                                     // HBlank
                u16& ds = k == 0 ? dispstat9_ : dispstat7_;
                ds |= 2; if (ds & 0x10) requestIRQ(k == 0, 1);
            }
            arm9_.wake(); arm7_.wake();
            if (line < 192) triggerDMAs(true, 2);
            runCpus(kCyclesPerLine9 - kCyclesPerLine9 * 256 / 355);           // HBlank dots
            dispstat9_ &= ~2; dispstat7_ &= ~2;
            // Timers count at the 33.513982 MHz bus clock: one scanline = 2130 bus cycles
            // (33513982 / 59.8261 Hz / 263 lines). Doubling this ran the ARM7 sound sequencer 2x fast.
            stepTimers(s9_, true, kCyclesPerLine9);
            stepTimers(s7_, false, kCyclesPerLine9);
            mixAudioLine();
        }
    }
    lastDrawn_ = !romLoaded_ || drawFrame(frameCount_);
    ++frameCount_;
    {   u64 w = arm9_.writes() + arm7_.writes();
        stuckFrames_ = (romLoaded_ && w == lastWrites_) ? stuckFrames_ + 1 : 0;
        lastWrites_ = w; }
    if (romLoaded_) irqWatchdogFrame();
    if (!romLoaded_) mixAudioChunk(int(kAudioSampleRate / 59.8261) - frameAudio_);   // no ROM: keep the stream flowing
    // A locked-up game leaves looping sound channels running, which comes out as a buzz.
    // After ~0.25 s without any CPU activity output silence instead.
    if (stuckFrames_ >= 15) std::memset(frameBuf_, 0, sizeof(s16) * 2 * size_t(frameAudio_));
    audio_.push(frameBuf_, size_t(frameAudio_));
    frameAudio_ = 0;
}

// The SPU advances once per scanline (about 3 output samples), not once per frame, so
// channel position tracks the ARM7 to within ~64 us. Games that stream into small ring
// buffers (Mobiclip movies, NitroSDK streams: 2 x 29 ms halves) refill the half that just
// finished; with per-frame mixing the SPU lagged up to a whole frame and played freshly
// overwritten data, which sounded like crackle and stutter.
void NDSSystem::mixAudioLine() {
    audioFrac_ += kAudioSampleRate / 59.8261 / 263.0;
    int n = int(audioFrac_);
    audioFrac_ -= n;
    mixAudioChunk(n);
}

void NDSSystem::mixAudioChunk(int n) {
    n = std::min(n, kFrameAudioMax - frameAudio_);
    if (n <= 0) return;
    spu_.mix(frameBuf_ + frameAudio_ * 2, n);
    frameAudio_ += n;
}

void NDSSystem::renderLine(int line) {
    if (!drawFrame(frameCount_)) {
        // Capture must still run on skipped frames or captured buffers go stale (flicker).
        if (captureThisFrame_) { u32 tmp[256]; gpuA_.renderLine(line, tmp); finishCaptureLine(line); }
        else gpuA_.skipLine(line);
        gpuB_.skipLine(line);
        return;
    }
    bool aTop = powcnt1_ & 0x8000;                                            // POWCNT1 display swap
    u32* topLine = &top_[size_t(line) * kScreenWidth];
    u32* bottomLine = &bottom_[size_t(line) * kScreenWidth];
    gpuA_.renderLine(line, aTop ? topLine : bottomLine);
    finishCaptureLine(line);
    gpuB_.renderLine(line, aTop ? bottomLine : topLine);
    if (renderScale_ > 1) {
        upscaleLine(line, true, aTop ? topLine : bottomLine, aTop ? hiTop_ : hiBottom_);
        upscaleLine(line, false, aTop ? bottomLine : topLine, aTop ? hiBottom_ : hiTop_);
    }
}

std::string NDSSystem::freezeReport() {
    char b[640];
    auto io = [&](bool a9, u32 a, int n) { return read(a9, a, n); };
    std::snprintf(b, sizeof b,
        "frame=%llu stuck=%d pc9=%08X lr9=%08X cpsr9=%08X %s pc7=%08X lr7=%08X cpsr7=%08X %s | "
        "IME9=%X IE9=%08X IF9=%08X IME7=%X IE7=%08X IF7=%08X DISPSTAT=%04X/%04X VCOUNT=%u IPCSYNC=%04X/%04X FIFOCNT=%04X/%04X "
        "DISPCAPCNT=%08X POWCNT1=%04X AUXSPICNT=%04X ROMCTRL=%08X SPICNT7=%04X DMA9CNT=%08X/%08X/%08X/%08X GXSTAT=%08X",
        (unsigned long long)frameCount_, stuckFrames_,
        arm9_.pc(), arm9_.reg(14), arm9_.cpsr(), arm9_.halted ? "halted" : arm9_.idle ? "idle" : "run",
        arm7_.pc(), arm7_.reg(14), arm7_.cpsr(), arm7_.halted ? "halted" : arm7_.idle ? "idle" : "run",
        io(true, 0x04000208, 4), io(true, 0x04000210, 4), io(true, 0x04000214, 4),
        io(false, 0x04000208, 4), io(false, 0x04000210, 4), io(false, 0x04000214, 4),
        io(true, 0x04000004, 2), io(false, 0x04000004, 2), vcount_,
        io(true, 0x04000180, 2), io(false, 0x04000180, 2), io(true, 0x04000184, 2), io(false, 0x04000184, 2),
        io(true, 0x04000064, 4), io(true, 0x04000304, 2), io(true, 0x040001A0, 2), io(true, 0x040001A4, 4), io(false, 0x040001C0, 2),
        io(true, 0x040000B8, 4), io(true, 0x040000C4, 4), io(true, 0x040000D0, 4), io(true, 0x040000DC, 4), io(true, 0x04000600, 4));
    return b;
}

void NDSSystem::finishCaptureLine(int line) {
    if (!captureThisFrame_) return;
    if (line < GPU2D::captureHeight(captureLatch_)) gpuA_.captureLine(line, captureLatch_);
    if (line == GPU2D::captureHeight(captureLatch_) - 1 || line == 191) {
        s9_.io[0x67] &= 0x7F;                                                 // capture done: clear enable
        captureThisFrame_ = false;
        gpuA_.setCaptureActive(false);
    }
}

// Resolution changes never happen mid-frame: the request is latched and applied at the start
// of the next frame, before any scanline or 3D render touches the high-resolution buffers.
void NDSSystem::setRenderScale(int n) {
    n = std::clamp(n, 1, 4);
    if (!romLoaded_) { applyRenderScale(n); return; }
    pendingScale_ = n;
}

void NDSSystem::applyRenderScale(int n) {
    pendingScale_ = 0;
    if (n == renderScale_) return;
    renderScale_ = n;
    gpu3d_.setScale(n);
    size_t px = kScreenPixels * size_t(n) * size_t(n);
    hiTop_.assign(n > 1 ? px : 0, 0xFF000000u); hiBottom_.assign(n > 1 ? px : 0, 0xFF000000u);
}

// High-resolution line: 2D pixels are replicated; pixels that show the plain opaque 3D layer
// take the 3D engine's high-resolution samples instead.
void NDSSystem::upscaleLine(int line, bool engineA, const u32* src, std::vector<u32>& dst) {
    const int s = renderScale_, W = kScreenWidth * s;
    const u8* mask = engineA ? gpuA_.pure3DMask() : nullptr;
    const u32* hi3d = gpu3d_.outputHiRes();
    int scroll = engineA ? gpuA_.bg0Scroll() * s : 0;
    for (int j = 0; j < s; ++j) {
        u32* out = &dst[size_t(line * s + j) * size_t(W)];
        const u32* row3d = hi3d + size_t(line * s + j) * size_t(W);
        for (int x = 0; x < kScreenWidth; ++x) {
            u32 c = src[x];
            if (mask && mask[x]) {
                for (int k = 0; k < s; ++k) {
                    int hx = x * s + k + scroll;
                    u32 p = (hx >= 0 && hx < W) ? row3d[hx] : 0;
                    out[x * s + k] = ((p >> 16) & 31) == 31 ? GPU2D::toARGB(u16(p & 0x7FFF)) : c;
                }
            } else {
                for (int k = 0; k < s; ++k) out[x * s + k] = c;
            }
        }
    }
}

// ------------------------------------------------------------- save states
namespace { constexpr u32 kStateMagic = 0x54534453u, kStateVersion = 3; }   // "SDST"

void NDSSystem::serialize(StateIO& s) {
    for (auto* v : {&mainRAM_, &sharedWRAM_, &arm7WRAM_, &itcm_, &dtcm_, &palette_, &oam_}) s.vec(*v);
    arm9_.serialize(s); arm7_.serialize(s);
    for (CpuState* st : {&s9_, &s7_}) {
        s.tag(0x494F0001);
        s.bytes(st->io.data(), st->io.size());
        s.bytes(st->timers, sizeof st->timers); s.bytes(st->dma, sizeof st->dma);
        s.pod(st->ime); s.pod(st->ie); s.pod(st->iflags); s.pod(st->ipcSync); s.pod(st->fifoCnt);
        s.deque(st->fifoRecv); s.pod(st->lastFifoWord);
    }
    vram_.serialize(s); gpuA_.serialize(s); gpuB_.serialize(s); gpu3d_.serialize(s);
    spi_.serialize(s); save_.serialize(s); spu_.serialize(s); rtc_.serialize(s);
    s.tag(0x53595301);
    s.pod(saveOut_); s.pod(audioFrac_); s.pod(itcmSize_); s.pod(itcmOn_); s.pod(dtcmOn_); s.pod(dtcmBase_);
    s.pod(wramCnt_); s.pod(powcnt1_); s.pod(dispstat9_); s.pod(dispstat7_); s.pod(vcount_); s.map(cp15_);
    s.pod(romCtrl_); s.pod(auxSpiCnt_); s.bytes(romCmd_, sizeof romCmd_); s.pod(romAddr_); s.pod(romRemaining_); s.pod(romCmdKind_);
    s.pod(cartMode_);
    s.pod(divCnt_); s.pod(sqrtCnt_); s.pod(divNumer_); s.pod(divDenom_); s.pod(divResult_); s.pod(divRem_);
    s.pod(sqrtParam_); s.pod(sqrtResult_);
    s.pod(intrWaiting9_); s.pod(intrWaiting7_); s.pod(intrWaitMask9_); s.pod(intrWaitMask7_); s.pod(frameCount_);
    s.vec(top_); s.vec(bottom_);
    s.tag(0x454E4421);
}

std::vector<u8> NDSSystem::saveState() {
    if (!romLoaded_) return {};
    StateIO s;
    u32 magic = kStateMagic, version = kStateVersion; s.pod(magic); s.pod(version);
    std::string code = info_.gameCode; u16 crc = info_.headerCrc; s.str(code); s.pod(crc);
    serialize(s);
    return std::move(s.output());
}

bool NDSSystem::loadState(const std::vector<u8>& data) {
    if (!romLoaded_) return false;
    {   // validate the header before touching any state
        StateIO h(data);
        u32 magic = 0, version = 0; std::string code; u16 crc = 0;
        h.pod(magic); h.pod(version); h.str(code); h.pod(crc);
        if (!h.ok() || magic != kStateMagic || version != kStateVersion || code != info_.gameCode || crc != info_.headerCrc) return false;
    }
    std::vector<u8> backup = saveState();            // restore this if the stream turns out to be corrupt
    StateIO s(data);
    u32 magic, version; std::string code; u16 crc; s.pod(magic); s.pod(version); s.str(code); s.pod(crc);
    serialize(s);
    if (!s.ok()) { StateIO b(backup); u32 m, v; std::string c; u16 k; b.pod(m); b.pod(v); b.str(c); b.pod(k); serialize(b); return false; }
    rebuildPageTables();
    audio_.clear();
    lastNotice_.clear();
    return true;
}

std::unique_ptr<EmulatorCore> createTestPatternCore();
std::unique_ptr<EmulatorCore> createGBACore();
std::unique_ptr<EmulatorCore> createGBCore();
std::unique_ptr<EmulatorCore> createNESCore();
std::unique_ptr<EmulatorCore> createSNESCore();
std::unique_ptr<EmulatorCore> createN64Core();
std::unique_ptr<EmulatorCore> createN3DSCore();
std::unique_ptr<EmulatorCore> createCore(CoreKind kind) {
    if (kind == CoreKind::TestPattern) return createTestPatternCore();
    if (kind == CoreKind::GBA) return createGBACore();
    if (kind == CoreKind::GB) return createGBCore();
    if (kind == CoreKind::NES) return createNESCore();
    if (kind == CoreKind::SNES) return createSNESCore();
    if (kind == CoreKind::N64) return createN64Core();
    if (kind == CoreKind::N3DS) return createN3DSCore();
    return std::make_unique<NDSSystem>();
}

} // namespace dscore
