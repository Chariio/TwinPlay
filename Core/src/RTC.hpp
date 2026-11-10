// Copyright (c) 2026 Charlie Rodriguez Garcia. All rights reserved.
// Original clean-room real-time clock (3-wire serial RTC on ARM7 port
// 0x04000138). Protocol from GBATEK. Time comes from the host clock.
#pragma once
#include "dscore/StateIO.hpp"
#include <ctime>
#include <functional>

namespace dscore {

class RTC {
public:
    RTC() { reset(); }
    void reset();
    u16 read() const;
    void write(u16 v);
    // Host time source (overridable for tests). Returns local broken-down time.
    std::function<std::tm()> clock;
    void serialize(StateIO& s);

private:
    void commandComplete();
    void loadReadData();
    void storeWritten();

    u16 latch_ = 0;            // last value written (direction + output bits)
    bool dataOut_ = false;      // bit driven by the RTC
    bool cs_ = false, sck_ = false;
    u8 cmd_ = 0; int bitCount_ = 0; bool haveCmd_ = false;
    u8 buf_[8] = {}; int byteIndex_ = 0, byteCount_ = 0;
    u8 status1_ = 0x02, status2_ = 0, int1_[3] = {}, int2_[3] = {}, clockAdjust_ = 0, freeReg_ = 0;
};

} // namespace dscore
