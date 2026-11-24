// Copyright (c) 2026 Charlie Rodriguez Garcia.
// In-process Flycast libretro host. GPL-2.0-or-later because it links Flycast.
//
// iOS / iPadOS: the dylib is built with -DTARGET_NO_REC, so the SH4, ARM7 and
// DSP recompilers are not compiled. There is no JIT and no StikDebug. The GPU
// path is OpenGL ES 3 (threaded), and each frame is read back into the buffer
// TwinPlay's existing Metal presenter already draws.
// macOS: the same host, but the dylib keeps Flycast's ARM64 dynarec.
#import "twinplay_flycast.h"

#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <pthread.h>
#import <string.h>
#import <vector>
#import <mutex>
#import <string>
#import <algorithm>

#if TARGET_OS_IPHONE
#import <OpenGLES/ES3/gl.h>
#import <OpenGLES/EAGL.h>
#else
#import <OpenGL/OpenGL.h>
#import <OpenGL/gl3.h>
#endif

namespace {

constexpr unsigned kEnvExperimental = 0x10000;
constexpr unsigned kSetPixelFormat = 10;
constexpr unsigned kSetHwRender = 14;
constexpr unsigned kGetVariable = 15;
constexpr unsigned kSetVariables = 16;
constexpr unsigned kGetVariableUpdate = 17;
constexpr unsigned kGetLogInterface = 27;
constexpr unsigned kGetSaveDirectory = 31;
constexpr unsigned kSetSystemAvInfo = 32;
constexpr unsigned kSetGeometry = 37;
constexpr unsigned kGetInputBitmasks = 51 | kEnvExperimental;
constexpr unsigned kSetCoreOptions = 53;
constexpr unsigned kSetCoreOptionsV2 = 67;
constexpr unsigned kSetCoreOptionsUpdate = 69;
constexpr unsigned kGetPreferredHw = 56;
constexpr unsigned kSetMessage = 6;
constexpr unsigned kGetSystemDirectory = 9;
constexpr unsigned kSetSupportNoGame = 18;
constexpr unsigned kShutdown = 7;
constexpr unsigned kGetFastForwarding = 49 | kEnvExperimental;
constexpr unsigned kSetInputDescriptors = 11;
constexpr unsigned kSetControllerInfo = 35;
constexpr unsigned kSetDiskControl = 13;
constexpr unsigned kGetDiskControlVersion = 57 | kEnvExperimental;
constexpr unsigned kSetDiskControlExt = 58 | kEnvExperimental;
constexpr unsigned kSetKeyboardCallback = 12;
constexpr unsigned kGetPerfInterface = 28;
constexpr unsigned kGetRumble = 23 | kEnvExperimental;

constexpr int kHwOpenGL = 1;
constexpr int kHwGLES2 = 2;
constexpr int kHwOpenGLCore = 3;
constexpr int kHwGLES3 = 4;
constexpr unsigned kPixelXRGB8888 = 1;
constexpr int kDeviceJoypad = 1;
constexpr int kDeviceAnalog = 5;
constexpr int kAnalogLeft = 0;
constexpr int kAnalogX = 0;
constexpr int kAnalogY = 1;
constexpr int kPadB = 0, kPadY = 1, kPadSelect = 2, kPadStart = 3;
constexpr int kPadUp = 4, kPadDown = 5, kPadLeft = 6, kPadRight = 7;
constexpr int kPadA = 8, kPadX = 9, kPadL = 10, kPadR = 11;

struct RetroVariable { const char* key; const char* value; };
struct RetroGameGeometry { unsigned base_width, base_height, max_width, max_height; float aspect_ratio; };
struct RetroSystemTiming { double fps; double sample_rate; };
struct RetroSystemAvInfo { RetroGameGeometry geometry; RetroSystemTiming timing; };
struct RetroGameInfo { const char* path; const void* data; size_t size; const char* meta; };

typedef void (*RetroResetFn)(void);
typedef uintptr_t (*RetroGetFb)(void);
typedef void (*RetroProc)(void);
typedef RetroProc (*RetroGetProc)(const char*);
struct RetroHwRender {
    int context_type;
    RetroResetFn context_reset;
    RetroGetFb get_current_framebuffer;
    RetroGetProc get_proc_address;
    bool depth;
    bool stencil;
    bool bottom_left_origin;
    unsigned version_major;
    unsigned version_minor;
    bool cache_context;
    RetroResetFn context_destroy;
    bool debug_context;
};

using RetroEnvironment = bool (*)(unsigned cmd, void* data);
using RetroVideo = void (*)(const void* data, unsigned width, unsigned height, size_t pitch);
using RetroAudioBatch = size_t (*)(const int16_t* data, size_t frames);
using RetroInputPoll = void (*)(void);
using RetroInputState = int16_t (*)(unsigned port, unsigned device, unsigned index, unsigned id);

struct RetroApi {
    void* lib = nullptr;
    void (*set_environment)(RetroEnvironment) = nullptr;
    void (*set_video_refresh)(RetroVideo) = nullptr;
    void (*set_audio_sample)(void (*)(int16_t, int16_t)) = nullptr;
    void (*set_audio_sample_batch)(RetroAudioBatch) = nullptr;
    void (*set_input_poll)(RetroInputPoll) = nullptr;
    void (*set_input_state)(RetroInputState) = nullptr;
    void (*init)(void) = nullptr;
    void (*deinit)(void) = nullptr;
    unsigned (*api_version)(void) = nullptr;
    void (*get_system_av_info)(RetroSystemAvInfo*) = nullptr;
    void (*reset)(void) = nullptr;
    void (*run)(void) = nullptr;
    size_t (*serialize_size)(void) = nullptr;
    bool (*serialize)(void*, size_t) = nullptr;
    bool (*unserialize)(const void*, size_t) = nullptr;
    bool (*load_game)(const RetroGameInfo*) = nullptr;
    void (*unload_game)(void) = nullptr;
    void (*get_system_info)(void*) = nullptr;
};

RetroApi gApi;
std::mutex gLock;
std::string gDataDir;
std::string gSaveDir;
bool gHle = true;
bool gLoaded = false;
bool gContextReady = false;
uint32_t gButtons = 0;
float gAx = 0, gAy = 0, gLt = 0, gRt = 0;
double gSampleRate = 44100;
double gResampleErr = 0;

#if TARGET_OS_IPHONE
EAGLContext* gEAGL = nil;
#else
CGLContextObj gCGL = nullptr;
#endif
GLuint gFbo = 0, gColor = 0, gDepth = 0;
int gFboW = 0, gFboH = 0;
RetroHwRender gHw{};
std::vector<uint32_t> gFrame;
int gFrameW = 0, gFrameH = 0;
std::vector<int16_t> gAudio; // stereo 48 kHz
std::string gLastError;

constexpr int kFbMaxW = 1920;
constexpr int kFbMaxH = 1088;

void logLine(const char* s) { NSLog(@"TwinPlay Flycast: %s", s); }

template <class T>
T loadSym(const char* name) {
    return reinterpret_cast<T>(dlsym(gApi.lib, name));
}

std::string dylibPath() {
    if (const char* e = getenv("TWINPLAY_FLYCAST_DYLIB")) if (e[0]) return e;
    NSFileManager* fm = NSFileManager.defaultManager;
    if (NSString* fw = NSBundle.mainBundle.privateFrameworksPath) {
        NSString* p = [fw stringByAppendingPathComponent:@"flycast_libretro.dylib"];
        if ([fm fileExistsAtPath:p]) return p.UTF8String;
    }
    NSString* exe = NSBundle.mainBundle.executablePath.stringByDeletingLastPathComponent;
    for (NSString* rel in @[@"flycast_libretro.dylib", @"../Frameworks/flycast_libretro.dylib"]) {
        NSString* p = [exe stringByAppendingPathComponent:rel];
        if ([fm fileExistsAtPath:p]) return p.UTF8String;
    }
#if TARGET_OS_IPHONE
    NSString* plat = @"iphoneos";
#else
    NSString* plat = @"macos";
#endif
    NSString* src = [NSString stringWithUTF8String:__FILE__];
    NSString* root = src.stringByDeletingLastPathComponent.stringByDeletingLastPathComponent.stringByDeletingLastPathComponent;
    NSString* built = [NSString stringWithFormat:@"%@/Core/third_party/build/flycast/%@/flycast_libretro.dylib", root, plat];
    if ([fm fileExistsAtPath:built]) return built.UTF8String;
    return {};
}

bool openCore() {
    if (gApi.lib) return true;
    std::string path = dylibPath();
    if (path.empty()) return false;
    gApi.lib = dlopen(path.c_str(), RTLD_NOW | RTLD_LOCAL);
    if (!gApi.lib) {
        gLastError = dlerror() ? dlerror() : "dlopen failed";
        return false;
    }
    gApi.set_environment = loadSym<void (*)(RetroEnvironment)>("retro_set_environment");
    gApi.set_video_refresh = loadSym<void (*)(RetroVideo)>("retro_set_video_refresh");
    gApi.set_audio_sample = loadSym<void (*)(void (*)(int16_t, int16_t))>("retro_set_audio_sample");
    gApi.set_audio_sample_batch = loadSym<void (*)(RetroAudioBatch)>("retro_set_audio_sample_batch");
    gApi.set_input_poll = loadSym<void (*)(RetroInputPoll)>("retro_set_input_poll");
    gApi.set_input_state = loadSym<void (*)(RetroInputState)>("retro_set_input_state");
    gApi.init = loadSym<void (*)()>("retro_init");
    gApi.deinit = loadSym<void (*)()>("retro_deinit");
    gApi.api_version = loadSym<unsigned (*)()>("retro_api_version");
    gApi.get_system_av_info = loadSym<void (*)(RetroSystemAvInfo*)>("retro_get_system_av_info");
    gApi.reset = loadSym<void (*)()>("retro_reset");
    gApi.run = loadSym<void (*)()>("retro_run");
    gApi.serialize_size = loadSym<size_t (*)()>("retro_serialize_size");
    gApi.serialize = loadSym<bool (*)(void*, size_t)>("retro_serialize");
    gApi.unserialize = loadSym<bool (*)(const void*, size_t)>("retro_unserialize");
    gApi.load_game = loadSym<bool (*)(const RetroGameInfo*)>("retro_load_game");
    gApi.unload_game = loadSym<void (*)()>("retro_unload_game");
    return gApi.init && gApi.run && gApi.load_game && gApi.api_version && gApi.api_version() == 1;
}

void pushAudio48(int16_t l, int16_t r) {
    if (gAudio.size() > 48000 * 4) gAudio.erase(gAudio.begin(), gAudio.begin() + (gAudio.size() / 2));
    gAudio.push_back(l);
    gAudio.push_back(r);
}

void ingestAudio(const int16_t* data, size_t frames) {
    const double step = 48000.0 / std::max(1.0, gSampleRate);
    for (size_t i = 0; i < frames; ++i) {
        gResampleErr += step;
        int n = (int)gResampleErr;
        if (n < 1) n = 0;
        gResampleErr -= n;
        if (n > 4) n = 4;
        int16_t l = data[i * 2], r = data[i * 2 + 1];
        for (int k = 0; k < n; ++k) pushAudio48(l, r);
    }
}

size_t audioBatch(const int16_t* data, size_t frames) {
    if (data && frames) ingestAudio(data, frames);
    return frames;
}
void audioSample(int16_t l, int16_t r) { int16_t s[2] = {l, r}; ingestAudio(s, 1); }
void inputPoll() {}

int16_t inputState(unsigned port, unsigned device, unsigned index, unsigned id) {
    if (port != 0) return 0;
    if (device == kDeviceAnalog && index == (unsigned)kAnalogLeft) {
        float v = (id == kAnalogY) ? -gAy : gAx; // Apple / TwinPlay Y is up; libretro Y is down
        if (id != kAnalogX && id != kAnalogY) return 0;
        v = std::max(-1.f, std::min(1.f, v));
        return (int16_t)std::lrintf(v * 32767.f);
    }
    if (device != kDeviceJoypad) return 0;
    auto bit = [&](uint32_t m) { return (gButtons & m) ? (int16_t)1 : (int16_t)0; };
    // TwinPlay bits: A=1<<0 B=1<<1 Select=1<<2 Start=1<<3 Right=1<<4 Left=1<<5 Up=1<<6 Down=1<<7 R=1<<8 L=1<<9 X=1<<10 Y=1<<11
    switch (id) {
    case kPadB: return bit(1u << 0);      // DC A
    case kPadA: return bit(1u << 1);      // DC B
    case kPadY: return bit(1u << 10);     // DC X
    case kPadX: return bit(1u << 11);     // DC Y
    case kPadStart: return bit(1u << 3);
    case kPadSelect: return bit(1u << 2);
    case kPadUp: return bit(1u << 6);
    case kPadDown: return bit(1u << 7);
    case kPadLeft: return bit(1u << 5);
    case kPadRight: return bit(1u << 4);
    case kPadL: return (gLt > 0.4f || (gButtons & (1u << 9))) ? 1 : 0;
    case kPadR: return (gRt > 0.4f || (gButtons & (1u << 8))) ? 1 : 0;
    default: return 0;
    }
}

const char* variable(const char* key) {
    if (!key) return nullptr;
    std::string k = key;
    auto ends = [&](const char* s) { return k.size() >= strlen(s) && k.compare(k.size() - strlen(s), strlen(s), s) == 0; };
    if (ends("_hle_bios")) return gHle ? "enabled" : "disabled";
    // GPU thread overlaps the SH4 interpreter. This is Flycast's own "highly recommended" switch.
    if (ends("_threaded_rendering")) return "enabled";
    if (ends("_vblank_pacing")) return "disabled";
#if TARGET_OS_IPHONE
    // Interpreter builds spend the frame on the CPU. Keep the GPU cheap and skip
    // when a frame runs long so the game stays responsive on A17-class chips.
    if (ends("_internal_resolution")) return "640x480";
    if (ends("_enable_dsp")) return "disabled";
    if (ends("_auto_skip_frame")) return "some";
    if (ends("_alpha_sorting")) return "per-strip (fast, least accurate)";
    if (ends("_frame_skipping")) return "disabled";
#else
    if (ends("_internal_resolution")) return "640x480";
    if (ends("_enable_dsp")) return "enabled";
    if (ends("_auto_skip_frame")) return "disabled";
    if (ends("_alpha_sorting")) return "per-triangle (normal)";
#endif
    if (ends("_region")) return "USA";
    if (ends("_language")) return "English";
    if (ends("_cable_type")) return "TV (Composite)";
    if (ends("_broadcast")) return "NTSC";
    return nullptr;
}

void copyFlashAlias() {
    if (gDataDir.empty()) return;
    NSString* dir = [NSString stringWithUTF8String:gDataDir.c_str()];
    NSFileManager* fm = NSFileManager.defaultManager;
    NSString* flash = [dir stringByAppendingPathComponent:@"dc_flash.bin"];
    NSString* nv = [dir stringByAppendingPathComponent:@"dc_nvmem.bin"];
    if ([fm fileExistsAtPath:flash] && ![fm fileExistsAtPath:nv]) {
        [fm copyItemAtPath:flash toPath:nv error:nil];
    }
}

bool makeCurrent() {
#if TARGET_OS_IPHONE
    if (!gEAGL) return false;
    return [EAGLContext setCurrentContext:gEAGL];
#else
    if (!gCGL) return false;
    return CGLSetCurrentContext(gCGL) == kCGLNoError;
#endif
}

bool ensureFbo(int w, int h) {
    w = std::max(640, std::min(w, kFbMaxW));
    h = std::max(480, std::min(h, kFbMaxH));
    if (gFbo && w <= gFboW && h <= gFboH) return true;
    if (!makeCurrent()) return false;
    if (gFbo) {
        glDeleteFramebuffers(1, &gFbo);
        glDeleteRenderbuffers(1, &gColor);
        glDeleteRenderbuffers(1, &gDepth);
        gFbo = gColor = gDepth = 0;
    }
    gFboW = kFbMaxW;
    gFboH = kFbMaxH;
    glGenFramebuffers(1, &gFbo);
    glBindFramebuffer(GL_FRAMEBUFFER, gFbo);
    glGenRenderbuffers(1, &gColor);
    glBindRenderbuffer(GL_RENDERBUFFER, gColor);
#if TARGET_OS_IPHONE
    glRenderbufferStorage(GL_RENDERBUFFER, GL_RGBA8, gFboW, gFboH);
#else
    glRenderbufferStorage(GL_RENDERBUFFER, GL_RGBA8, gFboW, gFboH);
#endif
    glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_RENDERBUFFER, gColor);
    glGenRenderbuffers(1, &gDepth);
    glBindRenderbuffer(GL_RENDERBUFFER, gDepth);
    glRenderbufferStorage(GL_RENDERBUFFER, GL_DEPTH24_STENCIL8, gFboW, gFboH);
    glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_DEPTH_STENCIL_ATTACHMENT, GL_RENDERBUFFER, gDepth);
    GLenum st = glCheckFramebufferStatus(GL_FRAMEBUFFER);
    glViewport(0, 0, gFboW, gFboH);
    return st == GL_FRAMEBUFFER_COMPLETE;
}

