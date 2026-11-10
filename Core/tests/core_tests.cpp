// Copyright (c) 2026 Charlie Rodriguez Garcia. All rights reserved.
// Host-side unit tests for the clean-room core (build with `make test`).
#include "dscore/ARMCPU.hpp"
#include "dscore/AudioRing.hpp"
#include "dscore/EmulatorCore.hpp"
#include "../src/NDSSystem.hpp"
#include "../src/Cheats.hpp"
#include <map>
#include "../src/GBASystem.hpp"
#include <cstdio>
#include <ctime>
#include <algorithm>
#include <cstdlib>
#include <cstring>
#include <vector>

using namespace dscore;
static int failures = 0;
#define CHECK(cond) do { if (!(cond)) { std::printf("FAIL %s:%d %s\n", __FILE__, __LINE__, #cond); ++failures; } } while (0)

struct FlatBus : Bus {
    std::vector<u8> m = std::vector<u8>(1 << 16);
    u8 read8(u32 a) override { return m[a & 0xFFFF]; }
    u16 read16(u32 a) override { a &= 0xFFFE; return u16(m[a] | (m[a + 1] << 8)); }
    u32 read32(u32 a) override { a &= 0xFFFC; return m[a] | (m[a + 1] << 8) | (m[a + 2] << 16) | (u32(m[a + 3]) << 24); }
    void write8(u32 a, u8 v) override { m[a & 0xFFFF] = v; }
    void write16(u32 a, u16 v) override { a &= 0xFFFE; m[a] = u8(v); m[a + 1] = u8(v >> 8); }
    void write32(u32 a, u32 v) override { a &= 0xFFFC; for (int i = 0; i < 4; ++i) m[a + i] = u8(v >> (8 * i)); }
    void arm(u32 a, std::initializer_list<u32> code) { for (u32 c : code) { write32(a, c); a += 4; } }
    void thumb(u32 a, std::initializer_list<u16> code) { for (u16 c : code) { write16(a, c); a += 2; } }
};

static void run(ARMCPU& c, int n) { for (int i = 0; i < n && !c.faulted; ++i) c.step(); }

static void testArmBasics() {
    FlatBus b; ARMCPU c(ARMCPU::Arch::ARMv5TE, b);
    b.arm(0x100, {
        0xE3A00001,  // MOV r0,#1
        0xE3A01102,  // MOV r1,#0x80000000
        0xE0912001,  // ADDS r2,r1,r1  -> 0, C=1 V=1 Z=1
        0xE2803005,  // ADD r3,r0,#5   -> 6
        0xE0040393,  // MUL r4,r3,r3   -> 36
        0xE16F5F14,  // CLZ r5,r4      -> 26
        0xE1A06103,  // MOV r6,r3,LSL #2 -> 24
        0xE3A0DC01,  // MOV sp,#0x100
        0xE92D0018,  // STMFD sp!,{r3,r4}
        0xE8BD0180,  // LDMFD sp!,{r7,r8}
        0xE1600384,  // SMULBB r0,r4,r3 -> 216
    });
    c.reset(0x100);
    run(c, 3);
    CHECK(c.reg(2) == 0);
    CHECK(c.cpsr() & ARMCPU::FlagZ); CHECK(c.cpsr() & ARMCPU::FlagC); CHECK(c.cpsr() & ARMCPU::FlagV);
    run(c, 8);
    CHECK(!c.faulted);
    CHECK(c.reg(3) == 6); CHECK(c.reg(4) == 36); CHECK(c.reg(5) == 26); CHECK(c.reg(6) == 24);
    CHECK(c.reg(7) == 6); CHECK(c.reg(8) == 36); CHECK(c.reg(13) == 0x100);
    CHECK(c.reg(0) == 216);
}

static void testBranchAndThumb() {
    FlatBus b; ARMCPU c(ARMCPU::Arch::ARMv5TE, b);
    b.arm(0x200, {
        0xE3A00C03,  // MOV r0,#0x300
        0xE2800001,  // ADD r0,r0,#1 (thumb bit)
        0xE12FFF30,  // BLX r0
        0xE3A0A0AA,  // MOV r10,#0xAA (after return)
    });
    b.thumb(0x300, {
        0x2005,      // MOV r0,#5
        0x3003,      // ADD r0,#3   -> 8
        0x0081,      // LSL r1,r0,#2 -> 32
        0x2920,      // CMP r1,#32
        0xD000,      // BEQ +0 (skip next)
        0x2263,      // MOV r2,#99 (skipped)
        0x2307,      // MOV r3,#7
        0x4358,      // MUL r0,r3   -> 56
        0x4770,      // BX lr
    });
    c.reset(0x200);
    run(c, 3);
    CHECK(c.thumb()); CHECK(c.pc() == 0x300);
    CHECK(c.reg(14) == 0x20C);
    run(c, 8);
    CHECK(c.reg(0) == 56); CHECK(c.reg(1) == 32); CHECK(c.reg(2) == 0); CHECK(c.reg(3) == 7);
    CHECK(!c.thumb()); CHECK(c.pc() == 0x20C);
    run(c, 1);
    CHECK(c.reg(10) == 0xAA);
}

static void testThumbBL() {
    FlatBus b; ARMCPU c(ARMCPU::Arch::ARMv4T, b);
    // At 0x400: BL to 0x500 (offset = 0x500 - 0x404 = 0xFC -> halfwords 0x7E)
    b.thumb(0x400, {0xF000, 0xF87E});
    b.thumb(0x500, {0x2142});      // MOV r1,#0x42
    c.reset(0x400, true);
    run(c, 2);
    CHECK(c.pc() == 0x500); CHECK(c.reg(14) == 0x405);
    run(c, 1);
    CHECK(c.reg(1) == 0x42);
}

static void testHeaderAndBoot() {
    std::vector<u8> rom(0x400, 0);
    std::memcpy(rom.data(), "HOMEBREWTEST", 12);
    std::memcpy(rom.data() + 0x0C, "TEST", 4);
    auto put = [&](u32 off, u32 v) { for (int i = 0; i < 4; ++i) rom[off + i] = u8(v >> (8 * i)); };
    put(0x20, 0x200); put(0x24, 0x02000000); put(0x28, 0x02000000); put(0x2C, 0x40);
    put(0x30, 0x300); put(0x34, 0x02380000); put(0x38, 0x02380000); put(0x3C, 0x4);
    const u32 arm9[] = {0xE3A00301, 0xE3A05080, 0xE5C05240 /* VRAMCNT_A = LCDC */, 0xE3A01802, 0xE5801000, 0xE3A02668, 0xE3A0301F, 0xE3A04CC0,
                        0xE0C230B2, 0xE2544001, 0x1AFFFFFC, 0xEAFFFFFE};
    for (u32 i = 0; i < 12; ++i) put(0x200 + i * 4, arm9[i]);
    put(0x300, 0xEAFFFFFE);
    u16 crc = crc16(rom.data(), 0x15E); rom[0x15E] = u8(crc); rom[0x15F] = u8(crc >> 8);

    RomInfo info; std::string err;
    CHECK(parseRomHeader(rom.data(), rom.size(), info, err));
    CHECK(info.title == "HOMEBREWTEST"); CHECK(info.gameCode == "TEST"); CHECK(info.headerCrcValid);

    auto core = createCore(CoreKind::Interpreter);
    CHECK(core->loadROM(rom.data(), rom.size(), err));
    core->runFrame();
    core->runFrame();
    std::printf("status: %s\n", core->statusText().c_str());
    CHECK(core->framebuffer(0)[0] == 0xFFFF0000u);                 // red, VRAM display mode
    CHECK(core->framebuffer(0)[kScreenPixels - 1] == 0xFFFF0000u);
    s16 audio[2048];
    CHECK(core->readAudio(audio, 1024) > 0);

    auto tp = createCore(CoreKind::TestPattern);
    tp->setButtons(BtnA);
    tp->runFrame();
    CHECK(tp->framebuffer(0)[0] == 0xFFFFFFFFu);
    CHECK(tp->readAudio(audio, 1024) == 800);
}

// ---------------------------------------------------------------- ROM builder
// Tiny ARM "assembler" used to hand-build test ROMs.
struct Asm {
    std::vector<u32> code;
    std::vector<std::pair<size_t, u32>> lits;
    size_t here() const { return code.size(); }
    void raw(u32 w) { code.push_back(w); }
    void ldr(int rd, u32 value) { lits.push_back({code.size(), value}); code.push_back(0xE59F0000u | (u32(rd) << 12)); }
    void poke32(u32 a, u32 v) { ldr(0, a); ldr(1, v); raw(0xE5801000u); }           // STR r1,[r0]
    void poke16(u32 a, u32 v) { ldr(0, a); ldr(1, v); raw(0xE1C010B0u); }           // STRH r1,[r0]
    void poke8(u32 a, u32 v)  { ldr(0, a); ldr(1, v); raw(0xE5C01000u); }           // STRB r1,[r0]
    void fill16(u32 a, u32 v, u32 count) {
        ldr(0, a); ldr(1, v); ldr(2, count);
        raw(0xE0C010B2u);   // STRH r1,[r0],#2
        raw(0xE2522001u);   // SUBS r2,r2,#1
        raw(0x1AFFFFFCu);   // BNE back
    }
    void branchTo(size_t target, u32 cond = 0xE) {
        s32 off = (s32(target) * 4 - (s32(code.size()) * 4 + 8)) / 4;
        raw((cond << 28) | 0x0A000000u | (u32(off) & 0xFFFFFF));
    }
    std::vector<u32> finish() {
        raw(0xEAFFFFFEu);   // B .
        size_t pool = code.size();
        for (size_t j = 0; j < lits.size(); ++j) {
            size_t i = lits[j].first;
            u32 off = u32((pool + j) * 4 - (i * 4 + 8));
            code[i] |= off;
            code.push_back(lits[j].second);
        }
        return code;
    }
};

static std::vector<u8> makeRom(const std::vector<u32>& arm9, const std::vector<u32>& arm7 = {0xEAFFFFFEu}) {
    std::vector<u8> rom(0x4000, 0);
    auto put = [&](u32 off, u32 v) { for (int i = 0; i < 4; ++i) rom[off + i] = u8(v >> (8 * i)); };
    std::memcpy(rom.data(), "UNITTESTROM", 11);
    put(0x20, 0x200); put(0x24, 0x02000000); put(0x28, 0x02000000); put(0x2C, u32(arm9.size() * 4));
    put(0x30, 0x2000); put(0x34, 0x02380000); put(0x38, 0x02380000); put(0x3C, u32(arm7.size() * 4));
    for (size_t i = 0; i < arm9.size(); ++i) put(0x200 + u32(i) * 4, arm9[i]);
    for (size_t i = 0; i < arm7.size(); ++i) put(0x2000 + u32(i) * 4, arm7[i]);
    u16 crc = crc16(rom.data(), 0x15E); rom[0x15E] = u8(crc); rom[0x15F] = u8(crc >> 8);
    return rom;
}

