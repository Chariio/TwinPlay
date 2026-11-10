// Copyright (c) 2026 Charlie Rodriguez Garcia. All rights reserved.
// Original clean-room implementation written from public hardware documentation.
#pragma once
#include <cstdint>
#include <cstddef>

namespace dscore {
using u8 = uint8_t;  using u16 = uint16_t; using u32 = uint32_t; using u64 = uint64_t;
using s8 = int8_t;   using s16 = int16_t;  using s32 = int32_t;  using s64 = int64_t;

constexpr int kScreenWidth = 256;
constexpr int kScreenHeight = 192;
constexpr int kScreenPixels = kScreenWidth * kScreenHeight;
constexpr int kAudioSampleRate = 48000;

// Button bits used by the public API (1 = pressed).
enum Button : u32 {
    BtnA = 1u << 0, BtnB = 1u << 1, BtnSelect = 1u << 2, BtnStart = 1u << 3,
    BtnRight = 1u << 4, BtnLeft = 1u << 5, BtnUp = 1u << 6, BtnDown = 1u << 7,
    BtnR = 1u << 8, BtnL = 1u << 9, BtnX = 1u << 10, BtnY = 1u << 11,
    // N64 / 3DS. Existing cores ignore bits they do not use.
    BtnZ = 1u << 12, BtnCUp = 1u << 13, BtnCDown = 1u << 14, BtnCLeft = 1u << 15, BtnCRight = 1u << 16,
    BtnZL = 1u << 17, BtnZR = 1u << 18,
};
} // namespace dscore
