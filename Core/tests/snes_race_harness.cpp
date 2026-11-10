// Headless Super NES race check. The cartridge stays on the machine that runs this.
//
//   cd Core && make snes_race_harness
//   ./build/snes_race_harness /path/to/game.sfc /tmp/smk-frames
//
// Button timeline (raceButtons, the same with or without flags):
//   Start at frame 360, held 6.
//   B at 516, 672, 828, 984 and 1170, each held 6.
//   B at 1350 held 90, and B at 1680 held 90.
//   From frame 2700, B is held and Left/Right pulse.
// Pictures at frames 2220, 2670, 3000 and 3900.
//
//   ./build/snes_race_harness <rom> <outdir> --watch-from 1300
//   ./build/snes_race_harness <rom> <outdir> --dump-wram 1800,1801,1802,2220,2670
//   ./build/snes_race_harness <rom> <outdir> --pc-trace-bank 84
//   ./build/snes_race_harness <rom> <outdir> --dsp-log 1600-1850
//   ./build/snes_race_harness <rom> <outdir> --dump-wram-every 1600-1850:1
//   ./build/snes_race_harness <rom> <outdir> --trace 2100-2230
//
// Power-on WRAM and APU RAM use a fixed seed. Flags only arm logs.
#include "dscore/RaceRun.hpp"
#include <cstdio>
#include <fstream>
#include <vector>

using namespace dscore;

int main(int argc, char** argv) {
    std::string romPath, outDir, error;
    RaceRunOptions opt;
    if (!parseRaceCommand(argc, argv, romPath, outDir, opt, error)) {
        std::fprintf(stderr, "%s\n", error.c_str());
        std::fprintf(stderr,
                     "usage: %s <rom> <output-dir> [--trace FRAME|START-END] [--watch-from N]\n"
                     "          [--dump-wram F,F,...] [--dump-wram-every START-END:STEP]\n"
                     "          [--dsp-log START-END] [--dsp-raw START-END] [--pc-trace-bank BB]\n",
                     argv[0]);
        return 2;
    }
    std::ifstream in(romPath, std::ios::binary);
    if (!in) { std::fprintf(stderr, "cannot open %s\n", romPath.c_str()); return 1; }
    std::vector<u8> rom((std::istreambuf_iterator<char>(in)), {});
    auto core = createCore(CoreKind::SNES);
    if (!core->loadROM(rom.data(), rom.size(), error)) {
        std::fprintf(stderr, "load failed: %s\n", error.c_str());
        return 1;
    }
    std::fprintf(stderr,
                 "input timeline (identical with --trace, --watch-from, --dump-wram, --pc-trace-bank):\n"
                 "  Start @360 hold 6; B @516,672,828,984,1170 hold 6;\n"
                 "  B @1350 hold 90; B @1680 hold 90; from 2700 hold B and pulse Left/Right\n"
                 "power-on RAM seed is 0. frames 0-%d\n",
                 opt.last);
    opt.outDir = outDir;
    RaceRunResult result = runSnesRace(*core, opt);
    if (!result.ok) {
        std::fprintf(stderr, "%s\n", result.error.c_str());
        return 1;
    }
    return 0;
}