static std::unique_ptr<NDSSystem> bootRom(const std::vector<u32>& arm9, int frames = 2) {
    auto sys = std::make_unique<NDSSystem>();
    std::string err;
    auto rom = makeRom(arm9);
    if (!sys->loadROM(rom.data(), rom.size(), err)) { std::printf("load failed: %s\n", err.c_str()); ++failures; }
    for (int i = 0; i < frames; ++i) sys->runFrame();
    if (sys->arm9().faulted) { std::printf("ARM9 fault: %s\n", sys->arm9().faultMessage.c_str()); ++failures; }
    return sys;
}

constexpr u32 RED = 0xFFFF0000u, GREEN = 0xFF00FF00u, BLUE = 0xFF0000FFu, BLACK = 0xFF000000u, WHITE = 0xFFFFFFFFu;
static u32 px(const EmulatorCore& c, int screen, int x, int y) { return c.framebuffer(screen)[y * 256 + x]; }

// IPC FIFO "receive not empty" stays requested while words are waiting (level, not edge):
// with the user's real BIOS, IntrWait acknowledged it before the FIFO was read and
// Pokemon B2/W2's PXI start-up deadlocked.
static void testFifoRecvIrqIsLevel() {
    auto delay = [](Asm& a, u32 n) { a.ldr(2, n); a.raw(0xE2522001u); a.raw(0x1AFFFFFDu); };
    Asm a7;
    a7.poke16(0x04000184, 0x8400);              // FIFO on, recv-not-empty IRQ enabled
    delay(a7, 20000);                           // ARM9 sends meanwhile
    a7.poke32(0x04000214, 0x40000);             // acknowledge IF bit 18 without reading the FIFO
    delay(a7, 2000);
    a7.ldr(0, 0x04000214); a7.raw(0xE5901000u); // r1 = IF
    a7.ldr(0, 0x02100000); a7.raw(0xE5801000u); // store to main RAM
    Asm a9;
    a9.poke16(0x04000184, 0x8000);
    delay(a9, 2000);
    a9.poke32(0x04000188, 0x12345678);
    auto sys = std::make_unique<NDSSystem>(); std::string err;
    auto rom = makeRom(a9.finish(), a7.finish());
    CHECK(sys->loadROM(rom.data(), rom.size(), err));
    for (int i = 0; i < 3; ++i) sys->runFrame();
    std::printf("fifo-level IF7=%08X\n", sys->cheatRead(0x02100000, 4));
    CHECK(sys->cheatRead(0x02100000, 4) & 0x40000u);
}

// Pokemon B2/W2 (Pokemon Center) waits for VBlank with IRQs masked: "halt; MSR enable; MSR
// disable; check the handler's flag". The IRQ must be taken inside that few-instruction window.
// It used to be checked only every 32 instructions, so the window was always missed and the game
// froze while the music kept playing.
static void testIrqTakenInShortEnableWindow() {
    Asm a;
    size_t skip = a.here(); a.raw(0);                       // patched: B main
    size_t handler = a.here();
    a.ldr(0, 0x02100000); a.raw(0xE3A01001u); a.raw(0xE5801000u);   // [flag] = 1
    a.ldr(0, 0x04000214); a.raw(0xE3A01001u); a.raw(0xE5801000u);   // acknowledge VBlank in IF
    a.raw(0xE12FFF1Eu);                                     // BX LR
    size_t main = a.here();
    a.raw(0xE321F0D2u); a.ldr(13, 0x02310000);              // IRQ mode (masked): SP
    a.raw(0xE321F09Fu); a.ldr(13, 0x02300000);              // system mode, IRQs masked: SP
    a.ldr(0, 0x027C000A); a.raw(0xEE090F11u);               // DTCM at 0x027C0000
    a.raw(0xEE110F10u); a.raw(0xE3800801u); a.raw(0xEE010F10u);     // DTCM on
    a.poke32(0x027C3FFC, 0x02000000u + u32(handler) * 4);   // IRQ handler vector
    a.poke16(0x04000004, 0x0008);                           // DISPSTAT: VBlank IRQ
    a.poke32(0x04000210, 1); a.poke32(0x04000208, 1);       // IE = VBlank, IME = 1
    size_t loop = a.here();
    a.raw(0xE3A00000u); a.raw(0xEE070F90u);                 // halt (CP15 wait for interrupt)
    a.raw(0xE10F0000u); a.raw(0xE3C01080u); a.raw(0xE121F001u);     // enable IRQs
    a.raw(0xE3811080u); a.raw(0xE121F001u);                 // disable IRQs again
    a.ldr(0, 0x02100000); a.raw(0xE5901000u); a.raw(0xE3510000u);
    a.branchTo(loop, 0x0);                                  // BEQ loop (flag still 0)
    a.poke32(0x02100004, 0xC0DE);
    auto code = a.finish();
    code[skip] = 0xEA000000u | (u32(s32(main) - s32(skip) - 2) & 0xFFFFFF);
    auto sys = bootRom(code, 6);
    std::printf("irq-window flag=%u done=%X\n", sys->cheatRead(0x02100000, 4), sys->cheatRead(0x02100004, 4));
    CHECK(sys->cheatRead(0x02100004, 4) == 0xC0DEu);
}

static void testTextBackgroundRom() {
    Asm a;
    a.poke8(0x04000240, 0x81);            // VRAMCNT_A: engine A BG, offset 0
    a.poke32(0x04000000, 0x00010100);     // DISPCNT A: display on, mode 0, BG0
    a.poke16(0x04000008, 0x0004);         // BG0CNT: char base 1 (0x4000), screen base 0, 4bpp
    a.poke16(0x05000000, 0x7C00);         // backdrop blue
    a.poke16(0x05000002, 0x001F);         // palette 1 red
    a.fill16(0x06004020, 0x1111, 16);     // tile 1: all pixels colour 1
    a.poke16(0x06000000, 0x0001);         // map (0,0) -> tile 1
    a.poke16(0x06000042, 0x0401);         // map (1,1) -> tile 1 h-flipped
    auto sys = bootRom(a.finish());
    CHECK(px(*sys, 0, 0, 0) == RED);
    CHECK(px(*sys, 0, 7, 7) == RED);
    CHECK(px(*sys, 0, 8, 0) == BLUE);
    CHECK(px(*sys, 0, 9, 9) == RED);
    CHECK(px(*sys, 0, 100, 100) == BLUE);
    CHECK(px(*sys, 1, 0, 0) == WHITE);    // engine B display off -> white, on the bottom screen
}

static void testSpriteEngineBRom() {
    Asm a;
    a.poke8(0x04000249, 0x82);            // VRAMCNT_I: engine B OBJ
    a.poke32(0x04001000, 0x00011000);     // DISPCNT B: display on, OBJ on, 2D mapping
    a.poke16(0x05000400, 0x0000);         // B backdrop black
    a.poke16(0x05000602, 0x03E0);         // B OBJ palette 1 green
    a.fill16(0x06600000, 0x1111, 16);     // OBJ tile 0
    a.fill16(0x07000400, 0x0200, 512);    // disable all B sprites
    a.poke16(0x07000400, 10);             // attr0: y=10, 8x8, 4bpp
    a.poke16(0x07000402, 20);             // attr1: x=20
    a.poke16(0x07000404, 0);              // attr2: tile 0, palette 0
    auto sys = bootRom(a.finish());
    CHECK(px(*sys, 1, 20, 10) == GREEN);
    CHECK(px(*sys, 1, 27, 17) == GREEN);
    CHECK(px(*sys, 1, 19, 10) == BLACK);
    CHECK(px(*sys, 1, 28, 10) == BLACK);
    CHECK(px(*sys, 1, 20, 18) == BLACK);
}

static void testCompositingDirect() {
    auto sys = bootRom({0xEAFFFFFEu}, 1);
    auto w16 = [&](u32 a, u32 v) { sys->write(true, a, v, 2); };
    auto w32 = [&](u32 a, u32 v) { sys->write(true, a, v, 4); };
    sys->write(true, 0x04000240, 0x81, 1);
    w32(0x04000000, 0x00010300);          // BG0 + BG1
    w16(0x04000008, 0x0005);              // BG0: prio 1, char base 1, map 0x0000
    w16(0x0400000A, 0x0104);              // BG1: prio 0, char base 1, map 0x0800
    w16(0x05000000, 0x0000);
    w16(0x05000002, 0x001F);              // red
    w16(0x05000004, 0x7C00);              // blue
    for (u32 i = 0; i < 16; ++i) { w16(0x06004020 + i * 2, 0x1111); w16(0x06004040 + i * 2, 0x2222); }
    for (u32 i = 0; i < 32 * 24; ++i) { w16(0x06000000 + i * 2, 1); w16(0x06000800 + i * 2, 2); }
    sys->runFrame();
    CHECK(px(*sys, 0, 50, 50) == BLUE);   // BG1 in front

    w16(0x04000050, 0x0142);              // alpha: 1st BG1, 2nd BG0
    w16(0x04000052, 0x0808);              // eva = evb = 8
    sys->runFrame();
    CHECK(px(*sys, 0, 50, 50) == 0xFF7B007Bu);

    w32(0x04000000, 0x00012300);          // + window 0
    w16(0x04000040, 0x0004);              // x 0..3
    w16(0x04000044, 0x00C0);              // y 0..191
    w16(0x04000048, 0x0001);              // inside: BG0 only
    w16(0x0400004A, 0x0022);              // outside: BG1 + effects
    sys->runFrame();
    CHECK(px(*sys, 0, 1, 10) == RED);
    CHECK(px(*sys, 0, 10, 10) == BLUE);   // BG0 masked out -> no 2nd target

    w16(0x0400006C, 0x4010);              // master brightness up 16
    sys->runFrame();
    CHECK(px(*sys, 0, 10, 10) == WHITE);
    w16(0x0400006C, 0);

    // Extended direct-colour bitmap on BG3 (mode 5), identity affine.
    w32(0x04000000, 0x00010805);
    w16(0x0400000E, 0x0084);              // BG3: bitmap, direct colour, 128x128, base 0
    w16(0x04000030, 0x0100); w16(0x04000036, 0x0100);
    w32(0x04000038, 0); w32(0x0400003C, 0);
    w16(0x06000000, 0x801F); w16(0x06000002, 0x0000);
    w16(0x05000000, 0x03E0);              // backdrop green
    sys->runFrame();
    CHECK(px(*sys, 0, 0, 0) == RED);
    CHECK(px(*sys, 0, 1, 0) == GREEN);
    CHECK(px(*sys, 0, 200, 0) == GREEN);  // outside 128x128 without wrap

    // POWCNT1 bit 15 clear: engine A goes to the bottom screen.
    w16(0x04000304, 0x020F);
    sys->runFrame();
    CHECK(px(*sys, 1, 0, 0) == RED);
    CHECK(px(*sys, 0, 0, 0) == WHITE);
}

