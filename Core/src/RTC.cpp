// Copyright (c) 2026 Charlie Rodriguez Garcia. All rights reserved.
// Original clean-room real-time clock. See RTC.hpp.
#include "RTC.hpp"
#include <cstring>
#include <cstdlib>

namespace dscore {

namespace {
inline u8 bcd(int v) { return u8(((v / 10) << 4) | (v % 10)); }
inline u8 reverse8(u8 b) { u8 r = 0; for (int i = 0; i < 8; ++i) if (b & (1 << i)) r |= u8(0x80 >> i); return r; }
// Command byte "0110 RRR D": RRR register, D = 1 read. Bytes per register:
// 0 status1, 1 status2, 2 date+time, 3 time, 4 alarm1/int1, 5 alarm2, 6 clock adjust, 7 free.
const int kLength[8] = {1, 1, 7, 3, 3, 3, 1, 1};
} // namespace

void RTC::reset() {
    latch_ = 0; dataOut_ = false; cs_ = sck_ = false;
    cmd_ = 0; bitCount_ = 0; haveCmd_ = false; byteIndex_ = byteCount_ = 0;
    std::memset(buf_, 0, sizeof buf_);
    status1_ = 0x02; status2_ = 0; std::memset(int1_, 0, 3); std::memset(int2_, 0, 3); clockAdjust_ = 0; freeReg_ = 0;
    if (!clock) clock = [] {
        std::tm out{};
        // DSEMU_FIXED_TIME (headless regression runs): a fixed date so emulation is reproducible.
        if (std::getenv("DSEMU_FIXED_TIME")) { out.tm_year = 126; out.tm_mon = 0; out.tm_mday = 1; out.tm_hour = 12; return out; }
        std::time_t t = std::time(nullptr);
        if (std::tm* p = std::localtime(&t)) out = *p;
        return out; };
}

u16 RTC::read() const {
    u16 v = latch_ & 0x0076;
    bool dataIsInput = !(latch_ & 0x10);
    if (dataIsInput) v = u16((v & ~1u) | (dataOut_ ? 1 : 0)); else v |= latch_ & 1;
    return v;
}

void RTC::loadReadData() {
    u32 reg = (cmd_ >> 1) & 7;
    std::memset(buf_, 0, sizeof buf_);
    switch (reg) {
    case 0: buf_[0] = status1_; status1_ &= ~0xF0; break;          // reading clears the status flags
    case 1: buf_[0] = status2_; break;
    case 2: case 3: {
        std::tm t = clock();
        u8 hour = (status1_ & 2) ? bcd(t.tm_hour) : bcd(t.tm_hour % 12);
        if (t.tm_hour >= 12) hour |= 0x40;
        u8 dt[7] = {bcd(t.tm_year % 100), bcd(t.tm_mon + 1), bcd(t.tm_mday), u8(t.tm_wday), hour, bcd(t.tm_min), bcd(t.tm_sec)};
        if (reg == 2) std::memcpy(buf_, dt, 7); else std::memcpy(buf_, dt + 4, 3);
        break;
    }
    case 4: std::memcpy(buf_, int1_, 3); break;
    case 5: std::memcpy(buf_, int2_, 3); break;
    case 6: buf_[0] = clockAdjust_; break;
    default: buf_[0] = freeReg_; break;
    }
}

void RTC::storeWritten() {
    u32 reg = (cmd_ >> 1) & 7;
    switch (reg) {
    case 0: status1_ = u8((status1_ & 0xF1) | (buf_[0] & 0x0E)); if (buf_[0] & 1) status1_ &= 0x0E; break;
    case 1: status2_ = buf_[0]; break;
    case 4: std::memcpy(int1_, buf_, 3); break;
    case 5: std::memcpy(int2_, buf_, 3); break;
    case 6: clockAdjust_ = buf_[0]; break;
    case 7: freeReg_ = buf_[0]; break;
    default: break;                                                // setting the date/time is ignored (host clock)
    }
}

void RTC::write(u16 v) {
    bool cs = v & 4, sck = v & 2, data = v & 1;
    bool dataIsOutput = v & 0x10;                                  // CPU drives the data line
    latch_ = v;
    if (!cs) {                                                     // deselect: end of transfer
        if (cs_ && haveCmd_ && !(cmd_ & 1) && byteIndex_ > 0) storeWritten();
        cs_ = false; sck_ = sck; haveCmd_ = false; bitCount_ = 0; byteIndex_ = 0; cmd_ = 0;
        return;
    }
    if (!cs_) { cs_ = true; sck_ = sck; bitCount_ = 0; haveCmd_ = false; cmd_ = 0; return; }
    bool rising = !sck_ && sck, falling = sck_ && !sck;
    sck_ = sck;
    if (!haveCmd_) {
        if (rising) {
            cmd_ = u8(cmd_ | ((data ? 1 : 0) << bitCount_));       // command bits arrive LSB first
            if (++bitCount_ == 8) {
                // Normalise to "0110 RRR D" form: accept either bit order.
                if ((cmd_ & 0xF0) != 0x60) cmd_ = reverse8(cmd_);
                if ((cmd_ & 0xF0) == 0x60) {
                    haveCmd_ = true; bitCount_ = 0; byteIndex_ = 0;
                    byteCount_ = kLength[(cmd_ >> 1) & 7];
                    if (cmd_ & 1) loadReadData();
                    else std::memset(buf_, 0, sizeof buf_);
                } else { bitCount_ = 0; cmd_ = 0; }
            }
        }
        return;
    }
    if (cmd_ & 1) {                                                // read: RTC drives data, LSB first
        // Each falling edge presents the next bit; it stays valid through the rising edge.
        if (falling) {
            dataOut_ = (buf_[byteIndex_] >> bitCount_) & 1;
            if (++bitCount_ == 8) { bitCount_ = 0; byteIndex_ = (byteIndex_ + 1) % byteCount_; }
        }
    } else if (rising && dataIsOutput) {                           // write
        if (byteIndex_ < byteCount_) buf_[byteIndex_] = u8(buf_[byteIndex_] | ((data ? 1 : 0) << bitCount_));
        if (++bitCount_ == 8) { bitCount_ = 0; if (byteIndex_ < 8) ++byteIndex_; }
    }
}

void RTC::commandComplete() {}

void RTC::serialize(StateIO& s) {
    s.tag(0x52544301);
    s.pod(latch_); s.pod(dataOut_); s.pod(cs_); s.pod(sck_); s.pod(cmd_); s.pod(bitCount_); s.pod(haveCmd_);
    s.bytes(buf_, sizeof buf_); s.pod(byteIndex_); s.pod(byteCount_);
    s.pod(status1_); s.pod(status2_); s.bytes(int1_, 3); s.bytes(int2_, 3); s.pod(clockAdjust_); s.pod(freeReg_);
}

} // namespace dscore
