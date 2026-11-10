// Copyright (c) 2026 Charlie Rodriguez Garcia. All rights reserved.
#include "SaveMemory.hpp"
#include <algorithm>

namespace dscore {

namespace {
const std::vector<u8> kEmpty;
constexpr u32 kFlashMax = 8u << 20;
}

void SaveMemory::Chip::ensure(u32 a) {
    if (!fixedCap) {                               // auto-sized flash: grow to cover the address
        a %= kFlashMax;
        while (a >= cap && cap < kFlashMax) cap *= 2;
    }
    if (data.size() < cap) data.resize(cap, 0xFF);
}

u8 SaveMemory::Chip::transfer(u8 v, bool& dirty) {
    if (stage == 0) {
        cmd = v; stage = 1; addr = 0; start = 0; count = 0; bad = false;
        switch (v) {
        case 0x06: wel = true; return 0xFF;        // WREN
        case 0x04: wel = false; return 0xFF;       // WRDI
        case 0x05: return 0xFF;                    // RDSR
        case 0x01: return 0xFF;                    // WRSR (block-protect bits; accepted, ignored)
        case 0x03: case 0x02: return 0xFF;
        default: break;
        }
        if (kind == kE512 && (v == 0x0B || v == 0x0A)) return 0xFF;   // A8 = 1 variants
        if (kind == kFlash && (v == 0x0B || v == 0x0A || v == 0x9F || v == 0xDB || v == 0xD8 || v == 0xC7 || v == 0xAB || v == 0xB9)) {
            if (v == 0xC7 && wel) { std::fill(data.begin(), data.end(), 0xFF); dirty = true; }
            return 0xFF;
        }
        if (v == 0x00 || v == 0xFF) return 0xFF;   // idle clocks
        bad = true;                                // opcode this chip does not have
        if (!pinned) alive = false;                // ruled out at once, so the reply comes from a chip that has it
        return 0xFF;
    }
    if (cmd == 0x05) return wel ? 0x02 : 0x00;     // status: WIP always 0 (writes are instant)
    if (cmd == 0x9F) { static const u8 id[3] = {0x20, 0x40, 0x12}; u8 r = id[(stage - 1) % 3]; ++stage; return r; }
    u8 c = cmd;
    if (kind == kE512) {
        if ((c & 0xF7) == 0x03 || (c & 0xF7) == 0x02) {
            if (stage == 1) addr = (c & 0x08) ? 0x100 : 0;
            c &= 0xF7;
        }
    }
    bool hasAddress = c == 0x03 || c == 0x02 || (kind == kFlash && (c == 0x0B || c == 0x0A || c == 0xDB || c == 0xD8));
    if (!hasAddress) return 0xFF;
    int ab = addrBytes();
    if (stage <= ab) {
        addr = kind == kE512 ? (addr | v) : ((addr << 8) | v);
        ++stage;
        if (stage > ab) {
            start = addr;
            if (wel && kind == kFlash) {
                if (c == 0xDB) { u32 b = addr & ~0xFFu; for (u32 i = 0; i < 0x100; ++i) poke(b + i, 0xFF); dirty = true; }
                if (c == 0xD8) { u32 b = addr & ~0xFFFFu; for (u32 i = 0; i < 0x10000; ++i) poke(b + i, 0xFF); dirty = true; }
            }
        }
        return 0xFF;
    }
    if (c == 0x0B && kind == kFlash && stage == ab + 1) { ++stage; return 0xFF; }   // dummy byte
    switch (c) {
    case 0x03: case 0x0B: { u8 r = peek(addr); addr = (addr + 1) % std::max(cap, 1u); return r; }
    case 0x02: case 0x0A:
        ++count;
        if (wel) { poke(addr, v); dirty = true; }
        if (u32 pg = page()) addr = (addr & ~(pg - 1)) | ((addr + 1) & (pg - 1));   // wraps inside the page
        else ++addr;
        return 0xFF;
    default: return 0xFF;
    }
}

void SaveMemory::Chip::release() {
    if (stage > 0) {
        u8 c = kind == kE512 ? u8(cmd & 0xF7) : cmd;
        bool write = c == 0x02 || (kind == kFlash && c == 0x0A);
        if (write && count > 0) {
            maxCount = std::max(maxCount, count);
            if (u32 pg = page(); pg && (start % pg) + u32(count) > pg) bad = true;   // crosses a page
            if (fixedCap && start + u32(count) > cap) bad = true;                     // past the end
        }
        if (write || (kind == kFlash && (c == 0xDB || c == 0xD8 || c == 0xC7))) wel = false;
        if (bad && !pinned) alive = false;
    }
    stage = 0;
}

void SaveMemory::reset(Override o) {
    override_ = o;
    static const u32 caps[kKinds] = {512, 0x2000, 0x10000, 0x8000, 0x20000, 0x40000};
    for (int k = 0; k < kKinds; ++k) {
        Chip& ch = chips_[size_t(k)];
        ch = Chip();
        ch.kind = Kind(k); ch.cap = caps[k]; ch.fixedCap = k != kFlash;
        ch.alive = o == Override::Auto;
    }
    auto force = [&](Kind k, u32 cap) { Chip& ch = chips_[size_t(k)]; ch.alive = true; ch.pinned = true; ch.cap = cap; ch.fixedCap = true; chosen_ = k; };
    switch (o) {
    case Override::Auto: chosen_ = kE512; break;
    case Override::EEPROM512: force(kE512, 512); break;
    case Override::EEPROM8K: force(kE8K, 0x2000); break;
    case Override::EEPROM64K: force(kE64K, 0x10000); break;
    case Override::EEPROM128K: force(kE128K, 0x20000); break;
    case Override::FRAM32K: force(kFRAM, 0x8000); break;
    case Override::Flash256K: force(kFlash, 0x40000); break;
    case Override::Flash512K: force(kFlash, 0x80000); break;
    case Override::Flash1M: force(kFlash, 0x100000); break;
    case Override::Flash8M: force(kFlash, kFlashMax); break;
    }
    decided_ = o != Override::Auto;
    maxWrite_ = 0; loadedKind_ = -1; loadedRejected_ = false;
}

void SaveMemory::clear() { reset(Override::Auto); dirty_ = false; }

void SaveMemory::load(const std::vector<u8>& d) {
    Override o = override_;
    reset(o);
    dirty_ = false;
    if (d.empty()) return;
    u32 n = u32(d.size());
    int k;
    if (o != Override::Auto) k = chosen_;
    else if (n <= 512) k = kE512;
    else if (n <= 0x2000) k = kE8K;
    else if (n <= 0x8000) k = kFRAM;
    else if (n <= 0x10000) k = kE64K;
    else k = kFlash;
    Chip& ch = chips_[size_t(k)];
    if (!ch.fixedCap) { ch.cap = 0x40000; while (ch.cap < n && ch.cap < kFlashMax) ch.cap *= 2; }
    ch.data.assign(ch.cap, 0xFF);
    std::copy(d.begin(), d.begin() + std::min<size_t>(d.size(), ch.cap), ch.data.begin());
    if (k == kFRAM && o == Override::Auto) {        // 32K files: FRAM or a 64K EEPROM's first half
        Chip& e = chips_[kE64K]; e.data.assign(e.cap, 0xFF); std::copy(ch.data.begin(), ch.data.end(), e.data.begin());
    }
    loadedKind_ = k; chosen_ = k; decided_ = true;
}

void SaveMemory::setOverride(Override o) {
    if (o == override_) return;
    std::vector<u8> cur = data();
    bool had = decided_;
    override_ = o;
    if (had && !cur.empty()) load(cur); else reset(o);
    dirty_ = true;
}

void SaveMemory::choose() {
    if (loadedKind_ >= 0 && chips_[size_t(loadedKind_)].alive) { chosen_ = loadedKind_; return; }
    if (loadedKind_ >= 0) { loadedRejected_ = true; loadedKind_ = -1; dirty_ = true; }
    // Smallest page that fits the largest write seen; FRAM after 64K EEPROM; flash last.
    static const int order[kKinds] = {kE512, kE8K, kE64K, kFRAM, kE128K, kFlash};
    for (int k : order) {
        const Chip& ch = chips_[size_t(k)];
        if (ch.alive && (ch.page() == 0 || int(ch.page()) >= ch.maxCount)) { chosen_ = k; return; }
    }
    for (int k : order) if (chips_[size_t(k)].alive) { chosen_ = k; return; }
    // Nothing fits (should not happen): fall back to auto-sized flash.
    chips_[kFlash].alive = true; chosen_ = kFlash;
}

u8 SaveMemory::transfer(u8 v) {
    if (ir_) {
        if (!irStarted_) { irStarted_ = true; irCmd_ = v; irPos_ = 0; return 0xFF; }
        if (irCmd_ != 0x00) return (irCmd_ == 0x08 && irPos_++ == 0) ? 0xAA : 0x00;   // IR controller: ID 0xAA, no IR traffic
    }
    u8 out = 0xFF;
    bool d = false;
    for (int k = 0; k < kKinds; ++k) {
        Chip& ch = chips_[size_t(k)];
        if (!ch.alive) continue;
        bool cd = false;
        u8 r = ch.transfer(v, cd);
        if (k == chosen_) { out = r; d = cd; }
    }
    if (!chips_[size_t(chosen_)].alive && override_ == Override::Auto) choose();
    if (d) dirty_ = true;
    return out;
}

void SaveMemory::release() {
    if (ir_) { bool passed = irStarted_ && irCmd_ == 0x00; irStarted_ = false; if (!passed) return; }
    const Chip& cur = chips_[size_t(chosen_)];
    bool wasWrite = cur.stage > 0 && cur.count > 0;
    int count = cur.count;
    bool anyActive = false;
    for (auto& ch : chips_) if (ch.alive) { anyActive |= ch.stage > 0; ch.release(); }
    if (!anyActive) return;
    if (wasWrite) { maxWrite_ = std::max(maxWrite_, count); if (!decided_) { decided_ = true; dirty_ = true; } }
    if (override_ == Override::Auto) {
        int before = chosen_;
        choose();
        if (chosen_ != before) dirty_ = true;
    }
}

SaveMemory::Type SaveMemory::type() const {
    if (!decided_) return Type::Unknown;
    switch (chosen_) {
    case kE512: return Type::EEPROM512;
    case kE8K: case kE64K: return Type::EEPROM;
    case kFRAM: return Type::FRAM;
    default: return Type::Flash;
    }
}

u32 SaveMemory::capacity() const { return chips_[size_t(chosen_)].cap; }

const std::vector<u8>& SaveMemory::data() const {
    if (!decided_) return kEmpty;
    Chip& ch = const_cast<Chip&>(chips_[size_t(chosen_)]);
    if (ch.data.size() < ch.cap) ch.data.resize(ch.cap, 0xFF);   // blank chip reads as 0xFF
    return ch.data;
}

void SaveMemory::serialize(StateIO& s) {
    s.tag(0x53415602);
    s.pod(override_); s.pod(chosen_); s.pod(decided_); s.pod(maxWrite_); s.pod(loadedKind_); s.pod(loadedRejected_);
    for (auto& ch : chips_) {
        s.pod(ch.alive); s.pod(ch.cap); s.pod(ch.fixedCap); s.vec(ch.data); s.pod(ch.wel); s.pod(ch.cmd);
        s.pod(ch.stage); s.pod(ch.addr); s.pod(ch.start); s.pod(ch.count); s.pod(ch.maxCount); s.pod(ch.bad); s.pod(ch.pinned);
    }
    if (!s.writing()) dirty_ = true;               // make sure the restored save gets written back
}

} // namespace dscore