static void testVRAMMapping() {
    auto sys = bootRom({0xEAFFFFFEu}, 1);
    sys->write(true, 0x04000240, 0x80, 1);                 // A -> LCDC
    sys->write(true, 0x06800010, 0xCAFE, 2);
    CHECK(sys->read(true, 0x06800010, 2) == 0xCAFE);
    CHECK(sys->read(true, 0x06000010, 2) == 0);            // not mapped to BG
    sys->write(true, 0x04000240, 0x89, 1);                 // A -> ABG offset 1 (0x06020000)
    CHECK(sys->read(true, 0x06020010, 2) == 0xCAFE);
    CHECK(sys->read(true, 0x06820010, 2) == 0);            // B bank not mapped
    sys->write(true, 0x04000245, 0x89, 1);                 // F -> ABG at 0x4000
    sys->write(true, 0x06004000, 0x1234, 2);
    CHECK(sys->read(true, 0x06004000, 2) == 0x1234);
    sys->write(true, 0x04000244, 0x84, 1);                 // E -> ABG ext palettes
    CHECK(sys->vram().bgExtPalette(true, 3) != nullptr);
    sys->write(true, 0x04000242, 0x82, 1);                 // C -> ARM7
    CHECK((sys->read(false, 0x04000240, 1) & 1) == 1);     // VRAMSTAT
    sys->write(false, 0x06000004, 0xBEEF, 2);
    CHECK(sys->read(false, 0x06000004, 2) == 0xBEEF);
    sys->write(true, 0x05000001, 0xFF, 1);                 // 8-bit palette writes ignored
    CHECK(sys->read(true, 0x05000000, 2) == 0);
}

static void testTouchScreenSPI() {
    auto sys = bootRom({0xEAFFFFFEu}, 1);
    sys->setTouch(true, 100, 50);
    auto spiRead = [&](u32 channelCmd) {
        sys->write(false, 0x040001C0, 0x8A00, 2);           // enable, TSC, chip-select hold
        sys->write(false, 0x040001C2, channelCmd, 1);
        sys->write(false, 0x040001C2, 0, 1);
        u32 hi = sys->read(false, 0x040001C2, 1);
        sys->write(false, 0x040001C0, 0x8200, 2);           // release after last byte
        sys->write(false, 0x040001C2, 0, 1);
        u32 lo = sys->read(false, 0x040001C2, 1);
        return (hi << 5) | (lo >> 3);
    };
    u32 x = spiRead(0xD0), y = spiRead(0x90);
    CHECK(x == sys->spi().adcX()); CHECK(y == sys->spi().adcY());
    int sx = int(x - 0x200) * 0xFE / 0xC00, sy = int(y - 0x200) * 0xBE / 0xC00;
    CHECK(sx >= 99 && sx <= 100); CHECK(sy >= 49 && sy <= 50);
    CHECK((sys->read(false, 0x04000136, 2) & 0x40) == 0);  // pen down
    sys->setTouch(false, 0, 0);
    CHECK((sys->read(false, 0x04000136, 2) & 0x40) != 0);

    // Firmware read: header byte 0x20 (user settings offset / 8 = 0x7FC0).
    sys->write(false, 0x040001C0, 0x8900, 2);
    for (u32 b : {0x03u, 0x00u, 0x00u, 0x20u}) sys->write(false, 0x040001C2, b, 1);
    sys->write(false, 0x040001C2, 0, 1);
    CHECK(sys->read(false, 0x040001C2, 1) == 0xC0);
    sys->write(false, 0x040001C2, 0, 1);
    CHECK(sys->read(false, 0x040001C2, 1) == 0x7F);
}

static void testVBlankPolling() {
    Asm a;
    a.ldr(0, 0x04000004); a.ldr(3, 0x02100000); a.raw(0xE3A04000);
    size_t waitSet = a.here();
    a.raw(0xE1D010B0); a.raw(0xE3110001); a.branchTo(waitSet, 0x0);   // BEQ
    a.raw(0xE2844001); a.raw(0xE5834000);
    size_t waitClear = a.here();
    a.raw(0xE1D010B0); a.raw(0xE3110001); a.branchTo(waitClear, 0x1); // BNE
    a.branchTo(waitSet);
    auto sys = bootRom(a.finish(), 5);
    CHECK(sys->read(true, 0x02100000, 4) == 5);
}

static void testVBlankIRQ() {
    Asm a;
    size_t skip = a.here(); a.raw(0);                     // patched: B main
    size_t handler = a.here();
    a.ldr(1, 0x04000214); a.raw(0xE3A02001); a.raw(0xE5812000);       // IF = 1 (ack)
    a.ldr(1, 0x00803FF8); a.raw(0xE5912000); a.raw(0xE3822001); a.raw(0xE5812000); // check flags |= 1
    a.raw(0xE12FFF1E);                                                 // BX lr
    size_t main = a.here();
    a.code[skip] = 0xEA000000u | u32((s32(main) * 4 - (s32(skip) * 4 + 8)) / 4);
    a.poke32(0x00803FFC, 0x02000000u + u32(handler) * 4);
    a.poke16(0x04000004, 0x0008);                         // VBlank IRQ enable
    a.poke32(0x04000210, 1);                              // IE
    a.poke32(0x04000208, 1);                              // IME
    a.raw(0xE321F01F);                                    // MSR CPSR_c, #0x1F (IRQs on)
    a.ldr(3, 0x02100000); a.raw(0xE3A04000);
    size_t loop = a.here();
    a.raw(0xEF050000);                                    // SWI VBlankIntrWait
    a.raw(0xE2844001); a.raw(0xE5834000);
    a.branchTo(loop);
    auto sys = bootRom(a.finish(), 6);
    u32 n = sys->read(true, 0x02100000, 4);
    std::printf("vblank irq count after 6 frames: %u\n", n);
    CHECK(n >= 5 && n <= 6);
}

static void testUserBankAndMisc() {
    FlatBus b; ARMCPU c(ARMCPU::Arch::ARMv5TE, b);
    b.arm(0x100, {
        0xE3A0DC02,  // MOV sp,#0x200 (SYS)
        0xE321F012,  // MSR CPSR_c,#0x12 (IRQ mode)
        0xE3A0DC03,  // MOV sp,#0x300 (IRQ sp)
        0xE3A00C01,  // MOV r0,#0x100... base for STM
        0xE2800C0F,  // ADD r0,r0,#0xF00 -> 0x1000
        0xE8C02000,  // STMIA r0,{sp}^   (user sp)
        0xE1200070,  // BKPT (ignored)
        0xEE000000,  // CDP (ignored)
        0xE5901000,  // LDR r1,[r0]
    });
    c.reset(0x100);
    run(c, 9);
    CHECK(!c.faulted);
    CHECK(c.reg(13) == 0x300);
    CHECK(c.reg(1) == 0x200);
}

// --------------------------------------------------------- milestone 3 tests
static std::vector<u8> auxSpi(NDSSystem& sys, std::initializer_list<u8> bytes, int extraReads = 0) {
    std::vector<u8> out;
    size_t n = bytes.size() + size_t(extraReads), i = 0;
    auto xfer = [&](u8 b) {
        bool last = ++i == n;
        sys.write(true, 0x040001A0, last ? 0xA000 : 0xA040, 2);   // enable + backup SPI, hold unless last
        sys.write(true, 0x040001A2, b, 1);
        out.push_back(u8(sys.read(true, 0x040001A2, 1)));
    };
    for (u8 b : bytes) xfer(b);
    for (int k = 0; k < extraReads; ++k) xfer(0);
    return out;
}

static void testSaveDetection() {
    {   // EEPROM 64K / FRAM-class (2-byte address, 128-byte page)
        auto sys = bootRom({0xEAFFFFFEu}, 1);
        CHECK(sys->saveMemory().type() == SaveMemory::Type::Unknown);
        auxSpi(*sys, {0x06});
        std::vector<u8> cmd = {0x02, 0x01, 0x00};
        for (int k = 0; k < 128; ++k) cmd.push_back(u8(k + 1));
        size_t i = 0;
        for (u8 b : cmd) { sys->write(true, 0x040001A0, ++i == cmd.size() ? 0xA000 : 0xA040, 2); sys->write(true, 0x040001A2, b, 1); }
        CHECK(sys->saveMemory().type() == SaveMemory::Type::EEPROM);
        CHECK(sys->saveData().size() == 0x10000);
        CHECK(sys->saveDataDirty());
        auto r = auxSpi(*sys, {0x03, 0x01, 0x00}, 3);
        CHECK(r[3] == 1 && r[4] == 2 && r[5] == 3);
        auto st = auxSpi(*sys, {0x05}, 1);
        CHECK(st[1] == 0x00);                                  // WEL cleared after the write
    }
    {   // Flash (3-byte address, 256-byte page write)
        auto sys = bootRom({0xEAFFFFFEu}, 1);
        auxSpi(*sys, {0x06});
        std::vector<u8> cmd = {0x0A, 0x00, 0x10, 0x00};
        for (int k = 0; k < 256; ++k) cmd.push_back(0x5A);
        size_t i = 0;
        for (u8 b : cmd) { sys->write(true, 0x040001A0, ++i == cmd.size() ? 0xA000 : 0xA040, 2); sys->write(true, 0x040001A2, b, 1); }
        CHECK(sys->saveMemory().type() == SaveMemory::Type::Flash);
        CHECK(sys->saveData().size() == 0x40000);
        CHECK(sys->saveData()[0x1000] == 0x5A && sys->saveData()[0x10FF] == 0x5A && sys->saveData()[0x1100] == 0xFF);
        auto id = auxSpi(*sys, {0x9F}, 3);
        CHECK(id[1] == 0x20 && id[2] == 0x40);
        auxSpi(*sys, {0x06}); auxSpi(*sys, {0xDB, 0x00, 0x10, 0x00});   // page erase
        CHECK(sys->saveData()[0x1000] == 0xFF);
    }
    {   // EEPROM 512 bytes: A8 in the command byte
        auto sys = bootRom({0xEAFFFFFEu}, 1);
        auxSpi(*sys, {0x06});
        auxSpi(*sys, {0x0A, 0x10, 0xAA, 0xBB});
        CHECK(sys->saveMemory().type() == SaveMemory::Type::EEPROM512);
        CHECK(sys->saveData().size() == 512 && sys->saveData()[0x110] == 0xAA && sys->saveData()[0x111] == 0xBB);
        auto r = auxSpi(*sys, {0x0B, 0x10}, 2);
        CHECK(r[2] == 0xAA && r[3] == 0xBB);
    }
    {   // Existing save file restores type + contents
        auto sys = bootRom({0xEAFFFFFEu}, 1);
        std::vector<u8> file(0x2000, 0); file[0x1234] = 0x77;
        sys->loadSaveData(file);
        CHECK(sys->saveMemory().type() == SaveMemory::Type::EEPROM);
        auto r = auxSpi(*sys, {0x03, 0x12, 0x34}, 1);
        CHECK(r[3] == 0x77);
        CHECK(!sys->saveDataDirty());
    }
}

