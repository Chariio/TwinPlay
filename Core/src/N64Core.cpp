// Copyright (c) 2026 Charlie Rodriguez Garcia. All rights reserved.
// TwinPlay's N64 session. The CPU and the video plugin live in the GPL libraries
// built by scripts/build-n64-3ds.sh (Mupen64Plus cached interpreter + GLideN64).
#include "dscore/EmulatorCore.hpp"
#include <algorithm>
#include <cstring>

extern "C" {
int twinplay_n64_available(void);
void twinplay_n64_set_plugin_dir(const char* dir);
void twinplay_n64_set_save_dir(const char* dir);
int twinplay_n64_load(const uint8_t* rom, int size, char* err, int err_len);
void twinplay_n64_unload(void);
void twinplay_n64_reset(void);
void twinplay_n64_run_frame(void);
void twinplay_n64_set_input(uint32_t buttons, float x, float y);
int twinplay_n64_copy_frame(uint32_t* dst, int cap, int* w, int* h);
int twinplay_n64_read_audio(int16_t* dst, int max_frames);
int twinplay_n64_save_state(uint8_t* dst, int cap);
int twinplay_n64_load_state(const uint8_t* src, int size);
void twinplay_n64_title(char* dst, int cap);
void twinplay_n64_set_paused(int paused);
}

namespace dscore {
namespace {
constexpr int kW = 256, kH = 192;
}

class N64Core final : public EmulatorCore {
public:
    N64Core() { top_.assign(kW * kH, 0xFF000000u); bottom_.assign(kW * kH, 0xFF000000u); }
    ~N64Core() override { shutDown(); }
    void shutDown() override {
        if (!booted_) return;
        twinplay_n64_unload();
        booted_ = false;
    }

    void setDataPath(const std::string& p) override { plugins_ = p; twinplay_n64_set_plugin_dir(p.c_str()); }
    void setSaveDirectory(const std::string& p) override { saves_ = p; twinplay_n64_set_save_dir(p.c_str()); }

    bool loadROM(const u8* data, size_t size, std::string& error) override {
        if (!data || !isN64Image(data, size)) { error = "This is not an N64 game image (.n64, .z64 or .v64)."; return false; }
        if (!twinplay_n64_available()) {
            error = "The N64 core is not linked into this build. On a Mac, run scripts/build-n64-3ds.sh and rebuild.";
            return false;
        }
        rom_.assign(data, data + size);
        normalizeN64(rom_);
        if (rom_.size() % 4) rom_.resize((rom_.size() + 3) & ~size_t(3), 0);
        info_ = {};
        info_.title = n64InternalName(rom_.data(), rom_.size());
        info_.gameCode = info_.title.empty() ? "N64" : info_.title.substr(0, 4);
        char err[512] = {};
        twinplay_n64_set_plugin_dir(plugins_.c_str());
        twinplay_n64_set_save_dir(saves_.c_str());
        if (twinplay_n64_load(rom_.data(), int(rom_.size()), err, int(sizeof err)) != 0) {
            error = err[0] ? err : "The N64 core could not open this game.";
            rom_.clear();
            return false;
        }
        char title[64] = {};
        twinplay_n64_title(title, int(sizeof title));
        if (title[0]) info_.title = title;
        booted_ = true;
        return true;
    }
    void reset() override { if (booted_) twinplay_n64_reset(); }
    void runFrame() override {
        if (!booted_) return;
        twinplay_n64_set_input(buttons_, analogX_, analogY_);
        twinplay_n64_run_frame();
        int w = 0, h = 0;
        twinplay_n64_copy_frame(nullptr, 0, &w, &h);
        if (w > 0 && h > 0 && w <= 1920 && h <= 1080) {
            std::vector<u32> native(size_t(w) * size_t(h));
            const int n = twinplay_n64_copy_frame(native.data(), int(native.size()), &w, &h);
            if (n > 0 && w > 0 && h > 0) scaleNearest(native.data(), w, h, top_.data(), kW, kH);
        }
        drawn_ = true;
    }
    const u32* framebuffer(int screen) const override { return screen == 0 ? top_.data() : bottom_.data(); }
    void setButtons(u32 m) override {
        buttons_ = m;
        if (booted_) twinplay_n64_set_input(buttons_, analogX_, analogY_);
    }
    void setTouch(bool, int, int) override {}
    void setAnalog(int stick, float x, float y) override {
        if (stick != 0) return;
        analogX_ = x; analogY_ = y;
        if (booted_) twinplay_n64_set_input(buttons_, analogX_, analogY_);
    }
    size_t readAudio(s16* out, size_t maxFrames) override {
        if (!booted_ || !out || !maxFrames) return 0;
        return size_t(std::max(0, twinplay_n64_read_audio(out, int(maxFrames))));
    }
    std::vector<u8> saveState() override {
        if (!booted_) return {};
        std::vector<u8> buf(8 * 1024 * 1024);
        const int n = twinplay_n64_save_state(buf.data(), int(buf.size()));
        if (n <= 0) return {};
        buf.resize(size_t(n));
        return buf;
    }
    bool loadState(const std::vector<u8>& d) override {
        return booted_ && !d.empty() && twinplay_n64_load_state(d.data(), int(d.size())) == 0;
    }
    int system() const override { return 6; }
    int screenWidth() const override { return kW; }
    int screenHeight() const override { return kH; }
    int screenCount() const override { return 1; }
    bool frameDrawn() const override { return drawn_; }
    const RomInfo& romInfo() const override { return info_; }
    std::string statusText() const override {
        return booted_ ? "N64 · Mupen64Plus cached interpreter · GLideN64" : "N64";
    }

private:
    std::vector<u8> rom_;
    std::vector<u32> top_, bottom_;
    RomInfo info_{};
    std::string plugins_, saves_;
    u32 buttons_ = 0;
    float analogX_ = 0, analogY_ = 0;
    bool booted_ = false, drawn_ = false;
};

std::unique_ptr<EmulatorCore> createN64Core() { return std::make_unique<N64Core>(); }

} // namespace dscore