bool createContext(int type) {
    (void)type;
#if TARGET_OS_IPHONE
    gEAGL = [[EAGLContext alloc] initWithAPI:kEAGLRenderingAPIOpenGLES3];
    if (!gEAGL) gEAGL = [[EAGLContext alloc] initWithAPI:kEAGLRenderingAPIOpenGLES2];
    if (!gEAGL || ![EAGLContext setCurrentContext:gEAGL]) return false;
#else
    CGLPixelFormatAttribute attrs[] = {
        kCGLPFAOpenGLProfile, (CGLPixelFormatAttribute)kCGLOGLPVersion_3_2_Core,
        kCGLPFAAccelerated,
        kCGLPFAColorSize, (CGLPixelFormatAttribute)32,
        kCGLPFADepthSize, (CGLPixelFormatAttribute)24,
        kCGLPFAStencilSize, (CGLPixelFormatAttribute)8,
        (CGLPixelFormatAttribute)0
    };
    CGLPixelFormatObj pf = nullptr;
    GLint npix = 0;
    if (CGLChoosePixelFormat(attrs, &pf, &npix) != kCGLNoError || !pf) return false;
    if (CGLCreateContext(pf, nullptr, &gCGL) != kCGLNoError || !gCGL) {
        CGLReleasePixelFormat(pf);
        return false;
    }
    CGLReleasePixelFormat(pf);
    if (CGLSetCurrentContext(gCGL) != kCGLNoError) return false;
#endif
    return ensureFbo(kFbMaxW, kFbMaxH);
}