static void auxWrite(NDSSystem& sys, const std::vector<u8>& cmd) {
    size_t i = 0;
    for (u8 b : cmd) { sys.write(true, 0x040001A0, ++i == cmd.size() ? 0xA000 : 0xA040, 2); sys.write(true, 0x040001A2, b, 1); }
}

static void testInfraredSave() {
    // IR cartridges: one controller byte before every flash transaction.
    SaveMemory m; m.setOverride(SaveMemory::Override::Flash512K); m.setInfrared(true);
    auto tx = [&](std::vector<u8> b) { std::vector<u8> r; for (u8 v : b) r.push_back(m.transfer(v)); m.release(); return r; };
    tx({0x00, 0x06});
    tx({0x00, 0x0A, 0x00, 0x01, 0x00, 0x5A, 0xA5});
    auto r = tx({0x00, 0x03, 0x00, 0x01, 0x00, 0, 0});
    CHECK(r[5] == 0x5A && r[6] == 0xA5);
    CHECK(tx({0x00, 0x05, 0})[2] == 0x00);
    CHECK(tx({0x08, 0})[1] == 0xAA);
    CHECK(m.data().size() == 0x80000 && m.data()[0x100] == 0x5A);
}

static void testSaveProbeDetection() {
    // NSMB-style stream: a short first write that also fits a 512-byte EEPROM, then 32-byte
    // page writes at 0x11xx that only a 2-byte-address EEPROM can do.
    for (bool withBadFile : {false, true}) {
        auto sys = bootRom({0xEAFFFFFEu}, 1);
        if (withBadFile) sys->loadSaveData(std::vector<u8>(512, 0x00));   // misdetected old save
        auxSpi(*sys, {0x06});
        std::vector<u8> w = {0x02, 0x11, 0x00};
        for (int k = 0; k < 10; ++k) w.push_back(u8(0xC0 + k));
        auxWrite(*sys, w);
        auto r = auxSpi(*sys, {0x03, 0x11, 0x00}, 10);                    // read-back check
        CHECK(r[3] == 0xC0 && r[12] == 0xC9);
        for (int pg = 1; pg < 4; ++pg) {
            auxSpi(*sys, {0x06});
            std::vector<u8> p = {0x02, 0x11, u8(pg * 0x20)};
            for (int k = 0; k < 32; ++k) p.push_back(u8(pg));
            auxWrite(*sys, p);
        }
        CHECK(sys->saveMemory().type() == SaveMemory::Type::EEPROM);
        CHECK(sys->saveData().size() == 0x2000);
        CHECK(sys->saveData()[0x1100] == 0xC0 && sys->saveData()[0x1109] == 0xC9 && sys->saveData()[0x110A] == 0xFF);
        CHECK(sys->saveData()[0x1120] == 1 && sys->saveData()[0x117F] == 3);
        CHECK(sys->saveMemory().loadedSaveRejected() == withBadFile);
        auto st = auxSpi(*sys, {0x05}, 1);
        CHECK(st[1] == 0x00);
    }
    {   // Flash ID read before any write is answered by the flash candidate
        auto sys = bootRom({0xEAFFFFFEu}, 1);
        auto id = auxSpi(*sys, {0x9F}, 3);
        CHECK(id[1] == 0x20 && id[2] == 0x40);
    }
    {   // Per-game override forces the chip
        auto sys = bootRom({0xEAFFFFFEu}, 1);
        sys->saveMemory().setOverride(SaveMemory::Override::Flash512K);
        CHECK(sys->saveData().size() == 0x80000 && sys->saveData()[0] == 0xFF);
        auxSpi(*sys, {0x06}); auxSpi(*sys, {0x02, 0x07, 0x00, 0x00, 0x42});
        CHECK(sys->saveData()[0x70000] == 0x42);
    }
}


static void testSoundCaptureAndInterp() {
    auto sys = bootRom({0xEAFFFFFEu}, 1);
    auto w = [&](u32 a, u32 v, int sz) { sys->write(false, a, v, sz); };
    s16 buf[4096];
    while (sys->readAudio(buf, 2048)) {}
    for (u32 i = 0; i < 64; ++i) w(0x02300000 + i * 2, (i & 1) ? 0x2000 : 0xE000, 2);   // square at nyquist
    w(0x04000500, 0x807F, 2);
    w(0x04000404, 0x02300000, 4); w(0x04000408, 0x10000 - 512, 2); w(0x0400040A, 0, 2); w(0x0400040C, 32, 4);
    // Capture 0: left mixer to 0x02310000, 16 words, PCM16, loop, rate = ch1 timer.
    for (u32 i = 0; i < 32; ++i) w(0x02310000 + i * 2, 0x1234, 2);
    w(0x04000418, 0x10000 - 512, 2);
    w(0x04000510, 0x02310000, 4); w(0x04000514, 16, 2);
    w(0x04000508, 0x80, 1);
    w(0x04000400, 0xA840007F | (64u << 16), 4);
    sys->runFrame();
    size_t n = sys->readAudio(buf, 2048);
    CHECK(n > 700);
    bool wrote = false;
    for (u32 i = 0; i < 32; ++i) if (u16(sys->read(false, 0x02310000 + i * 2, 2)) != 0x1234) wrote = true;
    CHECK(wrote);                                   // capture stored mixer output
    // Cubic interpolation keeps output within full scale (no overshoot wrap).
    for (size_t i = 0; i < n; ++i) CHECK(buf[i * 2] > -32768 && buf[i * 2] < 32767);
}

static void testSoundChannels() {
    auto sys = bootRom({0xEAFFFFFEu}, 1);
    auto w = [&](u32 a, u32 v, int sz) { sys->write(false, a, v, sz); };
    s16 buf[4096];
    while (sys->readAudio(buf, 2048)) {}
    // Ch0: PCM16 loop of constant 0x4000, full volume, centre pan.
    for (u32 i = 0; i < 64; ++i) w(0x02300000 + i * 2, 0x4000, 2);
    w(0x04000504, 0x200, 2);                       // SOUNDBIAS
    w(0x04000500, 0x807F, 2);                      // SOUNDCNT: enable, master 127
    w(0x04000404, 0x02300000, 4);                  // SAD
    w(0x04000408, 0x10000 - 512, 2);               // TMR (~32.7 kHz)
    w(0x0400040A, 0, 2);                           // PNT
    w(0x0400040C, 32, 4);                          // LEN (words)
    w(0x04000400, 0xA840007F | (64u << 16), 4);    // start, loop, PCM16, pan 64, vol 127
    sys->runFrame();
    size_t n = sys->readAudio(buf, 2048);
    CHECK(n >= 790 && n <= 810);
    s32 expectL = ((((0x4000 * 127) >> 7) * (128 - 64)) >> 7) * 127 >> 7 >> 1;   // GBATEK pan: left = 128 - pan
    CHECK(std::abs(buf[200] - expectL) <= 2);
    CHECK(buf[201] > 0);
    CHECK((sys->read(false, 0x04000403, 1) & 0x80) != 0);   // still playing (looping)

    // One-shot PCM8 of one word ends and clears the start bit.
    w(0x04000400, 0, 4);
    w(0x0400041C, 1, 4); w(0x04000414, 0x02300000, 4); w(0x04000418, 0x10000 - 512, 2);
    w(0x04000410, 0x9000007F | (64u << 16), 4);    // start, one-shot, PCM8
    sys->runFrame();
    CHECK((sys->read(false, 0x04000413, 1) & 0x80) == 0);

    // Ch8: PSG square wave produces both polarities.
    w(0x04000410, 0, 4);
    w(0x04000488, 0x10000 - 2000, 2);
    w(0x04000480, 0xE300007F | (64u << 16), 4);    // start, PSG, duty 3 (50%)
    while (sys->readAudio(buf, 2048)) {}
    sys->runFrame();
    n = sys->readAudio(buf, 2048);
    bool pos = false, neg = false;
    for (size_t i = 0; i < n; ++i) { pos |= buf[i * 2] > 1000; neg |= buf[i * 2] < -1000; }
    CHECK(pos && neg);

    // Ch1: IMA-ADPCM with nibbles 7 (large positive steps) rises from the header value.
    w(0x04000480, 0, 4);
    w(0x02310000, 0x00000000 | 100, 4);            // header: value 100, index 0
    for (u32 i = 1; i < 9; ++i) w(0x02310000 + i * 4, 0x77777777, 4);
    w(0x04000414, 0x02310000, 4); w(0x04000418, 0x10000 - 512, 2); w(0x0400041A, 0, 2); w(0x0400041C, 8, 4);
    while (sys->readAudio(buf, 2048)) {}
    w(0x04000410, 0xD000007F | (64u << 16), 4);    // start, one-shot, ADPCM
    sys->runFrame();
    n = sys->readAudio(buf, 2048);
    CHECK(n > 40);
    CHECK(buf[2 * 2] > 0 && buf[40 * 2] > buf[2 * 2]);
}

