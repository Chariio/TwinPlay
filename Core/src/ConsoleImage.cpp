// Copyright (c) 2026 Charlie Rodriguez Garcia. All rights reserved.
// Cartridge-image sniffing for N64 and 3DS. No ROMs, BIOS or keys live here.
#include "dscore/EmulatorCore.hpp"
#include <fstream>
#include <cstring>

namespace dscore {

bool EmulatorCore::loadROMPath(const std::string& path, std::string& error) {
    std::ifstream in(path, std::ios::binary);
    if (!in) { error = "Could not open the game file."; return false; }
    std::vector<u8> data((std::istreambuf_iterator<char>(in)), std::istreambuf_iterator<char>());
    return loadROM(data.data(), data.size(), error);
}

bool isN64Image(const u8* d, size_t n) {
    if (!d || n < 4) return false;
    const u32 m = (u32(d[0]) << 24) | (u32(d[1]) << 16) | (u32(d[2]) << 8) | u32(d[3]);
    return m == 0x80371240u || m == 0x37804012u || m == 0x40123780u;
}

bool is3DSImage(const u8* d, size_t n) {
    if (!d || n < 0x104) return false;
    return std::memcmp(d + 0x100, "NCSD", 4) == 0 || std::memcmp(d + 0x100, "NCCH", 4) == 0;
}

void normalizeN64(std::vector<u8>& rom) {
    if (rom.size() < 4) return;
    const u32 m = (u32(rom[0]) << 24) | (u32(rom[1]) << 16) | (u32(rom[2]) << 8) | u32(rom[3]);
    if (m == 0x80371240u) return;
    if (m == 0x37804012u) {
        for (size_t i = 0; i + 1 < rom.size(); i += 2) std::swap(rom[i], rom[i + 1]);
    } else if (m == 0x40123780u) {
        for (size_t i = 0; i + 3 < rom.size(); i += 4) {
            std::swap(rom[i], rom[i + 3]);
            std::swap(rom[i + 1], rom[i + 2]);
        }
    }
}

std::string n64InternalName(const u8* d, size_t n) {
    if (!d || n < 0x34) return {};
    std::string s;
    for (int i = 0; i < 20; ++i) {
        const char c = char(d[0x20 + i]);
        if (c == 0) break;
        s.push_back((c >= 32 && c < 127) ? c : ' ');
    }
    while (!s.empty() && s.back() == ' ') s.pop_back();
    return s;
}

void scaleNearest(const u32* src, int sw, int sh, u32* dst, int dw, int dh) {
    if (!src || !dst || sw <= 0 || sh <= 0 || dw <= 0 || dh <= 0) return;
    for (int y = 0; y < dh; ++y) {
        const int sy = y * sh / dh;
        for (int x = 0; x < dw; ++x) dst[y * dw + x] = src[sy * sw + (x * sw / dw)];
    }
}

void letterboxNearest(const u32* src, int sw, int sh, u32* dst, int dw, int dh) {
    if (!dst || dw <= 0 || dh <= 0) return;
    std::fill(dst, dst + size_t(dw) * size_t(dh), 0xFF000000u);
    if (!src || sw <= 0 || sh <= 0) return;
    const int scaleW = dw * sh;
    const int scaleH = dh * sw;
    int ow, oh;
    if (scaleW <= scaleH) { ow = dw; oh = std::max(1, dw * sh / sw); }
    else { oh = dh; ow = std::max(1, dh * sw / sh); }
    if (ow > dw) ow = dw;
    if (oh > dh) oh = dh;
    const int x0 = (dw - ow) / 2, y0 = (dh - oh) / 2;
    for (int y = 0; y < oh; ++y) {
        const int sy = y * sh / oh;
        u32* row = dst + (y0 + y) * dw + x0;
        for (int x = 0; x < ow; ++x) row[x] = src[sy * sw + (x * sw / ow)];
    }
}

} // namespace dscore