void destroyContext() {
    if (gFbo) {
        makeCurrent();
        glDeleteFramebuffers(1, &gFbo);
        glDeleteRenderbuffers(1, &gColor);
        glDeleteRenderbuffers(1, &gDepth);
        gFbo = gColor = gDepth = 0;
    }
#if TARGET_OS_IPHONE
    if (gEAGL) { [EAGLContext setCurrentContext:nil]; gEAGL = nil; }
#else
    if (gCGL) { CGLSetCurrentContext(nullptr); CGLReleaseContext(gCGL); gCGL = nullptr; }
#endif
    gContextReady = false;
}

uintptr_t currentFb() { return gFbo; }

RetroProc procAddress(const char* sym) {
    if (!sym) return nullptr;
    return reinterpret_cast<RetroProc>(dlsym(RTLD_DEFAULT, sym));
}

void storeFrame(int w, int h) {
    if (w <= 0 || h <= 0 || w > kFbMaxW || h > kFbMaxH || !gFbo) return;
    if (!makeCurrent()) return;
    glBindFramebuffer(GL_FRAMEBUFFER, gFbo);
#if !TARGET_OS_IPHONE
    glReadBuffer(GL_COLOR_ATTACHMENT0);
#endif
    std::vector<uint8_t> raw((size_t)w * (size_t)h * 4);
    // Bottom-left origin. Read and flip into top-left 0xAARRGGBB.
    glPixelStorei(GL_PACK_ALIGNMENT, 1);
    glReadPixels(0, 0, w, h, GL_RGBA, GL_UNSIGNED_BYTE, raw.data());
    gFrame.assign((size_t)w * (size_t)h, 0xFF000000u);
    for (int y = 0; y < h; ++y) {
        const uint8_t* src = raw.data() + (size_t)(h - 1 - y) * (size_t)w * 4;
        uint32_t* dst = gFrame.data() + (size_t)y * (size_t)w;
        for (int x = 0; x < w; ++x) {
            uint32_t r = src[x * 4 + 0], g = src[x * 4 + 1], b = src[x * 4 + 2], a = src[x * 4 + 3];
            dst[x] = (a << 24) | (r << 16) | (g << 8) | b;
        }
    }
    gFrameW = w;
    gFrameH = h;
}

