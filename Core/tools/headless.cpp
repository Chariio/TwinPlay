#include <filesystem>
// Copyright (c) 2026 Charlie Rodriguez Garcia. All rights reserved.
// Headless runner for the DS core (Linux/macOS): runs a ROM for N frames, writes
// PNG frames and a trace of PCs, I/O accesses, BIOS SWIs and CPU faults.
// Usage: headless <rom.nds> [-frames N] [-every K] [-out DIR] [-buttons-at F:MASK ...] [-touch-at F:X:Y]
#include "../src/NDSSystem.hpp"
#include "../src/GBASystem.hpp"
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <algorithm>
#include <map>
#include <string>
#include <vector>

using namespace dscore;

// ---- minimal PNG writer (stored deflate blocks, no zlib dependency)
static u32 crcTable[256];
static void initCrc() { for (u32 n = 0; n < 256; ++n) { u32 c = n; for (int k = 0; k < 8; ++k) c = (c & 1) ? 0xEDB88320u ^ (c >> 1) : c >> 1; crcTable[n] = c; } }
static u32 crc(const u8* d, size_t n, u32 c = 0xFFFFFFFFu) { for (size_t i = 0; i < n; ++i) c = crcTable[(c ^ d[i]) & 0xFF] ^ (c >> 8); return c; }
static void be32(std::vector<u8>& v, u32 x) { for (int i = 3; i >= 0; --i) v.push_back(u8(x >> (8 * i))); }
static void chunk(std::vector<u8>& out, const char* type, const std::vector<u8>& data) {
    be32(out, u32(data.size()));
    std::vector<u8> td(type, type + 4); td.insert(td.end(), data.begin(), data.end());
    out.insert(out.end(), td.begin(), td.end());
    be32(out, crc(td.data(), td.size()) ^ 0xFFFFFFFFu);
}
static void writePNG(const std::string& path, const u32* top, const u32* bottom, int scale = 1) {
    const int w = 256 * scale, h = 384 * scale, sh = 192 * scale;
    std::vector<u8> raw;
    for (int y = 0; y < h; ++y) {
        raw.push_back(0);
        const u32* row = y < sh ? top + y * w : bottom + (y - sh) * w;
        for (int x = 0; x < w; ++x) { raw.push_back(u8(row[x] >> 16)); raw.push_back(u8(row[x] >> 8)); raw.push_back(u8(row[x])); }
    }
    std::vector<u8> z = {0x78, 0x01};
    size_t pos = 0;
    while (pos < raw.size()) {
        size_t n = std::min<size_t>(65535, raw.size() - pos);
        z.push_back(pos + n == raw.size() ? 1 : 0);
        z.push_back(u8(n)); z.push_back(u8(n >> 8)); z.push_back(u8(~n)); z.push_back(u8(~n >> 8));
        z.insert(z.end(), raw.begin() + long(pos), raw.begin() + long(pos + n));
        pos += n;
    }
    u32 a = 1, b = 0; for (u8 c : raw) { a = (a + c) % 65521; b = (b + a) % 65521; }
    be32(z, (b << 16) | a);
    std::vector<u8> out = {0x89, 'P', 'N', 'G', 0x0D, 0x0A, 0x1A, 0x0A}, ihdr;
    be32(ihdr, w); be32(ihdr, h); ihdr.insert(ihdr.end(), {8, 2, 0, 0, 0});
    chunk(out, "IHDR", ihdr); chunk(out, "IDAT", z); chunk(out, "IEND", {});
    std::ofstream(path, std::ios::binary).write(reinterpret_cast<const char*>(out.data()), long(out.size()));
}

// PNG of a w x h region of a buffer with the given row stride (GBA frames).
static void writePNGRect(const std::string& path, const u32* px, int w, int h, int stride) {
    std::vector<u8> raw;
    for (int y = 0; y < h; ++y) { raw.push_back(0); for (int x = 0; x < w; ++x) { u32 c = px[y * stride + x]; raw.push_back(u8(c >> 16)); raw.push_back(u8(c >> 8)); raw.push_back(u8(c)); } }
    std::vector<u8> z = {0x78, 0x01}; size_t pos = 0;
    while (pos < raw.size()) {
        size_t n = std::min<size_t>(65535, raw.size() - pos);
        z.push_back(pos + n == raw.size() ? 1 : 0); z.push_back(u8(n)); z.push_back(u8(n >> 8)); z.push_back(u8(~n)); z.push_back(u8(~n >> 8));
        z.insert(z.end(), raw.begin() + long(pos), raw.begin() + long(pos + n)); pos += n;
    }
    u32 a = 1, b = 0; for (u8 c : raw) { a = (a + c) % 65521; b = (b + a) % 65521; }
    be32(z, (b << 16) | a);
    std::vector<u8> out = {0x89, 'P', 'N', 'G', 0x0D, 0x0A, 0x1A, 0x0A}, ihdr;
    be32(ihdr, u32(w)); be32(ihdr, u32(h)); ihdr.insert(ihdr.end(), {8, 2, 0, 0, 0});
    chunk(out, "IHDR", ihdr); chunk(out, "IDAT", z); chunk(out, "IEND", {});
    std::ofstream(path, std::ios::binary).write(reinterpret_cast<const char*>(out.data()), long(out.size()));
}

