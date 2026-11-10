/* TwinPlay frontend for Mupen64Plus.
   GPL-2.0-or-later. The R4300 is forced to the cached interpreter (no dynarec is
   compiled into the core: the build passes NO_ASM=1). GLideN64 draws into an
   offscreen GL context; this file copies that picture out for SwiftUI.
*/
#include "m64p_common.h"
#include "m64p_config.h"
#include "m64p_frontend.h"
#include "m64p_types.h"

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <condition_variable>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <dlfcn.h>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

static constexpr int kFrontendApi = 0x020106;

extern "C" void twinplay_n64_fill_vidext(m64p_video_extension_functions* v);

std::atomic<int> g_allow_gl{1};

namespace {
std::string g_plugins, g_saves;
std::mutex g_wait_mu, g_frame_mu, g_audio_mu;
std::condition_variable g_wait_cv;
int g_serial = 0;
bool g_alive = false;
int g_save_done = 0;
int g_save_ok = 0;
std::thread g_thread;
bool g_started = false;
int g_armed = 0;

std::vector<uint32_t> g_frame;
int g_fw = 0, g_fh = 0;

std::vector<int16_t> g_audio;
constexpr int kAudioCap = 48000 * 4;

std::atomic<uint32_t> g_buttons{0};
std::atomic<float> g_ax{0}, g_ay{0};

void* g_core = nullptr;
ptr_CoreStartup g_CoreStartup = nullptr;
ptr_CoreDoCommand g_CoreDoCommand = nullptr;
ptr_CoreAttachPlugin g_CoreAttachPlugin = nullptr;
ptr_CoreOverrideVidExt g_CoreOverrideVidExt = nullptr;
ptr_ConfigOpenSection g_ConfigOpenSection = nullptr;
ptr_ConfigSetParameter g_ConfigSetParameter = nullptr;
ptr_CoreErrorMessage g_CoreErrorMessage = nullptr;
void* g_gfx = nullptr;
void* g_audio_plug = nullptr;
void* g_input = nullptr;
void* g_rsp = nullptr;
bool g_rom_open = false;

template <typename T>
T sym(const char* name) { return (T)dlsym(g_core, name); }

void state_cb(void*, m64p_core_param param, int value) {
    if (param == M64CORE_EMU_STATE && value == M64EMU_RUNNING && !g_armed) {
        g_armed = 1;
        int on = 1;
        if (g_CoreDoCommand)
            g_CoreDoCommand(M64CMD_CORE_STATE_SET, M64CORE_SPEED_LIMITER, &on);
        return;
    }
    if (param == M64CORE_STATE_SAVECOMPLETE) {
        std::lock_guard<std::mutex> lock(g_wait_mu);
        g_save_ok = value;
        g_save_done = 1;
        g_wait_cv.notify_all();
        return;
    }
    if (param == M64CORE_EMU_STATE && value == M64EMU_PAUSED) {
        std::lock_guard<std::mutex> lock(g_wait_mu);
        ++g_serial;
        g_wait_cv.notify_all();
    }
}

void debug_cb(void*, int level, const char* message) {
    if (level <= M64MSG_WARNING && message) std::fprintf(stderr, "mupen: %s\n", message);
}

int path_is_plugins_alias(const std::string& dir) {
    if (dir.empty()) return 0;
    auto slash = dir.find_last_of('/');
    const std::string last = slash == std::string::npos ? dir : dir.substr(slash + 1);
    if (last.size() != 7) return 0;
    const char* a = "plugins";
    const char* b = last.c_str();
    for (int i = 0; i < 7; ++i) {
        const unsigned char c = (unsigned char)b[i];
        const char l = (c >= 'A' && c <= 'Z') ? char(c - 'A' + 'a') : char(c);
        if (l != a[i]) return 0;
    }
    return 1;
}

std::string frameworks_dir() {
    if (g_plugins.empty()) return {};
    const auto slash = g_plugins.find_last_of('/');
    if (slash == std::string::npos) return {};
    return g_plugins.substr(0, slash) + "/Frameworks";
}

std::string plugin_path(const char* name) {
    const char* ext = name[0] == 'l' ? "" :
#if defined(__APPLE__)
        ".dylib";
#else
        ".so";
#endif
    const std::string fw = frameworks_dir();
    if (!fw.empty()) return fw + "/" + name + ext;
    return g_plugins + "/" + name + ext;
}

void* open_one(const char* name) {
    const std::string path = plugin_path(name);
    // DEEPBIND: GLideN64's function-pointer globals share names with the core
    // (ConfigOpenSection, VidExt_Init). Without it the core's functions interpose
    // those globals and the plugin crashes on startup.
    int flags = RTLD_NOW;
#ifdef RTLD_DEEPBIND
    flags |= RTLD_DEEPBIND;
#endif
    void* h = dlopen(path.c_str(), flags);
    if (!h && !g_plugins.empty() && !path_is_plugins_alias(g_plugins)) {
        h = dlopen((g_plugins + "/" + name +
#if defined(__APPLE__)
            ".dylib"
#else
            ".so"
#endif
        ).c_str(), flags);
    }
    if (!h) std::fprintf(stderr, "TwinPlay N64: %s (%s)\n", path.c_str(), dlerror());
    return h;
}

int set_int(const char* section, const char* key, int value) {
    m64p_handle sec = nullptr;
    if (!g_ConfigOpenSection || g_ConfigOpenSection(section, &sec) != M64ERR_SUCCESS) return -1;
    return g_ConfigSetParameter(sec, key, M64TYPE_INT, &value) == M64ERR_SUCCESS ? 0 : -1;
}
int set_str(const char* section, const char* key, const char* value) {
    m64p_handle sec = nullptr;
    if (!g_ConfigOpenSection || g_ConfigOpenSection(section, &sec) != M64ERR_SUCCESS) return -1;
    return g_ConfigSetParameter(sec, key, M64TYPE_STRING, value) == M64ERR_SUCCESS ? 0 : -1;
}

void execute_thread() {
    if (g_CoreDoCommand) g_CoreDoCommand(M64CMD_EXECUTE, 0, nullptr);
    std::lock_guard<std::mutex> lock(g_wait_mu);
    g_alive = false;
    ++g_serial;
    g_wait_cv.notify_all();
}

int wait_serial(int seen) {
    std::unique_lock<std::mutex> lock(g_wait_mu);
    g_wait_cv.wait_for(lock, std::chrono::seconds(3), [&] { return g_serial != seen || !g_alive; });
    return g_serial;
}

double g_resample_pos = 1.0;
int16_t g_s0l = 0, g_s0r = 0, g_s1l = 0, g_s1r = 0;

void reset_audio() {
    std::lock_guard<std::mutex> lock(g_audio_mu);
    g_audio.clear();
    g_resample_pos = 1.0;
    g_s0l = g_s0r = g_s1l = g_s1r = 0;
}

void enqueue_stereo(int16_t l, int16_t r) {
    if ((int)g_audio.size() + 2 > kAudioCap) {
        const int overflow = (int)g_audio.size() + 2 - kAudioCap;
        const int drop = overflow + (overflow & 1);
        if (drop >= (int)g_audio.size()) g_audio.clear();
        else g_audio.erase(g_audio.begin(), g_audio.begin() + drop);
    }
    g_audio.push_back(l);
    g_audio.push_back(r);
}

void resample_push(const int16_t* stereo, int frames, int rate) {
    if (!stereo || frames <= 0) return;
    if (rate < 8000 || rate > 96000) rate = 32000;
    const double step = double(rate) / 48000.0;
    if (step <= 0) return;
    std::lock_guard<std::mutex> lock(g_audio_mu);
    for (int i = 0; i < frames; ++i) {
        g_s0l = g_s1l; g_s0r = g_s1r;
        g_s1l = stereo[i * 2]; g_s1r = stereo[i * 2 + 1];
        g_resample_pos -= 1.0;
        while (g_resample_pos < 1.0) {
            const float t = g_resample_pos < 0 ? 0.f : float(g_resample_pos);
            auto mix = [&](int16_t a, int16_t b) { return int16_t(a + (b - a) * t); };
            enqueue_stereo(mix(g_s0l, g_s1l), mix(g_s0r, g_s1r));
            g_resample_pos += step;
        }
    }
}
}

