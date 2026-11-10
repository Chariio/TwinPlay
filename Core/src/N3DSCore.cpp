// Copyright (c) 2026 Charlie Rodriguez Garcia. All rights reserved.
// TwinPlay's 3DS session. The core is Azahar (FastInterp, no dynarmic) when
// scripts/build-n64-3ds.sh has produced libtwinplay_3ds. Two screens are scaled
// into the same 256x192 pair the DS presenter already draws.
#include "dscore/EmulatorCore.hpp"
#include "dscore/ShaderCacheFlag.hpp"
#include <algorithm>
#include <cstring>
#include <fstream>

extern "C" {
int twinplay_3ds_available(void);
void twinplay_3ds_set_data_dir(const char* dir);
void twinplay_3ds_set_save_dir(const char* dir);
int twinplay_3ds_load(const char* path, char* err, int err_len);
void twinplay_3ds_unload(void);
void twinplay_3ds_reset(void);
void twinplay_3ds_run_frame(void);
void twinplay_3ds_set_input(uint32_t buttons, float cx, float cy, float sx, float sy, int touch, int tx, int ty);
int twinplay_3ds_copy_frame(int screen, uint32_t* dst, int cap, int* w, int* h);
uint64_t twinplay_3ds_frame_count(void);
int twinplay_3ds_using_vulkan(void);
int twinplay_3ds_read_audio(int16_t* dst, int max_frames);
int twinplay_3ds_save_state(uint8_t* dst, int cap);
int twinplay_3ds_load_state(const uint8_t* src, int size);
const char* twinplay_3ds_last_error(void);
}

namespace dscore {
namespace {
constexpr int kW = 256, kH = 192;

void present(const u32* src, int w, int h, std::vector<u32>& dst, bool letter) {
    if (!src || w <= 0 || h <= 0) return;
    if (letter) letterboxNearest(src, w, h, dst.data(), kW, kH);
    else scaleNearest(src, w, h, dst.data(), kW, kH);
}

void clearFlagForTitle(const std::string& dataDir, u64 titleId) {
    const std::string home = defaultAzaharUserDir();
    if (!home.empty()) clearStaleShaderCacheFlag(home, titleId);
    // The live core stores shaders under Documents/Azahar. Also clear a custom
    // user dir if the host pointed one at an Azahar folder (never Frameworks).
    if (!dataDir.empty() && isAzaharUserDir(dataDir) && dataDir != home)
        clearStaleShaderCacheFlag(dataDir, titleId);
}

void clearFlagForPathOrError(const std::string& dataDir, const std::string& path,
                             const char* errorText) {
    if (auto id = titleIdFrom3DSPath(path)) clearFlagForTitle(dataDir, *id);
    if (errorText && errorText[0]) {
        if (auto id = titleIdFromCoreError(errorText)) clearFlagForTitle(dataDir, *id);
    }
}
}

class N3DSCore final : public EmulatorCore {
public:
    N3DSCore() { top_.assign(kW * kH, 0xFF000000u); bottom_.assign(kW * kH, 0xFF000000u); }
    ~N3DSCore() override { shutDown(); }
    void shutDown() override {
        if (!booted_) return;
        twinplay_3ds_unload();
        booted_ = false;
    }

    bool prefersPathLoad() const override { return true; }
    void setDataPath(const std::string& p) override { data_ = p; twinplay_3ds_set_data_dir(p.c_str()); }
    void setSaveDirectory(const std::string& p) override { saves_ = p; twinplay_3ds_set_save_dir(p.c_str()); }