static std::vector<u8> readFile(const std::string& p) { std::ifstream f(p, std::ios::binary); return std::vector<u8>((std::istreambuf_iterator<char>(f)), {}); }

// Game Boy Advance mode: frames, audio WAV, saves and states.
static int runGBA(const std::vector<u8>& rom, int frames, int every, const std::string& out, const std::vector<std::pair<int, u32>>& presses,
                  const std::string& savePath, const std::string& stateIn, const std::string& stateOut, const std::string& wavPath, bool bench, const std::vector<std::pair<u32, u32>>& dumps) {
    GBASystem sys; std::string err;
    if (!sys.loadROM(rom.data(), rom.size(), err)) { std::fprintf(stderr, "load failed: %s\n", err.c_str()); return 1; }
    { std::error_code ec; std::filesystem::create_directories(out, ec); }
    if (!savePath.empty()) sys.loadSaveData(readFile(savePath));
    if (!stateIn.empty() && !sys.loadState(readFile(stateIn))) { std::fprintf(stderr, "state load failed\n"); return 1; }
    std::vector<s16> wav;
    auto t0 = std::chrono::steady_clock::now();
    for (int fr = 0; fr < frames; ++fr) {
        u32 buttons = 0;
        for (auto& p : presses) if (fr >= p.first && fr < p.first + 6) buttons |= p.second;
        sys.setButtons(buttons);
        std::vector<std::pair<u32, u32>> siot;
        if (std::getenv("GBA_SIO") && fr < 8) sys.ioTrace = &siot;
        sys.runFrame();
        sys.ioTrace = nullptr;
        for (auto& e : siot) { u32 o = e.first & 0x3FF; if (o >= 0x120 && o < 0x15A) std::printf("f%d %s %03X %08X\n", fr, (e.first >> 31) ? "W" : "R", o, e.second); }
        if (std::getenv("GBA_REGS") && fr < std::atoi(std::getenv("GBA_REGS")))
            std::printf("f%d DISPCNT=%04X BG=%04X %04X %04X %04X BLD=%04X/%04X/%04X IE=%04X pc=%08X\n", fr, sys.read16(0x04000000), sys.read16(0x04000008),
                        sys.read16(0x0400000A), sys.read16(0x0400000C), sys.read16(0x0400000E), sys.read16(0x04000050), sys.read16(0x04000052),
                        sys.read16(0x04000054), sys.read16(0x04000200), sys.cpu().pc());
        if (const char* w = std::getenv("GBA_WATCH")) { static u32 last = 0xDEADBEEF; u32 wa = u32(std::strtoul(w, nullptr, 16)); u32 v = sys.read32(wa); if (v != last) { std::printf("f%d [%08X]=%08X pc=%08X\n", fr, wa, v, sys.cpu().pc()); last = v; } }
        s16 ab[4096]; size_t n; while ((n = sys.readAudio(ab, 2048)) > 0) if (!wavPath.empty()) wav.insert(wav.end(), ab, ab + n * 2);
        if ((fr + 1) % every == 0 || fr == frames - 1) {
            char name[64]; std::snprintf(name, sizeof name, "/frame%04d.png", fr + 1);
            writePNGRect(out + name, sys.framebuffer(0), GBASystem::W, GBASystem::H, kScreenWidth);
        }
        if (sys.cpu().faulted) { std::printf("FAULT at frame %d: %s\n", fr, sys.cpu().faultMessage.c_str()); writePNGRect(out + "/fault.png", sys.framebuffer(0), 240, 160, 256); break; }
    }
    double ms = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - t0).count();
    if (bench) std::printf("avg %.3f ms/frame\n", ms / frames);
    if (!wavPath.empty()) {
        FILE* w = std::fopen(wavPath.c_str(), "wb");
        auto u32le = [&](u32 v) { std::fwrite(&v, 4, 1, w); }; auto u16le = [&](u16 v) { std::fwrite(&v, 2, 1, w); };
        u32 bytes = u32(wav.size() * 2);
        std::fwrite("RIFF", 1, 4, w); u32le(36 + bytes); std::fwrite("WAVEfmt ", 1, 8, w);
        u32le(16); u16le(1); u16le(2); u32le(kAudioSampleRate); u32le(kAudioSampleRate * 4); u16le(4); u16le(16);
        std::fwrite("data", 1, 4, w); u32le(bytes); std::fwrite(wav.data(), 2, wav.size(), w); std::fclose(w);
    }
    if (!stateOut.empty()) { auto st = sys.saveState(); std::ofstream(stateOut, std::ios::binary).write(reinterpret_cast<const char*>(st.data()), std::streamsize(st.size())); }
    if (!savePath.empty() && !sys.saveData().empty()) { auto sd = sys.saveData(); std::ofstream(savePath, std::ios::binary).write(reinterpret_cast<const char*>(sd.data()), std::streamsize(sd.size())); }
    if (std::getenv("GBA_IO")) {
        std::vector<std::pair<u32, u32>> tr; sys.ioTrace = &tr; sys.runFrame(); sys.ioTrace = nullptr;
        std::map<u32, u32> c; for (auto& e : tr) ++c[e.first];
        for (auto& kv : c) std::printf("%s %03X x%u\n", (kv.first >> 31) ? "W" : "R", kv.first & 0x3FF, kv.second);
    }
    if (std::getenv("GBA_HOT")) {
        std::vector<u32> tr; sys.pcTrace = &tr; sys.runFrame(); sys.pcTrace = nullptr;
        std::map<u32, u32> h; for (u32 pc : tr) ++h[pc & ~0x3Fu];
        std::vector<std::pair<u32, u32>> v; for (auto& kv : h) v.push_back({kv.second, kv.first});
        std::sort(v.rbegin(), v.rend());
        std::printf("hot:"); for (size_t i = 0; i < v.size() && i < 15; ++i) std::printf(" %08X(%u)", v[i].second, v[i].first); std::printf("\n");
        std::printf("pcs in hot block:"); std::map<u32,u32> h2; for (u32 pc : tr) if ((pc & ~0x3Fu) == u32(std::strtoul(std::getenv("GBA_HOT"), nullptr, 16) ? std::strtoul(std::getenv("GBA_HOT"), nullptr, 16) : v[0].second)) ++h2[pc];
        for (auto& kv : h2) std::printf(" %08X:%u", kv.first, kv.second); std::printf("\n");
    }
    if (std::getenv("GBA_CPU")) { for (int i=0;i<16;++i) std::printf("r%d=%08X ", i, sys.cpu().reg(i)); std::printf("cpsr=%08X\n", sys.cpu().cpsr()); }
    for (auto& d : dumps) { std::printf("%08X:", d.first); for (u32 o = 0; o < d.second; o += 2) std::printf(" %04X", sys.read16(d.first + o)); std::printf("\n"); }
    std::printf("GBA %s [%s] frames %llu, pc=%08X %s, save: %s, notice: %s\n", sys.romInfo().title.c_str(), sys.romInfo().gameCode.c_str(),
                (unsigned long long)sys.frameCount(), sys.cpu().pc(), sys.cpu().halted ? "halted" : "run", sys.saveTypeDescription().c_str(), sys.lastNotice().c_str());
    return 0;
}

