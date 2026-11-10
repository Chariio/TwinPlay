// Copyright (c) 2026 Charlie Rodriguez Garcia. All rights reserved.
// Original clean-room KEY1 implementation from the GBATEK description.
#include "CartCrypto.hpp"
#include <cstring>

namespace dscore {

namespace {
inline u32 bswap(u32 v) { return (v >> 24) | ((v >> 8) & 0xFF00) | ((v << 8) & 0xFF0000) | (v << 24); }
inline u32 rd32(const u8* p) { return u32(p[0]) | (u32(p[1]) << 8) | (u32(p[2]) << 16) | (u32(p[3]) << 24); }
inline void wr32(u8* p, u32 v) { p[0] = u8(v); p[1] = u8(v >> 8); p[2] = u8(v >> 16); p[3] = u8(v >> 24); }
constexpr u32 kMarker = 0xE7FFDEFFu;
} // namespace

void Key1::encrypt(u32* p) const {
    u32 y = p[0], x = p[1];
    for (int i = 0; i <= 0x0F; ++i) {
        u32 z = kb_[i] ^ x;
        x = kb_[0x012 + ((z >> 24) & 0xFF)];
        x += kb_[0x112 + ((z >> 16) & 0xFF)];
        x ^= kb_[0x212 + ((z >> 8) & 0xFF)];
        x += kb_[0x312 + (z & 0xFF)];
        x ^= y; y = z;
    }
    p[0] = x ^ kb_[0x10]; p[1] = y ^ kb_[0x11];
}

void Key1::decrypt(u32* p) const {
    u32 y = p[0], x = p[1];
    for (int i = 0x11; i >= 0x02; --i) {
        u32 z = kb_[i] ^ x;
        x = kb_[0x012 + ((z >> 24) & 0xFF)];
        x += kb_[0x112 + ((z >> 16) & 0xFF)];
        x ^= kb_[0x212 + ((z >> 8) & 0xFF)];
        x += kb_[0x312 + (z & 0xFF)];
        x ^= y; y = z;
    }
    p[0] = x ^ kb_[0x01]; p[1] = y ^ kb_[0x00];
}

void Key1::apply(u32 modulo) {
    encrypt(&kc_[1]);
    encrypt(&kc_[0]);
    u32 scratch[2] = {0, 0};
    u32 n = modulo / 4;
    for (u32 i = 0; i <= 0x11; ++i) kb_[i] ^= bswap(kc_[i % n]);
    for (u32 i = 0; i <= 0x410; i += 2) { encrypt(scratch); kb_[i] = scratch[1]; kb_[i + 1] = scratch[0]; }
}

void Key1::init(const u8* table, u32 idcode, int level, u32 modulo) {
    for (size_t i = 0; i < 0x412; ++i) kb_[i] = rd32(table + i * 4);
    kc_[0] = idcode; kc_[1] = idcode / 2; kc_[2] = idcode * 2;
    if (level >= 1) apply(modulo);
    if (level >= 2) apply(modulo);
    kc_[1] *= 2; kc_[2] /= 2;
    if (level >= 3) apply(modulo);
}

static u32 gameCodeWord(const std::vector<u8>& rom) { return rd32(&rom[0x0C]); }

SecureArea prepareSecureArea(std::vector<u8>& rom, const u8* keyTable) {
    if (rom.size() < 0x8000) return SecureArea::None;
    u32 arm9Off = rd32(&rom[0x20]);
    if (arm9Off < 0x4000 || arm9Off >= 0x8000) return SecureArea::None;   // homebrew: no secure area
    u8* sa = &rom[0x4000];
    if (rd32(sa) == kMarker && rd32(sa + 4) == kMarker) return SecureArea::AlreadyDecrypted;
    if (std::memcmp(sa, "encryObj", 8) == 0) { wr32(sa, kMarker); wr32(sa + 4, kMarker); return SecureArea::AlreadyDecrypted; }
    bool allZero = true;
    for (int i = 0; i < 0x800 && allZero; ++i) allZero = sa[i] == 0;
    if (allZero) return SecureArea::None;
    if (!keyTable) return SecureArea::EncryptedNoKey;

    std::vector<u8> copy(sa, sa + 0x800);
    Key1 k; u32 w[2];
    k.init(keyTable, gameCodeWord(rom), 2, 8);
    w[0] = rd32(&copy[0]); w[1] = rd32(&copy[4]); k.decrypt(w); wr32(&copy[0], w[0]); wr32(&copy[4], w[1]);
    k.init(keyTable, gameCodeWord(rom), 3, 8);
    for (size_t i = 0; i < 0x800; i += 8) {
        w[0] = rd32(&copy[i]); w[1] = rd32(&copy[i + 4]); k.decrypt(w); wr32(&copy[i], w[0]); wr32(&copy[i + 4], w[1]);
    }
    if (std::memcmp(copy.data(), "encryObj", 8) != 0) return SecureArea::BadKey;
    std::memcpy(sa, copy.data(), 0x800);
    wr32(sa, kMarker); wr32(sa + 4, kMarker);
    return SecureArea::Decrypted;
}

void encryptSecureArea(std::vector<u8>& rom, const u8* keyTable) {
    u8* sa = &rom[0x4000];
    std::memcpy(sa, "encryObj", 8);
    Key1 k; u32 w[2];
    k.init(keyTable, gameCodeWord(rom), 3, 8);
    for (size_t i = 0; i < 0x800; i += 8) {
        w[0] = rd32(sa + i); w[1] = rd32(sa + i + 4); k.encrypt(w); wr32(sa + i, w[0]); wr32(sa + i + 4, w[1]);
    }
    k.init(keyTable, gameCodeWord(rom), 2, 8);
    w[0] = rd32(sa); w[1] = rd32(sa + 4); k.encrypt(w); wr32(sa, w[0]); wr32(sa + 4, w[1]);
}

} // namespace dscore