static void testIdleSkipAndFastMemory() {
    auto sys = bootRom({0xEAFFFFFEu}, 1);
    u64 before = sys->arm9().instructionsExecuted;
    sys->runFrame();
    CHECK(sys->arm9().instructionsExecuted - before < 2000);   // "B ." sleeps instead of spinning
    CHECK(sys->arm9().idle);

    // Fast-path stores from the ARM9 are visible to the ARM7 and through WRAMCNT changes.
    Asm a;
    a.poke32(0x02200000, 0x11223344);
    a.poke8(0x04000247, 0x00);                // WRAMCNT: all shared WRAM to ARM9
    a.poke32(0x03000010, 0xA5A5A5A5);
    auto s2 = bootRom(a.finish(), 1);
    CHECK(s2->read(false, 0x02200000, 4) == 0x11223344);
    CHECK(s2->read(true, 0x03000010, 4) == 0xA5A5A5A5);
    s2->write(true, 0x04000247, 3, 1);        // now ARM7 owns it
    CHECK(s2->read(false, 0x03000010, 4) == 0xA5A5A5A5);
    CHECK(s2->read(true, 0x03000010, 4) == 0);

    // A counting loop is NOT treated as idle (registers change every pass).
    Asm b;
    b.ldr(2, 200000); b.ldr(3, 0x02100000);
    size_t loop = b.here();
    b.raw(0xE2522001); b.branchTo(loop, 0x1);  // SUBS r2,#1 ; BNE loop
    b.raw(0xE3A04001); b.raw(0xE5834000);      // MOV r4,#1 ; STR r4,[r3]
    auto s3 = bootRom(b.finish(), 2);
    CHECK(s3->read(true, 0x02100000, 4) == 1);
}


// ------------------------------------------------------------ milestone 4
static void gx(NDSSystem& s, u8 cmd, std::initializer_list<u32> params) {
    if (params.size() == 0) { s.write(true, 0x04000400u + cmd * 4u, 0, 4); return; }
    for (u32 p : params) s.write(true, 0x04000400u + cmd * 4u, p, 4);
}
static void vtx(NDSSystem& s, s32 x, s32 y, s32 z) { gx(s, 0x23, {(u32(x) & 0xFFFF) | (u32(y) << 16), u32(z) & 0xFFFF}); }

static void test3DGeometryAndRaster() {
    auto sys = bootRom({0xEAFFFFFEu}, 1);
    NDSSystem& s = *sys;
    s.write(true, 0x04000000, 0x00010108, 4);           // DISPCNT A: BG0 on, BG0 = 3D
    s.write(true, 0x05000000, 0x7C00, 2);               // backdrop blue
    s.write(true, 0x04000060, 0x0000, 2);               // DISP3DCNT: no textures
    s.write(true, 0x04000350, 0x00000000, 4);           // clear colour transparent
    s.write(true, 0x04000354, 0x7FFF, 2);               // clear depth: far
    // Packed FIFO: MTX_MODE(0) then MTX_IDENTITY
    s.write(true, 0x04000400, 0x00001510, 4);
    s.write(true, 0x04000400, 0x00000000, 4);
    gx(s, 0x10, {2}); gx(s, 0x15, {});
    gx(s, 0x60, {0xBFFF0000u});                         // viewport full screen
    gx(s, 0x29, {0x001F00C0u});                         // opaque, both faces, no lights
    gx(s, 0x40, {0});                                   // triangles
    gx(s, 0x20, {0x001F});                              // red
    vtx(s, -0x800, -0x800, 0); vtx(s, 0x800, -0x800, 0); vtx(s, 0, 0x800, 0);
    gx(s, 0x40, {1});                                   // quads: a green full-screen quad behind
    gx(s, 0x20, {0x03E0});
    vtx(s, -0x1000, -0x1000, 0x800); vtx(s, 0x1000, -0x1000, 0x800); vtx(s, 0x1000, 0x1000, 0x800); vtx(s, -0x1000, 0x1000, 0x800);
    gx(s, 0x41, {});
    CHECK((s.read(true, 0x04000604, 4) & 0xFFF) == 2);   // RAM_COUNT: 2 polygons
    gx(s, 0x50, {0});
    CHECK(s.read(true, 0x04000600, 4) & (1u << 27));     // busy until VBlank swap
    gx(s, 0x20, {0x7C00});                               // deferred while the swap is pending
    s.runFrame(); s.runFrame();
    CHECK(!(s.read(true, 0x04000600, 4) & (1u << 27)));
    CHECK(s.gpu3d().lastPolygonCount() == 2);
    CHECK(px(s, 0, 128, 100) == RED);                    // triangle wins the depth test
    CHECK(px(s, 0, 5, 5) == GREEN);                      // quad elsewhere
    CHECK(px(s, 0, 128, 40) == GREEN);                   // above the triangle's apex

    // Matrices: translate then read back the clip matrix.
    gx(s, 0x10, {0}); gx(s, 0x15, {});
    gx(s, 0x10, {1}); gx(s, 0x15, {});
    gx(s, 0x1C, {0x1000, 0x2000, 0x3000});
    CHECK(s.read(true, 0x04000670, 4) == 0x1000);
    CHECK(s.read(true, 0x04000674, 4) == 0x2000);
    gx(s, 0x11, {}); gx(s, 0x11, {});
    CHECK(((s.read(true, 0x04000600, 4) >> 8) & 31) == 2);
    gx(s, 0x12, {2});
    CHECK(((s.read(true, 0x04000600, 4) >> 8) & 31) == 0);
    gx(s, 0x71, {0, 0});                                 // POS_TEST at origin -> translation
    CHECK(s.read(true, 0x04000620, 4) == 0x1000 && s.read(true, 0x04000628, 4) == 0x3000);
}


// Regression: a triangle wound counter-clockwise in clip space (y up) is the front face.
// The inverted sign used to cull every ground polygon of a commercial racing game.
static void test3DCullingWinding() {
    for (int pass = 0; pass < 2; ++pass) {
        auto sys = bootRom({0xEAFFFFFEu}, 1);
        NDSSystem& s = *sys;
        s.write(true, 0x04000000, 0x00010108, 4);
        s.write(true, 0x04000060, 0x0000, 2);
        s.write(true, 0x04000350, 0x00000000, 4);
        s.write(true, 0x04000354, 0x7FFF, 2);
        gx(s, 0x10, {0}); gx(s, 0x15, {}); gx(s, 0x10, {2}); gx(s, 0x15, {});
        gx(s, 0x60, {0xBFFF0000u});
        gx(s, 0x29, {pass == 0 ? 0x001F0080u : 0x001F0040u});   // front only, then back only
        gx(s, 0x40, {0});
        gx(s, 0x20, {0x001F});
        vtx(s, -0x800, -0x800, 0); vtx(s, 0x800, -0x800, 0); vtx(s, 0, 0x800, 0);
        gx(s, 0x41, {});
        gx(s, 0x50, {0});
        s.runFrame(); s.runFrame();
        CHECK(s.gpu3d().lastPolygonCount() == (pass == 0 ? 1u : 0u));
    }
}

static void test3DTexturesAlphaFog() {
    auto sys = bootRom({0xEAFFFFFEu}, 1);
    NDSSystem& s = *sys;
    // Texture (16-colour, 8x8, all index 1) in bank A, palette in bank E, written through LCDC.
    s.write(true, 0x04000240, 0x80, 1); s.write(true, 0x04000244, 0x80, 1);
    for (u32 i = 0; i < 32; i += 2) s.write(true, 0x06800000 + i, 0x1111, 2);
    s.write(true, 0x06880002, 0x03E0, 2);                // palette colour 1 = green
    s.write(true, 0x04000240, 0x83, 1); s.write(true, 0x04000244, 0x83, 1);   // A -> texture slot 0, E -> palette
    s.write(true, 0x04000000, 0x00010108, 4);
    s.write(true, 0x04000060, 0x0009, 2);                // textures + alpha blending
    s.write(true, 0x04000350, 0x001F7C00, 4);            // clear: opaque blue
    s.write(true, 0x04000354, 0x7FFF, 2);
    gx(s, 0x10, {0}); gx(s, 0x15, {}); gx(s, 0x10, {2}); gx(s, 0x15, {});
    gx(s, 0x60, {0xBFFF0000u});
    // Left half: textured opaque quad.
    gx(s, 0x29, {0x001F00C0u});
    gx(s, 0x2A, {(3u << 26) | (1u << 16) | (1u << 17)}); // 16-colour, repeat
    gx(s, 0x2B, {0});
    gx(s, 0x20, {0x7FFF});
    gx(s, 0x40, {1});
    gx(s, 0x22, {0}); vtx(s, -0x1000, -0x1000, 0);
    gx(s, 0x22, {0x80}); vtx(s, 0, -0x1000, 0);
    gx(s, 0x22, {0x00800080}); vtx(s, 0, 0x1000, 0);
    gx(s, 0x22, {0x00800000}); vtx(s, -0x1000, 0x1000, 0);
    // Right half: untextured red at alpha 16 over the blue clear colour.
    gx(s, 0x2A, {0});
    gx(s, 0x29, {0x001000C0u});
    gx(s, 0x20, {0x001F});
    gx(s, 0x40, {1});
    vtx(s, 0, -0x1000, 0); vtx(s, 0x1000, -0x1000, 0); vtx(s, 0x1000, 0x1000, 0); vtx(s, 0, 0x1000, 0);
    gx(s, 0x50, {0});
    s.runFrame(); s.runFrame();
    CHECK(px(s, 0, 40, 96) == GREEN);
    u32 mixed = px(s, 0, 200, 96);
    u32 r = (mixed >> 16) & 0xFF, b = mixed & 0xFF;
    CHECK(r > 0x50 && r < 0xB0 && b > 0x50 && b < 0xB0);   // roughly half red, half blue

    // Fog: all-density table, fog colour white on fogged pixels.
    s.write(true, 0x04000060, 0x0080, 2);                // fog on, no textures
    s.write(true, 0x04000358, 0x001F7FFF, 4);
    for (u32 i = 0; i < 32; ++i) s.write(true, 0x04000360 + i, 127, 1);
    gx(s, 0x29, {0x001F80C0u});                          // opaque, fog enabled
    gx(s, 0x20, {0x001F});
    gx(s, 0x40, {1});
    vtx(s, -0x1000, -0x1000, 0); vtx(s, 0x1000, -0x1000, 0); vtx(s, 0x1000, 0x1000, 0); vtx(s, -0x1000, 0x1000, 0);
    gx(s, 0x50, {0});
    s.runFrame(); s.runFrame();
    CHECK(px(s, 0, 128, 96) == WHITE);
}