void videoRefresh(const void* data, unsigned width, unsigned height, size_t pitch) {
    (void)pitch;
    if (data == (void*)-1 && width && height) storeFrame((int)width, (int)height);
}

bool environment(unsigned cmd, void* data) {
    switch (cmd) {
    case kSetPixelFormat:
        return data && *static_cast<unsigned*>(data) == kPixelXRGB8888;
    case kGetSaveDirectory:
    case kGetSystemDirectory: {
        if (gDataDir.empty()) return false;
        *static_cast<const char**>(data) = gDataDir.c_str();
        return true;
    }
    case kGetVariable: {
        auto* v = static_cast<RetroVariable*>(data);
        if (!v || !v->key) return false;
        if (const char* val = variable(v->key)) { v->value = val; return true; }
        return false;
    }
    case kGetVariableUpdate:
        if (data) *static_cast<bool*>(data) = false;
        return true;
    case kGetPreferredHw:
        // Leave the choice to Flycast's fallback (it asks for GLES on iOS and
        // OpenGL core on macOS). Returning a type we cannot create would abort the load.
        return false;
    case kSetHwRender: {
        if (!data) return false;
        gHw = *static_cast<RetroHwRender*>(data);
        int type = gHw.context_type;
#if TARGET_OS_IPHONE
        if (type != kHwGLES2 && type != kHwGLES3 && type != 5) return false;
#else
        if (type != kHwOpenGL && type != kHwOpenGLCore) return false;
#endif
        if (!createContext(type)) return false;
        gHw.get_current_framebuffer = currentFb;
        gHw.get_proc_address = procAddress;
        *static_cast<RetroHwRender*>(data) = gHw;
        if (gHw.context_reset) gHw.context_reset();
        gContextReady = true;
        return true;
    }
    case kSetSystemAvInfo:
    case kSetGeometry: {
        if (cmd == kSetSystemAvInfo && data) {
            auto* info = static_cast<RetroSystemAvInfo*>(data);
            if (info->timing.sample_rate > 1000) gSampleRate = info->timing.sample_rate;
        }
        return true;
    }
    case kGetLogInterface:
    case kSetVariables:
    case kSetCoreOptions:
    case kSetCoreOptionsV2:
    case kSetCoreOptionsUpdate:
    case kSetMessage:
    case kSetSupportNoGame:
    case kSetInputDescriptors:
    case kSetControllerInfo:
    case kSetDiskControl:
    case kGetDiskControlVersion:
    case kSetDiskControlExt:
    case kSetKeyboardCallback:
    case kGetPerfInterface:
    case kGetRumble:
    case kGetInputBitmasks:
    case kGetFastForwarding:
    case kShutdown:
        return false;
    default:
        return false;
    }
}

