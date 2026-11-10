// Copyright (c) 2026 Charlie Rodriguez Garcia. All rights reserved.
// Original clean-room VRAM bank controller (VRAMCNT A-I), from GBATEK.
#pragma once
#include "dscore/Types.hpp"
#include "dscore/StateIO.hpp"
#include <vector>

namespace dscore {

class VRAM {
public:
    enum Region { ABG, AOBJ, BBG, BOBJ, LCDC, ARM7, TEX, TEXPAL, kNumRegions };
    static constexpr u32 kPage = 0x4000;   // mapping granularity: 16 KB

    VRAM();
    void reset();
    void setControl(int bank, u8 value);   // bank 0..8 = A..I
    u8 control(int bank) const { return cnt_[bank]; }

    // Offsets are relative to the start of the region and wrap at the region size.
    u8  read8(Region r, u32 off) const {
        u32 o = (r == LCDC) ? off : (off & (regionSize(r) - 1));
        if (r != LCDC || o < 0xA4000) { if (const u8* p = fast_[r][o / kPage]) return p[o & (kPage - 1)]; }
        return read8Slow(r, off);
    }
    // Pointer to a 16 KB page if exactly one bank is mapped there (fast path), else nullptr.
    const u8* page(Region r, u32 off) const {
        u32 o = (r == LCDC) ? off : (off & (regionSize(r) - 1));
        return (r == LCDC && o >= 0xA4000) ? nullptr : fast_[r][o / kPage];
    }
    u16 read16(Region r, u32 off) const {
        // Fast path: both bytes in one directly mapped 16 KB page (the common case).
        u32 o = (r == LCDC) ? off : (off & (regionSize(r) - 1));
        if ((o & (kPage - 1)) != kPage - 1 && (r != LCDC || o < 0xA4000)) {
            if (const u8* p = fast_[r][o / kPage]) { const u8* q = p + (o & (kPage - 1)); return u16(q[0] | (q[1] << 8)); }
        }
        return u16(read8(r, off) | (read8(r, off + 1) << 8));
    }
    void write8(Region r, u32 off, u8 v);
    static constexpr u32 regionSize(Region r) {
        return r == ABG ? 0x80000 : r == AOBJ ? 0x40000 : r == BBG ? 0x20000 : r == BOBJ ? 0x20000 : r == LCDC ? 0xA4000 : r == TEXPAL ? 0x20000 : r == TEX ? 0x80000 : 0x40000;
    }

    // Extended palettes (8 KB per slot): BG slots 0..3, OBJ slot. nullptr if unmapped.
    const u8* bgExtPalette(bool engineA, int slot) const { return bgExt_[engineA ? 0 : 1][slot & 3]; }
    const u8* objExtPalette(bool engineA) const { return objExt_[engineA ? 0 : 1]; }

    // VRAMSTAT for ARM7: bit0 = bank C mapped to ARM7, bit1 = bank D.
    u8 arm7Status() const;

    void serialize(StateIO& s) { s.tag(0x5652414D); s.vec(mem_); s.bytes(cnt_, sizeof cnt_); if (!s.writing()) remap(); }

    const u8* bankData(int bank) const { return &mem_[kBankBase[bank]]; }
    u8* bankDataMut(int bank) { return &mem_[kBankBase[bank]]; }   // display capture writes

    static constexpr u32 kBankBase[9] = {0x00000, 0x20000, 0x40000, 0x60000, 0x80000, 0x90000, 0x94000, 0x98000, 0xA0000};
    static constexpr u32 kBankSize[9] = {0x20000, 0x20000, 0x20000, 0x20000, 0x10000, 0x4000, 0x4000, 0x8000, 0x4000};

private:
    void remap();
    u8 read8Slow(Region r, u32 off) const;
    std::vector<const u8*> fast_[kNumRegions];
    std::vector<u8> mem_;          // 656 KB, laid out like the LCDC region
    u8 cnt_[9] = {};
    // For each region page: bitmask of banks mapped there.
    std::vector<u16> pages_[kNumRegions];
    u32 bankRegionOffset_[9] = {};  // where each bank starts inside its region
    const u8* bgExt_[2][4] = {};
    const u8* objExt_[2] = {};
};

} // namespace dscore