static void testRTC() {
    auto sys = bootRom({0xEAFFFFFEu}, 1);
    NDSSystem& s = *sys;
    s.rtc().clock = [] { std::tm t{}; t.tm_year = 126; t.tm_mon = 9; t.tm_mday = 14; t.tm_wday = 3; t.tm_hour = 21; t.tm_min = 7; t.tm_sec = 42; return t; };
    auto w = [&](u16 v) { s.write(false, 0x04000138, v, 2); };
    w(0x0000); w(0x0004);                                // select
    u8 cmd = 0x65;                                       // 0110 010 1 = read date/time, sent MSB first
    for (int i = 7; i >= 0; --i) { u16 d = (cmd >> i) & 1; w(u16(0x0014 | d)); w(u16(0x0016 | d)); }
    u8 out[7] = {};
    for (int byte = 0; byte < 7; ++byte)
        for (int bit = 0; bit < 8; ++bit) {
            w(0x0004); w(0x0006);
            out[byte] = u8(out[byte] | ((s.read(false, 0x04000138, 2) & 1) << bit));
        }
    w(0x0000);
    CHECK(out[0] == 0x26 && out[1] == 0x10 && out[2] == 0x14 && out[3] == 3);
    CHECK((out[4] & 0x3F) == 0x21 && (out[4] & 0x40) && out[5] == 0x07 && out[6] == 0x42);
}

static void testBiosDecompression() {
    Asm a;
    auto bytes = [&](u32 addr, std::initializer_list<u8> d) { u32 i = 0; for (u8 b : d) a.poke8(addr + i++, b); };
    bytes(0x02100000, {0x10, 0x08, 0x00, 0x00, 0x20, 'A', 'B', 0x30, 0x01});               // LZ77 "ABABABAB"
    bytes(0x02100100, {0x30, 0x05, 0x00, 0x00, 0x82, 'Z'});                                // RLE "ZZZZZ"
    bytes(0x02100200, {0x28, 0x04, 0x00, 0x00, 0x01, 0xC0, 'X', 'Y', 0x00, 0x00, 0x00, 0x60}); // Huffman "XYYX"
    bytes(0x02100300, {0x81, 0x05, 0x00, 0x00, 1, 1, 1, 1, 1});                            // Diff8: 1,2,3,4,5
    a.ldr(0, 0x02100000); a.ldr(1, 0x02110000); a.raw(0xEF110000u);   // SWI 0x11 LZ77 (8-bit writes)
    a.ldr(0, 0x02100000); a.ldr(1, 0x02110100); a.ldr(3, 0); a.raw(0xEF120000u);   // SWI 0x12 LZ77 (16-bit)
    a.ldr(0, 0x02100100); a.ldr(1, 0x02110200); a.raw(0xEF140000u);   // RLE
    a.ldr(0, 0x02100200); a.ldr(1, 0x02110300); a.ldr(3, 0); a.raw(0xEF130000u);   // Huffman
    a.ldr(0, 0x02100300); a.ldr(1, 0x02110400); a.raw(0xEF160000u);   // Diff8
    auto sys = bootRom(a.finish(), 1);
    auto rd = [&](u32 addr, size_t n) { std::string r; for (size_t i = 0; i < n; ++i) r += char(sys->read(true, addr + u32(i), 1)); return r; };
    CHECK(rd(0x02110000, 8) == "ABABABAB");
    CHECK(rd(0x02110100, 8) == "ABABABAB");
    CHECK(rd(0x02110200, 5) == "ZZZZZ");
    CHECK(rd(0x02110300, 4) == "XYYX");
    CHECK(rd(0x02110400, 5) == std::string("\x01\x02\x03\x04\x05"));
}

static void testKey1SecureArea() {
    std::vector<u8> table(Key1::kTableBytes);
    u32 seed = 12345;
    for (auto& b : table) { seed = seed * 1103515245u + 12345u; b = u8(seed >> 16); }   // fake key, not Nintendo's
    std::vector<u8> rom(0x8000, 0);
    std::memcpy(&rom[0x0C], "ABCD", 4);
    rom[0x20] = 0x00; rom[0x21] = 0x40;                   // ARM9 ROM offset 0x4000
    for (u32 i = 8; i < 0x800; ++i) rom[0x4000 + i] = u8(i * 7);
    std::vector<u8> plain = rom;
    encryptSecureArea(rom, table.data());
    CHECK(std::memcmp(&rom[0x4008], &plain[0x4008], 16) != 0);
    std::vector<u8> copy = rom;
    CHECK(prepareSecureArea(copy, nullptr) == SecureArea::EncryptedNoKey);
    CHECK(prepareSecureArea(rom, table.data()) == SecureArea::Decrypted);
    CHECK(std::memcmp(&rom[0x4008], &plain[0x4008], 0x7F8) == 0);
    CHECK(rom[0x4000] == 0xFF && rom[0x4001] == 0xDE && rom[0x4002] == 0xFF && rom[0x4003] == 0xE7);
    CHECK(prepareSecureArea(rom, table.data()) == SecureArea::AlreadyDecrypted);
}

static void testSaveStates() {
    Asm a;
    a.ldr(0, 0x02200000);
    size_t loop = a.here();
    a.raw(0xE5901000u);   // LDR r1,[r0]
    a.raw(0xE2811001u);   // ADD r1,r1,#1
    a.raw(0xE5801000u);   // STR r1,[r0]
    a.branchTo(loop);
    auto sys = bootRom(a.finish(), 3);
    std::vector<u8> st = sys->saveState();
    CHECK(!st.empty());
    for (int i = 0; i < 3; ++i) sys->runFrame();
    u32 counterA = sys->read(true, 0x02200000, 4);
    std::vector<u32> fbA(sys->framebuffer(0), sys->framebuffer(0) + kScreenPixels);
    CHECK(sys->loadState(st));
    for (int i = 0; i < 3; ++i) sys->runFrame();
    CHECK(sys->read(true, 0x02200000, 4) == counterA);
    CHECK(std::equal(fbA.begin(), fbA.end(), sys->framebuffer(0)));
    std::vector<u8> bad(st.begin(), st.begin() + long(st.size() / 2));
    CHECK(!sys->loadState(bad));                          // truncated: rejected, state kept
    CHECK(sys->read(true, 0x02200000, 4) == counterA);
}

// Performance features must not change results: threaded 3D raster is pixel-identical,
// frame skip only drops pictures, and the audio ring is lock-free SPSC with clear().
static void drawTestScene(NDSSystem& s) {
    s.write(true, 0x04000000, 0x00010108, 4);
    s.write(true, 0x04000060, 0x0008, 2);                 // alpha blending
    s.write(true, 0x04000350, 0x001F0000, 4);             // opaque black clear
    s.write(true, 0x04000354, 0x7FFF, 2);
    gx(s, 0x10, {0}); gx(s, 0x15, {}); gx(s, 0x10, {2}); gx(s, 0x15, {});
    gx(s, 0x60, {0xBFFF0000u});
    gx(s, 0x29, {0x001F00C0u}); gx(s, 0x40, {0});
    gx(s, 0x20, {0x001F}); vtx(s, -0x900, -0xA00, 0); vtx(s, 0xB00, -0x700, 0); vtx(s, 0x100, 0xC00, 0);
    gx(s, 0x29, {0x010F00C0u}); gx(s, 0x40, {1});         // translucent quad on top
    gx(s, 0x20, {0x03E0}); vtx(s, -0x600, -0x600, -0x100); vtx(s, 0x600, -0x600, -0x100); vtx(s, 0x600, 0x600, -0x100); vtx(s, -0x600, 0x600, -0x100);
    gx(s, 0x41, {}); gx(s, 0x50, {0});
}
static void testPerformanceFeatures() {
    std::vector<u32> ref;
    for (int threads : {0, 3}) {
        auto sys = bootRom({0xEAFFFFFEu}, 1);
        sys->setRenderThreads(threads);
        drawTestScene(*sys);
        sys->runFrame(); sys->runFrame();
        const u32* fb = sys->framebuffer(0);
        std::vector<u32> got(fb, fb + 256 * 192);
        if (ref.empty()) ref = got; else CHECK(got == ref);
    }
    {
        auto sys = bootRom({0xEAFFFFFEu}, 1);
        sys->setFrameSkip(1);
        int drawn = 0;
        for (int i = 0; i < 6; ++i) { drawTestScene(*sys); sys->runFrame(); drawn += sys->frameDrawn() ? 1 : 0; }
        CHECK(drawn == 3);
        if (!sys->frameDrawn()) { drawTestScene(*sys); sys->runFrame(); }
        CHECK(sys->frameDrawn());
        const u32* fb = sys->framebuffer(0);
        CHECK(std::vector<u32>(fb, fb + 256 * 192) == ref);   // a drawn frame matches the unskipped one
    }
    {
        AudioRing r(4);
        s16 in[12] = {1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12}, out[12] = {};
        CHECK(r.push(in, 6) == 4 && r.size() == 4);       // full: extra frames are dropped
        CHECK(r.pop(out, 2) == 2 && out[0] == 1 && out[3] == 4 && r.size() == 2);
        r.clear();
        CHECK(r.size() == 0);
        CHECK(r.push(in + 8, 2) == 2);
        CHECK(r.pop(out, 4) == 2 && out[0] == 9 && out[3] == 12);
    }
}

// Regression: timers count at the 33.513982 MHz bus clock (560,190 ticks per 263-line frame).
// They used to run 2x fast, which made the ARM7 sound sequencer play music at double tempo.
static void testTimerRate() {
    for (bool arm9 : {true, false}) {
        auto sys = bootRom({0xEAFFFFFEu}, 1);
        sys->write(arm9, 0x04000100, 0x00830000u, 4);   // reload 0, enable, prescaler /1024
        sys->runFrame(); sys->runFrame();
        u32 c = sys->read(arm9, 0x04000100, 2);
        CHECK(c >= 1090 && c <= 1096);                    // 2 frames * 560190 / 1024 = 1094
    }
}

