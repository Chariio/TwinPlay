// Cartridge-image checks for N64 and 3DS. No commercial games, no firmware.
#include "dscore/EmulatorCore.hpp"
#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

using namespace dscore;
static int failures = 0;
#define CHECK(cond) do { if (!(cond)) { std::printf("FAIL %s:%d %s\n", __FILE__, __LINE__, #cond); ++failures; } } while (0)

static std::vector<u8> magic(u8 a, u8 b, u8 c, u8 d) {
    std::vector<u8> r(0x40, 0);
    r[0] = a; r[1] = b; r[2] = c; r[3] = d;
    return r;
}

int main() {
    CHECK(isN64Image(magic(0x80, 0x37, 0x12, 0x40).data(), 0x40));
    CHECK(isN64Image(magic(0x37, 0x80, 0x40, 0x12).data(), 0x40));
    CHECK(isN64Image(magic(0x40, 0x12, 0x37, 0x80).data(), 0x40));
    CHECK(!isN64Image(magic(0x4E, 0x45, 0x53, 0x1A).data(), 0x40));
    CHECK(!isN64Image(nullptr, 0));

    auto v64 = magic(0x80, 0x37, 0x12, 0x40);
    std::memcpy(v64.data() + 0x20, "V64 NAME             ", 20);
    for (size_t i = 0; i + 1 < v64.size(); i += 2) std::swap(v64[i], v64[i + 1]);
    CHECK(isN64Image(v64.data(), v64.size()));
    normalizeN64(v64);
    CHECK(v64[0] == 0x80 && v64[1] == 0x37 && v64[2] == 0x12 && v64[3] == 0x40);
    CHECK(n64InternalName(v64.data(), v64.size()) == "V64 NAME");

    auto n64 = magic(0x40, 0x12, 0x37, 0x80);
    normalizeN64(n64);
    CHECK(n64[0] == 0x80 && n64[1] == 0x37 && n64[2] == 0x12 && n64[3] == 0x40);

    auto z64 = magic(0x80, 0x37, 0x12, 0x40);
    std::memcpy(z64.data() + 0x20, "ZELDA MAJORA'S MASK  ", 20);
    CHECK(n64InternalName(z64.data(), z64.size()) == "ZELDA MAJORA'S MASK");

    std::vector<u8> ncsd(0x120, 0);
    std::memcpy(ncsd.data() + 0x100, "NCSD", 4);
    CHECK(is3DSImage(ncsd.data(), ncsd.size()));
    std::vector<u8> ncch(0x120, 0);
    std::memcpy(ncch.data() + 0x100, "NCCH", 4);
    CHECK(is3DSImage(ncch.data(), ncch.size()));
    CHECK(!is3DSImage(z64.data(), z64.size()));
    CHECK(!is3DSImage(ncsd.data(), 0x100));

    const u32 src[4] = {0xFF0000FFu, 0xFF00FF00u, 0xFFFF0000u, 0xFFFFFFFFu};
    u32 dst[16] = {};
    scaleNearest(src, 2, 2, dst, 4, 4);
    CHECK(dst[0] == 0xFF0000FFu);
    CHECK(dst[3] == 0xFF00FF00u);
    CHECK(dst[12] == 0xFFFF0000u);
    CHECK(dst[15] == 0xFFFFFFFFu);

    u32 box[8 * 4] = {};
    letterboxNearest(src, 2, 2, box, 8, 4);
    int ink = 0;
    for (u32 p : box) if (p != 0xFF000000u) ++ink;
    CHECK(ink > 0 && ink < 32);

    auto core = createCore(CoreKind::N64);
    CHECK(core->system() == 6);
    CHECK(core->screenCount() == 1);
    std::string err;
    CHECK(!core->loadROM(z64.data(), z64.size(), err));
    CHECK(err.find("not linked") != std::string::npos);

    auto ds = createCore(CoreKind::N3DS);
    CHECK(ds->system() == 7);
    CHECK(ds->screenCount() == 2);
    CHECK(ds->prefersPathLoad());
    CHECK(!ds->loadROMPath("/no/such/game.3ds", err));

    if (failures) { std::printf("%d failed\n", failures); return 1; }
    std::printf("n64/3ds image tests passed\n");
    return 0;
}