struct Tracer : DebugHooks {
    FILE* log;
    std::map<u64, u64> ioCount;          // (cpu, addr, write) -> count
    std::map<u64, u64> swiCount, swiSites;
    std::map<u32, u64> pc9, pc7;
    u64 frame = 0;
    int mbLogged = 0, swiLogged = 0, fifoLogged = 0, spiLogged = 0;
    NDSSystem* sys = nullptr;
    int cardLogged = 0;
    explicit Tracer(FILE* f) : log(f) {}
    void io(bool arm9, u32 addr, int size, bool write, u32 value) override {
        if (write && (addr == 0x04000188) && fifoLogged < 600) {
            ++fifoLogged;
            std::fprintf(log, "[f%llu] FIFO %s->%s 0x%08X (tag %u, data 0x%X, flag %u)\n", (unsigned long long)frame, arm9 ? "ARM9" : "ARM7",
                         arm9 ? "ARM7" : "ARM9", value, value & 31, (value >> 6), (value >> 5) & 1);
            if (sys) { auto& c = arm9 ? sys->arm9() : sys->arm7(); std::fprintf(log, "   pc %08X lr %08X sp %08X\n", c.reg(15), c.reg(14), c.reg(13)); }
        }
        if (!write && addr == 0x04100000 && fifoLogged < 600) { ++fifoLogged; std::fprintf(log, "[f%llu] FIFO %s recv 0x%08X\n", (unsigned long long)frame, arm9 ? "ARM9" : "ARM7", value); }
        if (write && !arm9 && (addr == 0x040001C0 || addr == 0x040001C2) && spiLogged < 20000) {
            ++spiLogged;
            std::fprintf(log, "[f%llu] SPI %s 0x%X\n", (unsigned long long)frame, addr == 0x040001C0 ? "cnt " : "data", value);
        }
        if (write && addr == 0x040001A4 && size == 4 && (value & 0x80000000u) && cardLogged < 3000 && sys) {
            ++cardLogged;
            std::fprintf(log, "[f%llu] CARD %s cmd", (unsigned long long)frame, arm9 ? "ARM9" : "ARM7");
            for (int i = 0; i < 8; ++i) std::fprintf(log, " %02X", sys->read(true, 0x040001A8 + u32(i), 1));
            std::fprintf(log, " ctrl %08X\n", value);
        }
        if (write && (addr == 0x0400006C || addr == 0x0400106C) && mbLogged < 50) { ++mbLogged; std::fprintf(log, "[f%llu] MASTER_BRIGHT %s = %X\n", (unsigned long long)frame, addr == 0x0400006C ? "A" : "B", value); }
        u64 key = (u64(arm9) << 40) | (u64(write) << 39) | addr;
        if (ioCount[key]++ == 0)
            std::fprintf(log, "[f%llu] first %s %s 0x%08X size %d value 0x%X\n", (unsigned long long)frame, arm9 ? "ARM9" : "ARM7",
                         write ? "write" : "read ", addr, size, value);
    }
    void swi(bool arm9, u32 n, u32 pc) override {
        ++swiCount[(u64(arm9) << 32) | n];
        if (swiSites[(u64(arm9) << 40) | (u64(n) << 32) | pc]++ == 0 && swiLogged < 400) {
            ++swiLogged;
            std::fprintf(log, "[f%llu] %s SWI 0x%02X at pc 0x%08X\n", (unsigned long long)frame, arm9 ? "ARM9" : "ARM7", n, pc);
        }
    }
    void sample(u32 a, u32 b) override { ++pc9[a & ~0xFu]; ++pc7[b & ~0xFu]; }
};