void bindCallbacks() {
    gApi.set_environment(environment);
    gApi.set_video_refresh(videoRefresh);
    gApi.set_audio_sample(audioSample);
    gApi.set_audio_sample_batch(audioBatch);
    gApi.set_input_poll(inputPoll);
    gApi.set_input_state(inputState);
}

} // namespace

int twinplay_dc_available(void) {
    std::lock_guard<std::mutex> lock(gLock);
    return openCore() ? 1 : 0;
}

const char* twinplay_dc_cpu_mode(void) {
#if TARGET_OS_IPHONE
    return "interpreter";
#else
    return "dynarec";
#endif
}

const char* twinplay_dc_renderer(void) {
#if TARGET_OS_IPHONE
    return "opengl-es";
#else
    return "opengl";
#endif
}

void twinplay_dc_set_dirs(const char* data_dir, const char* save_dir) {
    std::lock_guard<std::mutex> lock(gLock);
    gDataDir = data_dir ? data_dir : "";
    gSaveDir = save_dir ? save_dir : "";
    if (!gDataDir.empty() && gDataDir.back() != '/') gDataDir.push_back('/');
}

void twinplay_dc_set_hle(int hle) {
    std::lock_guard<std::mutex> lock(gLock);
    gHle = hle != 0;
}

int twinplay_dc_load(const char* path, char* err, int err_len) {
    std::lock_guard<std::mutex> lock(gLock);
    auto fail = [&](const std::string& m) {
        if (err && err_len > 0) {
            strncpy(err, m.c_str(), (size_t)err_len - 1);
            err[err_len - 1] = 0;
        }
        return -1;
    };
    if (!path || !path[0]) return fail("No Dreamcast disc was given.");
    if (!openCore()) return fail(gLastError.empty()
        ? "The Dreamcast core is not linked. On a Mac, run scripts/build-flycast.sh and rebuild."
        : gLastError);
    if (gLoaded) {
        gApi.unload_game();
        gApi.deinit();
        gLoaded = false;
        destroyContext();
    }
    copyFlashAlias();
    bindCallbacks();
    gFrame.clear();
    gFrameW = gFrameH = 0;
    gAudio.clear();
    gResampleErr = 0;
    gApi.init();
    RetroGameInfo info{};
    info.path = path;
    info.data = nullptr;
    info.size = 0;
    if (!gApi.load_game(&info)) {
        gApi.deinit();
        destroyContext();
        return fail("Flycast could not open that disc. Dreamcast games are .cdi, .gdi (with their tracks), .chd, .cue/.bin or .zip. BIOS is optional.");
    }
    if (!gContextReady) {
        gApi.unload_game();
        gApi.deinit();
        destroyContext();
        return fail("Flycast did not get a graphics context.");
    }
    RetroSystemAvInfo av{};
    if (gApi.get_system_av_info) {
        gApi.get_system_av_info(&av);
        if (av.timing.sample_rate > 1000) gSampleRate = av.timing.sample_rate;
    }
    gLoaded = true;
    logLine(twinplay_dc_cpu_mode());
    return 0;
}

