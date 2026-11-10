// Copyright (c) 2026 Charlie Rodriguez Garcia. All rights reserved.
// Headless Game Boy runner for test ROMs: gbheadless rom frames [out.ppm] [-gray] [-raw]
#include "../src/GBSystem.hpp"
#include <chrono>
#include <cstdio>
#include <cstring>
#include <fstream>
#include <iterator>
using namespace dscore;
int main(int argc, char** argv) {
    if (argc < 3) { std::puts("usage: gbheadless rom frames [out.ppm] [-gray] [-raw] [-hold F:MASK]"); return 1; }
    std::ifstream f(argv[1], std::ios::binary);
    std::vector<u8> rom((std::istreambuf_iterator<char>(f)), {});
    GBSystem gb; std::string err;
    bool gray = false, raw = false; int holdF = -1; u32 holdM = 0;
    for (int i = 3; i < argc; ++i) { if (!strcmp(argv[i], "-gray")) gray = true; if (!strcmp(argv[i], "-raw")) raw = true; if (!strcmp(argv[i], "-hold") && i + 1 < argc) sscanf(argv[++i], "%d:%u", &holdF, &holdM); }
    gb.setVideoOptions(gray ? 1 : 0, !raw);
    if (!gb.loadROM(rom.data(), rom.size(), err)) { std::printf("load error: %s\n", err.c_str()); return 1; }
    int n = std::atoi(argv[2]);
    auto t0 = std::chrono::steady_clock::now();
    size_t audio = 0; s16 buf[4096];
    for (int i = 0; i < n; ++i) {
        gb.setButtons(holdF >= 0 && i >= holdF && i < holdF + 10 ? holdM : 0);
        gb.runFrame();
        size_t k; while ((k = gb.readAudio(buf, 2048))) audio += k;
    }
    double s = std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count();
    std::printf("frames %d  %.2f s  %.0f fps (%.1fx)  audio %zu samples  cgb %d\n", n, s, n / s, n / s / 59.7275, audio, gb.isCGBMode());
    std::printf("serial: %s\n", gb.serialLog().c_str());
    if (argc > 3 && argv[3][0] != '-') {
        FILE* o = std::fopen(argv[3], "wb"); std::fprintf(o, "P6\n160 144\n255\n");
        const u32* fb = gb.framebuffer(0);
        for (int y = 0; y < 144; ++y) for (int x = 0; x < 160; ++x) { u32 c = fb[y * 256 + x]; u8 p[3] = {u8(c >> 16), u8(c >> 8), u8(c)}; std::fwrite(p, 1, 3, o); }
        std::fclose(o);
    }
}
