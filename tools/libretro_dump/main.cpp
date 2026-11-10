// Headless libretro frontend. Loads any core (.dylib or .so) and a ROM, presses
// the same buttons as snes_race_harness, and dumps WRAM plus a PNG at the
// requested frames. The core itself is not part of this repository.
//
//   make -C tools/libretro_dump
//   ./tools/libretro_dump/libretro_dump core.dylib game.sfc outdir --dump-frames 1800,1801,1802,2220,2670
#include "dscore/RaceTimeline.hpp"
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <dlfcn.h>
#include <string>
#include <vector>

namespace {
constexpr unsigned kRetroApiVersion = 1;
constexpr unsigned kDeviceJoypad = 1;
constexpr unsigned kDeviceNone = 0;
constexpr unsigned kMemorySystemRam = 2;
constexpr unsigned kPix0RGB1555 = 0;
constexpr unsigned kPixXRGB8888 = 1;
constexpr unsigned kPixRGB565 = 2;

constexpr unsigned kEnvSetPixelFormat = 10;
constexpr unsigned kEnvSetInputDescriptors = 11;
constexpr unsigned kEnvGetSystemDirectory = 9;
constexpr unsigned kEnvSetVariables = 16;
constexpr unsigned kEnvGetVariable = 15;
constexpr unsigned kEnvGetVariableUpdate = 17;
constexpr unsigned kEnvSetSupportNoGame = 18;
constexpr unsigned kEnvGetCanDupe = 3;
constexpr unsigned kEnvGetLogInterface = 27;
constexpr unsigned kEnvGetSaveDirectory = 31;
constexpr unsigned kEnvSetSystemAvInfo = 32;
constexpr unsigned kEnvSetControllerInfo = 35;
constexpr unsigned kEnvSetGeometry = 37;
constexpr unsigned kEnvGetLanguage = 39;
constexpr unsigned kEnvGetCoreOptionsVersion = 52;
constexpr unsigned kEnvSetCoreOptions = 53;
constexpr unsigned kEnvSetCoreOptionsIntl = 54;
constexpr unsigned kEnvSetCoreOptionsV2 = 67;
constexpr unsigned kEnvSetCoreOptionsV2Intl = 68;
constexpr unsigned kEnvGetInputBitmasks = 51;
constexpr unsigned kEnvSetSerializationQuirks = 44;
constexpr unsigned kEnvGetAudioVideoEnable = 47;
constexpr unsigned kEnvShutdown = 7;

struct RetroSystemInfo {
    const char* library_name;
    const char* library_version;
    const char* valid_extensions;
    bool need_fullpath;
    bool block_extract;
};
struct RetroGameGeometry {
    unsigned base_width, base_height, max_width, max_height;
    float aspect_ratio;
};
struct RetroSystemTiming { double fps, sample_rate; };
struct RetroSystemAvInfo { RetroGameGeometry geometry; RetroSystemTiming timing; };
struct RetroGameInfo { const char* path; const void* data; size_t size; const char* meta; };
struct RetroVariable { const char* key; const char* value; };
struct RetroLogCallback { void (*log)(int, const char*); };

using RetroEnvironment = bool (*)(unsigned, void*);
using RetroVideoRefresh = void (*)(const void*, unsigned, unsigned, size_t);
using RetroAudioSample = void (*)(int16_t, int16_t);
using RetroAudioSampleBatch = size_t (*)(const int16_t*, size_t);
using RetroInputPoll = void (*)();
using RetroInputState = int16_t (*)(unsigned, unsigned, unsigned, unsigned);

#define LOAD(name) do { \
    api.name = (decltype(api.name))dlsym(lib, #name); \
    if (!api.name) { std::fprintf(stderr, "missing %s\n", #name); return false; } \
} while (0)

struct Api {
    void (*retro_set_environment)(RetroEnvironment);
    void (*retro_set_video_refresh)(RetroVideoRefresh);
    void (*retro_set_audio_sample)(RetroAudioSample);
    void (*retro_set_audio_sample_batch)(RetroAudioSampleBatch);
    void (*retro_set_input_poll)(RetroInputPoll);
    void (*retro_set_input_state)(RetroInputState);
    void (*retro_init)();
    void (*retro_deinit)();
    unsigned (*retro_api_version)();
    void (*retro_get_system_info)(RetroSystemInfo*);
    void (*retro_get_system_av_info)(RetroSystemAvInfo*);
    void (*retro_set_controller_port_device)(unsigned, unsigned);
    void (*retro_reset)();
    void (*retro_run)();
    bool (*retro_load_game)(const RetroGameInfo*);
    void (*retro_unload_game)();
    void* (*retro_get_memory_data)(unsigned);
    size_t (*retro_get_memory_size)(unsigned);
};

Api api;
void* lib = nullptr;
unsigned pixelFormat = kPixRGB565;
std::string directory;
dscore::u32 buttons = 0;
std::vector<uint8_t> frameRgb;
unsigned frameW = 0, frameH = 0;
bool haveFrame = false;

uint32_t crcTable[256];
bool crcReady = false;

void crcInit() {
    if (crcReady) return;
    for (uint32_t i = 0; i < 256; ++i) {
        uint32_t c = i;
        for (int k = 0; k < 8; ++k) c = (c & 1) ? (0xEDB88320u ^ (c >> 1)) : (c >> 1);
        crcTable[i] = c;
    }
    crcReady = true;
}

uint32_t crc32(const uint8_t* data, size_t n) {
    crcInit();
    uint32_t c = 0xFFFFFFFFu;
    for (size_t i = 0; i < n; ++i) c = crcTable[(c ^ data[i]) & 0xFF] ^ (c >> 8);
    return c ^ 0xFFFFFFFFu;
}

uint32_t adler32(const uint8_t* data, size_t n) {
    uint32_t a = 1, b = 0;
    for (size_t i = 0; i < n; ++i) {
        a = (a + data[i]) % 65521u;
        b = (b + a) % 65521u;
    }
    return (b << 16) | a;
}

void be32(std::vector<uint8_t>& o, uint32_t v) {
    o.push_back((uint8_t)(v >> 24));
    o.push_back((uint8_t)(v >> 16));
    o.push_back((uint8_t)(v >> 8));
    o.push_back((uint8_t)v);
}

void chunk(std::vector<uint8_t>& o, const char type[4], const uint8_t* data, size_t n) {
    be32(o, (uint32_t)n);
    size_t at = o.size();
    o.insert(o.end(), type, type + 4);
    if (n) o.insert(o.end(), data, data + n);
    uint32_t c = crc32(o.data() + at, 4 + n);
    be32(o, c);
}

bool writePng(const std::string& path, const uint8_t* rgb, unsigned w, unsigned h) {
    std::vector<uint8_t> raw;
    raw.reserve((size_t)h * (1 + (size_t)w * 3));
    for (unsigned y = 0; y < h; ++y) {
        raw.push_back(0);
        const uint8_t* row = rgb + (size_t)y * w * 3;
        raw.insert(raw.end(), row, row + (size_t)w * 3);
    }
    std::vector<uint8_t> z;
    z.push_back(0x78);
    z.push_back(0x01);
    size_t off = 0;
    while (off < raw.size()) {
        size_t n = raw.size() - off;
        if (n > 65535) n = 65535;
        bool last = off + n == raw.size();
        z.push_back(last ? 1 : 0);
        z.push_back((uint8_t)(n & 0xFF));
        z.push_back((uint8_t)((n >> 8) & 0xFF));
        uint16_t nlen = (uint16_t)~(uint16_t)n;
        z.push_back((uint8_t)(nlen & 0xFF));
        z.push_back((uint8_t)((nlen >> 8) & 0xFF));
        z.insert(z.end(), raw.data() + off, raw.data() + off + n);
        off += n;
    }
    uint32_t ad = adler32(raw.data(), raw.size());
    be32(z, ad);
    uint8_t ihdr[13];
    ihdr[0] = (uint8_t)(w >> 24); ihdr[1] = (uint8_t)(w >> 16); ihdr[2] = (uint8_t)(w >> 8); ihdr[3] = (uint8_t)w;
    ihdr[4] = (uint8_t)(h >> 24); ihdr[5] = (uint8_t)(h >> 16); ihdr[6] = (uint8_t)(h >> 8); ihdr[7] = (uint8_t)h;
    ihdr[8] = 8; ihdr[9] = 2; ihdr[10] = 0; ihdr[11] = 0; ihdr[12] = 0;
    std::vector<uint8_t> png = {137, 80, 78, 71, 13, 10, 26, 10};
    chunk(png, "IHDR", ihdr, 13);
    chunk(png, "IDAT", z.data(), z.size());
    chunk(png, "IEND", nullptr, 0);
    FILE* fp = std::fopen(path.c_str(), "wb");
    if (!fp) return false;
    bool ok = std::fwrite(png.data(), 1, png.size(), fp) == png.size();
    std::fclose(fp);
    return ok;
}

uint8_t scale5(unsigned v) { return (uint8_t)((v << 3) | (v >> 2)); }
uint8_t scale6(unsigned v) { return (uint8_t)((v << 2) | (v >> 4)); }

void captureFrame(const void* data, unsigned width, unsigned height, size_t pitch) {
    if (!data || width == 0 || height == 0 || width > 1024 || height > 1024) return;
    frameRgb.assign((size_t)width * height * 3, 0);
    const uint8_t* src = (const uint8_t*)data;
    for (unsigned y = 0; y < height; ++y) {
        const uint8_t* row = src + y * pitch;
        uint8_t* dst = frameRgb.data() + (size_t)y * width * 3;
        for (unsigned x = 0; x < width; ++x) {
            unsigned r = 0, g = 0, b = 0;
            if (pixelFormat == kPixXRGB8888) {
                uint32_t p;
                std::memcpy(&p, row + x * 4, 4);
                r = (p >> 16) & 0xFF; g = (p >> 8) & 0xFF; b = p & 0xFF;
            } else if (pixelFormat == kPix0RGB1555) {
                uint16_t p;
                std::memcpy(&p, row + x * 2, 2);
                r = scale5((p >> 10) & 31); g = scale5((p >> 5) & 31); b = scale5(p & 31);
            } else {
                uint16_t p;
                std::memcpy(&p, row + x * 2, 2);
                r = scale5((p >> 11) & 31); g = scale6((p >> 5) & 63); b = scale5(p & 31);
            }
            dst[x * 3] = (uint8_t)r;
            dst[x * 3 + 1] = (uint8_t)g;
            dst[x * 3 + 2] = (uint8_t)b;
        }
    }
    frameW = width;
    frameH = height;
    haveFrame = true;
}

void videoRefresh(const void* data, unsigned width, unsigned height, size_t pitch) {
    captureFrame(data, width, height, pitch);
}
void audioSample(int16_t, int16_t) {}
size_t audioSampleBatch(const int16_t*, size_t frames) { return frames; }
void inputPoll() {}

int16_t inputState(unsigned port, unsigned device, unsigned, unsigned id) {
    if (port != 0 || device != kDeviceJoypad || id > 11) return 0;
    static const dscore::u32 bit[12] = {
        dscore::BtnB, dscore::BtnY, dscore::BtnSelect, dscore::BtnStart,
        dscore::BtnUp, dscore::BtnDown, dscore::BtnLeft, dscore::BtnRight,
        dscore::BtnA, dscore::BtnX, dscore::BtnL, dscore::BtnR,
    };
    return (buttons & bit[id]) ? 1 : 0;
}

void coreLog(int, const char* msg) {
    if (msg) std::fprintf(stderr, "core: %s", msg);
}

bool environment(unsigned cmd, void* data) {
    switch (cmd) {
    case kEnvGetCanDupe:
        if (data) *static_cast<bool*>(data) = true;
        return true;
    case kEnvGetSystemDirectory:
    case kEnvGetSaveDirectory:
        if (data) *static_cast<const char**>(data) = directory.c_str();
        return true;
    case kEnvSetPixelFormat:
        if (!data) return false;
        pixelFormat = *static_cast<unsigned*>(data);
        return pixelFormat <= kPixRGB565;
    case kEnvSetInputDescriptors:
    case kEnvSetVariables:
    case kEnvSetSupportNoGame:
    case kEnvSetControllerInfo:
    case kEnvSetGeometry:
    case kEnvSetSystemAvInfo:
    case kEnvSetCoreOptions:
    case kEnvSetCoreOptionsIntl:
    case kEnvSetCoreOptionsV2:
    case kEnvSetCoreOptionsV2Intl:
    case kEnvSetSerializationQuirks:
        return true;
    case kEnvGetVariable:
    case kEnvGetVariableUpdate:
    case kEnvGetInputBitmasks:
        return false;
    case kEnvGetCoreOptionsVersion:
        if (data) *static_cast<unsigned*>(data) = 2;
        return true;
    case kEnvGetLanguage:
        if (data) *static_cast<unsigned*>(data) = 0;
        return true;
    case kEnvGetAudioVideoEnable:
        if (data) *static_cast<int*>(data) = 3;
        return true;
    case kEnvGetLogInterface:
        if (data) static_cast<RetroLogCallback*>(data)->log = coreLog;
        return true;
    case kEnvShutdown:
        return false;
    default:
        return false;
    }
}

bool loadApi() {
    LOAD(retro_set_environment);
    LOAD(retro_set_video_refresh);
    LOAD(retro_set_audio_sample);
    LOAD(retro_set_audio_sample_batch);
    LOAD(retro_set_input_poll);
    LOAD(retro_set_input_state);
    LOAD(retro_init);
    LOAD(retro_deinit);
    LOAD(retro_api_version);
    LOAD(retro_get_system_info);
    LOAD(retro_get_system_av_info);
    LOAD(retro_set_controller_port_device);
    LOAD(retro_reset);
    LOAD(retro_run);
    LOAD(retro_load_game);
    LOAD(retro_unload_game);
    LOAD(retro_get_memory_data);
    LOAD(retro_get_memory_size);
    return true;
}

std::vector<int> parseFrames(const char* spec) {
    std::vector<int> out;
    const char* p = spec;
    while (*p) {
        char* end = nullptr;
        long v = std::strtol(p, &end, 10);
        if (end == p || v < 0) return {};
        out.push_back((int)v);
        p = end;
        if (*p == ',') ++p;
        else if (*p) return {};
    }
    return out;
}

} // namespace

int main(int argc, char** argv) {
    const char* corePath = nullptr;
    const char* romPath = nullptr;
    const char* outDir = nullptr;
    const char* frameSpec = nullptr;
    const char* everySpec = nullptr;
    for (int i = 1; i < argc; ++i) {
        if (std::strcmp(argv[i], "--dump-frames") == 0) {
            if (i + 1 >= argc) { std::fprintf(stderr, "--dump-frames needs a list\n"); return 2; }
            frameSpec = argv[++i];
            continue;
        }
        if (std::strcmp(argv[i], "--dump-wram-every") == 0) {
            if (i + 1 >= argc) { std::fprintf(stderr, "--dump-wram-every needs START-END or START-END:STEP\n"); return 2; }
            everySpec = argv[++i];
            continue;
        }
        if (!corePath) corePath = argv[i];
        else if (!romPath) romPath = argv[i];
        else if (!outDir) outDir = argv[i];
        else {
            std::fprintf(stderr, "usage: %s <core.dylib> <rom> <outdir> [--dump-frames F,F,...] [--dump-wram-every START-END:STEP]\n", argv[0]);
            return 2;
        }
    }
    if (!corePath || !romPath || !outDir || (!frameSpec && !everySpec)) {
        std::fprintf(stderr, "usage: %s <core.dylib> <rom> <outdir> [--dump-frames F,F,...] [--dump-wram-every START-END:STEP]\n", argv[0]);
        return 2;
    }
    std::vector<int> frames;
    if (frameSpec) {
        frames = parseFrames(frameSpec);
        if (frames.empty()) { std::fprintf(stderr, "frame list is invalid\n"); return 2; }
    }
    int everyLo = -1, everyHi = -1, everyStep = 1;
    if (everySpec) {
        int a = 0, b = 0, s = 1;
        int got = std::sscanf(everySpec, "%d-%d:%d", &a, &b, &s);
        if (got < 2 || a < 0 || b < a || s < 1) {
            std::fprintf(stderr, "--dump-wram-every range is invalid\n");
            return 2;
        }
        everyLo = a; everyHi = b; everyStep = s;
    }
    int last = 0;
    for (int f : frames) if (f > last) last = f;
    if (everyHi > last) last = everyHi;
    directory = outDir;

    FILE* rf = std::fopen(romPath, "rb");
    if (!rf) { std::fprintf(stderr, "cannot open %s\n", romPath); return 1; }
    std::fseek(rf, 0, SEEK_END);
    long sz = std::ftell(rf);
    std::fseek(rf, 0, SEEK_SET);
    if (sz <= 0) { std::fprintf(stderr, "empty rom\n"); std::fclose(rf); return 1; }
    std::vector<uint8_t> rom((size_t)sz);
    if (std::fread(rom.data(), 1, rom.size(), rf) != rom.size()) {
        std::fprintf(stderr, "cannot read rom\n"); std::fclose(rf); return 1;
    }
    std::fclose(rf);

    lib = dlopen(corePath, RTLD_NOW | RTLD_LOCAL);
    if (!lib) { std::fprintf(stderr, "dlopen: %s\n", dlerror()); return 1; }
    if (!loadApi()) { dlclose(lib); return 1; }
    unsigned ver = api.retro_api_version();
    if (ver != kRetroApiVersion) std::fprintf(stderr, "api version %u\n", ver);
    RetroSystemInfo info{};
    api.retro_get_system_info(&info);
    std::fprintf(stderr, "core %s %s\n", info.library_name ? info.library_name : "?",
                 info.library_version ? info.library_version : "");
    std::fprintf(stderr,
                 "input timeline matches snes_race_harness: Start@360x6 "
                 "B@516,672,828,984,1170x6 B@1350x90 B@1680x90 steer@2700\n");

    api.retro_set_environment(environment);
    api.retro_set_video_refresh(videoRefresh);
    api.retro_set_audio_sample(audioSample);
    api.retro_set_audio_sample_batch(audioSampleBatch);
    api.retro_set_input_poll(inputPoll);
    api.retro_set_input_state(inputState);
    api.retro_init();
    RetroGameInfo game{};
    game.path = romPath;
    game.data = info.need_fullpath ? nullptr : rom.data();
    game.size = info.need_fullpath ? 0 : rom.size();
    if (!api.retro_load_game(&game)) {
        std::fprintf(stderr, "retro_load_game failed\n");
        api.retro_deinit();
        dlclose(lib);
        return 1;
    }
    api.retro_set_controller_port_device(0, kDeviceJoypad);
    api.retro_set_controller_port_device(1, kDeviceNone);

    for (int frame = 0; frame <= last; ++frame) {
        buttons = dscore::raceButtons(frame);
        api.retro_run();
        bool dump = false;
        for (int f : frames) if (f == frame) dump = true;
        if (everyLo >= 0 && frame >= everyLo && frame <= everyHi && ((frame - everyLo) % everyStep) == 0)
            dump = true;
        if (!dump) {
            if (frame && frame % 300 == 0) std::fprintf(stderr, "frame %d\n", frame);
            continue;
        }
        char path[512];
        if (haveFrame) {
            std::snprintf(path, sizeof path, "%s/frame-%d.png", outDir, frame);
            if (!writePng(path, frameRgb.data(), frameW, frameH)) {
                std::fprintf(stderr, "cannot write %s\n", path);
                return 1;
            }
            std::printf("wrote %s (%ux%u)\n", path, frameW, frameH);
        } else {
            std::fprintf(stderr, "frame %d produced no picture\n", frame);
        }
        void* ram = api.retro_get_memory_data(kMemorySystemRam);
        size_t ramSize = api.retro_get_memory_size(kMemorySystemRam);
        std::snprintf(path, sizeof path, "%s/wram-%d.bin", outDir, frame);
        FILE* wf = std::fopen(path, "wb");
        if (!wf) { std::fprintf(stderr, "cannot write %s\n", path); return 1; }
        size_t n = ram && ramSize ? ramSize : 0;
        if (n > 0x20000) n = 0x20000;
        if (n && std::fwrite(ram, 1, n, wf) != n) {
            std::fclose(wf);
            std::fprintf(stderr, "cannot write %s\n", path);
            return 1;
        }
        std::fclose(wf);
        std::printf("wrote %s (%zu bytes, core reports %zu)\n", path, n, ramSize);
    }
    api.retro_unload_game();
    api.retro_deinit();
    dlclose(lib);
    return 0;
}
