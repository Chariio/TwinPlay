#include "dscore/RaceRun.hpp"
#include "dscore/RaceTimeline.hpp"
#include "dscore/SnesTrace.hpp"
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <string>
#include <vector>

namespace dscore {
namespace {

bool writePPM(const std::string& path, const u32* px, int w, int h) {
    std::ofstream out(path, std::ios::binary);
    if (!out) return false;
    out << "P6\n" << w << " " << h << "\n255\n";
    for (int i = 0; i < w * h; ++i) {
        u32 p = px[i];
        char rgb[3] = { (char)((p >> 16) & 0xFF), (char)((p >> 8) & 0xFF), (char)(p & 0xFF) };
        out.write(rgb, 3);
    }
    return (bool)out;
}

uint64_t hashPixels(const u32* px, int n) {
    uint64_t h = 14695981039346656037ull;
    for (int i = 0; i < n; ++i) {
        u32 p = px[i];
        h ^= (uint64_t)(p & 0xFFFFFF);
        h *= 1099511628211ull;
    }
    return h;
}

bool wantFrame(const std::vector<int>& frames, int frame) {
    for (int f : frames) if (f == frame) return true;
    return false;
}

std::vector<int> parseFrameList(const char* spec, std::string& error) {
    std::vector<int> out;
    const char* p = spec;
    while (*p) {
        char* end = nullptr;
        long v = std::strtol(p, &end, 10);
        if (end == p || v < 0 || v > 1000000) {
            error = "frame list is invalid";
            return {};
        }
        out.push_back((int)v);
        p = end;
        if (*p == ',') ++p;
        else if (*p) {
            error = "frame list is invalid";
            return {};
        }
    }
    if (out.empty()) error = "frame list is empty";
    return out;
}

const int kShots[] = {2220, 2670, 3000, 3900};

} // namespace

bool parseRaceCommand(int argc, char** argv, std::string& romPath, std::string& outDir,
                      RaceRunOptions& opt, std::string& error) {
    romPath.clear();
    outDir.clear();
    opt = RaceRunOptions{};
    const char* rom = nullptr;
    const char* dir = nullptr;
    for (int i = 1; i < argc; ++i) {
        if (std::strcmp(argv[i], "--trace") == 0) {
            if (i + 1 >= argc) { error = "--trace needs a frame or START-END"; return false; }
            const char* spec = argv[++i];
            int a = 0, b = 0;
            if (std::sscanf(spec, "%d-%d", &a, &b) == 2) { opt.traceLo = a; opt.traceHi = b; }
            else { opt.traceLo = opt.traceHi = std::atoi(spec); }
            if (opt.traceLo < 0 || opt.traceHi < opt.traceLo) { error = "--trace range is invalid"; return false; }
            continue;
        }
        if (std::strcmp(argv[i], "--watch-from") == 0) {
            if (i + 1 >= argc) { error = "--watch-from needs a frame number"; return false; }
            opt.watchFrom = std::atoi(argv[++i]);
            if (opt.watchFrom < 0) { error = "--watch-from range is invalid"; return false; }
            continue;
        }
        if (std::strcmp(argv[i], "--dump-wram") == 0) {
            if (i + 1 >= argc) { error = "--dump-wram needs a frame list"; return false; }
            opt.dumpWram = parseFrameList(argv[++i], error);
            if (!error.empty()) return false;
            continue;
        }
        if (std::strcmp(argv[i], "--pc-trace-bank") == 0) {
            if (i + 1 >= argc) { error = "--pc-trace-bank needs a bank"; return false; }
            char* end = nullptr;
            long bank = std::strtol(argv[++i], &end, 16);
            if (end == argv[i] || *end || bank < 0 || bank > 0xFF) { error = "--pc-trace-bank is invalid"; return false; }
            opt.pcBank = (int)bank;
            continue;
        }
        if (std::strcmp(argv[i], "--dsp-log") == 0) {
            if (i + 1 >= argc) { error = "--dsp-log needs START-END"; return false; }
            int a = 0, b = 0;
            if (std::sscanf(argv[++i], "%d-%d", &a, &b) != 2 || a < 0 || b < a) {
                error = "--dsp-log range is invalid";
                return false;
            }
            opt.dspLogLo = a;
            opt.dspLogHi = b;
            continue;
        }
        if (std::strcmp(argv[i], "--dsp-raw") == 0) {
            if (i + 1 >= argc) { error = "--dsp-raw needs START-END"; return false; }
            int a = 0, b = 0;
            if (std::sscanf(argv[++i], "%d-%d", &a, &b) != 2 || a < 0 || b < a) {
                error = "--dsp-raw range is invalid";
                return false;
            }
            opt.dspRawLo = a;
            opt.dspRawHi = b;
            continue;
        }
        if (std::strcmp(argv[i], "--dump-wram-every") == 0) {
            if (i + 1 >= argc) { error = "--dump-wram-every needs START-END or START-END:STEP"; return false; }
            int a = 0, b = 0, s = 1;
            const char* spec = argv[++i];
            int got = std::sscanf(spec, "%d-%d:%d", &a, &b, &s);
            if (got < 2 || a < 0 || b < a || s < 1) {
                error = "--dump-wram-every range is invalid";
                return false;
            }
            opt.dumpEveryLo = a;
            opt.dumpEveryHi = b;
            opt.dumpEveryStep = s;
            continue;
        }
        if (!rom) rom = argv[i];
        else if (!dir) dir = argv[i];
        else { error = "unexpected argument"; return false; }
    }
    if (!rom || !dir) { error = "need a rom and an output directory"; return false; }
    romPath = rom;
    outDir = dir;
    int watchHi = opt.watchFrom > 2230 ? opt.watchFrom : 2230;
    int last = 3900;
    if (opt.watchFrom >= 0 && opt.traceLo < 0) last = watchHi;
    for (int f : opt.dumpWram) if (f > last) last = f;
    if (opt.pcBank >= 0 && last < 2220) last = 2220;
    if (opt.traceHi > last) last = opt.traceHi;
    if (opt.dspLogHi > last) last = opt.dspLogHi;
    if (opt.dspRawHi > last) last = opt.dspRawHi;
    if (opt.dumpEveryHi > last) last = opt.dumpEveryHi;
    opt.last = last;
    return true;
}

RaceRunResult runSnesRace(EmulatorCore& core, const RaceRunOptions& opt) {
    RaceRunResult result;
    const int w = core.screenWidth(), h = core.screenHeight();
    if (!core.framebuffer(0) || w <= 0 || h <= 0) {
        result.error = "no framebuffer";
        return result;
    }
    const int watchHi = opt.watchFrom > 2230 ? opt.watchFrom : 2230;
    std::vector<s16> audio(4096 * 2);
    std::ofstream watch;
    if (opt.watchFrom >= 0 && !opt.outDir.empty()) {
        std::string path = opt.outDir + "/watch.txt";
        watch.open(path, std::ios::binary);
        if (!watch) { result.error = "cannot write " + path; return result; }
        watch << "write watch $7E3C00-$7E3FFF and $7E4000-$7EFFFF\n";
        watch << "sources: CPU direct, CPU or DMA $2180 WMDATA, DMA A-bus, HDMA\n";
        watch << "also: every $2181-$2183 write, every $420B DMA setup\n";
        watch << "cap: 50 lines of each kind per frame; the counts on the frame line are the totals\n";
        watch << "DMA size is the $43x5 value; 0000 means 65536 bytes. dir AtoB is bus $2180 as the destination.\n";
        watch << "buttons: Start@360x6 B@516,672,828,984,1170x6 B@1350x90 B@1680x90 steer@2700\n";
        watch << "power-on RAM is seed 0. Flags do not change this timeline.\n\n";
    }
    std::vector<u32> pcs(65536);
    std::vector<u8> wram;
    bool dumpSome = !opt.dumpWram.empty() || opt.dumpEveryLo >= 0;
    if (dumpSome) wram.assign(0x20000, 0);
    std::FILE* dspFile = nullptr;
    if (opt.dspLogLo >= 0 && !opt.outDir.empty()) {
        std::string path = opt.outDir + "/dsp-log.txt";
        dspFile = std::fopen(path.c_str(), "wb");
        if (!dspFile) { result.error = "cannot write " + path; return result; }
        std::fputs("dsp-1 commands. raw is the byte written while waiting. nop is 0x40-0xFF.\n", dspFile);
        std::printf("dsp log %d-%d -> %s\n", opt.dspLogLo, opt.dspLogHi, path.c_str());
    }
    snesDspLogAttach(dspFile);
    std::FILE* rawFile = nullptr;
    if (opt.dspRawLo >= 0 && !opt.outDir.empty()) {
        std::string path = opt.outDir + "/dsp-raw.txt";
        rawFile = std::fopen(path.c_str(), "wb");
        if (!rawFile) {
            snesDspLogAttach(nullptr);
            if (dspFile) std::fclose(dspFile);
            result.error = "cannot write " + path;
            return result;
        }
        std::fputs("dsp-1 data port. W is a write, R is a read.\n", rawFile);
        std::printf("dsp raw %d-%d -> %s\n", opt.dspRawLo, opt.dspRawHi, path.c_str());
    }
    snesDspRawAttach(rawFile);
    for (int frame = 0; frame <= opt.last; ++frame) {
        u32 buttons = opt.timeline ? raceButtons(frame) : 0;
        core.setButtons(buttons);
        bool tracing = opt.traceLo >= 0 && frame >= opt.traceLo && frame <= opt.traceHi;
        bool watching = opt.watchFrom >= 0 && frame >= opt.watchFrom && frame <= watchHi;
        bool pc = opt.pcBank >= 0 && racePcTraceFrame(frame);
        bool dspLog = opt.dspLogLo >= 0 && frame >= opt.dspLogLo && frame <= opt.dspLogHi;
        bool dspRaw = opt.dspRawLo >= 0 && frame >= opt.dspRawLo && frame <= opt.dspRawHi;
        if (tracing) superFamicomTraceBegin();
        if (watching) superFamicomWatchOpenFrame(frame, buttons);
        if (pc) {
            snesPcTraceBank = opt.pcBank;
            snesPcTraceClear();
            snesPcTraceArmed = true;
        }
        snesDspLogSetFrame(frame, dspLog);
        snesDspRawSetFrame(frame, dspRaw);
        core.runFrame();
        snesDspLogSetFrame(frame, false);
        snesDspRawSetFrame(frame, false);
        if (pc) {
            snesPcTraceArmed = false;
            int n = snesPcTraceCollect(pcs.data(), (int)pcs.size());
            if (!opt.outDir.empty()) {
                char path[512];
                std::snprintf(path, sizeof path, "%s/pc-%02X-%d.txt", opt.outDir.c_str(), opt.pcBank & 0xFF, frame);
                std::ofstream out(path, std::ios::binary);
                if (!out) {
                    result.error = "cannot write pc trace";
                    snesDspLogAttach(nullptr);
                    snesDspRawAttach(nullptr);
                    if (dspFile) std::fclose(dspFile);
                    if (rawFile) std::fclose(rawFile);
                    return result;
                }
                char head[64];
                std::snprintf(head, sizeof head, "bank $%02X frame %d unique %d\n", opt.pcBank & 0xFF, frame, n);
                out << head;
                int shown = n < (int)pcs.size() ? n : (int)pcs.size();
                for (int i = 0; i < shown; ++i) {
                    char line[16];
                    std::snprintf(line, sizeof line, "%06X\n", pcs[i] & 0xFFFFFF);
                    out << line;
                }
                std::printf("wrote %s (%d unique)\n", path, n);
            }
        }
        if (watching) {
            std::string text = superFamicomWatchCloseFrame();
            if (watch) { watch << text; watch.flush(); }
        }
        if (tracing) {
            std::string text = superFamicomTraceEnd();
            if (!opt.outDir.empty()) {
                char path[512];
                std::snprintf(path, sizeof path, "%s/trace-%d.txt", opt.outDir.c_str(), frame);
                std::ofstream out(path, std::ios::binary);
                if (!out) {
                    result.error = "cannot write trace";
                    snesDspLogAttach(nullptr);
                    snesDspRawAttach(nullptr);
                    if (dspFile) std::fclose(dspFile);
                    if (rawFile) std::fclose(rawFile);
                    return result;
                }
                out << text;
                std::printf("wrote %s (frame %d)\n", path, frame);
            }
        }
        core.readAudio(audio.data(), audio.size() / 2);
        if (frame == 2220) {
            result.hash2220 = hashPixels(core.framebuffer(0), w * h);
            result.have2220 = true;
        }
        bool dumpEvery = opt.dumpEveryLo >= 0 && frame >= opt.dumpEveryLo && frame <= opt.dumpEveryHi
            && ((frame - opt.dumpEveryLo) % opt.dumpEveryStep) == 0;
        if (!opt.outDir.empty() && (wantFrame(opt.dumpWram, frame) || dumpEvery)) {
            superFamicomCpuDebug(nullptr, wram.data(), 0, 0x20000);
            char path[512];
            std::snprintf(path, sizeof path, "%s/wram-%d.bin", opt.outDir.c_str(), frame);
            std::ofstream out(path, std::ios::binary);
            if (!out) {
                result.error = "cannot write wram";
                snesDspLogAttach(nullptr);
                snesDspRawAttach(nullptr);
                if (dspFile) std::fclose(dspFile);
                if (rawFile) std::fclose(rawFile);
                return result;
            }
            out.write((const char*)wram.data(), (std::streamsize)wram.size());
            std::printf("wrote %s (%zu bytes)\n", path, wram.size());
        }
        if (!opt.outDir.empty()) {
            for (int shot : kShots) {
                if (frame != shot) continue;
                std::string path = opt.outDir + "/frame-" + std::to_string(frame) + ".ppm";
                if (!writePPM(path, core.framebuffer(0), w, h)) {
                    result.error = "cannot write " + path;
                    snesDspLogAttach(nullptr);
                    snesDspRawAttach(nullptr);
                    if (dspFile) std::fclose(dspFile);
                    if (rawFile) std::fclose(rawFile);
                    return result;
                }
                std::printf("wrote %s (frame %d)\n", path.c_str(), frame);
            }
        }
    }
    snesPcTraceArmed = false;
    snesWatchEnabled = false;
    snesDspLogAttach(nullptr);
    snesDspLogSetFrame(0, false);
    snesDspRawAttach(nullptr);
    snesDspRawSetFrame(0, false);
    if (dspFile) std::fclose(dspFile);
    if (rawFile) std::fclose(rawFile);
    result.ok = true;
    return result;
}

} // namespace dscore
