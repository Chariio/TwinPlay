// Copyright (c) 2026 Charlie Rodriguez Garcia. All rights reserved.
// Cheat codes, written from public format descriptions. No code databases are included:
// users type their own codes. Applied once per frame through the core's cheat hooks.
#pragma once
#include "dscore/EmulatorCore.hpp"
#include <string>
#include <vector>

namespace dscore {

enum class CheatFormat { Auto, ActionReplayDS, GBAGameSharkRaw, GBACodeBreaker, GBGameShark, GBGameGenie };

struct CheatLine { u32 a = 0, b = 0; };

struct Cheat {
    CheatFormat format = CheatFormat::Auto;
    std::vector<CheatLine> lines;                 // AR DS / GBA / GB GameShark
    std::vector<RomPatch> patches;                // GB Game Genie
};

// Parses one cheat (several lines) for a system ("ds", "gba", "gb"). Returns false with a message.
bool parseCheat(const std::string& system, const std::string& text, Cheat& out, std::string& error);

class CheatEngine {
public:
    void set(std::vector<Cheat> cheats);
    bool empty() const { return cheats_.empty(); }
    // Runs every enabled cheat once (call after each emulated frame).
    void apply(EmulatorCore& core) const;
    // All Game Genie ROM patches (installed in the core when the list changes).
    std::vector<RomPatch> romPatches() const;
private:
    std::vector<Cheat> cheats_;
    static void runAR(EmulatorCore& c, const std::vector<CheatLine>& l);
    static void runGBAGS(EmulatorCore& c, const std::vector<CheatLine>& l);
    static void runCB(EmulatorCore& c, const std::vector<CheatLine>& l);
    static void runGBGS(EmulatorCore& c, const std::vector<CheatLine>& l);
};

} // namespace dscore
