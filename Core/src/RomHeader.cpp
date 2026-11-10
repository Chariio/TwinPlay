// Copyright (c) 2026 Charlie Rodriguez Garcia. All rights reserved.
// Cartridge header layout per public GBATEK documentation.
#include "dscore/EmulatorCore.hpp"

namespace dscore {

static u32 rd32(const u8* p) { return u32(p[0]) | (u32(p[1]) << 8) | (u32(p[2]) << 16) | (u32(p[3]) << 24); }

u16 crc16(const u8* data, size_t size, u16 init) {
    u32 crc = init;
    for (size_t i = 0; i < size; ++i) {
        crc ^= data[i];
        for (int b = 0; b < 8; ++b) crc = (crc & 1) ? (crc >> 1) ^ 0xA001 : (crc >> 1);
    }
    return u16(crc);
}

static std::string asciiField(const u8* p, size_t n) {
    std::string s;
    for (size_t i = 0; i < n && p[i]; ++i) s.push_back((p[i] >= 0x20 && p[i] < 0x7F) ? char(p[i]) : '?');
    return s;
}

bool parseRomHeader(const u8* d, size_t size, RomInfo& o, std::string& error) {
    if (size < 0x200) { error = "The file is too small to be a DS ROM."; return false; }
    o = RomInfo{};
    o.title = asciiField(d, 12);
    o.gameCode = asciiField(d + 0x0C, 4);
    o.makerCode = asciiField(d + 0x10, 2);
    o.arm9RomOffset = rd32(d + 0x20); o.arm9Entry = rd32(d + 0x24);
    o.arm9RamAddress = rd32(d + 0x28); o.arm9Size = rd32(d + 0x2C);
    o.arm7RomOffset = rd32(d + 0x30); o.arm7Entry = rd32(d + 0x34);
    o.arm7RamAddress = rd32(d + 0x38); o.arm7Size = rd32(d + 0x3C);
    o.headerCrc = u16(d[0x15E] | (d[0x15F] << 8));
    o.headerCrcValid = crc16(d, 0x15E) == o.headerCrc;

    auto inRom = [&](u32 off, u32 len) { return u64(off) + len <= size; };
    if (!inRom(o.arm9RomOffset, o.arm9Size) || !inRom(o.arm7RomOffset, o.arm7Size)) {
        error = "Invalid header: the ARM9/ARM7 binaries extend past the end of the file."; return false;
    }
    if (o.arm9Size > 0x3BFE00 || o.arm7Size > 0x3BFE00) { error = "Invalid header: binary too large."; return false; }
    return true;
}


// Banner layout (GBATEK "DS Cartridge Icon/Title"): 0x20 4bpp 32x32 bitmap in 4x4 tiles of 8x8,
// 0x220 16-colour BGR555 palette, 0x240 + 0x100*n titles (UTF-16LE, n=1 English).
u32 romBannerOffset(const u8* h, size_t size) {
    if (size < 0x6C) return 0;
    return u32(h[0x68] | (h[0x69] << 8) | (h[0x6A] << 16) | (u32(h[0x6B]) << 24));
}

bool parseRomBanner(const u8* b, size_t size, RomBanner& out) {
    out = RomBanner{};
    if (size < 0x440) return false;
    u16 version = u16(b[0] | (b[1] << 8));
    if (version == 0 || version == 0xFFFF) return false;
    u32 pal[16];
    for (int i = 0; i < 16; ++i) {
        u16 c = u16(b[0x220 + i * 2] | (b[0x221 + i * 2] << 8));
        u32 r = (c & 31) * 255 / 31, g = ((c >> 5) & 31) * 255 / 31, bl = ((c >> 10) & 31) * 255 / 31;
        pal[i] = i == 0 ? 0u : (0xFF000000u | (r << 16) | (g << 8) | bl);
    }
    out.icon.assign(32 * 32, 0);
    for (int y = 0; y < 32; ++y)
        for (int x = 0; x < 32; ++x) {
            int tile = (y / 8) * 4 + (x / 8);
            u8 v = b[0x20 + tile * 32 + (y % 8) * 4 + (x % 8) / 2];
            out.icon[size_t(y * 32 + x)] = pal[(x & 1) ? (v >> 4) : (v & 15)];
        }
    // English title -> UTF-8 (BMP code points; surrogate pairs combined).
    std::string t;
    for (int i = 0; i < 128; ++i) {
        u32 c = u32(b[0x340 + i * 2] | (b[0x341 + i * 2] << 8));
        if (c == 0) break;
        if (c >= 0xD800 && c < 0xDC00 && i + 1 < 128) {
            u32 lo = u32(b[0x342 + i * 2] | (b[0x343 + i * 2] << 8));
            if (lo >= 0xDC00 && lo < 0xE000) { c = 0x10000 + ((c - 0xD800) << 10) + (lo - 0xDC00); ++i; }
        }
        if (c == '\r') continue;
        if (c < 0x80) t += char(c);
        else if (c < 0x800) { t += char(0xC0 | (c >> 6)); t += char(0x80 | (c & 0x3F)); }
        else if (c < 0x10000) { t += char(0xE0 | (c >> 12)); t += char(0x80 | ((c >> 6) & 0x3F)); t += char(0x80 | (c & 0x3F)); }
        else { t += char(0xF0 | (c >> 18)); t += char(0x80 | ((c >> 12) & 0x3F)); t += char(0x80 | ((c >> 6) & 0x3F)); t += char(0x80 | (c & 0x3F)); }
    }
    out.title = t;
    return true;
}

} // namespace dscore