#if defined(__APPLE__) && defined(__aarch64__) && defined(DSEMU_PCPROF)
// PC-sampling profiler for headless perf work (build with -DDSEMU_PCPROF): SIGPROF every 50 us
// of CPU time, raw PCs written to pcprof.txt for symbolizing with atos.
#include <signal.h>
#include <sys/time.h>
#include <sys/ucontext.h>
#include <mach-o/dyld.h>
static uint64_t gPcs[1 << 21]; static volatile size_t gPcCount = 0;
static void pcSample(int, siginfo_t*, void* ctx) {
    size_t n = gPcCount; if (n < (sizeof gPcs / sizeof gPcs[0])) { gPcs[n] = uint64_t(((ucontext_t*)ctx)->uc_mcontext->__ss.__pc); gPcCount = n + 1; }
}
struct PcProf {
    PcProf() { struct sigaction sa{}; sa.sa_sigaction = pcSample; sa.sa_flags = SA_SIGINFO | SA_RESTART; sigaction(SIGPROF, &sa, nullptr);
               itimerval t{{0, 50}, {0, 50}}; setitimer(ITIMER_PROF, &t, nullptr); }
    ~PcProf() { itimerval t{}; setitimer(ITIMER_PROF, &t, nullptr);
        FILE* f = std::fopen("pcprof.txt", "w"); if (!f) return;
        std::fprintf(f, "slide %llx\n", (unsigned long long)_dyld_get_image_vmaddr_slide(0));
        for (size_t i = 0; i < gPcCount; ++i) std::fprintf(f, "%llx\n", (unsigned long long)gPcs[i]);
        std::fclose(f); }
};
#endif
int main(int argc, char** argv) {
    if (argc < 2) { std::fprintf(stderr, "usage: %s rom.nds [-frames N] [-every K] [-out DIR] [-press F:MASK] [-bios7 file] [-notrace] [-bench] [-threads N] [-skip N] [-wav file] [-interp 0|1|2] [-touch F:X:Y] [-drag F:X0:Y0:X1:Y1:LEN] [-dump ADDR:LEN] [-dump7 ADDR:LEN] [-scale N] [-aa 0|1|2] [-texfilter] [-wide]\n", argv[0]); return 2; }
    initCrc();
    int frames = 300, every = 30; std::string out = "frames";
    std::vector<std::pair<int, u32>> presses; std::string bios7, lle9, lle7, fwPath; bool fwBoot = false; bool trace = true, bench = false; int threads = 0, skip = 0; std::string wavPath; int scale = 1; int interp = 2; std::vector<s16> wav;
    std::string savePath, stateIn, stateOut;
    std::vector<std::pair<u32, u32>> dumps;
    struct Touch { int frame, x, y; }; std::vector<Touch> touches;
    struct Poke { int f0, f1; u32 addr, val; int size; }; std::vector<Poke> pokes;
    struct Hold { int f0, f1; u32 mask; }; std::vector<Hold> holds; int stateEvery = 0;
    struct Drag { int frame, x0, y0, x1, y1, len; }; std::vector<Drag> drags;
    int aa = 0; bool texFilter = false, wide = false;
    for (int i = 2; i < argc; ++i) {
        std::string a = argv[i];
        if (a == "-frames" && i + 1 < argc) frames = std::atoi(argv[++i]);
        else if (a == "-every" && i + 1 < argc) every = std::atoi(argv[++i]);
        else if (a == "-out" && i + 1 < argc) out = argv[++i];
        else if (a == "-dump" && i + 1 < argc) { unsigned ad = 0, ln = 0; std::sscanf(argv[++i], "%x:%x", &ad, &ln); dumps.push_back({ad, ln}); }
        else if (a == "-dump7" && i + 1 < argc) { unsigned ad = 0, ln = 0; std::sscanf(argv[++i], "%x:%x", &ad, &ln); dumps.push_back({ad | 1u, ln}); }
        else if (a == "-drag" && i + 1 < argc) { Drag d{0, 64, 96, 192, 96, 20}; std::sscanf(argv[++i], "%d:%d:%d:%d:%d:%d", &d.frame, &d.x0, &d.y0, &d.x1, &d.y1, &d.len); if (d.len < 1) d.len = 1; drags.push_back(d); }
        else if (a == "-touch" && i + 1 < argc) { int f = 0, x = 128, y = 96; std::sscanf(argv[++i], "%d:%d:%d", &f, &x, &y); touches.push_back({f, x, y}); }
        else if (a == "-poke" && i + 1 < argc) { Poke q{}; std::sscanf(argv[++i], "%d:%d:%x:%x:%d", &q.f0, &q.f1, &q.addr, &q.val, &q.size); pokes.push_back(q); }
        else if (a == "-hold" && i + 1 < argc) { Hold h{}; int m = 0; std::sscanf(argv[++i], "%d:%d:%i", &h.f0, &h.f1, &m); h.mask = u32(m); holds.push_back(h); }
        else if (a == "-state-every" && i + 1 < argc) stateEvery = std::atoi(argv[++i]);
        else if (a == "-press" && i + 1 < argc) { std::string v = argv[++i]; presses.push_back({std::atoi(v.c_str()), u32(std::strtoul(v.substr(v.find(':') + 1).c_str(), nullptr, 0))}); }
        else if (a == "-bios7" && i + 1 < argc) bios7 = argv[++i];
        else if (a == "-lle9" && i + 1 < argc) lle9 = argv[++i];
        else if (a == "-lle7" && i + 1 < argc) lle7 = argv[++i];
        else if (a == "-fw" && i + 1 < argc) fwPath = argv[++i];
        else if (a == "-fwboot") fwBoot = true;
        else if (a == "-notrace") trace = false;
        else if (a == "-threads" && i + 1 < argc) threads = std::atoi(argv[++i]);
        else if (a == "-skip" && i + 1 < argc) skip = std::atoi(argv[++i]);
        else if (a == "-wav" && i + 1 < argc) wavPath = argv[++i];
        else if (a == "-interp" && i + 1 < argc) interp = std::atoi(argv[++i]);
        else if (a == "-scale" && i + 1 < argc) scale = std::atoi(argv[++i]);
        else if (a == "-aa" && i + 1 < argc) aa = std::atoi(argv[++i]);
        else if (a == "-texfilter") texFilter = true;
        else if (a == "-wide") wide = true;
        else if (a == "-save" && i + 1 < argc) savePath = argv[++i];
        else if (a == "-state-in" && i + 1 < argc) stateIn = argv[++i];
        else if (a == "-state-out" && i + 1 < argc) stateOut = argv[++i];
        else if (a == "-bench") { bench = true; trace = false; }
    }
    std::ifstream f(argv[1], std::ios::binary);
    std::vector<u8> rom((std::istreambuf_iterator<char>(f)), {});
    {
        std::string path = argv[1]; std::string ext = path.size() > 4 ? path.substr(path.size() - 4) : "";
        for (auto& ch : ext) ch = char(std::tolower(ch));
        if (ext == ".gba" || isGBAImage(rom.data(), rom.size()))
            return runGBA(rom, frames, every, out, presses, savePath, stateIn, stateOut, wavPath, bench, dumps);
    }
    NDSSystem sys;
    if (!bios7.empty()) { std::ifstream b(bios7, std::ios::binary); sys.setARM7BIOS(std::vector<u8>((std::istreambuf_iterator<char>(b)), {})); }
    if (!lle9.empty()) {   // user's own BIOS (LLE), as the app does: set before loading the ROM
        auto rd = [](const std::string& p) { std::ifstream b(p, std::ios::binary); return std::vector<u8>((std::istreambuf_iterator<char>(b)), {}); };
        std::vector<u8> fw = fwPath.empty() ? std::vector<u8>{} : rd(fwPath);
        std::fprintf(stderr, "setLLEBIOS -> %d\n", int(sys.setLLEBIOS(rd(lle9), rd(lle7), fw, fwBoot)));
    }
    std::string err;
    if (!sys.loadROM(rom.data(), rom.size(), err)) { std::fprintf(stderr, "load failed: %s\n", err.c_str()); return 1; }
    { std::error_code ec; std::filesystem::create_directories(out, ec); if (ec) return 1; }
    FILE* log = std::fopen((out + "/trace.log").c_str(), "w");
    Tracer t(log); t.sys = &sys;
    if (trace) sys.setDebugHooks(&t);
    sys.setRenderThreads(threads); sys.setFrameSkip(skip); sys.setRenderScale(scale); sys.setAudioInterpolation(interp);
    sys.setEnhancements(aa, texFilter, wide);
    if (!savePath.empty()) {
        std::ifstream sf(savePath, std::ios::binary);
        std::vector<u8> sd((std::istreambuf_iterator<char>(sf)), std::istreambuf_iterator<char>());
        sys.loadSaveData(sd);
    }
    if (!stateIn.empty()) {
        std::ifstream sf(stateIn, std::ios::binary);
        std::vector<u8> sd((std::istreambuf_iterator<char>(sf)), std::istreambuf_iterator<char>());
        if (!sys.loadState(sd)) { std::fprintf(stderr, "state load failed\n"); return 1; }
    }
    using clk = std::chrono::steady_clock;
#if defined(__APPLE__) && defined(__aarch64__) && defined(DSEMU_PCPROF)
    PcProf pcprof;
#endif
    auto winStart = clk::now(); double winMax = 0;
    u64 i9Start = sys.arm9().instructionsExecuted, i7Start = sys.arm7().instructionsExecuted;
    std::string lastStatus;
    for (int fr = 0; fr < frames; ++fr) {
        t.frame = u64(fr);
        u32 buttons = 0;
        for (auto& p : presses) if (fr >= p.first && fr < p.first + 6) buttons |= p.second;
        { bool down = false; int tx = 0, ty = 0;
          for (auto& t : touches) if (fr >= t.frame && fr < t.frame + 6) { down = true; tx = t.x; ty = t.y; }
          for (auto& d : drags) if (fr >= d.frame && fr <= d.frame + d.len) { int k = int(fr) - d.frame; down = true; tx = d.x0 + (d.x1 - d.x0) * k / d.len; ty = d.y0 + (d.y1 - d.y0) * k / d.len; }
          sys.setTouch(down, tx, ty); }
        for (auto& h : holds) if (fr >= h.f0 && fr < h.f1) buttons |= h.mask;
        for (auto& q : pokes) if (fr >= q.f0 && fr < q.f1) sys.write(true, q.addr, q.val, q.size);
        sys.setButtons(buttons);
        if (stateEvery && fr % stateEvery == 0) { auto st = sys.saveState(); char sn[64]; std::snprintf(sn, sizeof sn, "/st%05d.state", fr); std::ofstream(out + sn, std::ios::binary).write(reinterpret_cast<const char*>(st.data()), std::streamsize(st.size())); }
        auto t0 = clk::now();
        sys.runFrame();
        double ms = std::chrono::duration<double, std::milli>(clk::now() - t0).count();
        { s16 ab[4096]; size_t n; while ((n = sys.readAudio(ab, 2048)) > 0) if (!wavPath.empty()) wav.insert(wav.end(), ab, ab + n * 2); }
        winMax = std::max(winMax, ms);
        if (sys.stuckFrames() == 15 || sys.stuckFrames() == 120) { std::fprintf(log, "[f%d] STUCK %s\n", fr, sys.freezeReport().c_str()); std::fflush(log); }
        if (ms > 200) { std::fprintf(log, "[f%d] SLOW FRAME %.0f ms\n", fr, ms); std::fflush(log); }
        if (bench && (fr + 1) % 100 == 0) {
            double avg = std::chrono::duration<double, std::milli>(clk::now() - winStart).count() / 100.0;
            double i9 = double(sys.arm9().instructionsExecuted - i9Start) / 100.0, i7 = double(sys.arm7().instructionsExecuted - i7Start) / 100.0;
            std::printf("frames %4d-%4d: avg %.2f ms/frame, worst %.2f ms, arm9 %.0fk instr/frame, arm7 %.0fk\n", fr - 99, fr, avg, winMax, i9 / 1000, i7 / 1000);
            i9Start = sys.arm9().instructionsExecuted; i7Start = sys.arm7().instructionsExecuted;
            std::fflush(stdout);
            winStart = clk::now(); winMax = 0;
        }
        std::string st = sys.statusText();
        if (st != lastStatus && st.rfind("Experimental core", 0) != 0) { std::fprintf(log, "[f%d] status: %s\n", fr, st.c_str()); lastStatus = st; }
        if ((fr + 1) % every == 0 || fr == frames - 1) {
            char name[64]; std::snprintf(name, sizeof name, "/frame%04d.png", fr + 1);
            writePNG(out + name, sys.framebuffer(0), sys.framebuffer(1));
            if (sys.renderScale() > 1) {
                char hn[64]; std::snprintf(hn, sizeof hn, "/frame%04d_x%d.png", fr + 1, sys.renderScale());
                writePNG(out + hn, sys.framebufferHiRes(0), sys.framebufferHiRes(1), sys.renderScale());
            }
            auto& g = sys.gpu3d().stats;
            std::fprintf(log, "[f%d] 3D polys=%d verts=%d swap=%X submitted=%llu culled=%llu clipped=%llu far=%llu overflow=%llu shadow=%llu DISP3DCNT=%04X\n", fr,
                         sys.gpu3d().lastPolygonCount(), sys.gpu3d().lastVertexCount(), sys.gpu3d().lastSwapParam(), (unsigned long long)g.submitted, (unsigned long long)g.culled,
                         (unsigned long long)g.clippedAway, (unsigned long long)g.farDropped, (unsigned long long)g.overflow, (unsigned long long)g.shadow, sys.read(true, 0x04000060, 2));
            g = {};
            std::fprintf(log, "[f%d] 2D A: DISPCNT=%08X BG0-3CNT=%04X %04X %04X %04X BLDCNT=%04X BLDALPHA=%04X BLDY=%04X\n", fr,
                         sys.read(true, 0x04000000, 4), sys.read(true, 0x04000008, 2), sys.read(true, 0x0400000A, 2), sys.read(true, 0x0400000C, 2),
                         sys.read(true, 0x0400000E, 2), sys.read(true, 0x04000050, 2), sys.read(true, 0x04000052, 2), sys.read(true, 0x04000054, 2));
            std::fprintf(log, "[f%d] pc9=0x%08X pc7=0x%08X arm9 %s arm7 %s\n", fr, sys.arm9().pc(), sys.arm7().pc(),
                         sys.arm9().halted ? "halted" : sys.arm9().idle ? "idle" : "run", sys.arm7().halted ? "halted" : sys.arm7().idle ? "idle" : "run");
        }
        if (sys.arm9().faulted || sys.arm7().faulted) {
            std::fprintf(log, "[f%d] FAULT: %s | %s\n", fr, sys.arm9().faultMessage.c_str(), sys.arm7().faultMessage.c_str());
            writePNG(out + "/fault.png", sys.framebuffer(0), sys.framebuffer(1));
            break;
        }
    }
    auto top = [&](const std::map<u32, u64>& m, const char* name) {
        std::vector<std::pair<u64, u32>> v; for (auto& kv : m) v.push_back({kv.second, kv.first});
        std::sort(v.rbegin(), v.rend());
        std::fprintf(log, "hot PCs %s:", name);
        for (size_t i = 0; i < v.size() && i < 12; ++i) std::fprintf(log, " %08X(%llu)", v[i].second, (unsigned long long)v[i].first);
        std::fprintf(log, "\n");
    };
    top(t.pc9, "ARM9"); top(t.pc7, "ARM7");
    std::fprintf(log, "SWI totals:"); for (auto& kv : t.swiCount) std::fprintf(log, " %s:%02llX=%llu", (kv.first >> 32) ? "9" : "7", (unsigned long long)(kv.first & 0xFF), (unsigned long long)kv.second);
    std::fprintf(log, "\n");
    std::fprintf(log, "final ARM9 cpsr=%08X regs:", sys.arm9().cpsr()); for (int i = 0; i < 16; ++i) std::fprintf(log, " %08X", sys.arm9().reg(i));
    std::fprintf(log, "\nfinal ARM7 cpsr=%08X regs:", sys.arm7().cpsr()); for (int i = 0; i < 16; ++i) std::fprintf(log, " %08X", sys.arm7().reg(i));
    std::fprintf(log, "\n");
    for (int k = 0; k < 2; ++k)
        std::fprintf(log, "%s IME=%X IE=%08X IF=%08X DISPSTAT=%04X POWCNT1=%04X DISPCNT=%08X/%08X\n", k ? "ARM7" : "ARM9", sys.read(!k, 0x04000208, 4),
                     sys.read(!k, 0x04000210, 4), sys.read(!k, 0x04000214, 4), sys.read(!k, 0x04000004, 2), sys.read(true, 0x04000304, 2),
                     sys.read(true, 0x04000000, 4), sys.read(true, 0x04001000, 4));
    auto dump = [&](const char* name, bool arm9, u32 base, u32 len) {
        std::vector<u8> b(len); for (u32 i = 0; i < len; ++i) b[i] = u8(sys.read(arm9, base + i, 1));
        std::ofstream(out + "/" + name, std::ios::binary).write(reinterpret_cast<const char*>(b.data()), long(len));
    };
    dump("main.bin", true, 0x02000000, 0x400000);
    dump("arm7wram.bin", false, 0x03800000, 0x10000);
    dump("shared7.bin", false, 0x037F8000, 0x8000);
    dump("itcm.bin", true, 0x01FF8000, 0x8000);
    std::fclose(log);
    if (!wavPath.empty()) {                        // 16-bit stereo PCM WAV at the core's output rate
        FILE* w = std::fopen(wavPath.c_str(), "wb");
        auto u32le = [&](u32 v) { std::fwrite(&v, 4, 1, w); };
        auto u16le = [&](u16 v) { std::fwrite(&v, 2, 1, w); };
        u32 bytes = u32(wav.size() * 2);
        std::fwrite("RIFF", 1, 4, w); u32le(36 + bytes); std::fwrite("WAVEfmt ", 1, 8, w);
        u32le(16); u16le(1); u16le(2); u32le(kAudioSampleRate); u32le(kAudioSampleRate * 4); u16le(4); u16le(16);
        std::fwrite("data", 1, 4, w); u32le(bytes); std::fwrite(wav.data(), 2, wav.size(), w); std::fclose(w);
        std::printf("wav: %zu frames (%.2f s)\n", wav.size() / 2, wav.size() / 2.0 / kAudioSampleRate);
    }
    std::printf("capture lines blocked (bank not LCDC): %llu\n", (unsigned long long)sys.gpuA().captureBlocked);
    std::printf("done; see %s/trace.log\n", out.c_str());
    if (!stateOut.empty()) { auto st = sys.saveState(); std::ofstream so(stateOut, std::ios::binary); so.write(reinterpret_cast<const char*>(st.data()), std::streamsize(st.size())); }
    for (auto& d : dumps)
        for (u32 o = 0; o < d.second; o += 4) {
            bool a7 = d.first & 1; u32 base = d.first & ~3u;
            if (o % 32 == 0) std::printf("%s%s%08X:", o ? "\n" : "", a7 ? "7:" : "", base + o);
            std::printf(" %08X", sys.read(!a7, base + o, 4));
        }
    if (!dumps.empty()) std::printf("\n");
    if (!savePath.empty() && !sys.saveData().empty()) {
        std::ofstream so(savePath, std::ios::binary);
        auto sd = sys.saveData(); so.write(reinterpret_cast<const char*>(sd.data()), std::streamsize(sd.size()));
    }
    std::printf("save: %s (%zu bytes)%s\n", sys.saveTypeDescription().c_str(), sys.saveData().size(), sys.loadedSaveRejected() ? " - loaded file rejected" : "");
    std::printf("wifi accesses: %u\n", sys.wifiAccesses());
    return 0;
}
