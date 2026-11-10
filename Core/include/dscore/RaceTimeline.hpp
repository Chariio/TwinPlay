// The button timeline that reaches a 1P GP race. Shared by the harness and
// the libretro dump tool so the two runs press the same buttons on the same frames.
#pragma once
#include "dscore/Types.hpp"
#include <initializer_list>

namespace dscore {

inline u32 raceButtons(int frame) {
    auto held = [](int f, int start, int len) {
        return f >= start && f < start + len;
    };
    u32 b = 0;
    if (held(frame, 360, 6)) b |= BtnStart;
    for (int t : {516, 672, 828, 984, 1170}) if (held(frame, t, 6)) b |= BtnB;
    if (held(frame, 1350, 90)) b |= BtnB;
    if (held(frame, 1680, 90)) b |= BtnB;
    if (frame >= 2700) {
        b |= BtnB;
        int phase = (frame - 2700) % 32;
        if (phase < 8) b |= BtnLeft;
        else if (phase >= 16 && phase < 24) b |= BtnRight;
    }
    return b;
}

// --pc-trace-bank logs these frames only. Wide enough to cover the load and
// the picture we compare, narrow enough to stay cheap.
inline bool racePcTraceFrame(int frame) {
    if (frame == 2220) return true;
    return frame >= 1795 && frame <= 1810;
}

} // namespace dscore
