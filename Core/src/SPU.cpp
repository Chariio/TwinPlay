// Copyright (c) 2026 Charlie Rodriguez Garcia. All rights reserved.
// Original clean-room sound unit (see SPU.hpp), written from GBATEK's register
// description. Hold bit (SOUNDxCNT bit 15) is not modelled.
#include "SPU.hpp"
#include <algorithm>

namespace dscore {

namespace {
// IMA-ADPCM step table and index adjustments (public IMA/DVI ADPCM standard).
const s32 kStep[89] = {
    7, 8, 9, 10, 11, 12, 13, 14, 16, 17, 19, 21, 23, 25, 28, 31, 34, 37, 41, 45, 50, 55, 60, 66, 73, 80, 88, 97,
    107, 118, 130, 143, 157, 173, 190, 209, 230, 253, 279, 307, 337, 371, 408, 449, 494, 544, 598, 658, 724, 796,
    876, 963, 1060, 1166, 1282, 1411, 1552, 1707, 1878, 2066, 2272, 2499, 2749, 3024, 3327, 3660, 4026, 4428, 4871,
    5358, 5894, 6484, 7132, 7845, 8630, 9493, 10442, 11487, 12635, 13899, 15289, 16818, 18500, 20350, 22385, 24623,
    27086, 29794, 32767};
const int kIndexAdj[8] = {-1, -1, -1, -1, 2, 4, 6, 8};
constexpr u64 kSPUClock = 16756991;   // 33.513982 MHz / 2
constexpr int kOutRate = 48000;
// Source samples per output sample, 32.32 fixed point, for a timer reload value.
inline u64 stepFor(u32 tmr) { u64 period = 0x10000 - (tmr & 0xFFFF); return (kSPUClock << 32) / (period * kOutRate); }
// Gentle limiter: transparent below ~0.75 FS, rounds off peaks instead of hard clipping.
inline s32 limit(s32 x) {
    constexpr s32 knee = 24576;
    s32 a = x < 0 ? -x : x;
    if (a <= knee) return x;
    double over = double(a - knee), room = 32767.0 - knee;
    s32 y = knee + s32(room * over / (over + room));
    return x < 0 ? -y : y;
}
}

void SPU::reset() { for (auto& c : ch_) c = Channel{}; for (auto& c : cap_) c = Capture{}; }

void SPU::channelControlWritten(int ch, bool wasSet) {
    bool isSet = io_[ch * 16 + 3] & 0x80;
    if (isSet && !wasSet) start(ch);
    else if (!isSet) ch_[ch].active = false;
}

void SPU::start(int ch) {
    Channel& c = ch_[ch];
    c = Channel{};
    c.active = true;
    u32 format = (reg32(ch * 16) >> 29) & 3;
    if (format == 2) {                                   // ADPCM header: initial value + index
        u32 sad = reg32(ch * 16 + 4) & 0x07FFFFFC;
        u32 hdr = u32(read_(ctx_, sad)) | (u32(read_(ctx_, sad + 1)) << 8) | (u32(read_(ctx_, sad + 2)) << 16) | (u32(read_(ctx_, sad + 3)) << 24);
        c.adpcmValue = std::clamp<s32>(s16(hdr & 0xFFFF), -0x7FFF, 0x7FFF);
        c.adpcmIndex = std::min<int>((hdr >> 16) & 0x7F, 88);
        c.loopValue = c.adpcmValue; c.loopIndex = c.adpcmIndex;
        c.sample = c.adpcmValue;
    } else {
        c.sample = fetch(ch);
    }
    c.hist[3] = c.sample;                                // history starts from silence, no click
}

s32 SPU::fetch(int ch) {
    Channel& c = ch_[ch];
    u32 cnt = reg32(ch * 16);
    u32 sad = reg32(ch * 16 + 4) & 0x07FFFFFC;
    switch ((cnt >> 29) & 3) {
    case 0: return s32(s8(read_(ctx_, sad + c.index))) << 8;
    case 1: return s16(read_(ctx_, sad + c.index * 2) | (read_(ctx_, sad + c.index * 2 + 1) << 8));
    case 2: return c.adpcmValue;
    default:
        if (ch >= 8 && ch <= 13) { u32 duty = (cnt >> 24) & 7; return (c.phase & 7) > (6 - duty) ? 0x7FFF : -0x7FFF; }
        if (ch >= 14) return (c.lfsr & 1) ? -0x7FFF : 0x7FFF;
        return 0;
    }
}

bool SPU::advance(int ch) {
    Channel& c = ch_[ch];
    u32 cnt = reg32(ch * 16);
    u32 format = (cnt >> 29) & 3;
    if (format == 3) {                                   // PSG / noise never end
        if (ch >= 14) { bool carry = c.lfsr & 1; c.lfsr >>= 1; if (carry) c.lfsr ^= 0x6000; }
        else c.phase = (c.phase + 1) & 7;
        c.sample = fetch(ch);
        return true;
    }
    u32 pnt = reg16(ch * 16 + 0x0A), len = reg32(ch * 16 + 0x0C) & 0x3FFFFF;
    u32 perWord = format == 0 ? 4 : (format == 1 ? 2 : 8);
    // ADPCM: the first word of SAD is the header, so sample data starts one word in.
    u32 loopStart = format == 2 ? (pnt ? (pnt - 1) * 8 : 0) : pnt * perWord;
    u32 total = format == 2 ? (pnt + len ? (pnt + len - 1) * 8 : 0) : (pnt + len) * perWord;

    ++c.index;
    if (c.index >= total) {
        if (((cnt >> 27) & 3) == 1 && total > loopStart) {   // loop
            c.index = loopStart;
            if (format == 2) { c.adpcmValue = c.loopValue; c.adpcmIndex = c.loopIndex; }
        } else { stop(ch); return false; }
    } else if (format == 2) {
        u32 sad = reg32(ch * 16 + 4) & 0x07FFFFFC;
        u32 n = c.index - 1;                             // nibble being decoded
        if (!(n & 1)) c.adpcmByte = read_(ctx_, sad + 4 + n / 2);
        u32 nib = (n & 1) ? (c.adpcmByte >> 4) : (c.adpcmByte & 15);
        s32 step = kStep[c.adpcmIndex];
        s32 diff = step >> 3;
        if (nib & 1) diff += step >> 2;
        if (nib & 2) diff += step >> 1;
        if (nib & 4) diff += step;
        // GBATEK: clamp to -7FFFh..+7FFFh (not -8000h).
        c.adpcmValue = (nib & 8) ? std::max(c.adpcmValue - diff, -0x7FFF) : std::min(c.adpcmValue + diff, 0x7FFF);
        c.adpcmIndex = std::clamp(c.adpcmIndex + kIndexAdj[nib & 7], 0, 88);
        // Loop state is the decoder state *at* the loop-start sample (after nibble loopStart-1).
        if (c.index == loopStart) { c.loopValue = c.adpcmValue; c.loopIndex = c.adpcmIndex; }
    }
    c.sample = fetch(ch);
    return true;
}

s32 SPU::interpolate(const Channel& c, int ch) const {
    // PSG/noise are already band-limited by design on hardware: keep them raw.
    if (interp_ == 0 || ((reg32(ch * 16) >> 29) & 3) == 3) return c.hist[3];
    // Segment hist[1] (t=0) -> hist[2] (t=1); hist[0] and hist[3] are the outer taps of the
    // 4-point Catmull-Rom spline. Costs 2 source samples (~60 us) of latency.
    double t = double(u32(c.frac)) / 4294967296.0;
    double p0 = c.hist[0], p1 = c.hist[1], p2 = c.hist[2], p3 = c.hist[3];
    if (interp_ == 1) return s32(p1 + (p2 - p1) * t);
    double v = p1 + 0.5 * t * (p2 - p0 + t * (2 * p0 - 5 * p1 + 4 * p2 - p3 + t * (3 * (p1 - p2) + p3 - p0)));
    return std::clamp(s32(v), -0x8000, 0x7FFF);
}

void SPU::stepCapture(int u, s32 value) {
    Capture& k = cap_[u];
    u8 cnt = io_[0x108 + u];
    u32 dad = reg32(0x110 + u * 8) & 0x07FFFFFC;
    u32 len = u32(reg16(0x114 + u * 8)) * 4; if (!len) len = 4;
    bool pcm8 = cnt & 8;
    if (!write_) return;
    value = std::clamp(value, -0x8000, 0x7FFF);
    if (pcm8) {
        u8 b = u8(s8(value >> 8));
        if (!k.half) { k.pending = b; k.half = true; }
        else { write_(ctx_, dad + k.pos - 1, u16(k.pending | (b << 8))); k.half = false; }
        k.pos += 1;
    } else {
        write_(ctx_, dad + k.pos, u16(s16(value)));
        k.pos += 2;
    }
    if (k.pos >= len) {
        if (cnt & 4) { k.active = false; io_[0x108 + u] &= 0x7F; }   // one-shot
        k.pos = 0; k.half = false;
    }
}

void SPU::mix(s16* out, int frames) {
    u16 soundcnt = reg16(0x100);
    bool enabled = soundcnt & 0x8000;
    s32 master = soundcnt & 0x7F;
    u64 steps[16];
    for (int ch = 0; ch < 16; ++ch) steps[ch] = stepFor(reg16(ch * 16 + 8));
    for (int u = 0; u < 2; ++u) {                         // capture start (rising edge of bit 7)
        bool set = io_[0x108 + u] & 0x80;
        if (set && !cap_[u].wasSet) { cap_[u] = Capture{}; cap_[u].active = true; }
        if (!set) cap_[u].active = false;
        cap_[u].wasSet = set;
    }
    static const int kShift[4] = {0, 1, 2, 4};
    int outL = (soundcnt >> 8) & 3, outR = (soundcnt >> 10) & 3;
    bool ch1ToMixer = !(soundcnt & 0x1000), ch3ToMixer = !(soundcnt & 0x2000);
    for (int f = 0; f < frames; ++f) {
        s32 l = 0, r = 0;
        s32 pl[16], pr[16];                               // per-channel panned output
        if (enabled) {
            for (int ch = 0; ch < 16; ++ch) {
                Channel& c = ch_[ch];
                pl[ch] = pr[ch] = 0;
                if (!c.active) continue;
                c.frac += steps[ch];
                bool alive = true;
                while ((c.frac >> 32) && alive) {
                    c.frac -= u64(1) << 32;
                    alive = advance(ch);
                    c.hist[0] = c.hist[1]; c.hist[1] = c.hist[2]; c.hist[2] = c.hist[3];
                    c.hist[3] = alive ? c.sample : 0;
                }
                if (!alive) continue;
                u32 cnt = reg32(ch * 16);
                s32 s = (interpolate(c, ch) * s32(cnt & 0x7F)) >> 7;
                s >>= kShift[(cnt >> 8) & 3];
                c.out = s;
                // GBATEK pan: 0 = left, 64 = centre, 127 = right.
                s32 pan = (cnt >> 16) & 0x7F;
                pl[ch] = (s * (128 - pan)) >> 7;
                pr[ch] = (s * pan) >> 7;
                if ((ch == 1 && !ch1ToMixer) || (ch == 3 && !ch3ToMixer)) continue;
                l += pl[ch]; r += pr[ch];
            }
        } else { for (int ch = 0; ch < 16; ++ch) pl[ch] = pr[ch] = 0; }
        // Capture: unit 0 records the left mixer (or ch0), unit 1 the right mixer (or ch2),
        // at the rate of ch1 / ch3's timer. 'Add' folds ch1/ch3 into the source.
        for (int u = 0; u < 2; ++u) {
            Capture& k = cap_[u];
            if (!k.active || !enabled) continue;
            u8 cc = io_[0x108 + u];
            s32 v = (cc & 2) ? ch_[u * 2].out : (u ? r : l);
            if (cc & 1) v += ch_[u * 2 + 1].out;
            k.frac += stepFor(reg16((u * 2 + 1) * 16 + 8));
            while (k.frac >> 32) { k.frac -= u64(1) << 32; stepCapture(u, v); }
        }
        auto route = [&](int sel, s32 mixv, bool left) -> s32 {
            const s32* p = left ? pl : pr;
            switch (sel) { case 1: return p[1]; case 2: return p[3]; case 3: return p[1] + p[3]; default: return mixv; }
        };
        l = route(outL, l, true); r = route(outR, r, false);
        l = ((l * master) >> 7) >> 1;
        r = ((r * master) >> 7) >> 1;
        out[f * 2] = s16(limit(l));
        out[f * 2 + 1] = s16(limit(r));
    }
}

} // namespace dscore
