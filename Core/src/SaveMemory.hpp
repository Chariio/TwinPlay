// Copyright (c) 2026 Charlie Rodriguez Garcia. All rights reserved.
// Original clean-room cartridge backup memory (EEPROM / FRAM / Flash over the
// cartridge AUXSPI bus). Behaviour from GBATEK.
//
// Type detection is probe-based: every plausible chip type is simulated in parallel and
// fed the game's whole command stream. A candidate is ruled out as soon as the game does
// something that chip cannot do (a write crossing its page or end, an unknown opcode).
// Each candidate answers reads consistently with everything written so far, so the
// game's read-back checks pass under whichever candidate is currently chosen.
#pragma once
#include "dscore/Types.hpp"
#include "dscore/StateIO.hpp"
#include <array>
#include <vector>

namespace dscore {

class SaveMemory {
public:
    enum class Type { Unknown, EEPROM512, EEPROM, FRAM, Flash };
    // Forced chip (per-game override). Auto = probe-based detection.
    enum class Override { Auto = 0, EEPROM512, EEPROM8K, EEPROM64K, EEPROM128K, FRAM32K,
                          Flash256K, Flash512K, Flash1M, Flash8M };

    SaveMemory() { clear(); }
    void clear();                                   // new cartridge, nothing known yet
    void load(const std::vector<u8>& data);         // existing save file
    void setOverride(Override o);                   // applies to the current contents
    Override saveOverride() const { return override_; }
    u8 transfer(u8 v);                              // one SPI byte
    void release();                                 // chip select released
    // Cartridges with an infrared port (Pokemon HG/SS, B/W, B2/W2) put an IR controller in
    // front of the flash: each transaction starts with one extra byte, 0x00 = pass through.
    void setInfrared(bool on) { ir_ = on; irStarted_ = false; }

    Type type() const;
    u32 capacity() const;                           // size of the chosen chip
    const std::vector<u8>& data() const;
    bool dirty() const { return dirty_; }
    void clearDirty() { dirty_ = false; }
    // True if a loaded save file turned out not to match the game's chip (it was set aside
    // and the game now sees a blank chip of the detected type).
    bool loadedSaveRejected() const { return loadedRejected_; }
    void serialize(StateIO& s);

private:
    enum Kind { kE512, kE8K, kE64K, kFRAM, kE128K, kFlash, kKinds };
    struct Chip {
        Kind kind = kE512;
        bool alive = true;
        u32 cap = 512;                              // current size (flash in auto mode grows)
        bool fixedCap = true;
        std::vector<u8> data;                       // allocated lazily (blank = 0xFF)
        bool wel = false;
        u8 cmd = 0;
        int stage = 0;
        u32 addr = 0, start = 0;
        int count = 0;                              // data bytes in this transaction
        int maxCount = 0;                           // largest write so far
        bool bad = false;                           // transaction impossible for this chip
        bool pinned = false;                        // forced by the user: never ruled out
        u8 transfer(u8 v, bool& dirty);
        void release();
        int addrBytes() const { return kind == kE512 ? 1 : (kind == kE128K || kind == kFlash) ? 3 : 2; }
        u32 page() const { return kind == kE512 ? 16 : kind == kE8K ? 32 : kind == kE64K ? 128 : kind == kFRAM ? 0 : 256; }
        void ensure(u32 a);
        u8 peek(u32 a) const { a %= cap; return a < data.size() ? data[a] : 0xFF; }
        void poke(u32 a, u8 v) { ensure(a); a %= cap; data[a] = v; }
    };

    void choose();
    void reset(Override o);

    std::array<Chip, kKinds> chips_;
    int chosen_ = kE512;
    bool ir_ = false, irStarted_ = false; u8 irCmd_ = 0; int irPos_ = 0;
    bool decided_ = false;                          // a write (or load/override) fixed the type
    int maxWrite_ = 0;                              // largest data length in one write so far
    int loadedKind_ = -1;
    bool loadedRejected_ = false;
    bool dirty_ = false;
    Override override_ = Override::Auto;
};

} // namespace dscore
