/* TwinPlay frontend for Azahar (Citra fork), GPL-3.0-or-later.
   FastInterp only: use_cpu_jit is forced off and dynarmic is not linked.
   Vulkan (MoltenVK / Metal) is the default renderer. The software renderer
   remains a fallback if GPU init fails. Software frames can still be copied
   out for the existing DS presenter. */
#include <algorithm>
#include <atomic>
#include <chrono>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <exception>
#include <functional>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#include "common/file_util.h"
#include "common/logging/backend.h"
#include "common/logging/filter.h"
#include "common/logging/log.h"
#include "common/settings.h"
#include "core/core.h"
#include "core/frontend/applets/default_applets.h"
#include "core/frontend/emu_window.h"
#include "core/frontend/input.h"
#include "core/hle/service/service.h"
#include "core/savestate.h"
#include "video_core/gpu.h"
#include "video_core/rasterizer_interface.h"
#include "video_core/renderer_software/renderer_software.h"
#include "audio_core/sink.h"
#include "audio_core/sink_details.h"

namespace {

constexpr int kTopW = 400, kTopH = 240, kBotW = 320, kBotH = 240;
constexpr int kAudioRate = 32728;
constexpr int kAudioFramesCap = 48000; // 1 s of stereo frames at 48 kHz

std::string g_data, g_saves;
std::atomic<uint32_t> g_buttons{0};
std::atomic<float> g_cx{0}, g_cy{0}, g_sx{0}, g_sy{0};
std::atomic<int> g_touch{0}, g_tx{0}, g_ty{0};
std::atomic<int> g_audio_w{0}, g_audio_r{0}; // frame indices into the stereo ring
alignas(64) int16_t g_audio_ring[kAudioFramesCap * 2]{};
double g_resample_pos = 1.0;
int16_t g_s0l = 0, g_s0r = 0, g_s1l = 0, g_s1r = 0;
struct FrameSlot { std::vector<uint32_t> px; int w = 0, h = 0; };
FrameSlot g_top_tb[3], g_bot_tb[3];
std::atomic<int> g_pub{0};
int g_write = 1;
std::string g_error;
bool g_failed = false;
std::atomic<bool> g_emu_run{false};
std::atomic<bool> g_emu_pause{false};
std::thread g_emu_thread;
bool g_booted = false;
bool g_log_on = false;
bool g_using_vulkan = false;
std::atomic<uint64_t> g_frames{0};
std::atomic<int> g_cpu_clock{100};
std::atomic<int> g_fb_w{0}, g_fb_h{0};
std::atomic<int> g_top_x{0}, g_top_y{0}, g_top_rw{0}, g_top_rh{0};
std::atomic<int> g_bot_x{0}, g_bot_y{0}, g_bot_rw{0}, g_bot_rh{0};
std::atomic<uint32_t> g_layout_gen{0};
std::atomic<double> g_ft_last{0}, g_ft_max{0}, g_ft_p95{0};
bool g_shaders_loaded = false;
std::atomic<int> g_present_ready{0};

extern "C" void* twinplay_3ds_metal_layer(void);
extern "C" void twinplay_3ds_set_drawable_size(int w, int h, float scale);

void reset_audio() {
    g_audio_r.store(0, std::memory_order_relaxed);
    g_audio_w.store(0, std::memory_order_relaxed);
    g_resample_pos = 1.0;
    g_s0l = g_s0r = g_s1l = g_s1r = 0;
}

void enqueue_stereo(int16_t l, int16_t r) {
    int w = g_audio_w.load(std::memory_order_relaxed);
    int ridx = g_audio_r.load(std::memory_order_acquire);
    int next = w + 1;
    if (next >= kAudioFramesCap) next = 0;
    if (next == ridx) {
        int nr = ridx + 1;
        if (nr >= kAudioFramesCap) nr = 0;
        g_audio_r.store(nr, std::memory_order_release);
    }
    g_audio_ring[w * 2] = l;
    g_audio_ring[w * 2 + 1] = r;
    g_audio_w.store(next, std::memory_order_release);
}

void resample_push(const int16_t* stereo, int frames, int rate) {
    if (!stereo || frames <= 0) return;
    if (rate < 8000 || rate > 96000) rate = kAudioRate;
    const double step = double(rate) / 48000.0;
    if (step <= 0) return;
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

void apply_screen_layout() {
    // Native stacked framebuffer only: 400x240 top + 320x240 bottom (x=40) in
    // a 400x480 image. The host composites those source rects into the skin
    // cutouts. CustomLayout with host cutouts overflowed the swapchain and
    // presented black; PortraitTopFullWidth is 400x540 and was a mismatch.
    Settings::values.layout_option.SetValue(Settings::LayoutOption::Default);
    Settings::values.portrait_layout_option.SetValue(Settings::PortraitLayoutOption::PortraitOriginal);
    Settings::values.screen_gap.SetValue(0);
}

class TwinPlaySink final : public AudioCore::Sink {
public:
    explicit TwinPlaySink(std::string_view) {}
    unsigned int GetNativeSampleRate() const override { return AudioCore::native_sample_rate; }
    void SetCallback(std::function<void(s16*, std::size_t)>) override {}
    bool ImmediateSubmission() override { return true; }
    void PushSamples(const void* data, std::size_t num_samples) override {
        if (!data || num_samples == 0) return;
        resample_push(static_cast<const int16_t*>(data), int(num_samples),
                      int(AudioCore::native_sample_rate));
    }
};

std::unique_ptr<AudioCore::Sink> make_twinplay_sink(std::string_view device) {
    return std::make_unique<TwinPlaySink>(device);
}

class TwinPlayWindow final : public Frontend::EmuWindow {
public:
    TwinPlayWindow(bool vulkan) {
        Frontend::EmuWindow::WindowConfig cfg{};
        cfg.res_width = kTopW;
        cfg.res_height = kTopH + kBotH;
        SetConfig(cfg);
        if (vulkan) {
            window_info.type = Frontend::WindowSystemType::MacOS;
            window_info.render_surface = twinplay_3ds_metal_layer();
        } else {
            window_info.type = Frontend::WindowSystemType::Headless;
            window_info.render_surface = nullptr;
        }
        // drawableSize is the native 400x480 stack in pixels, so scale is 1.
        window_info.render_surface_scale = 1.0f;
        apply_screen_layout();
        UpdateCurrentFramebufferLayout(kTopW, kTopH + kBotH, true);
    }
    void PollEvents() override {
        // Do not resize Azahar's framebuffer to the skin union. The host
        // compositor places the two native screen regions into the cutouts.
    }
};

class TwinButton final : public Input::ButtonDevice {
public:
    explicit TwinButton(uint32_t mask) : mask_(mask) {}
    bool GetStatus() const override { return (g_buttons.load() & mask_) != 0; }
private:
    uint32_t mask_;
};

class TwinAnalog final : public Input::AnalogDevice {
public:
    TwinAnalog(int which) : which_(which) {}
    std::tuple<float, float> GetStatus() const override {
        if (which_ == 0) return {g_cx.load(), g_cy.load()};
        return {g_sx.load(), g_sy.load()};
    }
private:
    int which_;
};

class TwinTouch final : public Input::TouchDevice {
public:
    std::tuple<float, float, bool> GetStatus() const override {
        const bool down = g_touch.load() != 0;
        const float x = std::clamp(g_tx.load() / 319.f, 0.f, 1.f);
        const float y = std::clamp(g_ty.load() / 239.f, 0.f, 1.f);
        return {x, y, down};
    }
};

template <typename Device, typename... Args>
class TwinFactory final : public Input::Factory<Device> {
public:
    std::unique_ptr<Device> Create(const Common::ParamPackage& p) override {
        return make(p);
    }
    std::function<std::unique_ptr<Device>(const Common::ParamPackage&)> make;
};

void register_input() {
    static bool once = false;
    if (once) return;
    once = true;

    /* TwinPlay DSButton bits: A0 B1 Select2 Start3 Right4 Left5 Up6 Down7 R8 L9 X10 Y11 ZL17 ZR18 */
    auto buttons = std::make_shared<TwinFactory<Input::ButtonDevice>>();
    buttons->make = [](const Common::ParamPackage& p) -> std::unique_ptr<Input::ButtonDevice> {
        const int code = p.Get("code", 0);
        static const uint32_t kMap[] = {
            1u << 0,  /* A */
            1u << 1,  /* B */
            1u << 10, /* X */
            1u << 11, /* Y */
            1u << 6,  /* Up */
            1u << 7,  /* Down */
            1u << 5,  /* Left */
            1u << 4,  /* Right */
            1u << 9,  /* L */
            1u << 8,  /* R */
            1u << 3,  /* Start */
            1u << 2,  /* Select */
            0, 0,     /* Debug, Gpio14 */
            1u << 17, /* ZL */
            1u << 18, /* ZR */
        };
        const uint32_t mask = (code >= 0 && code < (int)(sizeof kMap / sizeof kMap[0])) ? kMap[code] : 0;
        return std::make_unique<TwinButton>(mask);
    };
    Input::RegisterFactory<Input::ButtonDevice>("twinplay", buttons);

    auto analogs = std::make_shared<TwinFactory<Input::AnalogDevice>>();
    analogs->make = [](const Common::ParamPackage& p) -> std::unique_ptr<Input::AnalogDevice> {
        return std::make_unique<TwinAnalog>(p.Get("axis", 0));
    };
    Input::RegisterFactory<Input::AnalogDevice>("twinplay", analogs);

    auto touch = std::make_shared<TwinFactory<Input::TouchDevice>>();
    touch->make = [](const Common::ParamPackage&) -> std::unique_ptr<Input::TouchDevice> {
        return std::make_unique<TwinTouch>();
    };
    Input::RegisterFactory<Input::TouchDevice>("twinplay", touch);
}

void bind_profile() {
    auto& profile = Settings::values.current_input_profile;
    const char* names[] = {"a","b","x","y","up","down","left","right","l","r","start","select","debug","gpio14","zl","zr"};
    for (int i = 0; i < Settings::NativeButton::NumButtons && i < 16; ++i) {
        profile.buttons[i] = std::string("engine:twinplay,code:") + std::to_string(i);
        (void)names;
    }
    profile.analogs[Settings::NativeAnalog::CirclePad] = "engine:twinplay,axis:0";
    profile.analogs[Settings::NativeAnalog::CStick] = "engine:twinplay,axis:1";
    profile.touch_device = "engine:twinplay";
}

void apply_settings() {
    Settings::values.use_cpu_jit = false;
    Settings::values.use_fastinterp = true;
    Settings::values.use_shader_jit = false;
    Settings::values.graphics_api = g_using_vulkan ? Settings::GraphicsAPI::Vulkan
                                                   : Settings::GraphicsAPI::Software;
    Settings::values.use_hw_shader = true;
    Settings::values.spirv_shader_gen = true;
    Settings::values.async_shader_compilation = true;
    Settings::values.async_presentation = true;
    Settings::values.use_disk_shader_cache = g_using_vulkan;
    Settings::values.resolution_factor = 1;
    Settings::values.use_vsync = false;
    Settings::values.frame_limit = 0;
    {
        int clock = g_cpu_clock.load();
        if (clock < 25) clock = 25;
        if (clock > 400) clock = 400;
        Settings::values.cpu_clock_percentage = clock;
    }
    Settings::values.audio_emulation = Settings::AudioEmulation::HLE;
    Settings::values.output_type = AudioCore::SinkType::Null;
    Settings::values.enable_audio_stretching = true;
    Settings::values.layout_option.SetValue(Settings::LayoutOption::Default);
    Settings::values.portrait_layout_option.SetValue(Settings::PortraitLayoutOption::PortraitOriginal);
    Settings::values.screen_gap.SetValue(0);
    Settings::values.log_filter = "*:Error";
    Settings::values.volume = 1.f;
    Settings::values.audio_muted = false;
    /* Service::Init looks up every HLE module with unordered_map::at().
       Other frontends (Qt, Android, libretro) fill this from config; without
       those keys, Load throws "unordered_map::at: key not found". */
    for (const auto& module : Service::service_module_map) {
        Settings::values.lle_modules.emplace(module.name, false);
        Settings::values.lle_modules[module.name] = false;
    }
    bind_profile();
}

void ensure_user_dirs() {
    const FileUtil::UserPath needed[] = {
        FileUtil::UserPath::UserDir,   FileUtil::UserPath::ConfigDir,
        FileUtil::UserPath::CacheDir,  FileUtil::UserPath::SDMCDir,
        FileUtil::UserPath::NANDDir,   FileUtil::UserPath::SysDataDir,
        FileUtil::UserPath::LogDir,    FileUtil::UserPath::StatesDir,
        FileUtil::UserPath::CheatsDir, FileUtil::UserPath::ShaderDir,
    };
    for (auto p : needed) {
        const std::string dir = FileUtil::GetUserPath(p);
        if (!dir.empty()) FileUtil::CreateFullPath(dir + (dir.back() == '/' ? "" : "/"));
    }
}

const char* status_text(Core::System::ResultStatus s) {
    using R = Core::System::ResultStatus;
    switch (s) {
    case R::ErrorNotInitialized: return "The 3DS core is not initialized.";
    case R::ErrorGetLoader: return "This 3DS game format is not supported.";
    case R::ErrorLoader: return "The 3DS core could not load this game.";
    case R::ErrorLoader_ErrorEncrypted:
        return "This 3DS image is encrypted. Place keys you dumped yourself in the app's 3DS user folder. TwinPlay never includes those keys.";
    case R::ErrorLoader_ErrorInvalidFormat: return "This is not a valid 3DS game image.";
    case R::ErrorLoader_ErrorGbaTitle: return "GBA Virtual Console titles are not supported here.";
    case R::ErrorSystemFiles:
        return "This game needs 3DS system files you dump yourself, placed in the app's 3DS user folder. TwinPlay never includes those files.";
    case R::ErrorSavestate: return "The 3DS save state failed.";
    default: return "The 3DS core reported an error.";
    }
}

void copy_screens(Core::System& sys) {
    auto* sw = dynamic_cast<SwRenderer::RendererSoftware*>(&sys.GPU().Renderer());
    if (!sw) return;
    const auto copy = [](const SwRenderer::ScreenInfo& info, std::vector<uint32_t>& dst, int& w, int& h) {
        const int src_w = int(info.width), src_h = int(info.height);
        if (src_w <= 0 || src_h <= 0 || src_w > 1024 || src_h > 1024) return;
        const size_t need = size_t(src_w) * size_t(src_h) * 4;
        if (info.pixels.size() < need) return;
        /* Software renderer writes a 90-degree-rotated buffer: index = x * height + y,
           width = stride (240), height = landscape width (400). Unrotate into a
           height-wide, width-tall image. The previous dest index (y * height + x)
           overflowed a 400x240 buffer whenever height > width and crashed in this loop. */
        const int out_w = src_h, out_h = src_w;
        dst.resize(size_t(out_w) * size_t(out_h));
        for (int x = 0; x < src_w; ++x) {
            for (int y = 0; y < src_h; ++y) {
                const u8* p = info.pixels.data() + (size_t(x) * size_t(src_h) + size_t(y)) * 4;
                const uint32_t r = p[0], g = p[1], b = p[2], a = p[3];
                dst[size_t(x) * size_t(out_w) + size_t(y)] =
                    (a << 24) | (r << 16) | (g << 8) | b;
            }
        }
        w = out_w;
        h = out_h;
    };
    int slot = g_write;
    copy(sw->Screen(VideoCore::ScreenId::TopLeft), g_top_tb[slot].px, g_top_tb[slot].w, g_top_tb[slot].h);
    copy(sw->Screen(VideoCore::ScreenId::Bottom), g_bot_tb[slot].px, g_bot_tb[slot].w, g_bot_tb[slot].h);
    g_pub.store(slot, std::memory_order_release);
    const int pub = slot;
    int next = (slot + 1) % 3;
    if (next == pub) next = (next + 1) % 3;
    g_write = next;
}

TwinPlayWindow* g_window = nullptr;

} // namespace

// Azahar's Null sink factory (patched under TWINPLAY_NO_JIT) calls this so 3DS audio
// is pushed into TwinPlay's 48 kHz queue without Cubeb/SDL/OpenAL.
std::unique_ptr<AudioCore::Sink> TwinPlayCreateAudioSink(std::string_view device) {
    return make_twinplay_sink(device);
}

extern "C" {

int twinplay_3ds_available(void) { return 1; }

void twinplay_3ds_set_data_dir(const char* d) { g_data = d ? d : ""; }
void twinplay_3ds_set_save_dir(const char* d) { g_saves = d ? d : ""; }

int twinplay_3ds_load(const char* path, char* err, int err_len) {
    auto fail = [&](const char* m) {
        g_booted = false;
        g_failed = true;
        g_error = m ? m : "The 3DS core reported an error.";
        if (err && err_len > 0) std::snprintf(err, (size_t)err_len, "%s", g_error.c_str());
        return -1;
    };
    reset_audio();
    g_error.clear();
    g_failed = false;
    if (!path || !path[0]) return fail("No 3DS game path.");
    try {
    if (!g_log_on) {
        Common::Log::Initialize();
        Common::Log::Filter filter(Common::Log::Level::Error);
        Common::Log::SetGlobalFilter(filter);
        Common::Log::Start();
        g_log_on = true;
    }
    const std::string user = !g_data.empty() ? g_data : (!g_saves.empty() ? g_saves : "/tmp/twinplay-3ds");
    FileUtil::SetUserPath(user);
    ensure_user_dirs();
    register_input();
    g_using_vulkan = true;
    apply_settings();
    // Attach the 400x480 CAMetalLayer to a hidden window before Vulkan
    // init so the first swapchain is never (0, 0).
    (void)twinplay_3ds_metal_layer();
    twinplay_3ds_set_drawable_size(kTopW, kTopH + kBotH, 1.f);
    auto& sys = Core::System::GetInstance();
    static bool applets_on = false;
    if (!applets_on) {
        Frontend::RegisterDefaultApplets(sys);
        applets_on = true;
    }
    auto try_load = [&]() -> Core::System::ResultStatus {
        if (sys.IsPoweredOn()) sys.Shutdown();
        delete g_window;
        g_window = new TwinPlayWindow(g_using_vulkan);
        return sys.Load(*g_window, path);
    };
    auto st = try_load();
    if (st != Core::System::ResultStatus::Success && g_using_vulkan) {
        /* GPU init failed: fall back to the software renderer rather than abort. */
        g_using_vulkan = false;
        apply_settings();
        st = try_load();
    }
    if (st != Core::System::ResultStatus::Success) {
        std::string msg = status_text(st);
        const std::string details = sys.GetStatusDetails();
        if (!details.empty()) msg += " " + details;
        return fail(msg.c_str());
    }
    for (int i = 0; i < 3; ++i) {
        g_top_tb[i].px.assign(kTopW * kTopH, 0xFF000000u);
        g_top_tb[i].w = kTopW; g_top_tb[i].h = kTopH;
        g_bot_tb[i].px.assign(kBotW * kBotH, 0xFF000000u);
        g_bot_tb[i].w = kBotW; g_bot_tb[i].h = kBotH;
    }
    g_pub.store(0, std::memory_order_relaxed);
    g_write = 1;
    g_shaders_loaded = false;
    g_present_ready.store(0, std::memory_order_release);
    g_ft_last.store(0); g_ft_max.store(0); g_ft_p95.store(0);
    g_frames.store(0, std::memory_order_relaxed);
    g_booted = true;
    g_failed = false;
    return 0;
    } catch (const std::exception& e) {
        return fail(e.what());
    } catch (...) {
        return fail("The 3DS core crashed while opening this game. If the image is encrypted, place keys you dumped yourself in the app's 3DS user folder. TwinPlay never includes those keys. Some games also need 3DS system files or shared fonts in that folder.");
    }
}

void twinplay_3ds_set_paused(int paused) {
    g_emu_pause.store(paused != 0, std::memory_order_release);
}

void record_frame_time(double ms) {
    static double ring[120]{};
    static int n = 0, i = 0;
    ring[i] = ms;
    i = (i + 1) % 120;
    if (n < 120) n++;
    g_ft_last.store(ms, std::memory_order_relaxed);
    double mx = 0;
    double tmp[120];
    for (int k = 0; k < n; ++k) {
        tmp[k] = ring[k];
        if (tmp[k] > mx) mx = tmp[k];
    }
    g_ft_max.store(mx, std::memory_order_relaxed);
    if (n > 0) {
        std::nth_element(tmp, tmp + (n * 95) / 100, tmp + n);
        g_ft_p95.store(tmp[(n * 95) / 100], std::memory_order_relaxed);
    }
}

void emu_thread_main() {
    using clock = std::chrono::steady_clock;
    const auto period = std::chrono::duration_cast<clock::duration>(std::chrono::duration<double>(1.0 / 60.0));
    auto deadline = clock::now();
    auto last = clock::now();
    while (g_emu_run.load(std::memory_order_acquire)) {
        if (g_emu_pause.load(std::memory_order_acquire) || !g_booted || g_failed) {
            std::this_thread::sleep_for(std::chrono::milliseconds(8));
            deadline = clock::now();
            last = deadline;
            continue;
        }
        try {
            auto& sys = Core::System::GetInstance();
            if (!sys.IsPoweredOn()) {
                std::this_thread::sleep_for(std::chrono::milliseconds(8));
                continue;
            }
            // Do not run the GPU (or present) until the host has a stable
            // non-zero surface. A first (0, 0) swapchain left titles black.
            if (g_using_vulkan && !g_present_ready.load(std::memory_order_acquire)) {
                std::this_thread::sleep_for(std::chrono::milliseconds(8));
                deadline = clock::now();
                last = deadline;
                continue;
            }
            if (g_using_vulkan && !g_shaders_loaded) {
                g_shaders_loaded = true;
                // Disk-cache preload is skipped this build: on-device caches for
                // Pokemon X / 3D Land coincided with a black present. Async shader
                // compilation stays on. A safer preload can be restored after those
                // titles present again.
            }
            auto& renderer = sys.GPU().Renderer();
            const auto before = renderer.GetCurrentFrame();
            const auto st = sys.RunLoop();
            if (st == Core::System::ResultStatus::ShutdownRequested) break;
            if (st != Core::System::ResultStatus::Success) {
                std::string msg = status_text(st);
                const std::string details = sys.GetStatusDetails();
                if (!details.empty()) msg += " " + details;
                g_error = msg;
                g_failed = true;
                g_booted = false;
                break;
            }
            const auto now = clock::now();
            record_frame_time(std::chrono::duration<double, std::milli>(now - last).count());
            last = now;
            if (renderer.GetCurrentFrame() != before) {
                g_frames.fetch_add(1, std::memory_order_relaxed);
                if (!g_using_vulkan) copy_screens(sys);
            }
            // Precise 60 Hz clock: sleep when ahead; if more than one frame behind, drop
            // one wait (allow a single skipped present interval) and resync.
            deadline += period;
            if (now < deadline) {
                std::this_thread::sleep_until(deadline);
            } else if (now - deadline > period) {
                deadline = now;
            }
        } catch (const std::exception& e) {
            g_error = e.what();
            g_failed = true;
            g_booted = false;
            break;
        } catch (...) {
            g_error = "The 3DS core crashed while running this game. Some titles need 3DS system files or shared fonts you dump yourself, placed in the app's 3DS user folder. TwinPlay never includes those files.";
            g_failed = true;
            g_booted = false;
            break;
        }
    }
}

void twinplay_3ds_unload(void) {
    g_emu_run.store(false, std::memory_order_release);
    g_emu_pause.store(true, std::memory_order_release);
    if (g_emu_thread.joinable()) g_emu_thread.join();
    try {
        auto& sys = Core::System::GetInstance();
        if (sys.IsPoweredOn()) sys.Shutdown();
    } catch (...) {}
    delete g_window;
    g_window = nullptr;
    g_booted = false;
    g_present_ready.store(0, std::memory_order_release);
    reset_audio();
}

void twinplay_3ds_reset(void) {
    if (!g_booted || g_failed) return;
    reset_audio();
    try {
        Core::System::GetInstance().Reset();
    } catch (...) {
        g_failed = true;
        g_error = "The 3DS core crashed while resetting this game.";
        g_booted = false;
    }
}

void twinplay_3ds_run_frame(void) {
    /* The 3DS core free-runs on its own thread so it is never stalled waiting
       for a display tick. The host only starts that thread; copy_screens runs
       there after each presented frame. */
    if (!g_booted || g_failed) return;
    if (!g_emu_thread.joinable()) {
        g_emu_pause.store(false, std::memory_order_release);
        g_emu_run.store(true, std::memory_order_release);
        g_emu_thread = std::thread(emu_thread_main);
    }
}

void twinplay_3ds_set_input(unsigned b, float cx, float cy, float sx, float sy, int t, int x, int y) {
    g_buttons.store(b);
    g_cx.store(cx);
    g_cy.store(cy);
    g_sx.store(sx);
    g_sy.store(sy);
    g_touch.store(t);
    g_tx.store(x);
    g_ty.store(y);
}

int twinplay_3ds_copy_frame(int screen, unsigned* dst, int cap, int* w, int* h) {
    const int slot = g_pub.load(std::memory_order_acquire);
    const FrameSlot& src = screen == 0 ? g_top_tb[slot] : g_bot_tb[slot];
    const int ww = src.w, hh = src.h;
    if (w) *w = ww;
    if (h) *h = hh;
    const int n = ww * hh;
    if (!dst || n <= 0 || n > cap || src.px.empty()) return 0;
    std::memcpy(dst, src.px.data(), size_t(n) * 4);
    return n;
}

int twinplay_3ds_read_audio(short* dst, int n) {
    if (!dst || n <= 0) return 0;
    int r = g_audio_r.load(std::memory_order_relaxed);
    const int w = g_audio_w.load(std::memory_order_acquire);
    int got = 0;
    while (got < n && r != w) {
        dst[got * 2] = g_audio_ring[r * 2];
        dst[got * 2 + 1] = g_audio_ring[r * 2 + 1];
        ++got;
        if (++r >= kAudioFramesCap) r = 0;
    }
    g_audio_r.store(r, std::memory_order_release);
    return got;
}

const char* twinplay_3ds_last_error(void) {
    return g_failed && !g_error.empty() ? g_error.c_str() : "";
}

int twinplay_3ds_save_state(unsigned char* d, int c) {
    if (!g_booted || !d || c <= 0) return -1;
    try {
        auto buf = Core::System::GetInstance().SaveStateBuffer();
        if (buf.empty() || (int)buf.size() > c) return -1;
        std::memcpy(d, buf.data(), buf.size());
        return (int)buf.size();
    } catch (...) {
        return -1;
    }
}

uint64_t twinplay_3ds_frame_count(void) {
    return g_frames.load(std::memory_order_relaxed);
}

int twinplay_3ds_using_vulkan(void) { return g_using_vulkan ? 1 : 0; }

void twinplay_3ds_set_cpu_clock(int percent) {
    if (percent < 25) percent = 25;
    if (percent > 400) percent = 400;
    g_cpu_clock.store(percent);
    Settings::values.cpu_clock_percentage = percent;
}

void twinplay_3ds_set_surface_size(int w, int h, float scale) {
    // Host size is ignored. The swapchain stays at 400x480.
    (void)w; (void)h; (void)scale;
    twinplay_3ds_set_drawable_size(kTopW, kTopH + kBotH, 1.f);
}

void twinplay_3ds_set_screen_layout(int fb_w, int fb_h, float scale,
                                   int top_x, int top_y, int top_w, int top_h,
                                   int bot_x, int bot_y, int bot_w, int bot_h) {
    // Stored only for diagnostics; Azahar keeps the native stacked layout.
    (void)fb_w; (void)fb_h; (void)scale;
    g_top_x.store(top_x); g_top_y.store(top_y);
    g_top_rw.store(top_w); g_top_rh.store(top_h);
    g_bot_x.store(bot_x); g_bot_y.store(bot_y);
    g_bot_rw.store(bot_w); g_bot_rh.store(bot_h);
    twinplay_3ds_set_drawable_size(kTopW, kTopH + kBotH, 1.f);
}

void twinplay_3ds_set_present_ready(int ready) {
    g_present_ready.store(ready ? 1 : 0, std::memory_order_release);
}

int twinplay_3ds_present_ready(void) {
    return g_present_ready.load(std::memory_order_acquire);
}

void twinplay_3ds_frame_timing(double* last_ms, double* max_ms, double* p95_ms) {
    if (last_ms) *last_ms = g_ft_last.load(std::memory_order_relaxed);
    if (max_ms) *max_ms = g_ft_max.load(std::memory_order_relaxed);
    if (p95_ms) *p95_ms = g_ft_p95.load(std::memory_order_relaxed);
}

int twinplay_3ds_load_state(const unsigned char* s, int n) {
    if (!g_booted || !s || n <= 0) return -1;
    try {
        std::vector<u8> buf(s, s + n);
        return Core::System::GetInstance().LoadStateBuffer(std::move(buf)) ? 0 : -1;
    } catch (...) {
        return -1;
    }
}

}
