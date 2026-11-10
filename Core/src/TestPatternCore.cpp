// Copyright (c) 2026 Charlie Rodriguez Garcia. All rights reserved.
// Test/stub core: renders a diagnostic pattern so the app runs end-to-end
// without any game. Shows pressed buttons, touch position and plays a tone.
#include "dscore/EmulatorCore.hpp"
#include "dscore/AudioRing.hpp"
#include <cmath>
#include <vector>

namespace dscore {

namespace {
constexpr u32 rgb(u32 r, u32 g, u32 b) { return 0xFF000000u | (r << 16) | (g << 8) | b; }

class TestPatternCore final : public EmulatorCore {
public:
    TestPatternCore() : top_(kScreenPixels), bottom_(kScreenPixels) { info_.title = "TEST PATTERN"; reset(); }

    bool loadROM(const u8* data, size_t size, std::string& error) override {
        RomInfo ri; if (!parseRomHeader(data, size, ri, error)) return false;
        info_ = ri; reset(); return true;
    }
    void reset() override { frame_ = 0; phase_ = 0; audio_.clear(); }

    void runFrame() override {
        ++frame_;
        static const u32 bars[8] = {rgb(255,255,255), rgb(255,255,0), rgb(0,255,255), rgb(0,255,0),
                                    rgb(255,0,255), rgb(255,0,0), rgb(0,0,255), rgb(0,0,0)};
        for (int y = 0; y < kScreenHeight; ++y)
            for (int x = 0; x < kScreenWidth; ++x) {
                u32 c = bars[(x * 8) / kScreenWidth];
                if (y > 150) { u32 v = u32((x + frame_) & 0xFF); c = rgb(v, v, v); }   // moving ramp
                top_[y * kScreenWidth + x] = c;
            }
        // Button indicators on the top screen (12 squares).
        for (int b = 0; b < 12; ++b) {
            bool on = buttons_ & (1u << b);
            fillRect(top_, 8 + b * 20, 160, 14, 14, on ? rgb(255, 64, 64) : rgb(40, 40, 40));
        }
        for (int y = 0; y < kScreenHeight; ++y)
            for (int x = 0; x < kScreenWidth; ++x)
                bottom_[y * kScreenWidth + x] = rgb(u32(x), u32(y * 255 / 191), u32((frame_ * 2) & 0xFF));
        if (touchDown_) {
            fillRect(bottom_, 0, touchY_, kScreenWidth, 1, rgb(255, 255, 255));
            fillRect(bottom_, touchX_, 0, 1, kScreenHeight, rgb(255, 255, 255));
            fillRect(bottom_, touchX_ - 3, touchY_ - 3, 7, 7, rgb(255, 0, 0));
        }
        // ~800 audio frames per video frame at 48 kHz; tone while A is held.
        s16 buf[801 * 2];
        int n = kAudioSampleRate / 60;
        for (int k = 0; k < n; ++k) {
            s16 v = 0;
            if (buttons_ & BtnA) { v = s16(std::sin(phase_) * 6000); phase_ += 2 * 3.14159265 * 440.0 / kAudioSampleRate; }
            buf[k * 2] = buf[k * 2 + 1] = v;
        }
        audio_.push(buf, size_t(n));
    }

    const u32* framebuffer(int s) const override { return s == 0 ? top_.data() : bottom_.data(); }
    void setButtons(u32 m) override { buttons_ = m; }
    void setTouch(bool d, int x, int y) override { touchDown_ = d; touchX_ = x; touchY_ = y; }
    size_t readAudio(s16* out, size_t n) override { return audio_.pop(out, n); }
    size_t audioBuffered() const override { return audio_.size(); }
    std::vector<u8> saveState() override {           // trivial state: frame counter
        std::vector<u8> v(4); for (int i = 0; i < 4; ++i) v[i] = u8(frame_ >> (i * 8)); return v;
    }
    bool loadState(const std::vector<u8>& v) override {
        if (v.size() != 4) return false; frame_ = 0; for (int i = 0; i < 4; ++i) frame_ |= u32(v[i]) << (i * 8); return true;
    }
    const RomInfo& romInfo() const override { return info_; }
    std::string statusText() const override { return "Test mode (no game)"; }

private:
    static void fillRect(std::vector<u32>& fb, int x0, int y0, int w, int h, u32 c) {
        for (int y = y0; y < y0 + h; ++y) for (int x = x0; x < x0 + w; ++x)
            if (x >= 0 && y >= 0 && x < kScreenWidth && y < kScreenHeight) fb[y * kScreenWidth + x] = c;
    }
    std::vector<u32> top_, bottom_;
    RomInfo info_;
    u32 frame_ = 0, buttons_ = 0;
    bool touchDown_ = false; int touchX_ = 0, touchY_ = 0;
    double phase_ = 0;
    AudioRing audio_;
};
} // namespace

std::unique_ptr<EmulatorCore> createTestPatternCore() { return std::make_unique<TestPatternCore>(); }
} // namespace dscore
