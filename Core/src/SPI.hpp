// Copyright (c) 2026 Charlie Rodriguez Garcia. All rights reserved.
// Original clean-room ARM7 SPI bus: power manager, firmware flash, touch screen
// controller (TSC). Behaviour from GBATEK.
#pragma once
#include "dscore/Types.hpp"
#include "dscore/StateIO.hpp"
#include <vector>

namespace dscore {

// Builds the 0x70-byte firmware "user settings" block (shared with direct boot).
void buildUserSettings(u8* out);

class SPIBus {
public:
    SPIBus();
    void reset();
    u16 readCnt() const { return cnt_; }
    void writeCnt(u16 v);
    u8 readData() const { return out_; }
    // Returns true if an IRQ should be raised (SPICNT bit 14).
    bool writeData(u8 v);

    void setTouch(bool down, int x, int y) { touchDown_ = down; touchX_ = x; touchY_ = y; }
    // ADC values for the current touch (exposed for tests).
    u16 adcX() const;
    u16 adcY() const;
    const std::vector<u8>& firmware() const { return fw_; }
    // The user's own firmware image (256/512 KB); empty = built-in generic image.
    void setFirmware(const std::vector<u8>& fw) { userFw_ = fw; reset(); }
    void serialize(StateIO& s) {
        s.tag(0x53504901); s.pod(cnt_); s.pod(out_); s.pod(tscShift_); s.vec(fw_);
        s.pod(fwCmd_); s.pod(fwStage_); s.pod(fwAddr_); s.pod(fwWel_); s.pod(pmStage_); s.pod(pmIndex_); s.bytes(pmRegs_, sizeof pmRegs_); s.pod(lastDevice_);
    }

private:
    u8 transferTSC(u8 v);
    u8 transferFirmware(u8 v);
    u8 transferPower(u8 v);
    void release();

    u16 cnt_ = 0;
    u8 out_ = 0;
    // TSC
    u16 tscShift_ = 0;
    bool touchDown_ = false; int touchX_ = 0, touchY_ = 0;
    // Firmware flash
    std::vector<u8> fw_;
    std::vector<u8> userFw_;
    u8 fwCmd_ = 0; int fwStage_ = 0; u32 fwAddr_ = 0; bool fwWel_ = false;
    // Power management
    int pmStage_ = 0; u8 pmIndex_ = 0; u8 pmRegs_[8] = {};
    int lastDevice_ = -1;
};

} // namespace dscore
