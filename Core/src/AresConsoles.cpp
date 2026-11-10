// Thin TwinPlay front end for the ares Famicom and Super Famicom cores.
// The cores are ISC (see Core/third_party/ares/LICENSE). They are interpreters:
// the JIT in upstream ares is not compiled.
#include "dscore/EmulatorCore.hpp"
#include <ares/ares.hpp>
#include <fc/fc.hpp>
#include <sfc/sfc.hpp>
#include <algorithm>
#include <cstdio>
#include <cstring>
#include <fstream>
#include <mutex>
#include <vector>

namespace dscore {

// Embedded copy of database/sfc-boards.bml. Defined in sfc_boards.cpp.
extern const unsigned char kSuperFamicomBoards[];
extern const unsigned int kSuperFamicomBoardsSize;

namespace {

bool pressed(u32 mask, const nall::string& name) {
    if (name == "A") return mask & BtnA;
    if (name == "B") return mask & BtnB;
    if (name == "X") return mask & BtnX;
    if (name == "Y") return mask & BtnY;
    if (name == "L") return mask & BtnL;
    if (name == "R") return mask & BtnR;
    if (name == "Select") return mask & BtnSelect;
    if (name == "Start") return mask & BtnStart;
    if (name == "Up") return mask & BtnUp;
    if (name == "Down") return mask & BtnDown;
    if (name == "Left") return mask & BtnLeft;
    if (name == "Right") return mask & BtnRight;
    return false;
}

// Clean-room SPC700 boot program. Not Nintendo's IPL ROM.
// Reset enters at $FFC0. $FFC9 is the only re-entry: it signals $AA/$BB
// again and waits until port 0 is exactly $CC. Any other value there
// (Yoshi writes $FF first) is ignored. After that kick, and after every
// later block, control is the main loop: echo whatever is in port 0, and
// if port 1 is 0 jump through $0000. Otherwise wait until port 0 is 0 and
// store bytes while port 0 matches the running index. A signed mismatch
// (the CPU wrote index+2 or more, and not 0) ends the block and returns
// to that main loop, not to the $CC wait. The byte is read before the
// index is echoed. On the jump, A, X and Y are 0 and Z is set.
constexpr u8 kIpl[64] = {
    0x00,0xAF,0xC8,0xF0,0xD0,0xFB,0xCD,0xEF,0xBD,0x8F,0xAA,0xF4,0x8F,0xBB,0xF5,0xE8,
    0xCC,0x2E,0xF4,0xFD,0x2F,0x19,0xEB,0xF4,0xD0,0xFC,0x7E,0xF4,0xD0,0x0B,0xE4,0xF5,
    0xCB,0xF4,0xD7,0x00,0xFC,0xD0,0xF3,0xAB,0x01,0x10,0xEF,0x7E,0xF4,0x10,0xEB,0xBA,
    0xF6,0xDA,0x00,0xBA,0xF4,0xC4,0xF4,0xDD,0x5D,0xD0,0xDB,0x1F,0x00,0x00,0xC0,0xFF,
};

std::string boardsText() {
    static std::string cached;
    if (!cached.empty()) return cached;
    const char* candidates[] = {
        "third_party/ares/database/sfc-boards.bml",
        "Core/third_party/ares/database/sfc-boards.bml",
        "../Core/third_party/ares/database/sfc-boards.bml",
    };
    for (const char* path : candidates) {
        std::ifstream in(path, std::ios::binary);
        if (!in) continue;
        cached.assign(std::istreambuf_iterator<char>(in), std::istreambuf_iterator<char>());
        if (!cached.empty()) return cached;
    }
    if (kSuperFamicomBoardsSize)
        cached.assign(reinterpret_cast<const char*>(kSuperFamicomBoards), kSuperFamicomBoardsSize);
    return cached;
}

struct Host : ares::Platform {
    ares::VFS::Pak game;
    ares::VFS::Pak systemPak;
    std::vector<u32> picture;
    int outW = 256, outH = 240;
    u32 buttons = 0;
    mutable std::mutex audioMu;
    std::vector<s16> ring;
    size_t ringHead = 0, ringCount = 0;

    Host() { ring.assign(16384, 0); picture.assign(256 * 240, 0xFF000000u); }

    auto pak(ares::Node::Object node) -> std::shared_ptr<nall::vfs::directory> override {
        if (node && node->name() == "Super Famicom") return systemPak;
        return game;
    }

