#pragma once
#include "dscore/EmulatorCore.hpp"
#include <cstdint>
#include <string>
#include <vector>

namespace dscore {

struct RaceRunOptions {
    int traceLo = -1;
    int traceHi = -1;
    int watchFrom = -1;
    int last = 3900;
    int pcBank = -1;
    int dspLogLo = -1, dspLogHi = -1;
    int dspRawLo = -1, dspRawHi = -1;
    int dumpEveryLo = -1, dumpEveryHi = -1, dumpEveryStep = 1;
    bool timeline = true;
    std::vector<int> dumpWram;
    std::string outDir;
};

struct RaceRunResult {
    bool ok = false;
    std::string error;
    uint64_t hash2220 = 0;
    bool have2220 = false;
};

// rom and outDir are the positional arguments. Options never replace them.
bool parseRaceCommand(int argc, char** argv, std::string& romPath, std::string& outDir,
                      RaceRunOptions& opt, std::string& error);

// One frame loop. Flags only arm logs. Buttons come from raceButtons unless
// timeline is false (tests). outDir empty skips files and still runs the hooks.
RaceRunResult runSnesRace(EmulatorCore& core, const RaceRunOptions& opt);

} // namespace dscore