    bool loadROM(const u8* data, size_t size, std::string& error) override {
        if (!is3DSImage(data, size)) { error = "This is not a 3DS game image (.3ds, .cci or .cxi)."; return false; }
        error = "A 3DS game has to be opened from its file. Import the .3ds, .cci or .cxi and open it from the library.";
        return false;
    }
    bool loadROMPath(const std::string& path, std::string& error) override {
        std::ifstream probe(path, std::ios::binary);
        if (!probe) { error = "Could not open the game file."; return false; }
        std::vector<u8> head(0x200);
        probe.read(reinterpret_cast<char*>(head.data()), std::streamsize(head.size()));
        head.resize(size_t(probe.gcount()));
        if (!is3DSImage(head.data(), head.size())) {
            error = "This is not a 3DS game image (.3ds, .cci or .cxi).";
            return false;
        }
        if (!twinplay_3ds_available()) {
            error = "The 3DS core is not linked into this build. On a Mac, run scripts/build-n64-3ds.sh and rebuild. "
                    "Encrypted games also need keys you dumped yourself, placed in the app's 3DS user folder. "
                    "TwinPlay never includes those keys.";
            return false;
        }
        path_ = path;
        info_ = {};
        info_.title = path;
        auto slash = path.find_last_of("/\\");
        if (slash != std::string::npos) info_.title = path.substr(slash + 1);
        info_.gameCode = "3DS";
        char err[768] = {};
        twinplay_3ds_set_data_dir(data_.c_str());
        twinplay_3ds_set_save_dir(saves_.c_str());
        // Drop a leftover `{titleId}-loading.flag` before Load so GrantGpuRight
        // does not raise ErrorShaderCacheCrash. The disk shader cache stays on.
        if (auto id = titleIdFrom3DSPath(path)) clearFlagForTitle(data_, *id);
        cache_flag_retried_ = false;
        auto tryLoad = [&]() -> bool {
            std::memset(err, 0, sizeof err);
            return twinplay_3ds_load(path.c_str(), err, int(sizeof err)) == 0;
        };
        if (!tryLoad()) {
            if (titleIdFromCoreError(err[0] ? err : "")) {
                clearFlagForPathOrError(data_, path, err);
                cache_flag_retried_ = true;
                if (!tryLoad()) {
                    error = err[0] ? err : "The 3DS core could not open this game.";
                    return false;
                }
            } else {
                error = err[0] ? err : "The 3DS core could not open this game.";
                return false;
            }
        }
        booted_ = true;
        drawn_ = false;
        frames_seen_ = 0;
        error_.clear();
        return true;
    }
    void reset() override { if (booted_) twinplay_3ds_reset(); }
    void runFrame() override {
        if (!booted_) return;
        pushInput();
        twinplay_3ds_run_frame();
        if (const char* e = twinplay_3ds_last_error(); e && e[0]) {
            if (!cache_flag_retried_ && titleIdFromCoreError(e)) {
                cache_flag_retried_ = true;
                clearFlagForPathOrError(data_, path_, e);
                twinplay_3ds_unload();
                booted_ = false;
                char err[768] = {};
                if (twinplay_3ds_load(path_.c_str(), err, int(sizeof err)) == 0) {
                    booted_ = true;
                    error_.clear();
                    // The pre-layout archive does not export present_ready. The
                    // host keeps driving the surface; just restart the session.
                    twinplay_3ds_run_frame();
                    return;
                }
                error_ = err[0] ? err : e;
                booted_ = false;
                return;
            }
            error_ = e;
            booted_ = false;
            return;
        }
        if (twinplay_3ds_using_vulkan()) {
            const uint64_t n = twinplay_3ds_frame_count();
            drawn_ = n != frames_seen_;
            frames_seen_ = n;
        } else {
            std::vector<u32> buf(400 * 240);
            int w = 0, h = 0;
            if (twinplay_3ds_copy_frame(0, buf.data(), int(buf.size()), &w, &h) > 0) present(buf.data(), w, h, top_, true);
            w = h = 0;
            if (twinplay_3ds_copy_frame(1, buf.data(), int(buf.size()), &w, &h) > 0) present(buf.data(), w, h, bottom_, false);
            drawn_ = true;
        }
    }
    const u32* framebuffer(int screen) const override { return screen == 0 ? top_.data() : bottom_.data(); }
    void setButtons(u32 m) override { buttons_ = m; if (booted_) pushInput(); }
    void setTouch(bool down, int x, int y) override { touch_ = down; touchX_ = x; touchY_ = y; if (booted_) pushInput(); }
    void setAnalog(int stick, float x, float y) override {
        if (stick == 0) { circleX_ = x; circleY_ = y; }
        else { cStickX_ = x; cStickY_ = y; }
        if (booted_) pushInput();
    }
    void pushInput() {
        const int tx = std::clamp(touchX_ * 320 / 256, 0, 319);
        const int ty = std::clamp(touchY_ * 240 / 192, 0, 239);
        twinplay_3ds_set_input(buttons_, circleX_, circleY_, cStickX_, cStickY_, touch_ ? 1 : 0, tx, ty);
    }
    size_t readAudio(s16* out, size_t maxFrames) override {
        if (!booted_ || !out || !maxFrames) return 0;
        return size_t(std::max(0, twinplay_3ds_read_audio(out, int(maxFrames))));
    }
    std::vector<u8> saveState() override {
        if (!booted_) return {};
        std::vector<u8> buf(32 * 1024 * 1024);
        const int n = twinplay_3ds_save_state(buf.data(), int(buf.size()));
        if (n <= 0) return {};
        buf.resize(size_t(n));
        return buf;
    }
    bool loadState(const std::vector<u8>& d) override {
        return booted_ && !d.empty() && twinplay_3ds_load_state(d.data(), int(d.size())) == 0;
    }
    int system() const override { return 7; }
    int screenCount() const override { return 2; }
    bool frameDrawn() const override { return drawn_; }
    const RomInfo& romInfo() const override { return info_; }
    std::string statusText() const override {
        if (!error_.empty()) return error_;
        return booted_ ? "3DS · Azahar FastInterp (no JIT)" : "3DS";
    }

private:
    std::vector<u32> top_, bottom_;
    RomInfo info_{};
    std::string path_, data_, saves_, error_;
    u32 buttons_ = 0;
    float circleX_ = 0, circleY_ = 0, cStickX_ = 0, cStickY_ = 0;
    bool touch_ = false, booted_ = false, drawn_ = false, cache_flag_retried_ = false;
    uint64_t frames_seen_ = 0;
    int touchX_ = 0, touchY_ = 0;
};

std::unique_ptr<EmulatorCore> createN3DSCore() { return std::make_unique<N3DSCore>(); }

} // namespace dscore