    auto video(ares::Node::Video::Screen, const u32* data, u32 pitch, u32 width, u32 height) -> void override {
        if (!data || width == 0 || height == 0 || outW <= 0 || outH <= 0) return;
        const u32 row = pitch / 4;
        if (row == 0) return;
        // The Famicom viewport is already 256x240. The Super Famicom performance
        // PPU hands over hires columns (512x224, or the full 564-wide overscan).
        const int xStep = (int)width >= outW * 2 ? 2 : 1;
        const int yStep = (int)height >= outH * 2 ? 2 : 1;
        const int srcW = outW * xStep;
        const int srcH = outH * yStep;
        int x0 = ((int)width - srcW) / 2;
        int y0 = ((int)height - srcH) / 2;
        if (x0 < 0) x0 = 0;
        if (y0 < 0) y0 = 0;
        for (int y = 0; y < outH; ++y) {
            int sy = y0 + y * yStep;
            if (sy < 0 || sy >= (int)height) continue;
            const u32* src = data + (size_t)sy * row;
            u32* dst = picture.data() + (size_t)y * (size_t)outW;
            for (int x = 0; x < outW; ++x) {
                int sx = x0 + x * xStep;
                u32 px = 0xFF000000u;
                if (sx >= 0 && sx < (int)width) px = src[sx] | 0xFF000000u;
                dst[x] = px;
            }
        }
    }

    auto input(ares::Node::Input::Input node) -> void override {
        if (!node) return;
        if (auto button = std::dynamic_pointer_cast<ares::Core::Input::Button>(node))
            button->setValue(pressed(buttons, node->name()));
    }