static void testRomBanner() {
    std::vector<u8> b(0x840, 0);
    b[0] = 1;                                             // version 1
    b[0x222] = 0x1F; b[0x223] = 0x00;                     // palette 1 = red
    b[0x224] = 0xE0; b[0x225] = 0x03;                     // palette 2 = green
    b[0x20] = 0x21;                                       // tile 0 row 0: x0 = 1 (red), x1 = 2 (green)
    b[0x20 + 31 * 1] = 0;                                 // keep the rest transparent
    b[0x20 + 3 * 32 + 7 * 4 + 3] = 0x10;                  // tile 3 (x 24-31, y 0-7), row 7, x = 31 -> red
    const char* title = "Kart Racer\nPublisher";
    for (int i = 0; title[i]; ++i) b[0x340 + i * 2] = u8(title[i]);
    b[0x340 + 60] = 0xE9;                                 // U+00E9 after the text is ignored (after 0x0000)
    RomBanner bn;
    CHECK(parseRomBanner(b.data(), b.size(), bn));
    CHECK(bn.icon.size() == 1024);
    CHECK(bn.icon[0] == 0xFFFF0000u && bn.icon[1] == 0xFF00FF00u && bn.icon[2] == 0);
    CHECK(bn.icon[7 * 32 + 31] == 0xFFFF0000u);
    CHECK(bn.title == "Kart Racer\nPublisher");
    std::vector<u8> h(0x200, 0); h[0x68] = 0x00; h[0x69] = 0x84;
    CHECK(romBannerOffset(h.data(), h.size()) == 0x8400);
    b[0] = 0; CHECK(!parseRomBanner(b.data(), b.size(), bn));
}

static void testFreezeDetect() {
    auto sys = bootRom({0xEAFFFFFEu}, 1);              // a game stuck in a branch-to-self loop
    for (int i = 0; i < 20; ++i) sys->runFrame();
    CHECK(sys->stuckFrames() >= 15);
    CHECK(!sys->freezeReport().empty());
    s16 buf[4096]; size_t n; bool silent = true; int got = 0;
    while ((n = sys->readAudio(buf, 2048)) > 0) { got += int(n); }
    for (int i = 0; i < 4; ++i) sys->runFrame();
    while ((n = sys->readAudio(buf, 2048)) > 0) for (size_t k = 0; k < n * 2; ++k) silent &= buf[k] == 0;
    CHECK(silent); (void)got;
}

static void testRenderScale() {
    auto ref = bootRom({0xEAFFFFFEu}, 1);
    drawTestScene(*ref); ref->runFrame(); ref->runFrame();
    std::vector<u32> base(ref->framebuffer(0), ref->framebuffer(0) + 256 * 192);
    for (int s : {2, 4}) {
        auto sys = bootRom({0xEAFFFFFEu}, 1);
        sys->setRenderScale(s);
        CHECK(sys->renderScale() == 1);                  // latched: applied at the next frame start
        drawTestScene(*sys); sys->runFrame();
        CHECK(sys->renderScale() == s);
        sys->runFrame();
        const u32* fb = sys->framebuffer(0);
        const u32* hi = sys->framebufferHiRes(0);
        int same = 0, centre = 0;
        for (int y = 0; y < 192; ++y)
            for (int x = 0; x < 256; ++x) {
                same += fb[y * 256 + x] == base[y * 256 + x];
                centre += hi[(y * s + s / 2) * 256 * s + x * s + s / 2] == fb[y * 256 + x];
            }
        CHECK(same > 256 * 192 * 95 / 100);   // only polygon edges may move
        CHECK(centre == 256 * 192);           // 1x output is the hi-res block centre
    }
}

static void testEnhancements() {
    auto frame = [](int scale, int aa, bool wide) {
        auto sys = bootRom({0xEAFFFFFEu}, 1);
        sys->setRenderScale(scale);
        sys->setEnhancements(aa, false, wide);
        drawTestScene(*sys); sys->runFrame(); sys->runFrame();
        const u32* hi = sys->framebufferHiRes(0);
        return std::vector<u32>(hi, hi + 256 * scale * 192 * scale);
    };
    auto covered = [](const std::vector<u32>& f) { int n = 0; for (u32 c : f) n += (c & 0xFFFFFF) != 0; return n; };
    auto base = frame(2, 0, false), fxaa = frame(2, 1, false), ssaa = frame(2, 2, false), wide = frame(2, 0, true);
    int dF = 0, dS = 0;
    for (size_t i = 0; i < base.size(); ++i) { dF += fxaa[i] != base[i]; dS += ssaa[i] != base[i]; }
    CHECK(dF > 0 && dF < int(base.size() / 20));      // only edge pixels change
    CHECK(dS > 0 && dS < int(base.size() / 10));
    CHECK(ssaa.size() == base.size());                // supersampling keeps the output size
    double ratio = double(covered(wide)) / double(std::max(covered(base), 1));
    CHECK(ratio > 0.70 && ratio < 0.80);              // widescreen squeezes X by 3/4
    auto again = frame(2, 1, false);
    CHECK(again == fxaa);                             // deterministic
}

// ---- Game Boy Advance mode
static std::vector<u8> makeGBARom(const char* saveTag) {
    std::vector<u8> rom(0x400, 0);
    auto w32 = [&](u32 o, u32 v) { std::memcpy(&rom[o], &v, 4); };
    w32(0, 0xEA00002E);                       // b 0xC0
    std::memcpy(&rom[0xA0], "NDUOTEST", 8); std::memcpy(&rom[0xAC], "TEST", 4);
    rom[0xB2] = 0x96;
    const u32 code[] = {0xE3A00064, 0xE3A01007, 0xEF060000, 0xE3A02301, 0xE3A03B01, 0xE3833003, 0xE1C230B0,
                        0xE3A04406, 0xE3A0501F, 0xE1C450B0, 0xE3A0640E, 0xE3A0705A, 0xE5C67000, 0xEAFFFFFE};
    for (size_t i = 0; i < sizeof code / 4; ++i) w32(0xC0 + u32(i) * 4, code[i]);
    std::memcpy(&rom[0x200], saveTag, std::strlen(saveTag));
    return rom;
}

static void testGBAMode() {
    auto rom = makeGBARom("SRAM_V113");
    CHECK(isGBAImage(rom.data(), rom.size()));
    auto core = createCore(CoreKind::GBA);
    std::string err;
    CHECK(core->loadROM(rom.data(), rom.size(), err));
    CHECK(core->system() == 1 && core->screenWidth() == 240 && core->screenHeight() == 160 && core->screenCount() == 1);
    CHECK(core->romInfo().gameCode == "TEST");
    for (int i = 0; i < 3; ++i) core->runFrame();
    auto* g = static_cast<GBASystem*>(core.get());
    CHECK(g->cpu().reg(0) == 14); CHECK(g->cpu().reg(1) == 2);          // HLE Div
    CHECK(core->framebuffer(0)[0] == 0xFFFF0000u);                      // mode 3 red pixel
    CHECK(core->framebuffer(0)[1] == 0xFF000000u);
    CHECK(core->saveTypeDescription() == "SRAM 32 KB");
    CHECK(core->saveDataDirty() && core->saveData().size() == 0x8000 && core->saveData()[0] == 0x5A);
    auto st = core->saveState();
    CHECK(!st.empty());
    core->reset(); core->runFrame();
    CHECK(core->loadState(st));
    CHECK(g->cpu().reg(0) == 14 && core->framebuffer(0)[0] == 0xFFFF0000u);
    core->runFrame();
    size_t audio = 0; { s16 b[4096]; size_t n; while ((n = core->readAudio(b, 2048)) > 0) audio += n; }
    CHECK(audio > 700);
    // Save chip detection by library tag
    auto f = makeGBARom("FLASH1M_V103");
    auto c2 = createCore(CoreKind::GBA); CHECK(c2->loadROM(f.data(), f.size(), err));
    CHECK(c2->saveTypeDescription() == "Flash 128 KB");
    auto e = makeGBARom("EEPROM_V124");
    auto c3 = createCore(CoreKind::GBA); CHECK(c3->loadROM(e.data(), e.size(), err));
    c3->loadSaveData(std::vector<u8>(0x200, 1));
    CHECK(c3->saveTypeDescription() == "EEPROM 512 B");
    // A DS image is not mistaken for a GBA one
    std::vector<u8> nds(0x200, 0); std::memcpy(nds.data(), "MARIOKART DS", 12);
    CHECK(!isGBAImage(nds.data(), nds.size()));
}


// Optional user BIOS (LLE) with dummy BIOS images, and the HLE fallback.
static void testLLEBIOS() {
    auto put = [](std::vector<u8>& b, u32 off, u32 v) { for (int i = 0; i < 4; ++i) b[off + i] = u8(v >> (8 * i)); };
    std::vector<u8> b9(0x1000, 0), b7(0x4000, 0);
    put(b9, 0x08, 0xE3A0002A); put(b9, 0x0C, 0xE1B0F00E);                 // SWI vector: r0 = 42; MOVS PC, LR
    put(b7, 0x08, 0xE3A0002B); put(b7, 0x0C, 0xE1B0F00E);                 // r0 = 43
    const std::vector<u32> prog = {0xE3A00064, 0xE3A01007, 0xEF090000, 0xEAFFFFFE};   // r0=100 r1=7 SWI Div
    auto rom = makeRom(prog, prog);
    std::string err;
    {   // LLE: SWIs go through the dummy BIOS
        NDSSystem sys;
        CHECK(sys.setLLEBIOS(b9, b7, {}, false) && sys.usingLLEBIOS());
        CHECK(sys.loadROM(rom.data(), rom.size(), err));
        sys.runFrame();
        CHECK(sys.arm9().reg(0) == 42); CHECK(sys.arm7().reg(0) == 43);
        CHECK(!sys.arm9().faulted && !sys.arm7().faulted);
    }
    {   // Wrong sizes are rejected; the core stays on HLE
        NDSSystem sys;
        CHECK(!sys.setLLEBIOS(std::vector<u8>(100), b7, {}, false) && !sys.usingLLEBIOS());
        CHECK(sys.loadROM(rom.data(), rom.size(), err));
        sys.runFrame();
        CHECK(sys.arm9().reg(0) == 14 && sys.arm7().reg(0) == 14);     // HLE Div
    }
    {   // Removing the BIOS goes back to HLE
        NDSSystem sys;
        CHECK(sys.setLLEBIOS(b9, b7, {}, false));
        CHECK(sys.setLLEBIOS({}, {}, {}, false) && !sys.usingLLEBIOS());
        CHECK(sys.loadROM(rom.data(), rom.size(), err));
        sys.runFrame();
        CHECK(sys.arm9().reg(0) == 14);
    }
    {   // Firmware boot starts both CPUs at their reset vectors
        std::vector<u8> fw(0x40000, 0xFF);
        put(b9, 0x00, 0xEAFFFFFE); put(b7, 0x00, 0xEAFFFFFE);             // reset vectors: idle loops
        NDSSystem sys;
        CHECK(sys.setLLEBIOS(b9, b7, fw, true));
        CHECK(sys.loadROM(rom.data(), rom.size(), err));
        sys.runFrame();
        CHECK(sys.arm9().pc() == 0xFFFF0000u && sys.arm7().pc() == 0);
    }
    {   // GBA: dummy gba_bios.bin (reset jumps to the cartridge, SWI returns 42)
        std::vector<u8> gb(0x4000, 0);
        put(gb, 0x00, 0xE3A0F408);                                         // MOV PC, #0x08000000
        put(gb, 0x08, 0xE3A0002A); put(gb, 0x0C, 0xE1B0F00E);
        put(gb, 0x18, 0xE25EF004);                                         // IRQ: SUBS PC, LR, #4
        auto g = makeGBARom("SRAM_V113");
        GBASystem sys;
        CHECK(sys.setLLEBIOS(gb, {}, {}, false) && sys.usingLLEBIOS());
        CHECK(sys.loadROM(g.data(), g.size(), err));
        for (int i = 0; i < 3; ++i) sys.runFrame();
        CHECK(sys.cpu().reg(0) == 42 && !sys.cpu().faulted);
        GBASystem hle;
        CHECK(!hle.setLLEBIOS(std::vector<u8>(0x1000), {}, {}, false) && !hle.usingLLEBIOS());
        CHECK(hle.loadROM(g.data(), g.size(), err));
        for (int i = 0; i < 3; ++i) hle.runFrame();
        CHECK(hle.cpu().reg(0) == 14);
    }
}

