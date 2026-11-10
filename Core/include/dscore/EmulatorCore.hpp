// Copyright (c) 2026 Charlie Rodriguez Garcia. All rights reserved.
// Original clean-room implementation written from public hardware documentation.
#pragma once
#include "dscore/Types.hpp"
#include <memory>
#include <string>
#include <vector>

namespace dscore {

struct RomInfo {
    std::string title;      // 12 chars, header 0x000
    std::string gameCode;   // 4 chars, header 0x00C
    std::string makerCode;  // 2 chars, header 0x010
    u32 arm9RomOffset = 0, arm9Entry = 0, arm9RamAddress = 0, arm9Size = 0;
    u32 arm7RomOffset = 0, arm7Entry = 0, arm7RamAddress = 0, arm7Size = 0;
    u16 headerCrc = 0;
    bool headerCrcValid = false;
};

// GB/GBC Game Genie ROM patch: reads of `addr` return `value` (only when the ROM byte equals
// `compare`, if compare >= 0).
struct RomPatch { u16 addr = 0; u8 value = 0; int compare = -1; };

// Abstract interface that the iOS app talks to. Any core (test pattern,
// interpreter, future optimised core) implements this.
class EmulatorCore {
public:
    virtual ~EmulatorCore() = default;

    // Tears down a heavy core (N64 / 3DS). Safe to call more than once.
    // Default is a no-op for DS / GBA / GB / NES / SNES.
    virtual void shutDown() {}

    // Loads a cartridge image (copied internally). Returns false + error on failure.
    virtual bool loadROM(const u8* data, size_t size, std::string& error) = 0;
    virtual void reset() = 0;
    // Emulates one video frame (~1/59.8 s).
    virtual void runFrame() = 0;

    // 256x192 pixels, 32-bit 0xAARRGGBB (little-endian BGRA in memory).
    // screen 0 = top, 1 = bottom (touch screen).
    virtual const u32* framebuffer(int screen) const = 0;

    virtual void setButtons(u32 pressedMask) = 0;           // see dscore::Button
    virtual void setTouch(bool down, int x, int y) = 0;     // bottom-screen pixels
    // Analog sticks, each axis -1..1. stick 0 is the N64 stick / 3DS circle pad.
    // stick 1 is the 3DS C-stick. Ignored by every core that has no analog stick.
    virtual void setAnalog(int /*stick*/, float /*x*/, float /*y*/) {}
    // Plugin / user-data directory (N64 plugins, 3DS user keys). Never a bundled ROM or BIOS.
    virtual void setDataPath(const std::string&) {}
    virtual void setSaveDirectory(const std::string&) {}
    // 3DS images are large; the core can read the file itself instead of a copied buffer.
    virtual bool prefersPathLoad() const { return false; }
    virtual bool loadROMPath(const std::string& path, std::string& error);

    // Interleaved stereo int16 at kAudioSampleRate. Returns frames copied.
    virtual size_t readAudio(s16* stereoOut, size_t maxFrames) = 0;
    // Audio frames produced but not yet read (for audio-synchronised pacing).
    virtual size_t audioBuffered() const { return 0; }

    // Optional save states (empty vector / false = unsupported).
    virtual std::vector<u8> saveState() { return {}; }
    virtual bool loadState(const std::vector<u8>&) { return false; }

    // Cartridge backup memory (EEPROM/FRAM/Flash). Persisted by the frontend.
    virtual bool saveDataDirty() const { return false; }
    virtual std::vector<u8> saveData() const { return {}; }
    virtual void clearSaveDataDirty() {}
    virtual void loadSaveData(const std::vector<u8>&) {}

    // Optional: the user's own ARM7 BIOS dump (16 KB). Only its KEY1 table is
    // used, to decrypt encrypted cartridge secure areas. Call before loadROM.
    virtual void setARM7BIOS(const std::vector<u8>&) {}