void twinplay_dc_unload(void) {
    std::lock_guard<std::mutex> lock(gLock);
    if (!gApi.lib || !gLoaded) return;
    gApi.unload_game();
    gApi.deinit();
    gLoaded = false;
    destroyContext();
}

void twinplay_dc_reset(void) {
    std::lock_guard<std::mutex> lock(gLock);
    if (gLoaded && gApi.reset) gApi.reset();
}

void twinplay_dc_run_frame(void) {
    std::lock_guard<std::mutex> lock(gLock);
    if (!gLoaded || !gApi.run) return;
    makeCurrent();
    gApi.run();
}

void twinplay_dc_set_input(uint32_t buttons, float ax, float ay, float lt, float rt) {
    std::lock_guard<std::mutex> lock(gLock);
    gButtons = buttons;
    gAx = ax; gAy = ay; gLt = lt; gRt = rt;
}

int twinplay_dc_copy_frame(uint32_t* dst, int cap, int* w, int* h) {
    std::lock_guard<std::mutex> lock(gLock);
    if (w) *w = gFrameW;
    if (h) *h = gFrameH;
    if (!dst || gFrame.empty() || cap < (int)gFrame.size()) return 0;
    std::memcpy(dst, gFrame.data(), gFrame.size() * sizeof(uint32_t));
    return (int)gFrame.size();
}

