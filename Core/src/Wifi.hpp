// Copyright (c) 2026 Charlie Rodriguez Garcia. All rights reserved.
// Wireless chip as seen by the ARM7 (0x04800000-0x0480FFFF): an idle, present-but-offline
// adapter. Games that initialise the wireless library at start-up or when saving (Pokemon
// Platinum / HeartGold / SoulSilver) need a chip that answers its ID, power-state,
// baseband and RF serial handshakes, otherwise they stop with a "communication error".
// No networking is emulated. Written from public hardware documentation.
#pragma once
#include "dscore/Types.hpp"
#include <array>
#include <cstdlib>
#include <cstdio>

namespace dscore {

class WifiChip {
public:
    void reset() {
        regs_.fill(0); ram_.fill(0); bb_.fill(0); rf_.fill(0);
        bb_[0x00] = 0x6D;                 // baseband chip ID
        set(0x000, 0x1440);               // W_ID (original DS)
        set(0x03C, 0x0200);               // W_POWERSTATE: powered down
        set(0x214, 0x0009);               // W_RF_STATUS: idle / listening
        set(0x19C, 0x0084);               // W_RF_PINS: radio awake and receiving (bit 7 polled after wake-up)
        us_ = 0; rnd_ = 0x7FF; irq_ = false; accesses_ = 0;
    }

    /// True once the game has touched the chip (headless diagnostics).
    u32 accesses() const { return accesses_; }

    u16 read16(u32 a) {
        u16 r = read16i(a);
        if (trace()) std::fprintf(stderr, "wifi R %06X = %04X\n", a & 0xFFFFFF, r);
        return r;
    }
    u16 read16i(u32 a) {
        ++accesses_;
        u32 off = a & 0x7FFF;
        if (off >= 0x4000 && off < 0x6000) return u16(ram_[off - 0x4000] | (ram_[off - 0x4000 + 1] << 8));
        if (off >= 0x4000) return 0xFFFF;
        off &= 0xFFE;
        switch (off) {
        case 0x044: rnd_ = u16((rnd_ * 1103u + 12345u) & 0x7FF); return rnd_;   // W_RANDOM
        case 0x15E: case 0x180: return 0;                          // BB / RF serial never busy
        case 0x0F8: case 0x0FA: case 0x0FC: case 0x0FE: {          // W_US_COUNT: advances while read
            us_ += 16;
            int sh = int(off - 0x0F8) * 8;
            return sh < 64 ? u16(us_ >> sh) : 0;
        }
        default: return get(off);
        }
    }

    void write16(u32 a, u16 v) {
        if (trace()) std::fprintf(stderr, "wifi W %06X : %04X\n", a & 0xFFFFFF, v);
        ++accesses_;
        u32 off = a & 0x7FFF;
        if (off >= 0x4000 && off < 0x6000) { ram_[off - 0x4000] = u8(v); ram_[off - 0x4000 + 1] = u8(v >> 8); return; }
        if (off >= 0x4000) return;
        off &= 0xFFE;
        switch (off) {
        case 0x000: return;                                        // ID is read-only
        case 0x010: set(0x010, u16(get(0x010) & ~v)); return;      // W_IF: write 1 to acknowledge
        case 0x03C:                                                // W_POWERSTATE
            set(0x03C, u16((get(0x03C) & 0x0300) | (v & 0x0003)));
            if (v & 0x0002) { set(0x03C, 0x0000); raise(11); }     // wake-up request completes at once
            return;
        case 0x040:                                                // W_POWERFORCE
            set(0x040, v);
            if ((v & 0x8001) == 0x8000) set(0x03C, 0x0000);
            else if ((v & 0x8001) == 0x8001) set(0x03C, 0x0200);
            return;
        case 0x158: {                                              // W_BB_CNT: serial transfer
            u8 idx = u8(v);
            u8 dir = u8(v >> 12);
            if (dir == 5) bb_[idx] = u8(get(0x15A));
            else if (dir == 6) set(0x15C, bb_[idx]);
            set(0x158, v); return;
        }
        case 0x17E: {                                              // W_RF_DATA1: 24/26-bit RF transfer
            set(0x17E, v);
            u32 word = (u32(v) << 16) | get(0x17C);
            u32 idx = (word >> 18) & 0x1F;
            if (word & 0x00800000u) { u32 val = rf_[idx]; set(0x17C, u16(val)); set(0x17E, u16((v & ~0x3u) | ((val >> 16) & 3))); }
            else rf_[idx] = word & 0x3FFFF;
            return;
        }
        case 0x0F8: case 0x0FA: case 0x0FC: case 0x0FE: {
            int sh = int(off - 0x0F8) * 8;
            if (sh < 64) us_ = (us_ & ~(u64(0xFFFF) << sh)) | (u64(v) << sh);
            return;
        }
        default: set(off, v); return;
        }
    }

    /// Wireless interrupt pending (ARM7 IRQ line 24); cleared once reported.
    bool takeIRQ() { bool r = irq_; irq_ = false; return r; }

private:
    static bool trace() { static const bool on = std::getenv("DSEMU_WIFITRACE") != nullptr; return on; }
    void raise(int bit) { set(0x010, u16(get(0x010) | (1u << bit))); if (get(0x012) & (1u << bit)) irq_ = true; }
    u16 get(u32 off) const { return u16(regs_[off] | (regs_[off + 1] << 8)); }
    void set(u32 off, u16 v) { regs_[off] = u8(v); regs_[off + 1] = u8(v >> 8); }

    std::array<u8, 0x1000> regs_{};
    std::array<u8, 0x2000> ram_{};
    std::array<u8, 0x100> bb_{};
    std::array<u32, 0x20> rf_{};
    u64 us_ = 0;
    u16 rnd_ = 0x7FF;
    bool irq_ = false;
    u32 accesses_ = 0;
};

} // namespace dscore