extern "C" {

__attribute__((used, visibility("default")))
void twinplay_n64_store_frame(const uint32_t* bgra, int w, int h) {
    if (!bgra || w <= 0 || h <= 0 || w > 1920 || h > 1080) return;
    std::lock_guard<std::mutex> lock(g_frame_mu);
    g_frame.assign(bgra, bgra + size_t(w) * size_t(h));
    g_fw = w; g_fh = h;
}

__attribute__((used, visibility("default")))
void twinplay_n64_push_samples(const int16_t* stereo, int frames, int rate) {
    resample_push(stereo, frames, rate);
}

__attribute__((used, visibility("default")))
void twinplay_n64_read_pad(int control, uint32_t* word) {
    if (!word) return;
    *word = 0;
    if (control != 0) return;
    const uint32_t b = g_buttons.load();
    auto put = [&](uint32_t mask, int bit) { if (b & mask) *word |= 1u << bit; };
    put(1u << 4, 0); put(1u << 5, 1); put(1u << 7, 2); put(1u << 6, 3);
    put(1u << 3, 4); put(1u << 12, 5); put(1u << 1, 6); put(1u << 0, 7);
    put(1u << 16, 8); put(1u << 15, 9); put(1u << 14, 10); put(1u << 13, 11);
    put(1u << 8, 12); put(1u << 9, 13);
    /* Official N64 stick range is about +/-80. Radial deadzone 0.15, then remap
       the remaining range so a full tilt is 80 and small moves are still possible. */
    float ax = std::max(-1.f, std::min(1.f, g_ax.load()));
    float ay = std::max(-1.f, std::min(1.f, g_ay.load()));
    const float r = std::hypot(ax, ay);
    int x = 0, y = 0;
    constexpr float kDead = 0.15f, kMax = 80.f;
    if (r > kDead) {
        float s = (r - kDead) / (1.f - kDead);
        if (s > 1.f) s = 1.f;
        s = s * kMax / r;
        x = (int)std::lround(ax * s);
        y = (int)std::lround(ay * s);
        if (x > 80) x = 80; if (x < -80) x = -80;
        if (y > 80) y = 80; if (y < -80) y = -80;
    }
    *word |= (uint32_t)(uint8_t)(int8_t)x << 16;
    *word |= (uint32_t)(uint8_t)(int8_t)y << 24;
}

int twinplay_n64_available(void) { return 1; }

void twinplay_n64_set_plugin_dir(const char* dir) { g_plugins = dir ? dir : ""; }
void twinplay_n64_set_save_dir(const char* dir) { g_saves = dir ? dir : ""; }

int twinplay_n64_load(const uint8_t* rom, int size, char* err, int err_len) {
    reset_audio();
    auto fail = [&](const char* m) {
        if (err && err_len > 0) { std::snprintf(err, (size_t)err_len, "%s", m); }
        return -1;
    };
    if (!rom || size < 4096) return fail("N64 game image is too small.");
    if (g_plugins.empty()) return fail("N64 plugin directory is not set.");
    auto try_core = [&](const std::string& dir, const char* file) {
        if (dir.empty()) return false;
        g_core = dlopen((dir + "/" + file).c_str(), RTLD_NOW | RTLD_GLOBAL);
        return g_core != nullptr;
    };
    const char* core_names[] = {
#ifdef __APPLE__
        "libmupen64plus.dylib", "libmupen64plus.so.2",
#else
        "libmupen64plus.so.2", "libmupen64plus.dylib",
#endif
        nullptr
    };
    const std::string fw = frameworks_dir();
    if (!fw.empty()) {
        for (int i = 0; core_names[i] && !g_core; ++i) try_core(fw, core_names[i]);
    }
    if (!g_core && !g_plugins.empty() && !path_is_plugins_alias(g_plugins)) {
        for (int i = 0; core_names[i] && !g_core; ++i) try_core(g_plugins, core_names[i]);
    }
    if (!g_core) {
        std::string msg = std::string("Could not load Mupen64Plus (") + (dlerror() ? dlerror() : "not found") + ").";
        return fail(msg.c_str());
    }
    g_CoreStartup = sym<ptr_CoreStartup>("CoreStartup");
    g_CoreDoCommand = sym<ptr_CoreDoCommand>("CoreDoCommand");
    g_CoreAttachPlugin = sym<ptr_CoreAttachPlugin>("CoreAttachPlugin");
    g_CoreOverrideVidExt = sym<ptr_CoreOverrideVidExt>("CoreOverrideVidExt");
    g_ConfigOpenSection = sym<ptr_ConfigOpenSection>("ConfigOpenSection");
    g_ConfigSetParameter = sym<ptr_ConfigSetParameter>("ConfigSetParameter");
    g_CoreErrorMessage = sym<ptr_CoreErrorMessage>("CoreErrorMessage");
    if (!g_CoreStartup || !g_CoreDoCommand || !g_CoreAttachPlugin || !g_CoreOverrideVidExt) {
        return fail("Mupen64Plus is missing the frontend API.");
    }
    const std::string cfg = g_saves.empty() ? g_plugins : g_saves;
    if (g_CoreStartup(kFrontendApi, cfg.c_str(), cfg.c_str(), nullptr, debug_cb, nullptr, state_cb) != M64ERR_SUCCESS) {
        return fail("Mupen64Plus CoreStartup failed.");
    }
    m64p_video_extension_functions vid{};
    twinplay_n64_fill_vidext(&vid);
    g_CoreOverrideVidExt(&vid);
    set_int("Core", "R4300Emulator", 1);
    m64p_handle sec = nullptr;
    if (g_ConfigOpenSection && g_ConfigOpenSection("Core", &sec) == M64ERR_SUCCESS) {
        int off = 0, one = 1;
        g_ConfigSetParameter(sec, "OnScreenDisplay", M64TYPE_BOOL, &off);
        g_ConfigSetParameter(sec, "NoCompiledJump", M64TYPE_BOOL, &one);
    }
    if (!g_saves.empty()) {
        set_str("Core", "SaveSRAMPath", g_saves.c_str());
        set_str("Core", "SaveStatePath", g_saves.c_str());
    }
    const m64p_error opened = g_CoreDoCommand(M64CMD_ROM_OPEN, size, (void*)rom);
    if (opened != M64ERR_SUCCESS) {
        const char* why = g_CoreErrorMessage ? g_CoreErrorMessage(opened) : "ROM open failed";
        return fail(why ? why : "ROM open failed");
    }
    g_rom_open = true;
    g_gfx = open_one("mupen64plus-video-GLideN64");
    g_audio_plug = open_one("mupen64plus-audio-twinplay");
    g_input = open_one("mupen64plus-input-twinplay");
    g_rsp = open_one("mupen64plus-rsp-hle");
    if (!g_gfx || !g_audio_plug || !g_input || !g_rsp) return fail("An N64 plugin failed to load. See the log.");
    using startup_t = m64p_error (*)(m64p_dynlib_handle, void*, void (*)(void*, int, const char*));
    for (void* plug : {g_gfx, g_audio_plug, g_input, g_rsp}) {
        auto start = (startup_t)dlsym(plug, "PluginStartup");
        if (start && start(g_core, nullptr, debug_cb) != M64ERR_SUCCESS) return fail("A plugin refused to start.");
    }
    const m64p_error gfx_err = g_CoreAttachPlugin(M64PLUGIN_GFX, g_gfx);
    if (gfx_err != M64ERR_SUCCESS) {
        char buf[160];
        std::snprintf(buf, sizeof buf, "Could not attach GLideN64 (%d%s%s).", (int)gfx_err,
                      g_CoreErrorMessage ? ": " : "", g_CoreErrorMessage ? g_CoreErrorMessage(gfx_err) : "");
        return fail(buf);
    }
    if (g_CoreAttachPlugin(M64PLUGIN_AUDIO, g_audio_plug) != M64ERR_SUCCESS) return fail("Could not attach the N64 audio plugin.");
    if (g_CoreAttachPlugin(M64PLUGIN_INPUT, g_input) != M64ERR_SUCCESS) return fail("Could not attach the N64 input plugin.");
    if (g_CoreAttachPlugin(M64PLUGIN_RSP, g_rsp) != M64ERR_SUCCESS) return fail("Could not attach the HLE RSP plugin.");
    /* Cheap, reliable defaults for an iPhone: native 640x480, no MSAA / FXAA /
       threaded GL, keep FB emulation (GoldenEye needs it) but drop expensive extras. */
    set_int("Video-General", "ScreenWidth", 640);
    set_int("Video-General", "ScreenHeight", 480);
    set_int("Video-General", "VerticalSync", 0);
    set_int("Video-GLideN64", "UseNativeResolutionFactor", 1);
    set_int("Video-GLideN64", "MultiSampling", 0);
    set_int("Video-GLideN64", "FXAA", 0);
    set_int("Video-GLideN64", "ThreadedVideo", 0);
    set_int("Video-GLideN64", "AsyncShaderCompilation", 0);
    set_int("Video-GLideN64", "EnableFBEmulation", 1);
    set_int("Video-GLideN64", "EnableCopyColorToRDRAM", 1);
    set_int("Video-GLideN64", "EnableCopyDepthToRDRAM", 0);
    set_int("Video-GLideN64", "EnableCopyAuxToRDRAM", 0);
    set_int("Video-GLideN64", "EnableNativeResTexrects", 0);
    set_int("Core", "CountPerOp", 0);
    if (g_ConfigOpenSection && g_ConfigOpenSection("Core", &sec) == M64ERR_SUCCESS) {
        int off = 0, on = 1;
        g_ConfigSetParameter(sec, "DisableExtraMem", M64TYPE_BOOL, &off);
        g_ConfigSetParameter(sec, "EnableSpeedLimiter", M64TYPE_BOOL, &on);
    }
    g_alive = true;
    return 0;
}

void twinplay_n64_set_paused(int paused) {
    g_allow_gl.store(paused ? 0 : 1, std::memory_order_release);
    if (!g_CoreDoCommand || !g_started) return;
    g_CoreDoCommand(paused ? M64CMD_PAUSE : M64CMD_RESUME, 0, nullptr);
}

int twinplay_n64_gl_allowed(void) {
    return g_allow_gl.load(std::memory_order_acquire);
}

void twinplay_n64_unload(void) {
    g_allow_gl.store(0, std::memory_order_release);
    reset_audio();
    if (g_CoreDoCommand && g_started) {
        g_CoreDoCommand(M64CMD_PAUSE, 0, nullptr);
        g_CoreDoCommand(M64CMD_STOP, 0, nullptr);
    }
    if (g_thread.joinable()) g_thread.join();
    g_started = false;
    g_armed = 0;
    g_alive = false;
    if (g_core && g_rom_open && g_CoreDoCommand) g_CoreDoCommand(M64CMD_ROM_CLOSE, 0, nullptr);
    g_rom_open = false;
    auto close = [](void*& h) { if (h) { dlclose(h); h = nullptr; } };
    close(g_gfx); close(g_audio_plug); close(g_input); close(g_rsp); close(g_core);
    g_CoreStartup = nullptr;
    g_CoreDoCommand = nullptr;
    g_CoreAttachPlugin = nullptr;
    g_CoreOverrideVidExt = nullptr;
    g_ConfigOpenSection = nullptr;
    g_ConfigSetParameter = nullptr;
    g_CoreErrorMessage = nullptr;
}

void twinplay_n64_reset(void) {
    if (g_CoreDoCommand) g_CoreDoCommand(M64CMD_RESET, 0, nullptr);
}

void twinplay_n64_run_frame(void) {
    if (!g_rom_open || !g_CoreDoCommand) return;
    /* Free-run the core on its own thread with Mupen's VI speed limiter
       (NTSC 60 / PAL 50). The host FramePacer only copies the latest
       completed swap; ADVANCE_FRAME plus a disabled limiter left light
       games (SM64) unthrottled. */
    if (!g_started) {
        g_started = true;
        g_allow_gl.store(1, std::memory_order_release);
        int on = 1;
        g_CoreDoCommand(M64CMD_CORE_STATE_SET, M64CORE_SPEED_LIMITER, &on);
        g_thread = std::thread(execute_thread);
    }
}

void twinplay_n64_set_input(uint32_t buttons, float x, float y) {
    g_buttons.store(buttons);
    g_ax.store(x);
    g_ay.store(y);
}

int twinplay_n64_copy_frame(uint32_t* dst, int cap, int* w, int* h) {
    std::lock_guard<std::mutex> lock(g_frame_mu);
    if (w) *w = g_fw;
    if (h) *h = g_fh;
    const int n = g_fw * g_fh;
    if (n <= 0) return 0;
    if (!dst) return n; /* size query */
    if (n > cap) return 0;
    std::memcpy(dst, g_frame.data(), size_t(n) * 4);
    return n;
}

int twinplay_n64_read_audio(int16_t* dst, int max_frames) {
    if (!dst || max_frames <= 0) return 0;
    std::lock_guard<std::mutex> lock(g_audio_mu);
    const int have = (int)g_audio.size() / 2;
    const int n = have < max_frames ? have : max_frames;
    std::memcpy(dst, g_audio.data(), size_t(n) * 4);
    g_audio.erase(g_audio.begin(), g_audio.begin() + n * 2);
    return n;
}

static int advance_for_state(const char* path, int load) {
    if (!g_CoreDoCommand || !g_started) return -1;
    {
        std::lock_guard<std::mutex> lock(g_wait_mu);
        g_save_done = 0;
    }
    const int seen = g_serial;
    g_CoreDoCommand(load ? M64CMD_STATE_LOAD : M64CMD_STATE_SAVE, 1, (void*)path);
    g_CoreDoCommand(M64CMD_ADVANCE_FRAME, 0, nullptr);
    std::unique_lock<std::mutex> lock(g_wait_mu);
    g_wait_cv.wait_for(lock, std::chrono::seconds(3), [&] { return g_save_done || g_serial != seen; });
    return g_save_ok ? 0 : -1;
}

int twinplay_n64_save_state(uint8_t* dst, int cap) {
    const std::string path = (g_saves.empty() ? "/tmp" : g_saves) + "/twinplay-n64.st";
    if (advance_for_state(path.c_str(), 0) != 0) return -1;
    FILE* f = std::fopen(path.c_str(), "rb");
    if (!f) return -1;
    const int n = (int)std::fread(dst, 1, (size_t)cap, f);
    std::fclose(f);
    return n > 0 ? n : -1;
}

int twinplay_n64_load_state(const uint8_t* src, int size) {
    const std::string path = (g_saves.empty() ? "/tmp" : g_saves) + "/twinplay-n64-in.st";
    FILE* f = std::fopen(path.c_str(), "wb");
    if (!f) return -1;
    std::fwrite(src, 1, (size_t)size, f);
    std::fclose(f);
    return advance_for_state(path.c_str(), 1);
}

void twinplay_n64_title(char* dst, int cap) {
    if (!dst || cap <= 0) return;
    dst[0] = 0;
    if (!g_CoreDoCommand) return;
    m64p_rom_header header{};
    if (g_CoreDoCommand(M64CMD_ROM_GET_HEADER, (int)sizeof header, &header) != M64ERR_SUCCESS) return;
    int n = 0;
    for (; n < 20 && n + 1 < cap; ++n) {
        const char c = header.Name[n];
        if (c == 0) break;
        dst[n] = (c >= 32 && c < 127) ? c : ' ';
    }
    while (n > 0 && dst[n - 1] == ' ') --n;
    dst[n] = 0;
}

} // extern "C"
