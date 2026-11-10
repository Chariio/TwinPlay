// Copyright (c) 2026 Charlie Rodriguez Garcia. All rights reserved.
// Original clean-room implementation of the cartridge KEY1 (Blowfish-style)
// algorithm as described in GBATEK. The 0x1048-byte key table is NOT included:
// it lives in the console's ARM7 BIOS, which the user may optionally import.
#pragma once
#include "dscore/Types.hpp"
#include <vector>

namespace dscore {

class Key1 {
public:
    static constexpr size_t kTableBytes = 0x1048;     // ARM7 BIOS offset 0x30
    // table: kTableBytes of key data. level: 1..3, modulo: 8 or 12.
    void init(const u8* table, u32 idcode, int level, u32 modulo);
    void encrypt(u32* p) const;                        // p[0], p[1]
    void decrypt(u32* p) const;

private:
    void apply(u32 modulo);
    u32 kb_[0x412] = {};
    u32 kc_[3] = {};
};

enum class SecureArea { None, AlreadyDecrypted, Decrypted, EncryptedNoKey, BadKey };

// Inspects the ROM's secure area (0x4000-0x47FF) and decrypts it in place when it
// is encrypted and a key table is available. "encryObj" is replaced by the
// undefined-instruction marker, as the boot ROM does.
SecureArea prepareSecureArea(std::vector<u8>& rom, const u8* keyTable);
// Inverse operation (used by tests to build encrypted images).
void encryptSecureArea(std::vector<u8>& rom, const u8* keyTable);

} // namespace dscore
