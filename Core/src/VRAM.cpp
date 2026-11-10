// Copyright (c) 2026 Charlie Rodriguez Garcia. All rights reserved.
// Original clean-room VRAM bank controller (VRAMCNT A-I), from GBATEK.
#include "VRAM.hpp"
#include <algorithm>

namespace dscore {

constexpr u32 VRAM::kBankBase[9];
constexpr u32 VRAM::kBankSize[9];

VRAM::VRAM() : mem_(0xA4000) {
    for (int r = 0; r < kNumRegions; ++r) { pages_[r].assign((regionSize(Region(r)) + kPage - 1) / kPage, 0); fast_[r].assign(pages_[r].size(), nullptr); }
    reset();
}

void VRAM::reset() {
    std::fill(mem_.begin(), mem_.end(), 0);
    for (auto& c : cnt_) c = 0;
    remap();
}

void VRAM::setControl(int bank, u8 v) {
    if (bank < 0 || bank > 8 || cnt_[bank] == v) return;
    cnt_[bank] = v;
    remap();
}

void VRAM::remap() {
    for (auto& p : pages_) std::fill(p.begin(), p.end(), 0);
    for (auto& e : bgExt_) for (auto& s : e) s = nullptr;
    objExt_[0] = objExt_[1] = nullptr;

    for (int b = 0; b < 9; ++b) {
        u8 c = cnt_[b];
        if (!(c & 0x80)) continue;
        u32 mst = c & 7, ofs = (c >> 3) & 3;
        int region = -1; u32 off = 0;
        const u8* base = &mem_[kBankBase[b]];
        switch (b) {
        case 0: case 1:                                  // A, B
            switch (mst & 3) {
            case 0: region = LCDC; off = kBankBase[b]; break;
            case 1: region = ABG; off = 0x20000 * ofs; break;
            case 2: region = AOBJ; off = 0x20000 * (ofs & 1); break;
            default: region = TEX; off = 0x20000 * ofs; break;   // 3D texture slot
            }
            break;
        case 2: case 3:                                  // C, D
            switch (mst) {
            case 0: region = LCDC; off = kBankBase[b]; break;
            case 1: region = ABG; off = 0x20000 * ofs; break;
            case 2: region = ARM7; off = 0x20000 * (ofs & 1); break;
            case 3: region = TEX; off = 0x20000 * ofs; break;
            case 4: region = (b == 2) ? BBG : BOBJ; off = 0; break;
            default: break;
            }
            break;
        case 4:                                          // E
            switch (mst) {
            case 0: region = LCDC; off = kBankBase[b]; break;
            case 1: region = ABG; off = 0; break;
            case 2: region = AOBJ; off = 0; break;
            case 3: region = TEXPAL; off = 0; break;
            case 4: for (int s = 0; s < 4; ++s) bgExt_[0][s] = base + s * 0x2000; break;
            default: break;
            }
            break;
        case 5: case 6: {                                // F, G
            u32 fo = 0x4000 * (ofs & 1) + 0x10000 * (ofs >> 1);
            switch (mst) {
            case 0: region = LCDC; off = kBankBase[b]; break;
            case 1: region = ABG; off = fo; break;
            case 2: region = AOBJ; off = fo; break;
            case 3: region = TEXPAL; off = 0x4000 * (ofs & 1) + 0x10000 * (ofs >> 1); break;
            case 4: bgExt_[0][(ofs & 1) * 2] = base; bgExt_[0][(ofs & 1) * 2 + 1] = base + 0x2000; break;
            case 5: objExt_[0] = base; break;
            default: break;
            }
            break;
        }
        case 7:                                          // H
            switch (mst & 3) {
            case 0: region = LCDC; off = kBankBase[b]; break;
            case 1: region = BBG; off = 0; break;
            case 2: for (int s = 0; s < 4; ++s) bgExt_[1][s] = base + s * 0x2000; break;
            default: break;
            }
            break;
        default:                                         // I
            switch (mst & 3) {
            case 0: region = LCDC; off = kBankBase[b]; break;
            case 1: region = BBG; off = 0x8000; break;
            case 2: region = BOBJ; off = 0; break;
            default: objExt_[1] = base; break;
            }
            break;
        }
        if (region < 0) continue;
        bankRegionOffset_[b] = off;
        u32 n = kBankSize[b] / kPage;
        for (u32 i = 0; i < n; ++i) {
            u32 page = off / kPage + i;
            if (page < pages_[region].size()) pages_[region][page] |= u16(1u << b);
        }
    }
    for (int r = 0; r < kNumRegions; ++r)
        for (size_t pg = 0; pg < pages_[r].size(); ++pg) {
            u16 m = pages_[r][pg];
            fast_[r][pg] = nullptr;
            if (m && !(m & (m - 1))) {
                int b = __builtin_ctz(m);
                fast_[r][pg] = &mem_[kBankBase[b] + (pg * kPage - bankRegionOffset_[b])];
            }
        }
}

u8 VRAM::read8Slow(Region r, u32 off) const {
    u32 size = regionSize(r);
    if (r == LCDC) { if (off >= size) return 0; } else off &= size - 1;
    u16 m = pages_[r][off / kPage];
    u8 v = 0;
    while (m) {
        int b = __builtin_ctz(m); m &= m - 1;
        v |= mem_[kBankBase[b] + (off - bankRegionOffset_[b])];
    }
    return v;
}

void VRAM::write8(Region r, u32 off, u8 v) {
    u32 size = regionSize(r);
    if (r == LCDC) { if (off >= size) return; } else off &= size - 1;
    u16 m = pages_[r][off / kPage];
    while (m) {
        int b = __builtin_ctz(m); m &= m - 1;
        mem_[kBankBase[b] + (off - bankRegionOffset_[b])] = v;
    }
}

u8 VRAM::arm7Status() const {
    u8 s = 0;
    if ((cnt_[2] & 0x87) == 0x82) s |= 1;
    if ((cnt_[3] & 0x87) == 0x82) s |= 2;
    return s;
}

} // namespace dscore
