// Copyright (c) 2026 Charlie Rodriguez Garcia. All rights reserved.
// Original clean-room implementation written from public hardware documentation.
#pragma once
#include "dscore/Types.hpp"

namespace dscore {
// Memory interface seen by one CPU. Addresses are byte addresses; callers
// pass aligned addresses for 16/32-bit accesses.
class Bus {
public:
    virtual ~Bus() = default;
    virtual u8  read8(u32 addr) = 0;
    virtual u16 read16(u32 addr) = 0;
    virtual u32 read32(u32 addr) = 0;
    virtual void write8(u32 addr, u8 v) = 0;
    virtual void write16(u32 addr, u16 v) = 0;
    virtual void write32(u32 addr, u32 v) = 0;
};
} // namespace dscore