    // Optional low-level BIOS (the user's own dumps; nothing is bundled). DS: bios9 4 KB,
    // bios7 16 KB, firmware 256/512 KB (may be empty). With both BIOS files the CPUs run the
    // real BIOS code for SWIs and IRQs; with bootFirmware and a firmware image the system
    // starts at the reset vectors (firmware boot screen) instead of direct boot.
    // GBA: bios9 = gba_bios.bin (16 KB), the others empty. Empty vectors = HLE (default).
    // Call before loadROM / reset. Returns false if the files were rejected.
    virtual bool setLLEBIOS(const std::vector<u8>& /*bios9*/, const std::vector<u8>& /*bios7*/,
                            const std::vector<u8>& /*firmware*/, bool /*bootFirmware*/) { return false; }
    virtual bool usingLLEBIOS() const { return false; }

    // Performance options. frameSkip n draws one frame out of every n + 1 (0 = draw all);
    // emulation itself is never skipped. renderThreads = extra 3D rasterizer threads.
    virtual void setFrameSkip(int) {}
    virtual void setRenderThreads(int) {}
    // True if the last runFrame() produced a new picture (false on skipped frames).
    virtual bool frameDrawn() const { return true; }
    // 3D internal resolution (1..4). framebufferHiRes() is (256*scale) x (192*scale);
    // the 3D layer is rendered at that resolution, 2D layers are pixel-doubled.
    virtual void setRenderScale(int) {}
    // DS sound resampling: 0 = none (raw), 1 = linear, 2 = cubic (default, "High quality audio").
    virtual void setAudioInterpolation(int) {}
    virtual int renderScale() const { return 1; }
    // Polygons submitted since reset. Read at most a few times a second, never per pixel.
    virtual u64 polygonsSubmitted() const { return 0; }

    // Cheat hooks (see Cheats.hpp). Plain CPU-bus memory access, no side effects on I/O timing:
    // DS = ARM9 bus, GBA = system bus, GB = 16-bit CPU bus. Size 1, 2 or 4.
    virtual u32 cheatRead(u32 /*addr*/, int /*size*/) { return 0; }
    virtual void cheatWrite(u32 /*addr*/, u32 /*value*/, int /*size*/) {}
    // RetroAchievements: reads `count` bytes at `address` in rcheevos' memory layout for this
    // console (DS: main RAM at 0, DTCM at 0x1000000; GBA: IWRAM at 0, EWRAM at 0x8000; GB/GBC:
    // the CPU bus, then GBC WRAM banks 2-7 at 0x10000 and cartridge RAM banks 1-15 at 0x16000).
    // Plain memory only, no side effects. Returns how many bytes exist there.
    virtual u32 achievementRead(u32 /*address*/, u8* /*buffer*/, u32 /*count*/) { return 0; }
    virtual void setRomPatches(const std::vector<RomPatch>&) {}
    virtual bool captureInUse() const { return false; }
    // Frames in a row in which neither CPU wrote memory: the game has locked up.
    virtual int stuckFrames() const { return 0; }
    // One-line hardware snapshot for the diagnostics log.
    virtual std::string freezeReport() { return {}; }
    // Watchdog counters (NDS): IRQ-livelock recoveries and timed-out 3D worker waits.
    virtual u64 irqLivelockRecoveries() const { return 0; }
    virtual u64 renderPoolStalls() const { return 0; }
    virtual const u32* framebufferHiRes(int screen) const { return framebuffer(screen); }
    // Optional 3D enhancements (not hardware-accurate): antiAlias 0 off, 1 FXAA-style edge
    // smoothing, 2 2x supersampling; bilinear texture filtering; widescreen projection hack.
    // Cartridge save chip: 0 = auto-detect, 1 EEPROM 0.5K, 2 EEPROM 8K, 3 EEPROM 64K,
    // 4 EEPROM 128K, 5 FRAM 32K, 6 Flash 256K, 7 Flash 512K, 8 Flash 1M, 9 Flash 8M.
    virtual void setSaveTypeOverride(int) {}
    virtual std::string saveTypeDescription() const { return {}; }
    // True if the loaded save file did not match the chip the game uses (it was set aside).
    virtual bool loadedSaveRejected() const { return false; }
    virtual void setEnhancements(int /*antiAlias*/, bool /*textureFilter*/, bool /*widescreen*/) {}

