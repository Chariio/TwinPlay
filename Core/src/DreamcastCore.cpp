// Copyright (c) 2026 Charlie Rodriguez Garcia.
// Dreamcast session. The CPU and GPU live in Flycast (GPL-2.0-or-later), loaded
// in-process from the libretro dylib built by scripts/build-flycast.sh.
// iOS builds of that dylib are interpreter-only (no dynarec, no JIT).
#include "dscore/EmulatorCore.hpp"
#include "../dreamcast/twinplay_flycast.h"
#include <algorithm>
#include <cstring>

namespace dscore {
namespace {
constexpr int kW = 256, kH = 192;

bool discExtension(const std::string& path) {
    auto dot = path.find_last_of('.');
    if (dot == std::string::npos) return false;
    std::string e = path.substr(dot + 1);
    for (char& c : e) if (c >= 'A' && c <= 'Z') c = char(c - 'A' + 'a');
    return e == "cdi" || e == "gdi" || e == "chd" || e == "cue" || e == "zip";
}
}

bool isDreamcastDiscPath(const std::string& path) { return discExtension(path); }

class DreamcastCore final : public EmulatorCore {
public:
    DreamcastCore() { top_.assign(kW * kH, 0xFF000000u); bottom_.assign(kW * kH, 0xFF000000u); }
    ~DreamcastCore() override { shutDown(); }
    void shutDown() override {
        if (!booted_) return;
        twinplay_dc_unload();
        booted_ = false;
    }
    bool prefersPathLoad() const override { return true; }
    void setDataPath(const std::string& p) override { data_ = p; twinplay_dc_set_dirs(data_.c_str(), saves_.c_str()); }
    void setSaveDirectory(const std::string& p) override { saves_ = p; twinplay_dc_set_dirs(data_.c_str(), saves_.c_str()); }
    bool setLLEBIOS(const std::vector<u8>& bios9, const std::vector<u8>&, const std::vector<u8>&, bool) override {
        // A non-empty bios9 means the user imported dc_boot.bin. Empty keeps HLE.
        hle_ = bios9.empty();
        twinplay_dc_set_hle(hle_ ? 1 : 0);
        lle_ = !hle_;
        return true;
    }
    bool usingLLEBIOS() const override { return lle_; }

    bool loadROM(const u8*, size_t, std::string& error) override {
        error = "Dreamcast discs are loaded from a file path (.cdi, .gdi, .chd, .cue or .zip).";
        return false;
    }
    bool loadROMPath(const std::string& path, std::string& error) override {
        if (!isDreamcastDiscPath(path)) {
            error = "This is not a Dreamcast disc (.cdi, .gdi, .chd, .cue or .zip).";
            return false;
        }
        if (!twinplay_dc_available()) {
            error = "The Dreamcast core is not linked into this build. On a Mac, run scripts/build-flycast.sh and rebuild.";
            return false;
        }
        twinplay_dc_set_dirs(data_.c_str(), saves_.c_str());
        twinplay_dc_set_hle(hle_ ? 1 : 0);
        char err[512] = {};
        if (twinplay_dc_load(path.c_str(), err, int(sizeof err)) != 0) {
            error = err[0] ? err : "Flycast could not open this disc.";
            return false;
        }
        info_ = {};
        auto slash = path.find_last_of('/');
        std::string file = slash == std::string::npos ? path : path.substr(slash + 1);
        auto dot = file.find_last_of('.');
        info_.title = dot == std::string::npos ? file : file.substr(0, dot);
        info_.gameCode = "DC";
        booted_ = true;
        return true;
    }
    void reset() override { if (booted_) twinplay_dc_reset(); }
    void runFrame() override {
        if (!booted_) return;
        twinplay_dc_set_input(buttons_, analogX_, analogY_, lt_, rt_);
        twinplay_dc_run_frame();
        int w = 0, h = 0;
        twinplay_dc_copy_frame(nullptr, 0, &w, &h);
        if (w > 0 && h > 0 && w <= 1920 && h <= 1088) {
            std::vector<u32> native((size_t)w * (size_t)h);
            const int n = twinplay_dc_copy_frame(native.data(), int(native.size()), &w, &h);
            if (n > 0 && w > 0 && h > 0) scaleNearest(native.data(), w, h, top_.data(), kW, kH);
        }
        drawn_ = true;
    }
    const u32* framebuffer(int screen) const override { return screen == 0 ? top_.data() : bottom_.data(); }
    void setButtons(u32 m) override {
        buttons_ = m;
        if (booted_) twinplay_dc_set_input(buttons_, analogX_, analogY_, lt_, rt_);
    }
    void setTouch(bool, int, int) override {}
    void setAnalog(int stick, float x, float y) override {
        if (stick != 0) return;
        analogX_ = x;
        analogY_ = y;
        if (booted_) twinplay_dc_set_input(buttons_, analogX_, analogY_, lt_, rt_);
    }
    size_t readAudio(s16* out, size_t maxFrames) override {
        if (!booted_ || !out || !maxFrames) return 0;
        return size_t(std::max(0, twinplay_dc_read_audio(out, int(maxFrames))));
    }
    std::vector<u8> saveState() override {
        if (!booted_) return {};
        std::vector<u8> buf(16 * 1024 * 1024);
        const int n = twinplay_dc_save_state(buf.data(), int(buf.size()));
        if (n <= 0) return {};
        buf.resize(size_t(n));
        return buf;
    }
    bool loadState(const std::vector<u8>& d) override {
        return booted_ && !d.empty() && twinplay_dc_load_state(d.data(), int(d.size())) == 0;
    }
    int system() const override { return 8; }
    int screenWidth() const override { return kW; }
    int screenHeight() const override { return kH; }
    int screenCount() const override { return 1; }
    bool frameDrawn() const override { return drawn_; }
    const RomInfo& romInfo() const override { return info_; }
    std::string statusText() const override {
        if (!booted_) return "Dreamcast";
        // cpu_mode is "interpreter" on iOS (the dylib is built with TARGET_NO_REC) and "dynarec" on Mac.
        return std::string("Dreamcast · Flycast ") + twinplay_dc_cpu_mode() + " · " + twinplay_dc_renderer();
    }

private:
    std::vector<u32> top_, bottom_;
    RomInfo info_{};
    std::string data_, saves_;
    u32 buttons_ = 0;
    float analogX_ = 0, analogY_ = 0, lt_ = 0, rt_ = 0;
    bool booted_ = false, drawn_ = false, hle_ = true, lle_ = false;
};

std::unique_ptr<EmulatorCore> createDreamcastCore() { return std::make_unique<DreamcastCore>(); }

} // namespace dscore
