/* Copyright (c) 2026 Charlie Rodriguez Garcia.
   SPDX-License-Identifier: GPL-3.0-or-later
   GameCube session. The CPU and GPU are Dolphin's, behind twinplay_gc.h.
   The default app links the stub. The real host is built by scripts/build-dolphin.sh. */
#include "dscore/EmulatorCore.hpp"
#include "twinplay_gc.h"

#include <algorithm>
#include <cstring>
#include <vector>

namespace dscore {
namespace {
constexpr int kW = 256, kH = 192;
}

class GameCubeCore final : public EmulatorCore {
public:
    GameCubeCore() {
        top_.assign(kW * kH, 0xFF000000u);
        bottom_.assign(kW * kH, 0xFF000000u);
    }
    ~GameCubeCore() override { shutDown(); }

    void shutDown() override {
        if (!booted_) return;
        twinplay_gc_unload();
        booted_ = false;
    }

    void setSaveDirectory(const std::string& p) override {
        saves_ = p;
        twinplay_gc_set_user_dir(p.c_str());
    }

    bool prefersPathLoad() const override { return true; }

    bool loadROM(const u8*, size_t, std::string& error) override {
        error = "GameCube games are opened from their file, not copied into memory.";
        return false;
    }

    bool loadROMPath(const std::string& path, std::string& error) override {
        if (path.empty()) { error = "No GameCube game was selected."; return false; }
        if (!twinplay_gc_available()) {
            error = "The GameCube core is not linked into this build. On a Mac, run scripts/build-dolphin.sh and rebuild.";
            return false;
        }
        if (!saves_.empty()) twinplay_gc_set_user_dir(saves_.c_str());
        char err[512] = {};
        if (twinplay_gc_load_path(path.c_str(), err, int(sizeof err)) != 0) {
            error = err[0] ? err : "Dolphin could not boot this game.";
            return false;
        }
        info_ = {};
        info_.title = path;
        info_.gameCode = "GC";
        booted_ = true;
        drawn_ = false;
        return true;
    }

    void reset() override { if (booted_) twinplay_gc_reset(); }

    void runFrame() override {
        if (!booted_) return;
        twinplay_gc_set_input(buttons_, stickX_, stickY_, cX_, cY_);
        twinplay_gc_run_frame();
        int w = 0, h = 0;
        twinplay_gc_copy_frame(nullptr, 0, &w, &h);
        if (w > 0 && h > 0 && w <= 1920 && h <= 1080) {
            std::vector<u32> native(size_t(w) * size_t(h));
            const int n = twinplay_gc_copy_frame(native.data(), int(native.size()), &w, &h);
            if (n > 0 && w > 0 && h > 0) scaleNearest(native.data(), w, h, top_.data(), kW, kH);
        }
        drawn_ = true;
    }

    const u32* framebuffer(int screen) const override { return screen == 0 ? top_.data() : bottom_.data(); }

    void setButtons(u32 m) override { buttons_ = m; }
    void setTouch(bool, int, int) override {}
    void setAnalog(int stick, float x, float y) override {
        if (stick == 0) { stickX_ = x; stickY_ = y; }
        else { cX_ = x; cY_ = y; }
    }

    size_t readAudio(s16* out, size_t maxFrames) override {
        if (!booted_ || !out || !maxFrames) return 0;
        return size_t(std::max(0, twinplay_gc_read_audio(out, int(maxFrames))));
    }

    int system() const override { return 8; }
    int screenWidth() const override { return kW; }
    int screenHeight() const override { return kH; }
    int screenCount() const override { return 1; }
    bool frameDrawn() const override { return drawn_; }
    const RomInfo& romInfo() const override { return info_; }
    std::string statusText() const override {
        if (!booted_) return "GameCube";
        const char* cpu = twinplay_gc_cpu_name();
        const char* gpu = twinplay_gc_backend_name();
        std::string s = "GameCube · Dolphin";
        if (cpu && cpu[0]) { s += " · "; s += cpu; }
        if (gpu && gpu[0]) { s += " · "; s += gpu; }
        if (twinplay_gc_uses_jit()) s += " · JIT";
        else s += " · no JIT";
        return s;
    }

private:
    std::vector<u32> top_, bottom_;
    RomInfo info_{};
    std::string saves_;
    u32 buttons_ = 0;
    float stickX_ = 0, stickY_ = 0, cX_ = 0, cY_ = 0;
    bool booted_ = false, drawn_ = false;
};

std::unique_ptr<EmulatorCore> createGameCubeCore() { return std::make_unique<GameCubeCore>(); }

}  // namespace dscore