    // Which console this core emulates: 0 = Nintendo DS (two 256x192 screens), 1 = Game Boy
    // Advance (one screenWidth() x screenHeight() picture in the top-left of screen 0's buffer).
    // 2 = Game Boy, 3 = Game Boy Color (one 160x144 picture in the top-left of screen 0).
    // 4 = NES (one 256x240 picture), 5 = Super NES (one 256x224 picture).
    // 6 = N64 (one picture, presented in the 256x192 top buffer). 7 = 3DS (two screens,
    // presented in the same 256x192 pair the DS uses).
    virtual int system() const { return 0; }
    // Game Boy only: DMG shade palette (0 green, 1 gray) and LCD colour correction for GBC colours.
    virtual void setVideoOptions(int /*dmgPalette*/, bool /*colorCorrect*/) {}
    virtual int screenWidth() const { return kScreenWidth; }
    virtual int screenHeight() const { return kScreenHeight; }
    virtual int screenCount() const { return 2; }

    virtual const RomInfo& romInfo() const = 0;
    virtual std::string statusText() const { return {}; }
};

enum class CoreKind { TestPattern, Interpreter, GBA, GB, NES, SNES, N64, N3DS };
// True if the image looks like a Game Boy / Game Boy Color cartridge (header checksum at 0x14D).
bool isGBImage(const u8* data, size_t size);
// True if the image looks like a Game Boy Advance cartridge (ARM branch at 0, fixed byte 0x96 at 0xB2).
bool isGBAImage(const u8* data, size_t size);
// True if the image is an iNES cartridge ("NES\x1A" header).
bool isNESImage(const u8* data, size_t size);
// True if the image is a SNES cartridge (LoROM/HiROM header, optional 512-byte copier header).
bool isSNESImage(const u8* data, size_t size);
// N64: z64 (0x80371240), v64 byte-swapped, or n64 word-swapped. 3DS: NCSD (.3ds/.cci) or NCCH (.cxi).
bool isN64Image(const u8* data, size_t size);
bool is3DSImage(const u8* data, size_t size);
// Rewrites v64/n64 images to z64 in place. z64 is left unchanged.
void normalizeN64(std::vector<u8>& rom);
// Internal cartridge name (z64 offset 0x20, 20 bytes) after the image is normalized.
std::string n64InternalName(const u8* data, size_t size);
// Nearest-neighbor scale. letterbox fits the source inside the destination and clears the rest.
void scaleNearest(const u32* src, int sw, int sh, u32* dst, int dw, int dh);
void letterboxNearest(const u32* src, int sw, int sh, u32* dst, int dw, int dh);
std::unique_ptr<EmulatorCore> createCore(CoreKind kind);

// SNES CPU view for tests and the race harness. wramCount bytes from $7E0000+offset.
void superFamicomCpuDebug(u32* pc, u8* wram, u32 wramAddress, u32 wramCount);

// Built-in banner of a cartridge image (the icon and titles stored in the ROM itself).
struct RomBanner {
    std::string title;          // English title, lines joined with '\n' (UTF-8)
    std::vector<u32> icon;      // 32x32, 0xAARRGGBB (palette entry 0 is transparent)
};
// Offset of the banner from the header (0 = none). header needs >= 0x6C bytes.
u32 romBannerOffset(const u8* header, size_t size);
// Parses a banner block (>= 0x840 bytes, starting at romBannerOffset()).
bool parseRomBanner(const u8* banner, size_t size, RomBanner& out);

// Exposed for tests.
bool parseRomHeader(const u8* data, size_t size, RomInfo& out, std::string& error);
u16 crc16(const u8* data, size_t size, u16 init = 0xFFFF);

} // namespace dscore
