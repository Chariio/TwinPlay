// Copyright (c) 2026 Charlie Rodriguez Garcia. All rights reserved.
// Original clean-room sound unit: 16 channels (PCM8, PCM16, IMA-ADPCM,
// PSG square, noise), 2 capture units, mixed to 48 kHz stereo. Register layout from GBATEK.
#pragma once
#include "dscore/Types.hpp"
#include "dscore/StateIO.hpp"

namespace dscore {

class SPU {
public:
    using ReadFn = u8 (*)(void* ctx, u32 addr);
    using WriteFn = void (*)(void* ctx, u32 addr, u16 value);   // halfword store (capture)
    // io: ARM7 register block starting at 0x04000400.
    SPU(u8* io, ReadFn read, void* ctx, WriteFn write = nullptr) : io_(io), read_(read), write_(write), ctx_(ctx) { reset(); }
    void reset();
    void channelControlWritten(int ch, bool startBitWasSet);
    // Mixes `frames` stereo samples into out (interleaved). Call in small chunks (per scanline)
    // so playback stays in step with the CPUs that stream into ring buffers.
    void mix(s16* out, int frames);
    // 0 = none (sample-and-hold, raw hardware), 1 = linear, 2 = cubic (Hermite, default).
    void setInterpolation(int mode) { interp_ = mode < 0 ? 0 : mode > 2 ? 2 : mode; }
    int interpolation() const { return interp_; }
    void serialize(StateIO& s) { s.tag(0x53505502); s.bytes(ch_, sizeof ch_); s.bytes(cap_, sizeof cap_); }

private:
    struct Channel {
        bool active = false;
        u64 frac = 0;               // 32.32 fixed-point position between source samples
        u32 index = 0;              // current sample index
        s32 sample = 0;             // current output sample
        s32 hist[4] = {0, 0, 0, 0}; // last source samples, hist[3] newest (interpolation)
        // ADPCM
        s32 adpcmValue = 0; int adpcmIndex = 0;
        s32 loopValue = 0; int loopIndex = 0;
        u8 adpcmByte = 0;
        // PSG / noise
        u32 phase = 0; u16 lfsr = 0x7FFF;
        s32 out = 0;                // last mixed output (pre-pan), for capture source / routing
    };
    struct Capture {
        bool active = false; u64 frac = 0; u32 pos = 0;   // pos in bytes
        u16 pending = 0; bool half = false;                // PCM8 byte pairing
        bool wasSet = false;
    };
    u32 reg32(u32 off) const { return u32(io_[off]) | (u32(io_[off + 1]) << 8) | (u32(io_[off + 2]) << 16) | (u32(io_[off + 3]) << 24); }
    u16 reg16(u32 off) const { return u16(io_[off] | (io_[off + 1] << 8)); }
    void start(int ch);
    void stop(int ch) { ch_[ch].active = false; io_[ch * 16 + 3] &= 0x7F; }
    bool advance(int ch);           // steps one source sample; false if the channel ended
    s32 fetch(int ch);
    s32 interpolate(const Channel& c, int ch) const;
    void stepCapture(int unit, s32 value);

    u8* io_;
    ReadFn read_;
    WriteFn write_;
    void* ctx_;
    int interp_ = 2;
    Channel ch_[16];
    Capture cap_[2];
};

} // namespace dscore