int twinplay_dc_read_audio(int16_t* dst, int max_frames) {
    std::lock_guard<std::mutex> lock(gLock);
    if (!dst || max_frames <= 0 || gAudio.size() < 2) return 0;
    int have = (int)(gAudio.size() / 2);
    int n = std::min(have, max_frames);
    std::memcpy(dst, gAudio.data(), (size_t)n * 2 * sizeof(int16_t));
    gAudio.erase(gAudio.begin(), gAudio.begin() + n * 2);
    return n;
}

int twinplay_dc_save_state(uint8_t* dst, int cap) {
    std::lock_guard<std::mutex> lock(gLock);
    if (!gLoaded || !gApi.serialize || !gApi.serialize_size || !dst) return 0;
    size_t n = gApi.serialize_size();
    if (n == 0 || (int)n > cap) return 0;
    return gApi.serialize(dst, n) ? (int)n : 0;
}

int twinplay_dc_load_state(const uint8_t* src, int size) {
    std::lock_guard<std::mutex> lock(gLock);
    if (!gLoaded || !gApi.unserialize || !src || size <= 0) return -1;
    return gApi.unserialize(src, (size_t)size) ? 0 : -1;
}

void twinplay_dc_title(char* dst, int cap) {
    if (!dst || cap <= 0) return;
    dst[0] = 0;
}