// Display capture: engine A composition (backdrop only) captured into LCDC bank B, then a
// 50/50 blend of source A with VRAM source B (bank A holds a known colour).
static void testDisplayCapture() {
    VRAM vram; vram.reset();
    vram.setControl(0, 0x80); vram.setControl(1, 0x80);              // A, B -> LCDC
    std::vector<u8> io(0x70, 0), pal(0x400, 0), oam(0x400, 0);
    GPU2D g(true, io.data(), pal.data(), oam.data(), vram);
    io[2] = 0x01;                                                      // DISPCNT display mode 1 (graphics)
    pal[0] = 0x1F; pal[1] = 0x00;                                      // backdrop = red
    u32 cap = 0x80000000u | (1u << 16) | (3u << 20);                  // enable, write bank B, 256x192, source A
    g.setCaptureActive(true);
    u32 line[256];
    g.renderLine(5, line); g.captureLine(5, cap);
    const u8* b = vram.bankData(1);
    u32 o = (5 * 256 + 10) * 2;
    CHECK(b[o] == 0x1F && b[o + 1] == 0x80);
    // Blend: A red (opaque) * 8/16 + B (bank A, blue opaque) * 8/16
    u8* a = vram.bankDataMut(0);
    for (int i = 0; i < 256 * 192; ++i) { a[i * 2] = 0x00; a[i * 2 + 1] = 0x7C | 0x80; }   // 0xFC00 = blue | bit15
    cap = 0x80000000u | (1u << 16) | (3u << 20) | (2u << 29) | 8u | (8u << 8);
    g.renderLine(6, line); g.captureLine(6, cap);
    o = (6 * 256 + 3) * 2;
    u16 v = u16(b[o] | (b[o + 1] << 8));
    CHECK((v & 0x8000) && (v & 31) == 16 && ((v >> 10) & 31) == 16);
    // A bank mapped elsewhere (bank D as ARM7 WRAM, as Mario Kart DS does) must not be written.
    vram.setControl(3, 0x82);
    u8* d = vram.bankDataMut(3);
    for (int i = 0; i < 0x100; ++i) d[i] = 0xAB;
    cap = 0x80000000u | (3u << 16) | (3u << 20);
    g.renderLine(0, line); g.captureLine(0, cap);
    CHECK(d[0] == 0xAB && d[0x1FF / 2] == 0xAB && g.captureBlocked == 1);
}


// Cheats: parsers for every format, and the per-frame engine against a fake memory.
struct CheatMem final : EmulatorCore {
    std::map<u32, u8> m;
    bool loadROM(const u8*, size_t, std::string&) override { return true; }
    void reset() override {}
    void runFrame() override {}
    const u32* framebuffer(int) const override { return nullptr; }
    void setButtons(u32) override {}
    void setTouch(bool, int, int) override {}
    size_t readAudio(s16*, size_t) override { return 0; }
    RomInfo info;
    const RomInfo& romInfo() const override { return info; }
    u32 cheatRead(u32 a, int n) override { u32 v = 0; for (int i = 0; i < n; ++i) v |= u32(m[a + i]) << (8 * i); return v; }
    void cheatWrite(u32 a, u32 v, int n) override { for (int i = 0; i < n; ++i) m[a + i] = u8(v >> (8 * i)); }
};
static void testCheats() {
    std::string err; Cheat c;
    // Action Replay DS: 32/16/8-bit writes, a conditional block, offset register.
    CHECK(parseCheat("ds", "02000000 12345678\n12000010 0000BEEF\n22000020 000000AB", c, err));
    CheatMem mem; CheatEngine e; e.set({c}); e.apply(mem);
    CHECK(mem.cheatRead(0x02000000, 4) == 0x12345678 && mem.cheatRead(0x02000010, 2) == 0xBEEF && mem.cheatRead(0x02000020, 1) == 0xAB);
    CHECK(parseCheat("ds", "52000100 00000007\n02000104 00000063\nD2000000 00000000", c, err));
    CheatMem m2; CheatEngine e2; e2.set({c}); e2.apply(m2);
    CHECK(m2.cheatRead(0x02000104, 4) == 0);                     // condition false: no write
    m2.cheatWrite(0x02000100, 7, 4); e2.apply(m2);
    CHECK(m2.cheatRead(0x02000104, 4) == 0x63);                  // condition true
    CHECK(parseCheat("ds", "D3000000 02000200\nD5000000 00000005\nD6000000 00000010\nD2000000 00000000", c, err));
    CheatMem m3; CheatEngine e3; e3.set({c}); e3.apply(m3);
    CHECK(m3.cheatRead(0x02000210, 4) == 5);
    CHECK(!parseCheat("ds", "0200000 1", c, err));
    // GBA GameShark raw and CodeBreaker raw.
    CHECK(parseCheat("gba", "02000010 000000FF\n12000012 00001234", c, err) && c.format == CheatFormat::GBAGameSharkRaw);
    CheatMem m4; CheatEngine e4; e4.set({c}); e4.apply(m4);
    CHECK(m4.cheatRead(0x02000010, 1) == 0xFF && m4.cheatRead(0x02000012, 2) == 0x1234);
    CHECK(parseCheat("gba", "83001000 03E7\n33001002 0063", c, err) && c.format == CheatFormat::GBACodeBreaker);
    CheatMem m5; CheatEngine e5; e5.set({c}); e5.apply(m5);
    CHECK(m5.cheatRead(0x03001000, 2) == 999 && m5.cheatRead(0x03001002, 1) == 0x63);
    CHECK(!parseCheat("gba", "9A1B2C3D 1234", c, err));          // encrypted CodeBreaker rejected
    // GB GameShark (little-endian address) and Game Genie (ROM patch with compare).
    CHECK(parseCheat("gb", "010238CD", c, err) && c.format == CheatFormat::GBGameShark);
    CheatMem m6; CheatEngine e6; e6.set({c}); e6.apply(m6);
    CHECK(m6.cheatRead(0xCD38, 1) == 0x02);
    CHECK(parseCheat("gb", "00A-17B-C49", c, err) && c.patches.size() == 1);
    CHECK(c.patches[0].addr == 0x4A17 && c.patches[0].value == 0x00 && c.patches[0].compare >= 0);
    CHECK(parseCheat("gb", "3EA-08F", c, err) && c.patches[0].addr == 0x0A08 && c.patches[0].value == 0x3E && c.patches[0].compare < 0);
    CHECK(!parseCheat("gb", "12-34", c, err));
}

// RetroAchievements memory hook: rcheevos' DS layout (main RAM at 0, DTCM at 0x1000000).
static void testAchievementRead() {
    auto sys = std::make_unique<NDSSystem>(); std::string err;
    Asm a9; Asm a7;
    auto rom = makeRom(a9.finish(), a7.finish());
    CHECK(sys->loadROM(rom.data(), rom.size(), err));
    sys->cheatWrite(0x02000010, 0xCAFEBABE, 4);
    u8 b[4] = {};
    CHECK(sys->achievementRead(0x10, b, 4) == 4);
    CHECK(b[0] == 0xBE && b[1] == 0xBA && b[2] == 0xFE && b[3] == 0xCA);
    CHECK(sys->achievementRead(0x3FFFFE, b, 4) == 4);           // runs into the DSi padding
    CHECK(sys->achievementRead(0x1004000, b, 1) == 0);          // past the end
}

int main() {
    testAchievementRead();
    testDisplayCapture();
    testArmBasics();
    testBranchAndThumb();
    testThumbBL();
    testHeaderAndBoot();
    testFifoRecvIrqIsLevel(); testIrqTakenInShortEnableWindow(); testTextBackgroundRom();
    testSpriteEngineBRom();
    testCompositingDirect();
    testVRAMMapping();
    testTouchScreenSPI();
    testVBlankPolling();
    testVBlankIRQ();
    testUserBankAndMisc();
    testSaveDetection();
    testSaveProbeDetection();
    testSoundChannels();
    testSoundCaptureAndInterp();
    testIdleSkipAndFastMemory();
    test3DGeometryAndRaster();
    testCheats();
    test3DTexturesAlphaFog();
    test3DCullingWinding();
    testRenderScale();
    testFreezeDetect();
    testEnhancements();
    testInfraredSave();
    testPerformanceFeatures();
    testTimerRate();
    testRomBanner();
    testRTC();
    testBiosDecompression();
    testKey1SecureArea();
    testSaveStates();
    testGBAMode();
    testLLEBIOS();
    if (failures) { std::printf("%d check(s) failed\n", failures); return 1; }
    std::printf("All core tests passed\n");
    return 0;
}
