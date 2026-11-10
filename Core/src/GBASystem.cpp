// Copyright (c) 2026 Charlie Rodriguez Garcia. All rights reserved.
// Original clean-room Game Boy Advance system: memory map, I/O, DMA, timers,
// interrupts, keypad, cartridge save chips and an HLE BIOS. Written from public
// documentation (GBATEK). No Nintendo BIOS or third-party code.
#include "GBASystem.hpp"
#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <cstdlib>

namespace dscore {

namespace {
constexpr int kCyclesPerLine = 1232, kHDrawCycles = 960, kLines = 228;
constexpr u32 kIrqStub[] = {
    // Original IRQ dispatcher at the IRQ vector (0x18): saves the scratch registers,
    // calls the game's handler stored at 0x03007FFC and returns from the exception.
    0xE92D500F,  // stmfd sp!, {r0-r3, r12, lr}
    0xE3A00301,  // mov   r0, #0x04000000
    0xE28FE000,  // add   lr, pc, #0
    0xE510F004,  // ldr   pc, [r0, #-4]
    0xE8BD500F,  // ldmfd sp!, {r0-r3, r12, lr}
    0xE25EF004,  // subs  pc, lr, #4
};
constexpr u32 kPageCount = ARMCPU::kFastLimit >> ARMCPU::kPageShift;
}

bool isGBAImage(const u8* d, size_t n) {
    if (!d || n < 0xC0) return false;
    return d[3] == 0xEA && d[0xB2] == 0x96;
}

std::unique_ptr<EmulatorCore> createGBACore() { return std::make_unique<GBASystem>(); }

GBASystem::GBASystem() : cpu_(ARMCPU::Arch::ARMv4T, *this) {
    ewram_.assign(0x40000, 0); iwram_.assign(0x8000, 0); vram_.assign(0x18000, 0);
    pal_.assign(0x400, 0); oam_.assign(0x400, 0);
    frame_.assign(kScreenPixels, 0xFF000000u); blank_.assign(kScreenPixels, 0xFF000000u);
    cpu_.rawStoreAddresses = true;
    cpu_.onSWI = [this](ARMCPU& c, u32 n) { handleSWI(c, n); };
    buildBios();
}

// The user's own gba_bios.bin (16 KB): SWIs, IRQs and the boot intro run the real code.
bool GBASystem::setLLEBIOS(const std::vector<u8>& bios, const std::vector<u8>&, const std::vector<u8>&, bool) {
    if (bios.size() != 0x4000) {
        lle_ = false; buildBios();
        cpu_.onSWI = [this](ARMCPU& c, u32 n) { handleSWI(c, n); };
        return bios.empty();
    }
    std::memcpy(bios_.data(), bios.data(), 0x4000);
    lle_ = true;
    cpu_.onSWI = nullptr;
    return true;
}

void GBASystem::buildBios() {
    bios_.fill(0);
    // Reset/undefined/SWI/abort vectors loop on themselves (they are never used: reset
    // starts the cartridge directly and SWIs are handled in C++).
    for (u32 v = 0; v < 0x18; v += 4) { u32 b = 0xEAFFFFFE; std::memcpy(&bios_[v], &b, 4); }
    std::memcpy(&bios_[0x18], kIrqStub, sizeof kIrqStub);
}

bool GBASystem::loadROM(const u8* data, size_t size, std::string& error) {
    if (!data || size < 0xC0) { error = "File too small to be a Game Boy Advance game."; return false; }
    if (size > 0x2000000) { error = "Game Boy Advance games are at most 32 MB."; return false; }
    rom_.assign(data, data + size);
    info_ = RomInfo{};
    auto str = [&](size_t off, size_t len) { std::string s; for (size_t i = 0; i < len; ++i) { char c = char(data[off + i]); if (!c) break; s += c; } return s; };
    info_.title = str(0xA0, 12); info_.gameCode = str(0xAC, 4); info_.makerCode = str(0xB0, 2);
    info_.arm9Entry = 0x08000000;
    u8 chk = 0; for (size_t i = 0xA0; i < 0xBD; ++i) chk = u8(chk - data[i]);
    chk = u8(chk - 0x19);
    info_.headerCrc = data[0xBD]; info_.headerCrcValid = chk == data[0xBD];
    detectSave();
    reset();
    return true;
}

void GBASystem::detectSave() {
    auto has = [&](const char* s) {
        size_t n = std::strlen(s);
        for (size_t i = 0; i + n <= rom_.size(); i += 4) if (std::memcmp(&rom_[i], s, n) == 0) return true;
        return false;
    };
    SaveType t = SaveType::None;
    switch (saveOverride_) {
    case 1: t = SaveType::EEPROM512; break;
    case 2: t = SaveType::EEPROM8K; break;
    case 5: t = SaveType::SRAM; break;
    case 6: case 7: t = SaveType::Flash64; break;
    case 8: case 9: t = SaveType::Flash128; break;
    default:
        if (has("EEPROM_V")) t = SaveType::EEPROMUnknown;
        else if (has("FLASH1M_V")) t = SaveType::Flash128;
        else if (has("FLASH512_V") || has("FLASH_V")) t = SaveType::Flash64;
        else if (has("SRAM_V") || has("SRAM_F_V")) t = SaveType::SRAM;
        else t = SaveType::SRAM;   // unknown: offer battery RAM (harmless if unused)
    }
    setSaveType(t);
    saveDirty_ = false;
}

void GBASystem::setSaveType(SaveType t) {
    saveType_ = t;
    size_t n = 0;
    switch (t) {
    case SaveType::None: n = 0; break;
    case SaveType::SRAM: n = 0x8000; break;
    case SaveType::Flash64: n = 0x10000; break;
    case SaveType::Flash128: n = 0x20000; break;
    case SaveType::EEPROM512: n = 0x200; break;
    case SaveType::EEPROM8K: case SaveType::EEPROMUnknown: n = 0x2000; break;
    }
    if (save_.size() != n) save_.resize(n, 0xFF);
}

void GBASystem::loadSaveData(const std::vector<u8>& d) {
    saveRejected_ = false;
    if (d.empty()) return;
    if (saveType_ == SaveType::EEPROMUnknown) {
        if (d.size() == 0x200) setSaveType(SaveType::EEPROM512);
        else if (d.size() == 0x2000) setSaveType(SaveType::EEPROM8K);
    }
    if (saveType_ == SaveType::Flash64 && d.size() == 0x20000 && saveOverride_ == 0) setSaveType(SaveType::Flash128);
    if (saveType_ == SaveType::SRAM && d.size() == 0x10000 && saveOverride_ == 0) setSaveType(SaveType::Flash64);
    if (saveType_ == SaveType::SRAM && d.size() == 0x20000 && saveOverride_ == 0) setSaveType(SaveType::Flash128);
    if (d.size() != save_.size()) { saveRejected_ = true; return; }
    save_ = d;
    saveDirty_ = false;
}

std::string GBASystem::saveTypeDescription() const {
    switch (saveType_) {
    case SaveType::None: return "None";
    case SaveType::SRAM: return "SRAM 32 KB";
    case SaveType::Flash64: return "Flash 64 KB";
    case SaveType::Flash128: return "Flash 128 KB";
    case SaveType::EEPROM512: return "EEPROM 512 B";
    case SaveType::EEPROM8K: return "EEPROM 8 KB";
    case SaveType::EEPROMUnknown: return "EEPROM (size pending)";
    }
    return {};
}

void GBASystem::reset() {
    std::fill(ewram_.begin(), ewram_.end(), 0); std::fill(iwram_.begin(), iwram_.end(), 0);
    std::fill(vram_.begin(), vram_.end(), 0); std::fill(pal_.begin(), pal_.end(), 0); std::fill(oam_.begin(), oam_.end(), 0);
    io_.fill(0);
    for (auto& t : timers_) t = Timer{};
    for (auto& d : dma_) d = Dma{};
    sq_[0] = sq_[1] = Square{}; wave_ = Wave{}; noise_ = Noise{};
    std::memset(waveRam_, 0, sizeof waveRam_); std::memset(fifo_, 0, sizeof fifo_);
    fifoCount_[0] = fifoCount_[1] = fifoRead_[0] = fifoRead_[1] = 0; fifoSample_[0] = fifoSample_[1] = 0;
    seqCycles_ = 0; seqStep_ = 0; sampleAccum_ = 0;
    flashState_ = 0; flashId_ = flashErase_ = flashWrite_ = flashBankSel_ = false; flashBank_ = 0;
    eeBits_ = 0; eeCount_ = 0; eeMode_ = 0; eeReadPos_ = 0;
    io_[0x00 / 2] = 0x0080;
    io_[0x88 / 2] = 0x0200;
    io_[0x134 / 2] = 0x8000;                                           // RCNT after BIOS boot
    io_[0x20 / 2] = 0x100; io_[0x26 / 2] = 0x100; io_[0x30 / 2] = 0x100; io_[0x36 / 2] = 0x100;
    io_[0x300 / 2] = 0x0001;
    bgRefX_[0] = bgRefX_[1] = bgRefY_[0] = bgRefY_[1] = 0;
    line_ = 0; lineCycles_ = 0; intrWaiting_ = false; intrWaitMask_ = 0;
    frames_ = 0; notice_.clear(); biosLatch_ = 0xE129F000;
    std::memset(swiCounts_, 0, sizeof swiCounts_);

    // Fast pages for BIOS / EWRAM / IWRAM.
    pagesRd_.assign(kPageCount, nullptr); pagesWr_.assign(kPageCount, nullptr);
    for (u32 a = 0x02000000; a < 0x03000000; a += 0x4000) { u8* p = &ewram_[a & 0x3FFFF]; pagesRd_[a >> 14] = p; pagesWr_[a >> 14] = p; }
    for (u32 a = 0x03000000; a < 0x04000000; a += 0x4000) { u8* p = &iwram_[a & 0x7FFF]; pagesRd_[a >> 14] = p; pagesWr_[a >> 14] = p; }
    cpu_.setFastPages(pagesRd_.data(), pagesWr_.data());

    cpu_.reset(0x08000000, false);
    cpu_.halted = cpu_.faulted = false; cpu_.faultMessage.clear();
    cpu_.setCPSR(ARMCPU::SYS);
    cpu_.setBankedSP(ARMCPU::SVC, 0x03007FE0);
    cpu_.setBankedSP(ARMCPU::IRQ, 0x03007FA0);
    cpu_.setReg(13, 0x03007F00);
    if (lle_) {                                                        // real BIOS: start at the reset vector (boot intro)
        cpu_.reset(0x00000000, false);
        cpu_.setCPSR(ARMCPU::SVC);
        io_[0x300 / 2] = 0;
        io_[0x134 / 2] = 0;
    }
    audio_.clear();
}

// ------------------------------------------------------------------ memory

u8 GBASystem::read8(u32 a) {
    switch (a >> 24) {
    case 0x00: return u8(biosRead(a & ~3u) >> ((a & 3) * 8));
    case 0x02: return ewram_[a & 0x3FFFF];
    case 0x03: return iwram_[a & 0x7FFF];
    case 0x04: { u32 off = a & 0x00FFFFFF; if (off >= 0x400) return 0; u16 v = ioRead16(off & ~1u); return u8(v >> ((a & 1) * 8)); }
    case 0x05: return pal_[a & 0x3FF];
    case 0x06: { u32 o = a & 0x1FFFF; if (o >= 0x18000) o -= 0x8000; return vram_[o]; }
    case 0x07: return oam_[a & 0x3FF];
    case 0x08: case 0x09: case 0x0A: case 0x0B: case 0x0C: case 0x0D: {
        if (isEepromAddr(a)) return u8(eepromRead());
        u32 o = a & 0x01FFFFFF; if (o < rom_.size()) return rom_[o];
        return u8(((a >> 1) & 0xFFFF) >> ((a & 1) * 8));
    }
    case 0x0E: case 0x0F: return saveRead(a);
    default: return u8(openBus(a) >> ((a & 3) * 8));
    }
}

u16 GBASystem::read16(u32 a) {
    switch (a >> 24) {
    case 0x00: return u16(biosRead(a & ~3u) >> ((a & 2) * 8));
    case 0x04: { u32 off = a & 0x00FFFFFF; return off < 0x400 ? ioRead16(off) : 0; }
    case 0x05: { u16 v; std::memcpy(&v, &pal_[a & 0x3FE], 2); return v; }
    case 0x06: { u32 o = a & 0x1FFFE; if (o >= 0x18000) o -= 0x8000; u16 v; std::memcpy(&v, &vram_[o], 2); return v; }
    case 0x07: { u16 v; std::memcpy(&v, &oam_[a & 0x3FE], 2); return v; }
    case 0x08: case 0x09: case 0x0A: case 0x0B: case 0x0C: case 0x0D: {
        if (isEepromAddr(a)) return eepromRead();
        u32 o = a & 0x01FFFFFE; if (o + 1 < rom_.size()) { u16 v; std::memcpy(&v, &rom_[o], 2); return v; }
        return u16(a >> 1);
    }
    case 0x0E: case 0x0F: { u8 b = saveRead(a); return u16(b * 0x0101); }
    case 0x02: case 0x03: return u16(read8(a) | (read8(a + 1) << 8));
    default: return u16(openBus(a) >> ((a & 2) * 8));
    }
}

// BIOS reads: the code itself while executing inside the BIOS; otherwise the last opcode the
// BIOS fetched (read protection), which some games and tests check.
u32 GBASystem::biosRead(u32 a) {
    if (a >= 0x4000) return 0;
    u32 v; std::memcpy(&v, &bios_[a], 4);
    if (cpu_.pc() < 0x4000) {
        if (a == 0x24) biosLatch_ = 0xE25EF004;          // inside the IRQ dispatcher
        else if (a == 0x2C) biosLatch_ = 0xE55EC002;     // returning from an IRQ
        return v;
    }
    return biosLatch_;
}

// Unmapped regions (0x01xxxxxx, 0x10000000+) read back the last prefetched opcode. In THUMB
// mode the 16-bit opcode appears in both halves. Games depend on this: Minish Cap walks an
// animation list through a stray pointer into this space and only stops on a non-zero byte.
u32 GBASystem::openBus(u32 a) {
    (void)a;
    u32 pc = cpu_.pc(); u32 region = pc >> 24;
    if (region != 0x02 && region != 0x03 && (region < 0x08 || region > 0x0D)) return 0;
    if (cpu_.thumb()) { u32 op = read16(pc & ~1u); return op | (op << 16); }
    return read32(pc & ~3u);
}

u32 GBASystem::read32(u32 a) {
    if ((a >> 24) == 0) return biosRead(a & ~3u);
    if ((a >> 24) >= 0x08 && (a >> 24) <= 0x0D && !isEepromAddr(a)) {
        u32 o = a & 0x01FFFFFC; if (o + 3 < rom_.size()) { u32 v; std::memcpy(&v, &rom_[o], 4); return v; }
    }
    if ((a >> 24) == 0x0E || (a >> 24) == 0x0F) { u8 b = saveRead(a); return b * 0x01010101u; }
    if ((a >> 24) == 0x01 || (a >> 24) >= 0x10) return openBus(a);
    return read16(a) | (u32(read16(a + 2)) << 16);
}

void GBASystem::write8(u32 a, u8 v) {
    switch (a >> 24) {
    case 0x02: ewram_[a & 0x3FFFF] = v; return;
    case 0x03: iwram_[a & 0x7FFF] = v; return;
    case 0x04: { u32 off = a & 0x00FFFFFF; if (off < 0x400) ioWrite16(off & ~1u, u16(v << ((a & 1) * 8)), u16(0xFF << ((a & 1) * 8))); return; }
    case 0x05: { u32 o = a & 0x3FE; pal_[o] = v; pal_[o + 1] = v; return; }        // byte writes fill the halfword
    case 0x06: {
        u32 o = a & 0x1FFFE; if (o >= 0x18000) o -= 0x8000;
        u32 objStart = (io_[0] & 7) >= 3 ? 0x14000 : 0x10000;
        if (o < objStart) { vram_[o] = v; vram_[o + 1] = v; }                     // OBJ VRAM ignores byte writes
        return;
    }
    case 0x07: return;                                                                 // OAM ignores byte writes
    case 0x0E: case 0x0F: saveWrite(a, v); return;
    default: return;
    }
}

void GBASystem::write16(u32 a, u16 v) {
    if ((a >> 24) == 0x0E || (a >> 24) == 0x0F) { saveWrite(a, u8(v >> ((a & 1) * 8))); return; }
    a &= ~1u;
    switch (a >> 24) {
    case 0x02: std::memcpy(&ewram_[a & 0x3FFFE], &v, 2); return;
    case 0x03: std::memcpy(&iwram_[a & 0x7FFE], &v, 2); return;
    case 0x04: { u32 off = a & 0x00FFFFFF; if (off < 0x400) ioWrite16(off, v); return; }
    case 0x05: std::memcpy(&pal_[a & 0x3FE], &v, 2); return;
    case 0x06: { u32 o = a & 0x1FFFE; if (o >= 0x18000) o -= 0x8000; std::memcpy(&vram_[o], &v, 2); return; }
    case 0x07: std::memcpy(&oam_[a & 0x3FE], &v, 2); return;
    case 0x08: case 0x09: case 0x0A: case 0x0B: case 0x0C: case 0x0D:
        if (isEepromAddr(a)) eepromWrite(v);
        return;
    case 0x0E: case 0x0F: saveWrite(a, u8(v >> ((a & 1) * 8))); return;
    default: return;
    }
}

void GBASystem::write32(u32 a, u32 v) {
    if ((a >> 24) == 0x0E || (a >> 24) == 0x0F) { saveWrite(a, u8(v >> ((a & 3) * 8))); return; }
    a &= ~3u;
    write16(a, u16(v)); write16(a + 2, u16(v >> 16));
}

// ------------------------------------------------------------------ I/O

u16 GBASystem::ioRead16(u32 off) {
    if (ioTrace) ioTrace->push_back({off, cpu_.pc()});
    switch (off) {
    case 0x006: return u16(line_);
    case 0x100: case 0x104: case 0x108: case 0x10C: return u16(timers_[(off - 0x100) / 4].counter);
    case 0x130: return u16(~buttons_ & 0x3FF);
    case 0x084: return u16((io_[0x84 / 2] & 0x80) | (sq_[0].on ? 1 : 0) | (sq_[1].on ? 2 : 0) | (wave_.on ? 4 : 0) | (noise_.on ? 8 : 0));
    case 0x0A0: case 0x0A2: case 0x0A4: case 0x0A6: return 0;
    default: break;
    }
    if (off >= 0x90 && off < 0xA0) {
        int bank = (io_[0x70 / 2] & 0x40) ? 0 : 16;
        u32 i = bank + (off - 0x90);
        return u16(waveRam_[i] | (waveRam_[i + 1] << 8));
    }
    if (off >= 0xB0 && off < 0xE0) {                                    // DMA: only CNT_H readable
        u32 r = (off - 0xB0) % 12;
        return r == 10 ? io_[off / 2] : 0;
    }
    return io_[off / 2];
}

static s32 sx28(u32 v) { return s32(v << 4) >> 4; }

void GBASystem::ioWrite16(u32 off, u16 v, u16 mask) {
    if (ioTrace) ioTrace->push_back({off | 0x80000000u, v});
    u16 old = io_[off / 2];
    u16 nv = u16((old & ~mask) | (v & mask));
    if (off >= 0x90 && off < 0xA0) {
        int bank = (io_[0x70 / 2] & 0x40) ? 0 : 16;
        u32 i = bank + (off - 0x90);
        if (mask & 0x00FF) waveRam_[i] = u8(v);
        if (mask & 0xFF00) waveRam_[i + 1] = u8(v >> 8);
        return;
    }
    if (off >= 0xA0 && off < 0xA8) {
        int f = off >= 0xA4 ? 1 : 0;
        if (mask & 0x00FF) fifoPush(f, u8(v), 1);
        if (mask & 0xFF00) fifoPush(f, u8(v >> 8), 1);
        return;
    }
    switch (off) {
    case 0x004: io_[2] = u16((old & 0x0007) | (nv & 0xFF38)); return;
    case 0x006: case 0x130: return;
    case 0x028: case 0x02A: io_[off / 2] = nv; bgRefX_[0] = sx28(io_[0x28 / 2] | (u32(io_[0x2A / 2]) << 16)); return;
    case 0x02C: case 0x02E: io_[off / 2] = nv; bgRefY_[0] = sx28(io_[0x2C / 2] | (u32(io_[0x2E / 2]) << 16)); return;
    case 0x038: case 0x03A: io_[off / 2] = nv; bgRefX_[1] = sx28(io_[0x38 / 2] | (u32(io_[0x3A / 2]) << 16)); return;
    case 0x03C: case 0x03E: io_[off / 2] = nv; bgRefY_[1] = sx28(io_[0x3C / 2] | (u32(io_[0x3E / 2]) << 16)); return;
    case 0x064: case 0x06C: case 0x074: case 0x07C: {
        io_[off / 2] = u16(nv & 0x7FFF);
        if (nv & 0x8000 & mask) {
            if (off == 0x064 || off == 0x06C) {
                int c = off == 0x064 ? 0 : 1;
                u16 env = io_[(c ? 0x68 : 0x62) / 2];
                Square& s = sq_[c];
                s.on = (env >> 11) != 0;            // DAC off when initial volume 0 and decrease
                s.vol = env >> 12; s.envTimer = env >> 8 & 7;
                if (s.len == 0) s.len = 64 - (env & 63);
                s.shadow = nv & 0x7FF; s.sweepTimer = (io_[0x60 / 2] >> 4) & 7;
            } else if (off == 0x074) {
                wave_.on = (io_[0x70 / 2] & 0x80) != 0; wave_.pos = 0;
                if (wave_.len == 0) wave_.len = 256 - (io_[0x72 / 2] & 0xFF);
            } else {
                u16 env = io_[0x78 / 2];
                noise_.on = (env >> 11) != 0; noise_.vol = env >> 12; noise_.envTimer = env >> 8 & 7;
                noise_.lfsr = (nv & 8) ? 0x7F : 0x7FFF;
                if (noise_.len == 0) noise_.len = 64 - (env & 63);
            }
        }
        return;
    }
    case 0x062: io_[off / 2] = nv; sq_[0].len = 64 - (nv & 63); return;
    case 0x068: io_[off / 2] = nv; sq_[1].len = 64 - (nv & 63); return;
    case 0x072: io_[off / 2] = nv; wave_.len = 256 - (nv & 0xFF); return;
    case 0x078: io_[off / 2] = nv; noise_.len = 64 - (nv & 63); return;
    case 0x070: io_[off / 2] = nv; if (!(nv & 0x80)) wave_.on = false; return;
    case 0x082:
        io_[off / 2] = u16(nv & 0x770F);
        if (nv & 0x0800) { fifoCount_[0] = fifoRead_[0] = 0; }
        if (nv & 0x8000) { fifoCount_[1] = fifoRead_[1] = 0; }
        return;
    case 0x084:
        io_[off / 2] = u16(nv & 0x80);
        if (!(nv & 0x80)) { sq_[0].on = sq_[1].on = wave_.on = noise_.on = false; }
        return;
    case 0x128:                                                        // SIOCNT: no link cable attached
        if ((nv & 0x3000) == 0x2000) nv = u16((nv & 0xFF83) | 0x000C); // multiplayer, no partner: SI/SD high, ID 0
        io_[off / 2] = nv;
        if (nv & 0x80) {                                               // transfer "completes" at once
            io_[off / 2] = u16(nv & ~0x80);
            io_[0x120 / 2] = io_[0x122 / 2] = io_[0x124 / 2] = io_[0x126 / 2] = 0xFFFF;
            if (nv & 0x4000) raise(7);
        }
        return;
    case 0x202: io_[off / 2] = u16(old & ~(v & mask)); return;
    case 0x208: io_[off / 2] = u16(nv & 1); return;
    case 0x300:
        io_[off / 2] = u16(nv & 0xFF);
        if (mask & 0xFF00) { cpu_.halted = true; }                     // HALTCNT (bit 7 set = stop; treated as halt)
        return;
    default: break;
    }
    if (off >= 0xB0 && off < 0xE0) {
        int ch = int((off - 0xB0) / 12); u32 r = (off - 0xB0) % 12;
        io_[off / 2] = nv;
        Dma& d = dma_[ch];
        if (r < 4) d.src = io_[(0xB0 + ch * 12) / 2] | (u32(io_[(0xB2 + ch * 12) / 2]) << 16);
        else if (r < 8) d.dst = io_[(0xB4 + ch * 12) / 2] | (u32(io_[(0xB6 + ch * 12) / 2]) << 16);
        else if (r == 8) d.count = nv;
        else {
            d.ctl = nv;
            if ((nv & 0x8000) && !(old & 0x8000)) {
                d.isrc = d.src & (ch == 0 ? 0x07FFFFFF : 0x0FFFFFFF);
                d.idst = d.dst & (ch == 3 ? 0x0FFFFFFF : 0x07FFFFFF);
                if (((nv >> 12) & 3) == 0) runDma(ch);
            }
        }
        return;
    }
    if (off >= 0x100 && off < 0x110) {
        int i = int((off - 0x100) / 4);
        if (off & 2) {
            bool was = timers_[i].ctl & 0x80;
            timers_[i].ctl = u16(nv & 0xC7); io_[off / 2] = timers_[i].ctl;
            if ((nv & 0x80) && !was) { timers_[i].counter = timers_[i].reload; timers_[i].accum = 0; }
        } else { timers_[i].reload = nv; io_[off / 2] = nv; }
        return;
    }
    io_[off / 2] = nv;
}

// ------------------------------------------------------------------ DMA / timers / IRQ

void GBASystem::runDma(int ch) {
    Dma& d = dma_[ch];
    u16 ctl = d.ctl;
    int timing = (ctl >> 12) & 3;
    bool fifo = (ch == 1 || ch == 2) && timing == 3;
    bool word = fifo || (ctl & 0x0400);
    u32 count = fifo ? 4 : (d.count ? d.count : (ch == 3 ? 0x10000u : 0x4000u));
    if (!fifo) count &= ch == 3 ? 0x1FFFF : 0x7FFF;
    if (!count) count = ch == 3 ? 0x10000u : 0x4000u;
    int unit = word ? 4 : 2;
    int srcCtl = (ctl >> 7) & 3, dstCtl = fifo ? 2 : (ctl >> 5) & 3;
    int sstep = srcCtl == 0 || srcCtl == 3 ? unit : (srcCtl == 1 ? -unit : 0);
    int dstep = dstCtl == 0 || dstCtl == 3 ? unit : (dstCtl == 1 ? -unit : 0);
    if (ch == 3 && saveType_ == SaveType::EEPROMUnknown && ((d.idst >> 24) == 0x0D || (d.isrc >> 24) == 0x0D)) {
        if (count == 9 || count == 73) setSaveType(SaveType::EEPROM512);
        else if (count == 17 || count == 81) setSaveType(SaveType::EEPROM8K);
    }
    for (u32 i = 0; i < count; ++i) {
        if (word) write32(d.idst & ~3u, read32(d.isrc & ~3u));
        else write16(d.idst & ~1u, read16(d.isrc & ~1u));
        d.isrc += u32(sstep); d.idst += u32(dstep);
    }
    if (dstCtl == 3) d.idst = d.dst & (ch == 3 ? 0x0FFFFFFF : 0x07FFFFFF);
    if (ctl & 0x4000) raise(8 + ch);
    if (!(ctl & 0x0200) || timing == 0) { d.ctl &= 0x7FFF; io_[(0xBA + ch * 12) / 2] = d.ctl; }
}

void GBASystem::triggerDma(int timing) {
    for (int ch = 0; ch < 4; ++ch) {
        const Dma& d = dma_[ch];
        if ((d.ctl & 0x8000) && ((d.ctl >> 12) & 3) == timing) runDma(ch);
    }
}

void GBASystem::tickTimers(u32 cycles) {
    static const u32 presc[4] = {1, 64, 256, 1024};
    for (int i = 0; i < 4; ++i) {
        Timer& t = timers_[i];
        if (!(t.ctl & 0x80) || (i > 0 && (t.ctl & 4))) continue;
        t.accum += cycles;
        u32 p = presc[t.ctl & 3];
        if (t.accum < p) continue;
        u32 ticks = t.accum / p; t.accum -= ticks * p;
        t.counter += ticks;
        while (t.counter > 0xFFFF) { t.counter = t.counter - 0x10000 + t.reload; timerOverflow(i); if (t.reload == 0xFFFF && t.counter > 0xFFFF) { t.counter = 0xFFFF; break; } }
    }
}

void GBASystem::timerOverflow(int i) {
    if (timers_[i].ctl & 0x40) raise(3 + i);
    if (i < 2) {
        u16 h = io_[0x82 / 2];
        if (((h >> 10) & 1) == u16(i)) fifoPop(0);
        if (((h >> 14) & 1) == u16(i)) fifoPop(1);
    }
    if (i < 3) {
        Timer& n = timers_[i + 1];
        if ((n.ctl & 0x80) && (n.ctl & 4)) {
            if (++n.counter > 0xFFFF) { n.counter = n.reload; timerOverflow(i + 1); }
        }
    }
}

void GBASystem::fifoPush(int f, u32 value, int bytes) {
    for (int b = 0; b < bytes; ++b) {
        if (fifoCount_[f] >= 32) return;
        fifo_[f][(fifoRead_[f] + fifoCount_[f]) & 31] = s8(value >> (8 * b));
        ++fifoCount_[f];
    }
}

void GBASystem::fifoPop(int f) {
    if (fifoCount_[f] > 0) { fifoSample_[f] = fifo_[f][fifoRead_[f]]; fifoRead_[f] = (fifoRead_[f] + 1) & 31; --fifoCount_[f]; }
    if (fifoCount_[f] <= 16) {
        u32 addr = f ? 0x040000A4 : 0x040000A0;
        for (int ch = 1; ch <= 2; ++ch) {
            Dma& d = dma_[ch];
            if ((d.ctl & 0x8000) && ((d.ctl >> 12) & 3) == 3 && (d.dst & ~3u) == addr) { runDma(ch); break; }
        }
    }
}

void GBASystem::checkIRQ() {
    u16 pending = io_[0x200 / 2] & io_[0x202 / 2] & 0x3FFF;
    if (!pending) return;
    if (cpu_.halted) cpu_.halted = false;
    cpu_.wake();
    if (io_[0x208 / 2] & 1) cpu_.raiseIRQ();
}

void GBASystem::stepCycles(s64 cycles) {
    lineCycles_ += cycles;
    while (lineCycles_ > 0) {
        checkIRQ();
        u32 c;
        if (cpu_.sleeping()) {
            c = u32(lineCycles_);
            // Jump ahead, but stop at the next timer overflow so timer IRQs/FIFOs stay on time.
            static const u32 presc[4] = {1, 64, 256, 1024};
            for (int i = 0; i < 4; ++i) {
                const Timer& t = timers_[i];
                if (!(t.ctl & 0x80) || (i > 0 && (t.ctl & 4))) continue;
                u64 need = u64(0x10000 - t.counter) * presc[t.ctl & 3] - t.accum;
                if (need < c) c = u32(std::max<u64>(need, 1));
            }
        } else {
            u32 pc = cpu_.pc();
            if (pcTrace) pcTrace->push_back(pc);
            cpu_.step();
            u32 region = pc >> 24;
            bool th = cpu_.thumb();
            c = region >= 0x08 ? (th ? 2 : 4) : (region == 0x02 ? (th ? 3 : 6) : 1);
        }
        tickTimers(c);
        audioTick(c);
        lineCycles_ -= s64(c);
    }
}

void GBASystem::startLine() {
    io_[0x04 / 2] &= u16(~2);                                          // HBlank flag off
    if (line_ == 160) {
        io_[0x04 / 2] |= 1;
        if (io_[0x04 / 2] & 0x08) raise(0);
        triggerDma(1);
        bgRefX_[0] = sx28(io_[0x28 / 2] | (u32(io_[0x2A / 2]) << 16)); bgRefY_[0] = sx28(io_[0x2C / 2] | (u32(io_[0x2E / 2]) << 16));
        bgRefX_[1] = sx28(io_[0x38 / 2] | (u32(io_[0x3A / 2]) << 16)); bgRefY_[1] = sx28(io_[0x3C / 2] | (u32(io_[0x3E / 2]) << 16));
    } else if (line_ == 227) io_[0x04 / 2] &= u16(~1);
    u16 ds = io_[0x04 / 2];
    if ((ds >> 8) == line_) { io_[0x04 / 2] |= 4; if (ds & 0x20) raise(2); }
    else io_[0x04 / 2] &= u16(~4);
    cpu_.wake();
}

void GBASystem::enterHBlank() {
    io_[0x04 / 2] |= 2;
    if (io_[0x04 / 2] & 0x10) raise(1);
    if (line_ < 160) {
        if (lastDrawn_) renderLine(line_);
        triggerDma(2);
        bgRefX_[0] += s16(io_[0x22 / 2]); bgRefY_[0] += s16(io_[0x26 / 2]);
        bgRefX_[1] += s16(io_[0x32 / 2]); bgRefY_[1] += s16(io_[0x36 / 2]);
    }
    cpu_.wake();
}

void GBASystem::runFrame() {
    if (rom_.empty()) return;
    lastDrawn_ = (skipCounter_ == 0);
    skipCounter_ = frameSkip_ ? (skipCounter_ + 1) % (frameSkip_ + 1) : 0;
    // Keypad interrupt
    u16 kc = io_[0x132 / 2];
    if (kc & 0x4000) {
        u32 sel = kc & 0x3FF, pressed = buttons_ & sel;
        if ((kc & 0x8000) ? (pressed == sel && sel) : (pressed != 0)) raise(12);
    }
    for (line_ = 0; line_ < kLines; ++line_) {
        startLine();
        stepCycles(kHDrawCycles);
        enterHBlank();
        stepCycles(kCyclesPerLine - kHDrawCycles);
    }
    line_ = 0;
    ++frames_;
    if (!sampleBuf_.empty()) { audio_.push(sampleBuf_.data(), sampleBuf_.size() / 2); sampleBuf_.clear(); }
}

std::string GBASystem::statusText() const {
    char b[160];
    std::snprintf(b, sizeof b, "GBA %s [%s] | %s%s", info_.title.c_str(), info_.gameCode.c_str(), saveTypeDescription().c_str(),
                  cpu_.faulted ? (" | CPU: " + cpu_.faultMessage).c_str() : "");
    return b;
}

// ------------------------------------------------------------------ save chips

u8 GBASystem::saveRead(u32 a) {
    u32 o = a & 0xFFFF;
    switch (saveType_) {
    case SaveType::SRAM: return save_[o & 0x7FFF];
    case SaveType::Flash64: case SaveType::Flash128:
        if (flashId_ && o < 2) {
            if (saveType_ == SaveType::Flash64) return o == 0 ? 0x32 : 0x1B;   // Panasonic 512 Kbit
            return o == 0 ? 0x62 : 0x13;                                        // Sanyo 1 Mbit
        }
        return save_[(u32(flashBank_) << 16) | o];
    default: return 0xFF;
    }
}

void GBASystem::saveWrite(u32 a, u8 v) {
    u32 o = a & 0xFFFF;
    if (saveType_ == SaveType::SRAM) { if (save_[o & 0x7FFF] != v) { save_[o & 0x7FFF] = v; saveDirty_ = true; } return; }
    if (saveType_ != SaveType::Flash64 && saveType_ != SaveType::Flash128) return;
    if (flashWrite_) { save_[(u32(flashBank_) << 16) | o] = v; flashWrite_ = false; saveDirty_ = true; return; }
    if (flashBankSel_ && o == 0) { flashBank_ = saveType_ == SaveType::Flash128 ? (v & 1) : 0; flashBankSel_ = false; return; }
    if (flashState_ == 0 && o == 0x5555 && v == 0xAA) { flashState_ = 1; return; }
    if (flashState_ == 1 && o == 0x2AAA && v == 0x55) { flashState_ = 2; return; }
    if (flashState_ == 2) {
        flashState_ = 0;
        if (flashErase_ && v == 0x30) {                                         // sector erase (4 KB)
            u32 base = (u32(flashBank_) << 16) | (o & 0xF000);
            std::fill(save_.begin() + base, save_.begin() + base + 0x1000, 0xFF); flashErase_ = false; saveDirty_ = true; return;
        }
        if (o != 0x5555) return;
        switch (v) {
        case 0x90: flashId_ = true; break;
        case 0xF0: flashId_ = false; break;
        case 0x80: flashErase_ = true; break;
        case 0x10: if (flashErase_) { std::fill(save_.begin(), save_.end(), 0xFF); saveDirty_ = true; } flashErase_ = false; break;
        case 0xA0: flashWrite_ = true; break;
        case 0xB0: flashBankSel_ = true; break;
        default: break;
        }
        return;
    }
    flashState_ = 0;
    if (v == 0xF0) flashId_ = false;
}

u16 GBASystem::eepromRead() {
    if (eeMode_ != 1) return 1;
    u16 bit = 0;
    if (eeReadPos_ >= 4) bit = u16((eeReadData_ >> (63 - (eeReadPos_ - 4))) & 1);
    if (++eeReadPos_ >= 68) eeMode_ = 0;
    return bit;
}

void GBASystem::eepromWrite(u16 v) {
    if (saveType_ == SaveType::EEPROMUnknown) setSaveType(SaveType::EEPROM8K);
    if (eeMode_ == 1) eeMode_ = 0;                                       // a new command aborts a pending read
    const int n = eeAddrBits();
    const u32 bit = v & 1;
    // Serial protocol, MSB first: 2 command bits (11 read, 10 write), n address bits,
    // 64 data bits (write only), then one stop bit.
    if (eeCount_ < 2) eeCmd_ = eeCount_ == 0 ? int(bit) : (eeCmd_ << 1) | int(bit);
    else if (eeCount_ < 2 + n) { if (eeCount_ == 2) eeAddr_ = 0; eeAddr_ = (eeAddr_ << 1) | bit; }
    else if (eeCmd_ == 2 && eeCount_ < 2 + n + 64) { if (eeCount_ == 2 + n) eeBits_ = 0; eeBits_ = (eeBits_ << 1) | bit; }
    ++eeCount_;
    if (eeCount_ >= 2 && eeCmd_ != 2 && eeCmd_ != 3) { eeCount_ = 0; return; }
    const u32 base = (eeAddr_ & (u32(save_.size() / 8) - 1)) * 8;
    if (eeCmd_ == 3 && eeCount_ == 3 + n) {
        eeReadData_ = 0; for (int i = 0; i < 8; ++i) eeReadData_ = (eeReadData_ << 8) | save_[base + u32(i)];
        eeMode_ = 1; eeReadPos_ = 0; eeCount_ = 0;
    } else if (eeCmd_ == 2 && eeCount_ == 3 + n + 64) {
        for (int i = 0; i < 8; ++i) save_[base + u32(i)] = u8(eeBits_ >> (56 - 8 * i));
        saveDirty_ = true; eeCount_ = 0;
    }
}

// ------------------------------------------------------------------ HLE BIOS

void GBASystem::handleSWI(ARMCPU& c, u32 n) {
    ++swiCounts_[n & 0xFF];
    biosLatch_ = 0xE3A02004;
    auto R = [&](int i) { return c.reg(i); };
    auto reexecuteAndHalt = [&] { c.branchTo(c.pc() - (c.thumb() ? 4 : 8), c.thumb()); c.halted = true; };
    auto rd32 = [&](u32 a) { return read32(a & ~3u); };
    auto rd16 = [&](u32 a) { return read16(a & ~1u); };
    auto rd8 = [&](u32 a) { return read8(a); };
    auto store = [&](u32 dst, const std::vector<u8>& out, bool vram) {
        if (!vram) { for (size_t i = 0; i < out.size(); ++i) write8(dst + u32(i), out[i]); return; }
        for (size_t i = 0; i < out.size(); i += 2) write16(dst + u32(i), u16(out[i] | ((i + 1 < out.size() ? out[i + 1] : 0) << 8)));
    };
    switch (n) {
    case 0x00: {                                                                  // SoftReset
        bool ewram = read8(0x03007FFA) != 0;
        for (u32 a = 0x03007E00; a < 0x03008000; a += 4) write32(a, 0);
        c.setCPSR(ARMCPU::SVC); c.setReg(13, 0x03007FE0); c.setReg(14, 0); c.setSPSR(0);
        c.setCPSR(ARMCPU::IRQ); c.setReg(13, 0x03007FA0); c.setReg(14, 0); c.setSPSR(0);
        c.setCPSR(ARMCPU::SYS); c.setReg(13, 0x03007F00);
        for (int i = 0; i < 13; ++i) c.setReg(i, 0);
        c.branchTo(ewram ? 0x02000000 : 0x08000000, false);
        return;
    }
    case 0x01: {                                                                  // RegisterRamReset
        u32 f = R(0);
        if (f & 0x01) std::fill(ewram_.begin(), ewram_.end(), 0);
        if (f & 0x02) std::fill(iwram_.begin(), iwram_.begin() + 0x7E00, 0);
        if (f & 0x04) std::fill(pal_.begin(), pal_.end(), 0);
        if (f & 0x08) std::fill(vram_.begin(), vram_.end(), 0);
        if (f & 0x10) std::fill(oam_.begin(), oam_.end(), 0);
        if (f & 0x80) { for (u32 o = 0x08; o < 0x60; o += 2) io_[o / 2] = 0; io_[0x20 / 2] = io_[0x26 / 2] = io_[0x30 / 2] = io_[0x36 / 2] = 0x100; }
        io_[0] = 0x0080;
        return;
    }
    case 0x02: case 0x03: c.halted = true; return;                                // Halt / Stop
    case 0x04: case 0x05: {                                                       // IntrWait / VBlankIntrWait
        io_[0x208 / 2] = 1;
        u16 flags = read16(0x03007FF8);
        if (!intrWaiting_) {
            intrWaitMask_ = n == 0x05 ? 1 : u16(R(1));
            bool discard = n == 0x05 || R(0) != 0;
            if (discard) write16(0x03007FF8, u16(flags & ~intrWaitMask_));
            else if (flags & intrWaitMask_) { write16(0x03007FF8, u16(flags & ~intrWaitMask_)); return; }
            intrWaiting_ = true; reexecuteAndHalt(); return;
        }
        if (flags & intrWaitMask_) { write16(0x03007FF8, u16(flags & ~intrWaitMask_)); intrWaiting_ = false; return; }
        reexecuteAndHalt();
        return;
    }
    case 0x06: case 0x07: {                                                       // Div / DivArm
        s32 a = s32(n == 6 ? R(0) : R(1)), b = s32(n == 6 ? R(1) : R(0));
        if (b == 0) { c.setReg(0, a < 0 ? u32(-1) : 1); c.setReg(1, u32(a)); c.setReg(3, 1); return; }
        if (a == INT32_MIN && b == -1) { c.setReg(0, u32(a)); c.setReg(1, 0); c.setReg(3, u32(a)); return; }
        s32 q = a / b; c.setReg(0, u32(q)); c.setReg(1, u32(a % b)); c.setReg(3, u32(q < 0 ? -q : q));
        return;
    }
    case 0x08: c.setReg(0, u32(std::sqrt(double(R(0))))); return;               // Sqrt
    case 0x09: {                                                                  // ArcTan
        double t = double(s32(R(0))) / 16384.0;
        c.setReg(0, u32(s32(std::lround(std::atan(t) * 32768.0 / M_PI))));
        return;
    }
    case 0x0A: {                                                                  // ArcTan2
        double x = double(s16(R(0))), y = double(s16(R(1)));
        double a = std::atan2(y, x); if (a < 0) a += 2 * M_PI;
        c.setReg(0, u32(std::lround(a * 65536.0 / (2 * M_PI))) & 0xFFFF);
        return;
    }
    case 0x0B: case 0x0C: {                                                       // CpuSet / CpuFastSet
        u32 src = R(0), dst = R(1), ctl = R(2);
        u32 count = ctl & 0x1FFFFF; bool fill = ctl & (1u << 24);
        bool word = n == 0x0C || (ctl & (1u << 26));
        if (n == 0x0C) count = (count + 7) & ~7u;
        if ((src >> 24) == 0) return;                                             // BIOS area is protected
        if (word) { src &= ~3u; dst &= ~3u; u32 v = rd32(src); for (u32 i = 0; i < count; ++i) { write32(dst + i * 4, fill ? v : rd32(src + i * 4)); } }
        else { src &= ~1u; dst &= ~1u; u16 v = rd16(src); for (u32 i = 0; i < count; ++i) write16(dst + i * 2, fill ? v : rd16(src + i * 2)); }
        return;
    }
    case 0x0D: c.setReg(0, 0xBAAE187F); return;                                   // GetBiosChecksum (value games expect)
    case 0x0E: {                                                                  // BgAffineSet
        u32 src = R(0), dst = R(1);
        for (u32 i = 0; i < R(2); ++i, src += 20, dst += 16) {
            s32 ox = s32(rd32(src)), oy = s32(rd32(src + 4));
            s16 dx = s16(rd16(src + 8)), dy = s16(rd16(src + 10));
            s16 sx = s16(rd16(src + 12)), sy = s16(rd16(src + 14));
            double ang = double(rd16(src + 16) >> 8) * 2 * M_PI / 256.0;
            s32 cs = s32(std::lround(std::cos(ang) * 16384)), sn = s32(std::lround(std::sin(ang) * 16384));
            s16 pa = s16((cs * sx) >> 14), pb = s16(-(sn * sx) >> 14), pc = s16((sn * sy) >> 14), pd = s16((cs * sy) >> 14);
            write16(dst, u16(pa)); write16(dst + 2, u16(pb)); write16(dst + 4, u16(pc)); write16(dst + 6, u16(pd));
            write32(dst + 8, u32(ox - (pa * dx + pb * dy)));
            write32(dst + 12, u32(oy - (pc * dx + pd * dy)));
        }
        return;
    }
    case 0x0F: {                                                                  // ObjAffineSet
        u32 src = R(0), dst = R(1), stride = R(3);
        for (u32 i = 0; i < R(2); ++i, src += 8, dst += stride * 4) {
            s16 sx = s16(rd16(src)), sy = s16(rd16(src + 2));
            double ang = double(rd16(src + 4) >> 8) * 2 * M_PI / 256.0;
            s32 cs = s32(std::lround(std::cos(ang) * 16384)), sn = s32(std::lround(std::sin(ang) * 16384));
            write16(dst, u16(s16((cs * sx) >> 14))); write16(dst + stride, u16(s16(-(sn * sx) >> 14)));
            write16(dst + stride * 2, u16(s16((sn * sy) >> 14))); write16(dst + stride * 3, u16(s16((cs * sy) >> 14)));
        }
        return;
    }
    case 0x10: {                                                                  // BitUnPack
        u32 src = R(0), dst = R(1) & ~3u, info = R(2);
        u32 len = rd16(info); u32 sw = rd8(info + 2), dw = rd8(info + 3), offs = rd32(info + 4);
        bool zeroFlag = offs & 0x80000000u; offs &= 0x7FFFFFFF;
        if (!sw || !dw || sw > 8 || dw > 32) return;
        u32 out = 0, outBits = 0;
        for (u32 i = 0; i < len; ++i) {
            u8 b = rd8(src + i);
            for (u32 bit = 0; bit < 8; bit += sw) {
                u32 v = (b >> bit) & ((1u << sw) - 1);
                if (v || zeroFlag) v += offs;
                out |= (dw == 32 ? v : (v & ((1u << dw) - 1))) << outBits;
                outBits += dw;
                if (outBits >= 32) { write32(dst, out); dst += 4; out = 0; outBits = 0; }
            }
        }
        return;
    }
    case 0x11: case 0x12: {                                                       // LZ77UnComp
        u32 src = R(0); u32 hdr = rd32(src); u32 size = hdr >> 8; src += 4;
        std::vector<u8> out; out.reserve(size);
        while (out.size() < size) {
            u8 flags = rd8(src++);
            for (int k = 0; k < 8 && out.size() < size; ++k, flags <<= 1) {
                if (flags & 0x80) {
                    u8 b0 = rd8(src++), b1 = rd8(src++);
                    u32 disp = (((b0 & 0xF) << 8) | b1) + 1, len = (b0 >> 4) + 3;
                    for (u32 j = 0; j < len && out.size() < size; ++j) out.push_back(disp <= out.size() ? out[out.size() - disp] : 0);
                } else out.push_back(rd8(src++));
            }
        }
        store(R(1), out, n == 0x12);
        return;
    }
    case 0x13: {                                                                  // HuffUnComp
        u32 src = R(0); u32 hdr = rd32(src); u32 size = hdr >> 8, bitsPer = hdr & 0xF;
        if (bitsPer != 4 && bitsPer != 8) bitsPer = 8;
        u32 tree = src + 5, treeSize = (u32(rd8(src + 4)) + 1) * 2;
        u32 stream = src + 4 + treeSize;
        std::vector<u8> out; out.reserve(size);
        u32 node = tree, acc = 0, accBits = 0, outWord = 0, outBits = 0;
        while (out.size() < size) {
            if (accBits == 0) { acc = rd32(stream); stream += 4; accBits = 32; }
            u32 bit = (acc >> 31) & 1; acc <<= 1; --accBits;
            u8 nd = rd8(node);
            u32 next = (node & ~1u) + (nd & 0x3F) * 2 + 2 + bit;
            bool isData = bit ? (nd & 0x40) : (nd & 0x80);
            if (isData) {
                outWord |= u32(rd8(next)) << outBits; outBits += bitsPer;
                if (outBits >= 32) { for (int i = 0; i < 4; ++i) out.push_back(u8(outWord >> (8 * i))); outWord = 0; outBits = 0; }
                node = tree;
            } else node = next;
        }
        out.resize(size);
        store(R(1), out, false);
        return;
    }
    case 0x14: case 0x15: {                                                       // RLUnComp
        u32 src = R(0); u32 size = rd32(src) >> 8; src += 4;
        std::vector<u8> out; out.reserve(size);
        while (out.size() < size) {
            u8 f = rd8(src++);
            if (f & 0x80) { u32 len = (f & 0x7F) + 3; u8 b = rd8(src++); for (u32 j = 0; j < len && out.size() < size; ++j) out.push_back(b); }
            else { u32 len = (f & 0x7F) + 1; for (u32 j = 0; j < len && out.size() < size; ++j) out.push_back(rd8(src++)); }
        }
        store(R(1), out, n == 0x15);
        return;
    }
    case 0x16: case 0x17: case 0x18: {                                            // Diff8bitUnFilter / Diff16bitUnFilter
        u32 src = R(0); u32 size = rd32(src) >> 8; src += 4;
        std::vector<u8> out(size);
        if (n == 0x18) { u16 acc = 0; for (u32 i = 0; i + 1 < size; i += 2) { acc = u16(acc + rd16(src + i)); out[i] = u8(acc); out[i + 1] = u8(acc >> 8); } }
        else { u8 acc = 0; for (u32 i = 0; i < size; ++i) { acc = u8(acc + rd8(src + i)); out[i] = acc; } }
        store(R(1), out, n != 0x16);
        return;
    }
    case 0x19: io_[0x88 / 2] = u16((io_[0x88 / 2] & ~0x3FF) | (R(0) ? 0x200 : 0)); return;   // SoundBias
    case 0x1F: {                                                                  // MidiKey2Freq
        double freq = double(rd32(R(0) + 4)) / std::pow(2.0, (180.0 - double(R(1)) - double(R(2)) / 256.0) / 12.0);
        c.setReg(0, u32(freq));
        return;
    }
    default:                                                                      // sound driver / multiboot calls: no-op
        if (notice_.empty()) { char b[64]; std::snprintf(b, sizeof b, "SWI 0x%02X ignored (HLE)", n); notice_ = b; }
        return;
    }
}

// ------------------------------------------------------------------ save states

void GBASystem::serialize(StateIO& s) {
    s.tag(0x47424131);
    cpu_.serialize(s);
    s.vec(ewram_); s.vec(iwram_); s.vec(vram_); s.vec(pal_); s.vec(oam_);
    s.bytes(io_.data(), io_.size() * 2);
    s.pod(line_); s.pod(lineCycles_); s.pod(intrWaiting_); s.pod(intrWaitMask_);
    s.bytes(timers_, sizeof timers_); s.bytes(dma_, sizeof dma_);
    s.bytes(bgRefX_, sizeof bgRefX_); s.bytes(bgRefY_, sizeof bgRefY_);
    s.bytes(sq_, sizeof sq_); s.pod(wave_); s.pod(noise_); s.bytes(waveRam_, sizeof waveRam_);
    s.bytes(fifo_, sizeof fifo_); s.bytes(fifoCount_, sizeof fifoCount_); s.bytes(fifoRead_, sizeof fifoRead_); s.bytes(fifoSample_, sizeof fifoSample_);
    s.pod(seqCycles_); s.pod(seqStep_); s.pod(sampleAccum_);
    u8 st = u8(saveType_); s.pod(st);
    if (!s.writing()) setSaveType(SaveType(st));
    s.vec(save_);
    s.pod(flashState_); s.pod(flashId_); s.pod(flashErase_); s.pod(flashWrite_); s.pod(flashBankSel_); s.pod(flashBank_);
    s.pod(eeBits_); s.pod(eeCount_); s.pod(eeMode_); s.pod(eeAddr_); s.pod(eeReadPos_); s.pod(eeReadData_); s.pod(eeCmd_);
    s.pod(frames_); s.pod(biosLatch_);
    s.tag(0x47424145);
}

std::vector<u8> GBASystem::saveState() {
    StateIO s;
    u32 magic = 0x4E444741; std::string code = info_.gameCode; s.pod(magic); s.str(code);
    serialize(s);
    return s.output();
}

bool GBASystem::loadState(const std::vector<u8>& d) {
    std::vector<u8> backup = saveState();
    StateIO s(d);
    u32 magic = 0; std::string code; s.pod(magic); s.str(code);
    if (!s.ok() || magic != 0x4E444741 || code != info_.gameCode) return false;
    serialize(s);
    if (!s.ok()) { StateIO b(backup); u32 m; std::string c; b.pod(m); b.str(c); serialize(b); return false; }
    cpu_.setFastPages(pagesRd_.data(), pagesWr_.data());
    audio_.clear();
    saveDirty_ = true;
    return true;
}

} // namespace dscore
