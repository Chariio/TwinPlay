// Copyright (c) 2026 Charlie Rodriguez Garcia. All rights reserved.
#include "SPI.hpp"
#include "dscore/EmulatorCore.hpp"
#include <algorithm>
#include <cstring>

namespace dscore {

namespace {
// Touch calibration written into user settings (adc1 -> scr1, adc2 -> scr2).
constexpr int kAdcX1 = 0x200, kAdcY1 = 0x200, kScrX1 = 1, kScrY1 = 1;
constexpr int kAdcX2 = 0xE00, kAdcY2 = 0xE00, kScrX2 = 0xFF, kScrY2 = 0xBF;
inline void put16(u8* p, u16 v) { p[0] = u8(v); p[1] = u8(v >> 8); }
}

void buildUserSettings(u8* us) {
    std::memset(us, 0, 0x70);
    put16(us + 0x00, 5);                       // version
    us[0x02] = 11;                             // favourite colour
    us[0x03] = 1; us[0x04] = 1;                // birthday
    const char* nick = "Player";
    int n = 0;
    for (; nick[n]; ++n) put16(us + 0x06 + n * 2, u8(nick[n]));
    put16(us + 0x1A, u16(n));
    put16(us + 0x58, kAdcX1); put16(us + 0x5A, kAdcY1); us[0x5C] = kScrX1; us[0x5D] = kScrY1;
    put16(us + 0x5E, kAdcX2); put16(us + 0x60, kAdcY2); us[0x62] = kScrX2; us[0x63] = kScrY2;
    put16(us + 0x64, 0x0001);                  // language: English
}

SPIBus::SPIBus() : fw_(0x40000, 0xFF) { reset(); }

void SPIBus::reset() {
    if (!userFw_.empty()) {
        fw_ = userFw_;
        cnt_ = 0; out_ = 0; tscShift_ = 0; fwCmd_ = 0; fwStage_ = 0; fwAddr_ = 0; fwWel_ = false;
        pmStage_ = 0; pmIndex_ = 0; std::fill(std::begin(pmRegs_), std::end(pmRegs_), 0); lastDevice_ = -1;
        return;
    }
    fw_.assign(0x40000, 0xFF);
    cnt_ = 0; out_ = 0; tscShift_ = 0;
    fwCmd_ = 0; fwStage_ = 0; fwAddr_ = 0; fwWel_ = false; pmStage_ = 0; pmIndex_ = 0; lastDevice_ = -1;
    std::memset(pmRegs_, 0, sizeof pmRegs_);
    // Generic firmware image (no Nintendo code): header + two user-settings copies.
    std::fill(fw_.begin(), fw_.end(), 0xFF);
    std::fill(fw_.begin(), fw_.begin() + 0x200, 0x00);
    put16(&fw_[0x20], 0x3FE00 / 8);            // user settings offset / 8
    fw_[0x1D] = 0xFF;                          // console type: original DS
    // Wireless hardware info: locally administered MAC address, channel mask.
    const u8 mac[6] = {0x02, 0x00, 0x00, 0x00, 0x00, 0x01};
    std::memcpy(&fw_[0x36], mac, 6);
    put16(&fw_[0x3C], 0x3FFE);
    // Wireless calibration block (0x2C..0x163): a generic, self-consistent set so the games'
    // wireless library accepts the firmware (Pokemon Platinum checks it when loading a save).
    put16(&fw_[0x2C], 0x0138);                 // block length
    fw_[0x2F] = 0x00;                          // version
    std::fill(&fw_[0x30], &fw_[0x36], u8(0xFF));
    put16(&fw_[0x3E], 0xFFFF);
    fw_[0x40] = 0x02;                          // RF chip type (2 = 24-bit serial)
    fw_[0x41] = 0x18;                          // bits per RF entry
    fw_[0x42] = 0x0C;                          // RF entries
    fw_[0x43] = 0x01;
    {   // Initial wireless port values (0x44..0x81), baseband values (0x82..0xCE), RF values.
        static const u16 ports[] = {0x0002, 0x0017, 0x0026, 0x1818, 0x0048, 0x4840, 0x0058, 0x0042, 0x0140, 0x8064,
                                    0x80EC, 0x0101, 0x0040, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000,
                                    0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000};
        for (int i = 0; i < 31; ++i) put16(&fw_[0x44 + i * 2], ports[i]);
        static const u8 bb[0x69] = {0x6D, 0x9E, 0x40, 0x05, 0x1B, 0x6C, 0x48, 0x80, 0x38, 0x00, 0x35, 0x07, 0x00, 0x00, 0x00, 0x00,
                                    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00};
        std::memcpy(&fw_[0x82], bb, sizeof bb);
        for (int i = 0; i < 12; ++i) { u32 v = 0x00004000u | (u32(i) << 18); fw_[0xEC - 0x1E + i * 3] = u8(v); fw_[0xED - 0x1E + i * 3] = u8(v >> 8); fw_[0xEE - 0x1E + i * 3] = u8(v >> 16); }
        for (int ch = 0; ch < 14; ++ch) { fw_[0xF2 + ch * 6] = u8(0x10 + ch); fw_[0x146 + ch] = 0x14; }
    }
    put16(&fw_[0x2A], crc16(&fw_[0x2C], 0x138, 0x0000));
    // Three empty ("not configured") wireless connection slots with valid CRCs.
    for (int slot = 0; slot < 3; ++slot) {
        u8* ap = &fw_[0x3FA00 + slot * 0x100];
        std::memset(ap, 0, 0x100);
        ap[0xE7] = 0xFF;                       // status: not configured
        put16(ap + 0xFE, crc16(ap, 0xFE, 0x0000));
    }
    for (int copy = 0; copy < 2; ++copy) {
        u8* us = &fw_[0x3FE00 + copy * 0x100];
        std::memset(us, 0, 0x100);
        buildUserSettings(us);
        put16(us + 0x70, u16(copy == 0 ? 1 : 0));   // update counter
        put16(us + 0x72, crc16(us, 0x70));
    }
}

void SPIBus::writeCnt(u16 v) {
    bool wasHold = cnt_ & 0x0800;
    cnt_ = u16((cnt_ & 0x0080) | (v & 0xCF03));
    cnt_ &= ~0x0080;                           // transfers complete instantly: never busy
    (void)wasHold;
    if (!(cnt_ & 0x8000)) release();
}

void SPIBus::release() {
    if (fwStage_ > 0 && (fwCmd_ == 0x0A || fwCmd_ == 0x02 || fwCmd_ == 0xDB || fwCmd_ == 0xD8) && fwStage_ >= 4) fwWel_ = false;
    fwStage_ = 0; pmStage_ = 0; lastDevice_ = -1; }

bool SPIBus::writeData(u8 v) {
    if (!(cnt_ & 0x8000)) return false;
    int device = (cnt_ >> 8) & 3;
    if (device != lastDevice_) { fwStage_ = 0; pmStage_ = 0; lastDevice_ = device; }
    switch (device) {
    case 0: out_ = transferPower(v); break;
    case 1: out_ = transferFirmware(v); break;
    case 2: out_ = transferTSC(v); break;
    default: out_ = 0; break;
    }
    if (!(cnt_ & 0x0800)) release();           // chip select released after this byte
    return (cnt_ & 0x4000) != 0;
}

u16 SPIBus::adcX() const {
    if (!touchDown_) return 0;
    int x = std::min(std::max(touchX_, 0), 255);
    return u16(kAdcX1 + (x - (kScrX1 - 1)) * (kAdcX2 - kAdcX1) / (kScrX2 - kScrX1));
}
u16 SPIBus::adcY() const {
    if (!touchDown_) return 0xFFF;
    int y = std::min(std::max(touchY_, 0), 191);
    return u16(kAdcY1 + (y - (kScrY1 - 1)) * (kAdcY2 - kAdcY1) / (kScrY2 - kScrY1));
}

// TSC2046-style controller: a command byte (bit 7 set) selects a channel; the
// 12-bit result is shifted out MSB-first over the following bytes.
u8 SPIBus::transferTSC(u8 v) {
    u8 result = u8(tscShift_ >> 8);
    if (v & 0x80) {
        u32 channel = (v >> 4) & 7;
        u16 value;
        switch (channel) {
        case 1: value = adcY(); break;
        case 5: value = adcX(); break;
        case 3: value = touchDown_ ? 0x200 : 0; break;       // Z1 (pressure)
        case 4: value = touchDown_ ? 0xE00 : 0xFFF; break;   // Z2
        case 0: case 7: value = 0x320; break;                // temperature (arbitrary)
        default: value = 0x800; break;
        }
        if (v & 0x08) value >>= 4;                           // 8-bit conversion mode
        tscShift_ = u16((value & 0xFFF) << 3);
    } else {
        tscShift_ = u16(tscShift_ << 8);
    }
    return result;
}

u8 SPIBus::transferFirmware(u8 v) {
    if (fwStage_ == 0) {
        fwCmd_ = v; fwStage_ = 1; fwAddr_ = 0;
        if (v == 0x06) fwWel_ = true;                       // WREN
        if (v == 0x04) fwWel_ = false;                      // WRDI
        return 0;
    }
    switch (fwCmd_) {
    case 0x03: case 0x0B:                                    // READ / FAST READ
        if (fwStage_ <= 3) { fwAddr_ = (fwAddr_ << 8) | v; ++fwStage_; return 0; }
        if (fwCmd_ == 0x0B && fwStage_ == 4) { ++fwStage_; return 0; }   // dummy byte
        { u8 r = fw_[fwAddr_ & u32(fw_.size() - 1)]; ++fwAddr_; return r; }
    case 0x05: return u8(fwWel_ ? 0x02 : 0x00);              // status: never busy; WEL bit
    case 0x0A: case 0x02:                                    // PAGE WRITE / PAGE PROGRAM
        if (fwStage_ <= 3) { fwAddr_ = (fwAddr_ << 8) | v; ++fwStage_; return 0; }
        if (fwWel_) {
            u8& b = fw_[fwAddr_ & u32(fw_.size() - 1)];
            b = (fwCmd_ == 0x02) ? u8(b & v) : v;
            fwAddr_ = (fwAddr_ & ~0xFFu) | ((fwAddr_ + 1) & 0xFFu);   // wraps inside the 256-byte page
        }
        return 0;
    case 0xDB: case 0xD8:                                    // PAGE / SECTOR ERASE
        if (fwStage_ <= 3) {
            fwAddr_ = (fwAddr_ << 8) | v; ++fwStage_;
            if (fwStage_ == 4 && fwWel_) {
                u32 size = fwCmd_ == 0xDB ? 0x100u : 0x10000u;
                u32 base = (fwAddr_ & u32(fw_.size() - 1)) & ~(size - 1);
                std::fill(fw_.begin() + long(base), fw_.begin() + long(base + size), u8(0xFF));
            }
        }
        return 0;
    case 0x9F: { static const u8 id[3] = {0x20, 0x40, 0x12}; u8 r = id[(fwStage_ - 1) % 3]; ++fwStage_; return r; }
    default: return 0;                                       // writes ignored (TODO: persist)
    }
}

u8 SPIBus::transferPower(u8 v) {
    if (pmStage_ == 0) { pmIndex_ = v; pmStage_ = 1; return 0; }
    pmStage_ = 0;
    u8 reg = pmIndex_ & 7;
    if (pmIndex_ & 0x80) return pmRegs_[reg];
    pmRegs_[reg] = v;
    return 0;
}

} // namespace dscore