    auto audio(ares::Node::Audio::Stream stream) -> void override {
        if (!stream) return;
        f64 sample[2] = {};
        std::lock_guard<std::mutex> lk(audioMu);
        while (stream->pending()) {
            u32 nch = stream->read(sample);
            float l = (float)sample[0];
            float r = nch > 1 ? (float)sample[1] : l;
            auto clamp = [](float v) -> s16 {
                int s = (int)(v * 32767.f);
                if (s > 32767) s = 32767;
                if (s < -32768) s = -32768;
                return (s16)s;
            };
            if (ringCount + 2 <= ring.size()) {
                size_t i = (ringHead + ringCount) % ring.size();
                ring[i] = clamp(l);
                ring[(i + 1) % ring.size()] = clamp(r);
                ringCount += 2;
            }
        }
    }
};

// Stop the screen before the Host it calls into is destroyed.
// ares keeps the running system in a process-wide global.
void releaseSystem(Host& host, ares::Node::System& root) {
    if (!root) return;
    ares::platform = &host;
    root->unload();
    root = {};
    if (ares::platform == &host) ares::platform = nullptr;
}

// iNES / NES 2.0 mapper number to an ares board id. Unknown mappers stay null so load fails
// with a clear error instead of silently running as NROM. Pinouts are the ares Famicom
// database defaults for that iNES number (a few VRC games use a different pair).
struct NesPlan {
    const char* board = nullptr;
    int mapper = 0;
    int pinA0 = -1;
    int pinA1 = -1;
    size_t ramBytes = 8192;
    const char* region = "NTSC-U";
};

NesPlan planNES(const u8* data, size_t size, size_t chrSize) {
    NesPlan p;
    bool nes2 = size > 12 && (data[7] & 0x0C) == 0x08;
    int mapper = (data[6] >> 4) | (data[7] & 0xF0);
    int sub = 0;
    if (nes2) {
        mapper |= (data[8] & 0x0F) << 8;
        sub = (data[8] >> 4) & 0x0F;
        int tv = data[12] & 0x03;
        if (tv == 1 || tv == 3) p.region = "PAL";
    } else if (size > 9 && data[9] == 1) {
        p.region = "PAL";
    }
    p.mapper = mapper;
    auto vrc = [&](const char* id, int a0, int a1) { p.board = id; p.pinA0 = a0; p.pinA1 = a1; };
    switch (mapper) {
        case 0: p.board = "HVC-NROM-256"; break;
        case 1: p.board = "HVC-SXROM"; break;
        case 2: p.board = "HVC-UOROM"; break;
        case 3: p.board = "HVC-CNROM"; break;
        case 4: p.board = (nes2 && sub == 1) ? "HVC-HKROM" : "HVC-TLROM"; break;
        case 5: {
            size_t ram = 0;
            if (nes2 && size > 10) {
                int vol = data[10] & 0x0F, nv = (data[10] >> 4) & 0x0F;
                if (vol) ram += size_t(64) << vol;
                if (nv) ram += size_t(64) << nv;
            } else {
                int units = size > 8 ? data[8] : 0;
                bool battery = (data[6] & 2) != 0;
                if (units) ram = size_t(units) * 8192;
                else if (battery) ram = 8192;
            }
            if (ram == 0) { p.board = "HVC-ELROM"; p.ramBytes = 0; }
            else if (ram <= 8192) { p.board = "HVC-EKROM"; p.ramBytes = 8192; }
            else if (ram <= 16384) { p.board = "HVC-ETROM"; p.ramBytes = 16384; }
            else { p.board = "HVC-EWROM"; p.ramBytes = 32768; }
            break;
        }
        case 7: p.board = "HVC-AOROM"; break;
        case 9: p.board = "HVC-PNROM"; break;
        case 10: p.board = "HVC-FJROM"; break;
        case 11: p.board = "COLORDREAMS-74*377"; break;
        case 16: p.board = (nes2 && sub == 4) ? "BANDAI-FCG" : "BANDAI-LZ93D50"; break;
        case 18: p.board = "JALECO-JF-23A"; break;
        case 19: p.board = "NAMCO-163"; break;
        case 21: vrc("KONAMI-VRC-4", 1, 2); break;
        case 22: vrc("KONAMI-VRC-2A", 1, 0); break;
        case 23: vrc("KONAMI-VRC-2", 0, 1); break;
        case 24: vrc("KONAMI-VRC-6", 0, 1); break;
        case 25: vrc("KONAMI-VRC-4", 1, 0); break;
        case 26: vrc("KONAMI-VRC-6", 1, 0); break;
        case 28: p.board = "ACTION53"; break;
        case 30: p.board = "UNROM-512"; break;
        case 32: p.board = "IREM-G101"; break;
        case 33: p.board = "TAITO-TC0190"; break;
        case 34: p.board = chrSize ? "AVE-NINA-001" : "HVC-BNROM"; break;
        case 48: p.board = "TAITO-TC0690"; break;
        case 64: p.board = "TENGEN-800032"; break;
        case 65: p.board = "IREM-H3001"; break;
        case 66: p.board = "HVC-GNROM"; break;
        case 67: p.board = "SUNSOFT-3"; break;
        case 68: p.board = "SUNSOFT-4"; break;
        case 69: p.board = "SUNSOFT-5B"; break;
        case 70: p.board = "BANDAI-74161"; break;
        case 71: p.board = "CAMERICA-BF9097"; break;
        case 72: p.board = "JALECO-JF-17"; break;
        case 73: p.board = "KONAMI-VRC-3"; break;
        case 75: p.board = "KONAMI-VRC-1"; break;
        case 76: p.board = "NAMCO-3446"; break;
        case 78: p.board = "JALECO-JF-16"; break;
        case 79: p.board = "AVE-NINA-03"; break;
        case 80: p.board = "TAITO-X1-005"; break;
        case 82: p.board = "TAITO-X1-017"; break;
        case 85: vrc("KONAMI-VRC-7", 4, -1); break;
        case 86: p.board = "JALECO-JF-13"; break;
        case 87: p.board = "JALECO-JF-05"; break;
        case 88: p.board = "NAMCO-118"; break;
        case 89: p.board = "SUNSOFT-2"; break;
        case 94: p.board = "HVC-UN1ROM"; break;
        case 95: p.board = "NAMCO-3425"; break;
        case 97: p.board = "IREM-TAM-S1"; break;
        case 140: p.board = "JALECO-JF-11"; break;
        case 154: p.board = "NAMCO-3453"; break;
        case 157: p.board = "BANDAI-DATACH"; break;
        case 159: p.board = "BANDAI-LZ93D50"; break;
        case 184: p.board = "SUNSOFT-1"; break;
        case 206: p.board = "NAMCO-118"; break;
        case 210: p.board = (nes2 && sub == 1) ? "NAMCO-175" : "NAMCO-340"; break;
        case 228: p.board = "MLT-ACTION52"; break;
        default: break;
    }
    return p;
}

int headerScore(const u8* d, size_t n, size_t hdr, bool hi);

class AresFamicom final : public EmulatorCore {
public:
    AresFamicom() { info_.gameCode = "NES"; }
    ~AresFamicom() override { releaseSystem(host_, root_); }
    bool loadROM(const u8* data, size_t size, std::string& error) override {
        if (!isNESImage(data, size)) { error = "Not an iNES image."; return false; }
        size_t prgSize = (size_t)data[4] * 16384;
        size_t chrSize = (size_t)data[5] * 8192;
        bool vertical = (data[6] & 1) != 0;
        bool battery = (data[6] & 2) != 0;
        size_t off = 16 + ((data[6] & 4) ? 512 : 0);
        if (off + prgSize + chrSize > size || prgSize == 0) { error = "Truncated iNES image."; return false; }
        NesPlan plan = planNES(data, size, chrSize);
        if (!plan.board) {
            char msg[80];
            std::snprintf(msg, sizeof msg, "NES mapper %d is not supported.", plan.mapper);
            error = msg;
            return false;
        }
        host_.game = std::make_shared<nall::vfs::directory>();
        host_.game->setAttribute("title", "Cartridge");
        host_.game->setAttribute("region", plan.region);
        host_.game->setAttribute("board", plan.board);
        host_.game->setAttribute("mirror", vertical ? "vertical" : "horizontal");
        if (plan.pinA0 >= 0) host_.game->setAttribute("pinout/a0", plan.pinA0);
        if (plan.pinA1 >= 0) host_.game->setAttribute("pinout/a1", plan.pinA1);
        host_.game->append("program.rom", std::span<const u8>(data + off, prgSize));
        if (chrSize) host_.game->append("character.rom", std::span<const u8>(data + off + prgSize, chrSize));
        else if (plan.mapper == 5) {
            // ares' MMC5 board only maps character.rom. CHR-RAM games get a blank ROM so
            // pattern fetches do not read a null table. Games with CHR ROM are unchanged.
            std::vector<u8> chr(8192, 0);
            host_.game->append("character.rom", std::span<const u8>(chr.data(), chr.size()));
        } else {
            std::vector<u8> chr(8192, 0);
            host_.game->append("character.ram", std::span<const u8>(chr.data(), chr.size()));
        }
        if (plan.ramBytes) {
            std::vector<u8> ram(plan.ramBytes, 0);
            host_.game->append("save.ram", std::span<const u8>(ram.data(), ram.size()));
        }
        battery_ = battery && plan.ramBytes > 0;
        info_.title.clear();
        char code[8];
        std::snprintf(code, sizeof code, "M%03d", plan.mapper);
        info_.gameCode = code;
        if (!boot()) { error = "NES failed to start."; return false; }
        return true;
    }
    void reset() override { if (root_) root_->power(true); }
    void runFrame() override {
        if (!root_) return;
        ares::platform = &host_;
        root_->run();
    }
    const u32* framebuffer(int) const override { return host_.picture.data(); }
    void setButtons(u32 m) override { host_.buttons = m; }
    void setTouch(bool, int, int) override {}
    size_t readAudio(s16* stereoOut, size_t maxFrames) override {
        std::lock_guard<std::mutex> lk(host_.audioMu);
        size_t have = host_.ringCount / 2;
        size_t n = maxFrames < have ? maxFrames : have;
        for (size_t i = 0; i < n; ++i) {
            size_t p = (host_.ringHead + i * 2) % host_.ring.size();
            stereoOut[2 * i] = host_.ring[p];
            stereoOut[2 * i + 1] = host_.ring[(p + 1) % host_.ring.size()];
        }
        host_.ringHead = (host_.ringHead + n * 2) % host_.ring.size();
        host_.ringCount -= n * 2;
        return n;
    }
    size_t audioBuffered() const override {
        std::lock_guard<std::mutex> lk(host_.audioMu);
        return host_.ringCount / 2;
    }
    std::vector<u8> saveState() override {
        if (!root_) return {};
        ares::platform = &host_;
        auto s = root_->serialize(true);
        if (!s || !s.size()) return {};
        return std::vector<u8>(s.data(), s.data() + s.size());
    }
    bool loadState(const std::vector<u8>& d) override {
        if (!root_ || d.empty()) return false;
        ares::platform = &host_;
        nall::serializer s(d.data(), (u32)d.size());
        return root_->unserialize(s);
    }
    bool saveDataDirty() const override { return battery_; }
    std::vector<u8> saveData() const override {
        if (!host_.game) return {};
        if (auto fp = host_.game->read("save.ram")) {
            std::vector<u8> out(fp->size());
            fp->read(out.data(), out.size());
            return out;
        }
        return {};
    }
    void loadSaveData(const std::vector<u8>& d) override {
        if (!host_.game || d.empty()) return;
        host_.game->append("save.ram", std::span<const u8>(d.data(), d.size()));
    }
    const RomInfo& romInfo() const override { return info_; }
    std::string statusText() const override { return "NES · ares"; }
    int system() const override { return 4; }
    int screenWidth() const override { return 256; }
    int screenHeight() const override { return 240; }
    int screenCount() const override { return 1; }
    u32 achievementRead(u32 address, u8* buffer, u32 count) override {
        if (!buffer) return 0;
        ares::platform = &host_;
        u32 n = 0;
        // readDebugger peeks the bus. cpu.read() would burn cycles and re-enter the scheduler.
        for (; n < count && address + n < 0x10000; ++n)
            buffer[n] = ares::Famicom::cpu.readDebugger((n16)(address + n));
        return n;
    }

private:
    bool boot() {
        ares::platform = &host_;
        releaseSystem(host_, root_);
        ares::platform = &host_;
        if (!ares::Famicom::load(root_, "[Nintendo] Famicom (NTSC-U)")) return false;
        if (auto port = root_->find<ares::Node::Port>("Cartridge Slot")) {
            port->allocate();
            port->connect();
        }
        if (auto port = root_->find<ares::Node::Port>("Controller Port 1"))
            port->allocate("Gamepad");
        root_->power();
        return (bool)root_;
    }
    Host host_;
    ares::Node::System root_;
    RomInfo info_;
    bool battery_ = false;
};

struct CartPlan {
    const char* board = "SHVC-1A0N-01";
    size_t ramBytes = 0;
    bool battery = false;
    bool superFX = false;
    bool sa1 = false;
};

// $FFD6 chipset: high nibble is the coprocessor, low nibble is RAM / battery.
// $FFBD (three bytes before the header) is the Super FX work-RAM size code.
bool planCartridge(const u8* rom, size_t n, bool hi, CartPlan& plan, std::string& error) {
    size_t hdr = hi ? 0xFFC0 : 0x7FC0;
    if (n < hdr + 0x20) { error = "Super NES header is truncated."; return false; }
    u8 map = rom[hdr + 0x15];
    u8 chip = rom[hdr + 0x16];
    u8 sramCode = rom[hdr + 0x18];
    u8 fxCode = rom[hdr - 3];
    u8 family = chip >> 4;
    u8 extra = chip & 0x0F;
    bool ex = (map & 0x0F) == 5;
    bool battery = extra == 2 || extra == 5 || extra == 6 || extra == 0xA;
    bool hasRam = extra == 1 || extra == 2 || extra == 4 || extra == 5 || extra == 6 || extra == 0xA;
    auto sized = [](u8 code) -> size_t {
        if (code >= 1 && code <= 9) return size_t(1024) << code;
        return 0;
    };
    size_t ram = sized(sramCode);
    const char* board = nullptr;

    if (family == 0 && extra <= 2) {
        if (hasRam && ram == 0) ram = 8192;
        if (ex) board = ram ? "EXHIROM-RAM" : "EXHIROM";
        else if (hi) board = ram ? "SHVC-1J3M-01" : "SHVC-1J0N-01";
        else board = ram ? "SHVC-1A3M-10" : "SHVC-1A0N-01";
    } else if (family == 0 && (extra == 3 || extra == 4 || extra == 5)) {
        // HiROM DSP of at most 8 Mbit is SHVC-1K1B / SHVC-1K1X (Super Mario Kart),
        // even though the header map byte is $31. ROM is a real HiROM image: the
        // valid header and the reset vector live at $FFC0 / $FFFC. DSP is
        // $00-1F,$80-9F:$6000-7FFF mask $FFF, so $6000 is DR and $7000 is SR.
        // SRAM is $20-3F,$A0-BF:$6000-7FFF. SHVC-2B3B is a different, larger board:
        // its ROM mask $8000 would read $00:FFFC from file $7FFC (the other half),
        // and its DSP sits at $60-6F:$0000-7FFF, which this game never polls.
        if (hi && n <= 0x100000) {
            board = hasRam ? "SHVC-1K1X-10" : "SHVC-1K0N-01";
            if (hasRam && ram == 0) ram = 2048;
        } else {
            board = hi ? "SHVC-2B3B-01" : (hasRam ? "SHVC-1B5B-02" : "SHVC-1B0N-10");
            if (hasRam && ram == 0) ram = 8192;
        }
    } else if (family == 1) {
        plan.superFX = true;
        if (fxCode == 0 || fxCode == 0xFF) {
            board = "SHVC-1C0N";
            ram = 32 * 1024;
        } else if (fxCode >= 6) {
            board = "SHVC-1CA6B-01";
            ram = size_t(1024) << fxCode;
        } else {
            board = "SHVC-1CB5B-01";
            ram = size_t(1024) << fxCode;
        }
    } else if (family == 2) {
        board = "SHVC-2E3M-01";
        if (ram == 0) ram = 8192;
    } else if (family == 3) {
        plan.sa1 = true;
        board = battery ? "SHVC-1L5B-20" : "SHVC-1L3B-02";
        if (ram == 0) ram = 8192;
    } else if (family == 4) {
        board = hasRam ? "SHVC-LN3B-01" : "SHVC-1N0N-01";
        if (hasRam && ram == 0) ram = 8192;
    } else if (family == 5) {
        board = "EXHIROM-RAM-SHARPRTC";
        if (ram == 0) ram = 8192;
        battery = true;
    } else if (family == 0xF && extra == 3) {
        board = "SHVC-1DC0N-01";
    } else if (family == 0xF && (extra == 5 || extra == 6 || extra == 9)) {
        board = extra == 6 ? "SPC7110-RAM-EPSONRTC" : "SPC7110-RAM";
        if (ram == 0) ram = 8192;
        battery = extra == 5 || extra == 6;
    } else {
        char msg[64];
        std::snprintf(msg, sizeof msg, "unsupported cartridge chip $%02X", chip);
        error = msg;
        return false;
    }
    plan.board = board;
    plan.ramBytes = ram;
    plan.battery = battery && ram > 0;
    return true;
}

class AresSuperFamicom final : public EmulatorCore {
public:
    AresSuperFamicom() { info_.gameCode = "SNES"; host_.outW = 256; host_.outH = 224; host_.picture.assign(256 * 224, 0xFF000000u); }
    ~AresSuperFamicom() override { releaseSystem(host_, root_); }
    bool loadROM(const u8* data, size_t size, std::string& error) override {
        if (!isSNESImage(data, size)) { error = "Not a Super NES image."; return false; }
        size_t base = (size % 1024 == 512) ? 512 : 0;
        const u8* rom = data + base;
        size_t n = size - base;
        // Score both header slots. A map byte of $00 does not count as LoROM, so a real
        // HiROM header (Donkey Kong Country, Mortal Kombat II, Super Mario Kart) can win.
        // A tie stays LoROM so a real LoROM Super FX header is not flipped.
        int loScore = n > 0x7FFF ? headerScore(rom, n, 0x7FC0, false) : -100;
        int hiScore = n > 0xFFC0 ? headerScore(rom, n, 0xFFC0, true) : -100;
        bool hi = hiScore > loScore;
        CartPlan plan;
        if (!planCartridge(rom, n, hi, plan, error)) return false;
        std::string boards = boardsText();
        if (boards.empty()) { error = "Super NES board list is missing."; return false; }
        host_.systemPak = std::make_shared<nall::vfs::directory>();
        host_.systemPak->append("boards.bml", std::span<const u8>((const u8*)boards.data(), boards.size()));
        host_.systemPak->append("ipl.rom", std::span<const u8>(kIpl, 64));
        host_.game = std::make_shared<nall::vfs::directory>();
        host_.game->setAttribute("board", plan.board);
        host_.game->setAttribute("title", "Cartridge");
        host_.game->setAttribute("region", "NTSC");
        host_.game->append("program.rom", std::span<const u8>(rom, n));
        if (plan.ramBytes) {
            std::vector<u8> sram(plan.ramBytes, 0);
            host_.game->append("save.ram", std::span<const u8>(sram.data(), sram.size()));
        }
        if (plan.sa1) {
            std::vector<u8> iram(2048, 0);
            host_.game->append("internal.ram", std::span<const u8>(iram.data(), iram.size()));
        }
        battery_ = plan.battery && plan.ramBytes > 0;
        info_.gameCode = hi ? "HiROM" : "LoROM";
        info_.title = plan.board;
        boot();
        if (!root_) { error = "Super NES failed to start."; return false; }
        if (plan.superFX && !ares::SuperFamicom::cartridge.has.SuperFX) {
            error = "unsupported cartridge chip";
            return false;
        }
        return true;
    }
    void reset() override { if (root_) root_->power(true); }
    void runFrame() override { if (root_) { ares::platform = &host_; root_->run(); } }
    const u32* framebuffer(int) const override { return host_.picture.data(); }
    void setButtons(u32 m) override { host_.buttons = m; }
    void setTouch(bool, int, int) override {}
    size_t readAudio(s16* o, size_t n) override { return hostRead(o, n); }
    size_t audioBuffered() const override { std::lock_guard<std::mutex> lk(host_.audioMu); return host_.ringCount / 2; }
    std::vector<u8> saveState() override {
        if (!root_) return {};
        ares::platform = &host_;
        auto s = root_->serialize(true);
        if (!s || !s.size()) return {};
        return std::vector<u8>(s.data(), s.data() + s.size());
    }
    bool loadState(const std::vector<u8>& d) override {
        if (!root_ || d.empty()) return false;
        ares::platform = &host_;
        nall::serializer s(d.data(), (u32)d.size());
        return root_->unserialize(s);
    }
    bool saveDataDirty() const override { return battery_; }
    std::vector<u8> saveData() const override {
        if (!battery_) return {};
        auto* mem = liveSave();
        if (!mem || !mem->data() || !mem->size()) return {};
        auto* p = mem->data();
        return std::vector<u8>(p, p + mem->size());
    }
    void loadSaveData(const std::vector<u8>& d) override {
        if (!battery_ || d.empty()) return;
        auto* mem = liveSave();
        if (!mem || !mem->data() || !mem->size()) return;
        u32 n = mem->size() < d.size() ? mem->size() : (u32)d.size();
        std::memcpy(mem->data(), d.data(), n);
        if (host_.game)
            host_.game->append("save.ram", std::span<const u8>(d.data(), d.size()));
    }
    const RomInfo& romInfo() const override { return info_; }
    std::string statusText() const override { return "Super NES · ares"; }
    int system() const override { return 5; }
    int screenWidth() const override { return 256; }
    int screenHeight() const override { return 224; }
    int screenCount() const override { return 1; }

private:
    size_t hostRead(s16* stereoOut, size_t maxFrames) {
        std::lock_guard<std::mutex> lk(host_.audioMu);
        size_t have = host_.ringCount / 2;
        size_t n = maxFrames < have ? maxFrames : have;
        for (size_t i = 0; i < n; ++i) {
            size_t p = (host_.ringHead + i * 2) % host_.ring.size();
            stereoOut[2 * i] = host_.ring[p];
            stereoOut[2 * i + 1] = host_.ring[(p + 1) % host_.ring.size()];
        }
        host_.ringHead = (host_.ringHead + n * 2) % host_.ring.size();
        host_.ringCount -= n * 2;
        return n;
    }
    ares::SuperFamicom::AbstractMemory* liveSave() const {
        using namespace ares::SuperFamicom;
        if (cartridge.has.SuperFX && superfx.ram.size()) return &superfx.ram;
        if (cartridge.has.SA1 && sa1.bwram.size()) return &sa1.bwram;
        if (cartridge.has.HitachiDSP && hitachidsp.ram.size()) return &hitachidsp.ram;
        if (cartridge.has.SPC7110 && spc7110.ram.size()) return &spc7110.ram;
        if (cartridge.has.OBC1 && obc1.ram.size()) return &obc1.ram;
        if (cartridge.ram.size()) return &cartridge.ram;
        return nullptr;
    }
    void boot() {
        ares::platform = &host_;
        releaseSystem(host_, root_);
        ares::platform = &host_;
        // The bus map runs during load, so the PPU implementation has to exist first.
        // Performance is what a phone can draw every frame.
        ares::SuperFamicom::ppu.setAccurate(false);
        // entropy() seeds from the clock unless this is set first. Two launches
        // were different machines, so a flagged run could sit on driver select
        // while a plain run reached the race. Seed 0 is ares deterministic mode.
        ares::SuperFamicom::system.deterministicEntropy = true;
        if (!ares::SuperFamicom::load(root_, "[Nintendo] Super Famicom (NTSC)")) { root_ = {}; return; }
        if (auto port = root_->find<ares::Node::Port>("Cartridge Slot")) {
            port->allocate();
            port->connect();
        }
        if (auto port = root_->find<ares::Node::Port>("Controller Port 1"))
            port->allocate("Gamepad");
        root_->power();
    }
    Host host_;
    ares::Node::System root_;
    RomInfo info_;
    bool battery_ = false;
};

} // namespace

bool isNESImage(const u8* d, size_t n) {
    return d && n >= 16 && d[0] == 'N' && d[1] == 'E' && d[2] == 'S' && d[3] == 0x1A;
}

namespace {
int headerScore(const u8* d, size_t n, size_t hdr, bool hi) {
    if (!d || hdr + 0x40 > n) return -100;
    const u8* h = d + hdr;
    // Complement is stored first ($1C), checksum second ($1E). Either order still xors to $FFFF.
    u16 a = u16(h[0x1C] | (h[0x1D] << 8));
    u16 b = u16(h[0x1E] | (h[0x1F] << 8));
    u16 reset = u16(h[0x3C] | (h[0x3D] << 8));
    int score = 0;
    bool emptyPair = (a == 0 && b == 0) || (a == 0xFFFF && b == 0xFFFF);
    if (!emptyPair && (a ^ b) == 0xFFFF) score += 8;
    if (reset >= 0x8000 && reset <= 0xFFFC) score += 3;
    u8 mapByte = h[0x15];
    u8 mapN = mapByte & 0x0F;
    u8 mapS = mapByte & 0xF0;
    bool speed = mapS == 0x20 || mapS == 0x30;
    // LoROM family: 0, SA-1 (2), SDD1 (3). HiROM family: 1 and ExHiROM (5). $00 matches neither.
    if (speed && (hi ? (mapN == 1 || mapN == 5) : (mapN == 0 || mapN == 2 || mapN == 3))) score += 6;
    size_t codeOff = hi ? size_t(reset) : (reset >= 0x8000 ? size_t(reset - 0x8000) : size_t(-1));
    if (codeOff < n) {
        u8 op = d[codeOff];
        if (op == 0x78 || op == 0x18 || op == 0x4C || op == 0x5C || op == 0xA9 ||
            op == 0xA2 || op == 0xA0 || op == 0xC2 || op == 0xE2 || op == 0x38 || op == 0xEA)
            score += 2;
    }
    int letters = 0;
    bool printable = true;
    for (int i = 0; i < 21; ++i) {
        u8 c = h[i];
        if (c == 0 || c == ' ') continue;
        if (c < 0x20 || c > 0x7E) printable = false;
        else ++letters;
    }
    if (printable && letters >= 4) score += 3;
    u8 sz = h[0x17];
    if (sz >= 5 && sz <= 16) {
        size_t declared = size_t(1024) << sz;
        if (declared == n) score += 4;
        else if (declared / 2 < n && n < declared * 2) score += 2;
    }
    return score;
}
}

bool isSNESImage(const u8* data, size_t size) {
    if (!data || size < 0x8000) return false;
    size_t base = (size % 1024 == 512) ? 512 : 0;
    const u8* d = data + base;
    size_t n = size - base;
    return headerScore(d, n, 0x7FC0, false) >= 6 || headerScore(d, n, 0xFFC0, true) >= 6;
}

std::unique_ptr<EmulatorCore> createNESCore() { return std::make_unique<AresFamicom>(); }
std::unique_ptr<EmulatorCore> createSNESCore() { return std::make_unique<AresSuperFamicom>(); }

void superFamicomCpuDebug(u32* pc, u8* wram, u32 wramAddress, u32 wramCount) {
    if (pc) *pc = (u32)ares::SuperFamicom::cpu.r.pc.d;
    if (wram) {
        for (u32 i = 0; i < wramCount; ++i)
            wram[i] = (u8)ares::SuperFamicom::cpu.readRAM(wramAddress + i, 0);
    }
}

void superFamicomApuDebug(u16* pc, u8 visible[4], u8* ram, u32 ramAddress, u32 ramCount) {
    if (pc) *pc = (u16)ares::SuperFamicom::smp.r.pc.w;
    if (visible) {
        for (int i = 0; i < 4; ++i) visible[i] = (u8)ares::SuperFamicom::smp.portRead(i);
    }
    if (ram) {
        for (u32 i = 0; i < ramCount; ++i)
            ram[i] = (u8)ares::SuperFamicom::dsp.apuram[(u16)(ramAddress + i)];
    }
}

} // namespace dscore
