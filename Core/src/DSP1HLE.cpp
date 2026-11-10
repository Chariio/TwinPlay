// DSP-1 / DSP-1B high-level emulation.
//
// The chip's program ROM is not included. The command set is the fixed-point
// algorithm published by Andreas Naive, Overload, The Dumper and Neviksti
// (2006, "DSP-1 reverse engineering"): 16-bit multiply, interpolated sine,
// Newton reciprocal, normalize, and the parameter / raster / project / target
// projection used by Mode 7. This file is original code. No non-commercial
// or GPL source is copied.
//
// Sine nodes are trunc(sin(i * pi / 128) * 32768), clamped to +/-32767.
// Multiply weights are (i * 0x32440) >> 16, the 16.16 pi that table uses.
// A reciprocal seed is round(2^29 / c0) for the 128-wide bucket the
// coefficient falls in, followed by two Newton steps. Shift weights are the
// power-of-two windows of that algorithm (1, 2, 4, ... then 0x7fff, then
// back down). The 16 zenith-clip limits and four Taylor weights are the
// published projection constants, not a firmware image.
//
// The host port matches the uPD77C25 byte interface. A command is one byte in
// 0x00-0x3F. While the chip is waiting, any byte with bit 6 or bit 7 set
// (0x40-0xFF, including the 0x80 resync used at boot) is ignored and does not
// start a command. Argument and result words are 16-bit little-endian. While
// a command is waiting, the port is 8-bit (DRC set, DRS reads as 0) so each
// byte is its own opcode attempt. Once a command has started, the next byte
// is data even if it is 0x80.
// Data transfers are 16-bit (DRC clear, DRS marks the high byte). Raster
// keeps streaming until the word $8000 is written; that word is not an opcode.
// Status, as read by the SNES, has RQM in bit 7, DRS in bit 4 and DRC in bit 2.
// On SHVC-1K1X the data port is $6xxx and the status port is $7xxx.
// Math runs only when a data word completes. Nothing here scans the picture.

#include "dscore/SnesTrace.hpp"
#include <cmath>
#include <cstdint>
#include <cstring>

namespace dscore {
namespace {

int16_t s16(int v) { return (int16_t)v; }

// Power-of-two window. Index 0x22 starts at 1 and doubles through 0x4000,
// 0x31 is 0x7fff, and 0x32 halves from 0x4000 down to 1.
int dataShift(int index) {
    if (index >= 0x22 && index <= 0x30) return 1 << (index - 0x22);
    if (index == 0x31) return 0x7fff;
    if (index >= 0x32 && index <= 0x40) return 0x4000 >> (index - 0x32);
    return 0;
}

struct Tables {
    int16_t sine[256];
    int16_t mul[256];
    Tables() {
        for (int i = 0; i < 256; ++i) {
            double s = std::sin(i * 3.14159265358979323846 / 128.0) * 32768.0;
            int v = (int)s; // trunc toward zero
            if (v > 32767) v = 32767;
            if (v < -32767) v = -32767;
            sine[i] = (int16_t)v;
            mul[i] = (int16_t)((i * 0x32440) >> 16);
        }
    }
};

const Tables& tables() {
    static Tables t;
    return t;
}

// Published zenith-clip limit, one entry per CentreZ exponent 0..15.
constexpr int16_t kMaxAzs[16] = {
    0x38b4, 0x38b7, 0x38ba, 0x38be, 0x38c0, 0x38c4, 0x38c7, 0x38ca,
    0x38ce, 0x38d0, 0x38d4, 0x38d7, 0x38da, 0x38dd, 0x38e0, 0x38e4,
};
// Square-root nodes for command 0x28. Entry i+64 is the curve at position i,
// and i runs from -64 to 64 so a wrapped (negative) sum of squares still
// lands on the same node the chip uses.
constexpr int16_t kSqrtNode[129] = {
    0x5d17, 0x5c91, 0x5c0c, 0x5b88, 0x5b06, 0x5a85, 0x5a06, 0x5988,
    0x590b, 0x5890, 0x5816, 0x579d, 0x5726, 0x56b0, 0x563b, 0x55c8,
    0x5555, 0x54e4, 0x5474, 0x5405, 0x5398, 0x532b, 0x52bf, 0x5255,
    0x51ec, 0x5183, 0x511c, 0x50b6, 0x5050, 0x4fec, 0x4f89, 0x4f26,
    0x4ec5, 0x4e64, 0x4e05, 0x4da6, 0x4d48, 0x4cec, 0x4c90, 0x4c34,
    0x4bda, 0x4b81, 0x4b28, 0x4ad0, 0x4a79, 0x4a23, 0x49cd, 0x4979,
    0x4925, 0x48d1, 0x487f, 0x482d, 0x47dc, 0x478c, 0x473c, 0x46ed,
    0x469f, 0x4651, 0x4604, 0x45b8, 0x456c, 0x4521, 0x44d7, 0x448d,
    0x4444, 0x43fc, 0x43b4, 0x436d, 0x4326, 0x42e0, 0x429a, 0x4255,
    0x4211, 0x41cd, 0x4189, 0x4146, 0x4104, 0x40c2, 0x4081, 0x4040,
    0x3fff, 0x41f7, 0x43e1, 0x45bd, 0x478d, 0x4951, 0x4b0b, 0x4cbb,
    0x4e61, 0x4fff, 0x5194, 0x5322, 0x54a9, 0x5628, 0x57a2, 0x5914,
    0x5a81, 0x5be9, 0x5d4a, 0x5ea7, 0x5fff, 0x6152, 0x62a0, 0x63ea,
    0x6530, 0x6672, 0x67b0, 0x68ea, 0x6a20, 0x6b53, 0x6c83, 0x6daf,
    0x6ed9, 0x6fff, 0x7122, 0x7242, 0x735f, 0x747a, 0x7592, 0x76a7,
    0x77ba, 0x78cb, 0x79d9, 0x7ae5, 0x7bee, 0x7cf5, 0x7dfa, 0x7efe,
    0x7fff,
};

// Taylor weights of the clip correction (x + x^3/3, and the cosine series).
constexpr int16_t kT328 = 0x14ac;
constexpr int16_t kT327 = 0x6488;
constexpr int16_t kT324 = 0x0a26;
constexpr int16_t kT325 = 0x277a;

int16_t sin16(int16_t angle) {
    if (angle < 0) {
        if (angle == -32768) return 0;
        return s16(-sin16(s16(-angle)));
    }
    const Tables& t = tables();
    int s = t.sine[angle >> 8] + ((t.mul[angle & 0xff] * t.sine[(0x40 + (angle >> 8)) & 0xff]) >> 15);
    if (s > 32767) s = 32767;
    return s16(s);
}

int16_t cos16(int16_t angle) {
    if (angle < 0) {
        if (angle == -32768) return -32768;
        angle = s16(-angle);
    }
    const Tables& t = tables();
    int s = t.sine[(0x40 + (angle >> 8)) & 0xff] - ((t.mul[angle & 0xff] * t.sine[angle >> 8]) >> 15);
    if (s < -32768) s = -32767;
    return s16(s);
}

void normalize(int m, int& coefficient, int& exponent) {
    m = s16(m);
    int i = 0x4000;
    int e = 0;
    if (m < 0) {
        while ((m & i) && i) { i >>= 1; ++e; }
    } else {
        while (!(m & i) && i) { i >>= 1; ++e; }
    }
    if (e > 0) coefficient = s16((m * dataShift(0x21 + e)) << 1);
    else coefficient = m;
    exponent = s16(exponent - e);
}

void normalizeDouble(int product, int& coefficient, int& exponent) {
    int n = product & 0x7fff;
    int m = s16(product >> 15);
    int i = 0x4000;
    int e = 0;
    if (m < 0) {
        while ((m & i) && i) { i >>= 1; ++e; }
    } else {
        while (!(m & i) && i) { i >>= 1; ++e; }
    }
    if (e > 0) {
        coefficient = s16((m * dataShift(0x21 + e)) << 1);
        if (e < 15) {
            coefficient = s16(coefficient + ((n * dataShift(0x40 - e)) >> 15));
        } else {
            i = 0x4000;
            if (m < 0) {
                while ((n & i) && i) { i >>= 1; ++e; }
            } else {
                while (!(n & i) && i) { i >>= 1; ++e; }
            }
            if (e > 15) coefficient = s16((n * dataShift(0x12 + e)) << 1);
            else coefficient = s16(coefficient + n);
        }
    } else {
        coefficient = m;
    }
    exponent = s16(e);
}

int denormalize(int c, int e) {
    c = s16(c);
    e = s16(e);
    if (e > 0) {
        if (c > 0) return 32767;
        if (c < 0) return -32767;
        return 0;
    }
    if (e < 0) return s16((c * dataShift(0x31 + e)) >> 15);
    return c;
}

int shiftR(int c, int e) {
    return s16((s16(c) * dataShift(0x31 + s16(e))) >> 15);
}

void inverse(int coefficient, int exponent, int& iCoefficient, int& iExponent) {
    coefficient = s16(coefficient);
    exponent = s16(exponent);
    if (coefficient == 0) {
        iCoefficient = 0x7fff;
        iExponent = 0x002f;
        return;
    }
    int sign = 1;
    if (coefficient < 0) {
        if (coefficient < -32767) coefficient = -32767;
        coefficient = -coefficient;
        sign = -1;
    }
    while (coefficient < 0x4000) {
        coefficient <<= 1;
        --exponent;
    }
    if (coefficient == 0x4000) {
        if (sign == 1) iCoefficient = 0x7fff;
        else {
            iCoefficient = -0x4000;
            --exponent;
        }
    } else {
        int idx = (coefficient - 0x4000) >> 7;
        int c0 = 0x4000 + (idx << 7);
        int i = (0x20000000 + c0 / 2) / c0;
        if (i > 32767) i = 32767;
        for (int n = 0; n < 2; ++n) {
            int term = (coefficient * i) >> 15;
            int term2 = ((-i) * term) >> 15;
            i = s16((i + term2) << 1);
        }
        iCoefficient = s16(i * sign);
    }
    iExponent = s16(1 - exponent);
}

struct Proj {
    int16_t les = 0, cLes = 0, eLes = 0;
    int16_t sinAas = 0, cosAas = 0x7fff, sinAzs = 0, cosAzs = 0x7fff;
    int16_t nx = 0, ny = 0, nz = 0x7fff;
    int16_t hx = 0x7fff, hy = 0;
    int16_t vx = 0, vy = 0, vz = 0;
    int16_t centreX = 0, centreY = 0, centreZ = 0;
    int16_t gx = 0, gy = 0, gz = 0;
    int16_t centreZC = 0, centreZE = 0;
    int16_t sinAZS = 0, cosAZS = 0x7fff;
    int16_t secC1 = 0, secE1 = 0, secC2 = 0, secE2 = 0;
    int16_t vOffset = 0;
};

struct Chip {
    // 0 = waiting for an 8-bit opcode, 1 = reading 16-bit inputs, 2 = writing 16-bit outputs.
    int phase = 0;
    bool drc = true;
    bool drs = false;
    bool freeze = false;
    bool streaming = false;
    int need = 0, got = 0, nout = 0, wordsOut = 0, dataCount = 0;
    uint8_t op = 0;
    uint16_t dr = 0x0080;
    int16_t in[8]{};
    int16_t out[16]{};
    int16_t matrix[3][3][3]{};
    Proj proj{};
    int16_t vs = 0;

    void reset() { *this = Chip{}; }

    static void counts(uint8_t opcode, int& inn, int& outn) {
        inn = 0;
        outn = 0;
        switch (opcode) {
        case 0x00: case 0x20: inn = 2; outn = 1; break;             // multiply
        case 0x10: case 0x30: inn = 2; outn = 2; break;             // inverse
        case 0x04: case 0x24: inn = 2; outn = 2; break;             // triangle
        case 0x08: inn = 3; outn = 2; break;                        // radius
        case 0x18: case 0x38: inn = 4; outn = 1; break;             // range
        case 0x28: inn = 3; outn = 1; break;                        // distance
        case 0x0c: case 0x2c: inn = 3; outn = 2; break;             // rotate
        case 0x1c: case 0x3c: inn = 6; outn = 3; break;             // polar
        case 0x14: case 0x34: inn = 6; outn = 3; break;             // gyrate
        case 0x01: case 0x05: case 0x11: case 0x15:
        case 0x21: case 0x25: case 0x31: case 0x35: inn = 4; outn = 0; break; // attitude
        case 0x02: case 0x12: case 0x22: case 0x32: inn = 7; outn = 4; break; // parameter
        case 0x03: case 0x13: case 0x23: case 0x33: inn = 3; outn = 3; break; // subjective
        case 0x09: case 0x0d: case 0x19: case 0x1d:
        case 0x29: case 0x2d: case 0x39: case 0x3d: inn = 3; outn = 3; break; // objective
        case 0x0b: case 0x1b: case 0x2b: case 0x3b: inn = 3; outn = 1; break; // scalar
        case 0x06: case 0x16: case 0x26: case 0x36: inn = 3; outn = 3; break; // project
        case 0x0a: inn = 1; outn = 4; break;                        // raster
        case 0x0e: case 0x1e: case 0x2e: case 0x3e: inn = 2; outn = 2; break; // target
        case 0x07: case 0x0f: inn = 1; outn = 1; break;             // memory test
        case 0x17: case 0x1f: case 0x37: case 0x3f: inn = 1; outn = 1; break; // data block
        case 0x27: case 0x2f: inn = 1; outn = 1; break;             // version
        default: break;
        }
    }

    static int slotOf(uint8_t opcode) {
        switch (opcode) {
        case 0x11: case 0x15: case 0x13: case 0x19: case 0x1d: case 0x1b: return 1;
        case 0x21: case 0x25: case 0x23: case 0x29: case 0x2d: case 0x2b: return 2;
        default: return 0;
        }
    }

    void push(int v) { if (nout < 16) out[nout++] = s16(v); }

    void attitude(int slot, int16_t scale, int16_t rz, int16_t ry, int16_t rx) {
        scale = s16(scale >> 1);
        int sz = sin16(rz), cz = cos16(rz);
        int sy = sin16(ry), cy = cos16(ry);
        int sx = sin16(rx), cx = cos16(rx);
        int16_t* m = &matrix[slot][0][0];
        auto at = [&](int r, int c, int v) { m[r * 3 + c] = s16(v); };
        int ssz = s16(scale * sz >> 15);
        int scz = s16(scale * cz >> 15);
        at(0, 0, s16(scz * cy >> 15));
        at(0, 1, s16(ssz * cx >> 15) + s16(s16(scz * sx >> 15) * sy >> 15));
        at(0, 2, s16(ssz * sx >> 15) - s16(s16(scz * cx >> 15) * sy >> 15));
        at(1, 0, -s16(ssz * cy >> 15));
        at(1, 1, s16(scz * cx >> 15) - s16(s16(ssz * sx >> 15) * sy >> 15));
        at(1, 2, s16(scz * sx >> 15) + s16(s16(ssz * cx >> 15) * sy >> 15));
        at(2, 0, scale * sy >> 15);
        at(2, 1, -s16(s16(scale * sx >> 15) * cy >> 15));
        at(2, 2, s16(scale * cx >> 15) * cy >> 15);
    }

    void objective(int slot) {
        const int16_t* m = &matrix[slot][0][0];
        int x = in[0], y = in[1], z = in[2];
        auto col = [&](int c) {
            return s16((m[0 * 3 + c] * x >> 15) + (m[1 * 3 + c] * y >> 15) + (m[2 * 3 + c] * z >> 15));
        };
        push(col(0));
        push(col(1));
        push(col(2));
    }

    void subjective(int slot) {
        const int16_t* m = &matrix[slot][0][0];
        int f = in[0], l = in[1], u = in[2];
        auto row = [&](int r) {
            return s16((m[r * 3 + 0] * f >> 15) + (m[r * 3 + 1] * l >> 15) + (m[r * 3 + 2] * u >> 15));
        };
        push(row(0));
        push(row(1));
        push(row(2));
    }

    void parameter() {
        int fx = in[0], fy = in[1], fz = in[2];
        int lfe = in[3], les = in[4], aas = in[5], azs = in[6];
        int azsClip = azs;
        Proj& p = proj;
        p.les = s16(les);
        int cLes = 0, eLes = 0;
        normalize(les, cLes, eLes);
        p.cLes = s16(cLes);
        p.eLes = s16(eLes);
        p.sinAas = sin16(s16(aas));
        p.cosAas = cos16(s16(aas));
        p.sinAzs = sin16(s16(azs));
        p.cosAzs = cos16(s16(azs));
        p.nx = s16(((int)p.sinAzs * -(int)p.sinAas) >> 15);
        p.ny = s16(((int)p.sinAzs * p.cosAas) >> 15);
        p.nz = s16(((int)p.cosAzs * 0x7fff) >> 15);
        p.hx = s16(((int)p.cosAas * 0x7fff) >> 15);
        p.hy = s16(((int)p.sinAas * 0x7fff) >> 15);
        p.vx = s16(((int)p.cosAzs * -(int)p.sinAas) >> 15);
        p.vy = s16(((int)p.cosAzs * p.cosAas) >> 15);
        p.vz = s16((-(int)p.sinAzs * 0x7fff) >> 15);
        p.centreX = s16(fx + s16((lfe * p.nx) >> 15));
        p.centreY = s16(fy + s16((lfe * p.ny) >> 15));
        p.centreZ = s16(fz + s16((lfe * p.nz) >> 15));
        p.gx = s16(p.centreX - s16((les * p.nx) >> 15));
        p.gy = s16(p.centreY - s16((les * p.ny) >> 15));
        p.gz = s16(p.centreZ - s16((les * p.nz) >> 15));

        int c = 0, e = 0;
        normalize(p.centreZ, c, e);
        p.centreZC = s16(c);
        p.centreZE = s16(e);
        int maxIndex = -e;
        if (maxIndex < 0) maxIndex = 0;
        if (maxIndex > 15) maxIndex = 15;
        int maxAzs = kMaxAzs[maxIndex];
        if (azsClip < 0) {
            maxAzs = s16(-maxAzs);
            if (azsClip < maxAzs + 1) azsClip = s16(maxAzs + 1);
        } else if (azsClip > maxAzs) {
            azsClip = maxAzs;
        }
        p.sinAZS = sin16(s16(azsClip));
        p.cosAZS = cos16(s16(azsClip));
        int secC = 0, secE = 0;
        inverse(p.cosAZS, 0, secC, secE);
        p.secC1 = s16(secC);
        p.secE1 = s16(secE);
        normalize(s16((c * p.secC1) >> 15), c, e);
        e = s16(e + p.secE1);
        c = s16((denormalize(c, e) * p.sinAZS) >> 15);
        p.centreX = s16(p.centreX + s16((c * p.sinAas) >> 15));
        p.centreY = s16(p.centreY - s16((c * p.cosAas) >> 15));

        int vof = 0;
        int azsLocal = azs;
        if (azsLocal != azsClip || azsLocal == maxAzs) {
            if (azsLocal == -32768) azsLocal = -32767;
            c = s16(azsLocal - maxAzs);
            if (c >= 0) c = s16(c - 1);
            int aux = s16(~(c << 2));
            c = s16((aux * kT328) >> 15);
            c = s16(((c * aux) >> 15) + kT327);
            vof = s16(vof - s16((s16((c * aux) >> 15) * les) >> 15));
            c = s16((aux * aux) >> 15);
            aux = s16(((c * kT324) >> 15) + kT325);
            p.cosAZS = s16(p.cosAZS + s16((s16((c * aux) >> 15) * p.cosAZS) >> 15));
        }
        p.vOffset = s16((les * p.cosAZS) >> 15);
        int cSec = 0;
        inverse(p.sinAZS, 0, cSec, e);
        normalize(p.vOffset, c, e);
        normalize(s16((c * cSec) >> 15), c, e);
        if (c == -32768) { c = s16(c >> 1); e = s16(e + 1); }
        int vva = denormalize(s16(-c), e);
        inverse(p.cosAZS, 0, secC, secE);
        p.secC2 = s16(secC);
        p.secE2 = s16(secE);
        push(vof);
        push(vva);
        push(p.centreX);
        push(p.centreY);
    }

    void rasterAt(int vsLine, const char* tag) {
        int c = 0, e = 0;
        int base = s16(s16((vsLine * proj.sinAzs) >> 15) + proj.vOffset);
        inverse(base, 7, c, e);
        e = s16(e + proj.centreZE);
        int c1 = s16((c * proj.centreZC) >> 15);
        int e1 = s16(e + proj.secE2);
        normalize(c1, c, e);
        c = denormalize(c, e);
        int an = s16((c * proj.cosAas) >> 15);
        int cn = s16((c * proj.sinAas) >> 15);
        normalize(s16((c1 * proj.secC2) >> 15), c, e1);
        c = denormalize(c, e1);
        int bn = s16((c * -(int)proj.sinAas) >> 15);
        int dn = s16((c * proj.cosAas) >> 15);
        nout = 0;
        push(an);
        push(bn);
        push(cn);
        push(dn);
        if(dscore::snesTraceEnabled) {
            int16_t vsWord = s16(vsLine);
            dscore::snesTraceDsp(0x0a, &vsWord, 1, out, nout, tag);
            dscore::snesTraceRasterState(proj.sinAzs, proj.vOffset, proj.centreZC, proj.centreZE);
        }
        if (dscore::snesDspLogArmed) {
            int16_t vsWord = s16(vsLine);
            dscore::snesDspLogWrite(0x0a, &vsWord, 1, out, nout);
        }
    }

    void target() {
        int h = in[0], v = in[1];
        int c = 0, e = 0;
        inverse(s16(s16((v * proj.sinAzs) >> 15) + proj.vOffset), 8, c, e);
        e = s16(e + proj.centreZE);
        int c1 = s16((c * proj.centreZC) >> 15);
        int e1 = s16(e + proj.secE1);
        int hh = s16(h << 8);
        normalize(c1, c, e);
        c = s16((denormalize(c, e) * hh) >> 15);
        int x = s16(proj.centreX + s16((c * proj.cosAas) >> 15));
        int y = s16(proj.centreY - s16((c * proj.sinAas) >> 15));
        int vv = s16(v << 8);
        normalize(s16((c1 * proj.secC1) >> 15), c, e1);
        c = s16((denormalize(c, e1) * vv) >> 15);
        x = s16(x + s16((c * -(int)proj.sinAas) >> 15));
        y = s16(y + s16((c * proj.cosAas) >> 15));
        push(x);
        push(y);
    }

    void project() {
        int x = in[0], y = in[1], z = in[2];
        int px = 0, e4 = 0, py = 0, e = 0, pz = 0, e3 = 0;
        normalizeDouble((int)x - proj.gx, px, e4);
        normalizeDouble((int)y - proj.gy, py, e);
        normalizeDouble((int)z - proj.gz, pz, e3);
        px = s16(px >> 1); e4 = s16(e4 - 1);
        py = s16(py >> 1); e = s16(e - 1);
        pz = s16(pz >> 1); e3 = s16(e3 - 1);
        int refE = e < e3 ? e : e3;
        refE = refE < e4 ? refE : e4;
        px = shiftR(px, e4 - refE);
        py = shiftR(py, e - refE);
        pz = shiftR(pz, e3 - refE);
        int c11 = s16(-((px * proj.nx) >> 15));
        int c8 = s16(-((py * proj.ny) >> 15));
        int c9 = s16(-((pz * proj.nz) >> 15));
        int c12 = s16(c11 + c8 + c9);
        int aux4 = c12;
        // The common exponent is then replaced by 16 minus itself. Both the
        // depth denormalize and the later H/V exponents use that replaced value.
        int shift = s16(16 - refE);
        if (shift >= 0) aux4 <<= shift;
        else aux4 >>= -shift;
        if (aux4 == -1) aux4 = 0;
        aux4 >>= 1;
        // Les is zero-extended before it is added to the 32-bit depth term.
        int aux = (int)(uint16_t)proj.les + aux4;
        int c10 = 0, e2 = 0;
        normalizeDouble(aux, c10, e2);
        e2 = s16(15 - e2);
        int c4 = 0, e4b = 0;
        inverse(c10, 0, c4, e4b);
        int c2 = s16((c4 * proj.cLes) >> 15);

        int c16 = s16((px * proj.hx) >> 15);
        int c20 = s16((py * proj.hy) >> 15);
        int c17 = s16(c16 + c20);
        int c18 = s16((c17 * c2) >> 15);
        int c19 = 0, e7 = 0;
        normalize(c18, c19, e7);
        int h = denormalize(c19, s16(proj.eLes - e2 + shift + e7));

        int c21 = s16((px * proj.vx) >> 15);
        int c22 = s16((py * proj.vy) >> 15);
        int c23 = s16((pz * proj.vz) >> 15);
        int c24 = s16(c21 + c22 + c23);
        int c26 = s16((c24 * c2) >> 15);
        int c25 = 0, e6 = 0;
        normalize(c26, c25, e6);
        int v = denormalize(c25, s16(proj.eLes - e2 + shift + e6));

        int c6 = 0;
        normalize(c2, c6, e4b);
        int m = denormalize(c6, s16(e4b + proj.eLes - e2 - 7));
        push(h);
        push(v);
        push(m);
    }

    void gyrate() {
        int az = in[0], ax = in[1], ay = in[2], u = in[3], f = in[4], l = in[5];
        int sinAy = sin16(s16(ay)), cosAy = cos16(s16(ay));
        int cSec = 0, eSec = 0, c = 0, e = 0;
        inverse(cos16(s16(ax)), 0, cSec, eSec);
        normalizeDouble((int)u * cosAy - (int)f * sinAy, c, e);
        e = s16(eSec - e);
        normalize(s16((c * cSec) >> 15), c, e);
        int rz = s16(az + denormalize(c, e));
        int rx = s16(ax + s16((u * sinAy) >> 15) + s16((f * cosAy) >> 15));
        normalizeDouble((int)u * cosAy + (int)f * sinAy, c, e);
        e = s16(eSec - e);
        int cSin = 0;
        normalize(sin16(s16(ax)), cSin, e);
        normalize(s16(-s16((c * s16((cSec * cSin) >> 15)) >> 15)), c, e);
        int ry = s16(ay + denormalize(c, e) + l);
        push(rz);
        push(rx);
        push(ry);
    }

    void polar() {
        int az = in[0], ay = in[1], ax = in[2];
        int x1 = in[3], y1 = in[4], z1 = in[5];
        int x = s16((y1 * sin16(s16(az)) >> 15) + (x1 * cos16(s16(az)) >> 15));
        int y = s16((y1 * cos16(s16(az)) >> 15) - (x1 * sin16(s16(az)) >> 15));
        x1 = x; y1 = y;
        int z = s16((x1 * sin16(s16(ay)) >> 15) + (z1 * cos16(s16(ay)) >> 15));
        x = s16((x1 * cos16(s16(ay)) >> 15) - (z1 * sin16(s16(ay)) >> 15));
        int x2 = x; z1 = z;
        y = s16((z1 * sin16(s16(ax)) >> 15) + (y1 * cos16(s16(ax)) >> 15));
        z = s16((z1 * cos16(s16(ax)) >> 15) - (y1 * sin16(s16(ax)) >> 15));
        push(x2);
        push(y);
        push(z);
    }

    void run() {
        nout = 0;
        streaming = false;
        switch (op) {
        case 0x00:
            push(((int)in[0] * in[1]) >> 15);
            break;
        case 0x20:
            push(s16((((int)in[0] * in[1]) >> 15) + 1));
            break;
        case 0x10: case 0x30: {
            int c = 0, e = 0;
            inverse(in[0], in[1], c, e);
            push(c);
            push(e);
            break;
        }
        case 0x04: case 0x24:
            push((sin16(in[0]) * in[1]) >> 15);
            push((cos16(in[0]) * in[1]) >> 15);
            break;
        case 0x08: {
            long long radius = (((long long)in[0] * in[0] + (long long)in[1] * in[1] + (long long)in[2] * in[2]) << 1);
            push((int)radius);
            push((int)(radius >> 16));
            break;
        }
        case 0x18:
            push((int)((((long long)in[0] * in[0] + (long long)in[1] * in[1] + (long long)in[2] * in[2] - (long long)in[3] * in[3]) >> 15)));
            break;
        case 0x38:
            push(s16((int)((((long long)in[0] * in[0] + (long long)in[1] * in[1] + (long long)in[2] * in[2] - (long long)in[3] * in[3]) >> 15) + 1)));
            break;
        case 0x28: {
            // sqrt(x^2+y^2+z^2) through the chip's curve, not an integer root.
            // The sum of squares wraps in 32 bits, the same way the reference model does.
            int32_t x = in[0], y = in[1], z = in[2];
            uint32_t sum = (uint32_t)(x * x) + (uint32_t)(y * y) + (uint32_t)(z * z);
            if (sum == 0) { push(0); break; }
            int c = 0, e = 0;
            normalizeDouble((int32_t)sum, c, e);
            if (e & 1) c = s16((c * 0x4000) >> 15);
            int pos = (c * 0x0040) >> 15;
            if (pos < -64) pos = -64;
            if (pos > 63) pos = 63;
            int node1 = kSqrtNode[pos + 64];
            int node2 = kSqrtNode[pos + 65];
            int dist = s16(((node2 - node1) * (c & 0x1ff) >> 9) + node1);
            dist = s16(dist >> (e >> 1));
            push(dist);
            break;
        }
        case 0x0c: case 0x2c: {
            int s = sin16(in[0]), c = cos16(in[0]);
            push(s16((in[2] * s >> 15) + (in[1] * c >> 15)));
            push(s16((in[2] * c >> 15) - (in[1] * s >> 15)));
            break;
        }
        case 0x1c: case 0x3c:
            polar();
            break;
        case 0x14: case 0x34:
            gyrate();
            break;
        case 0x01: case 0x05: case 0x11: case 0x15:
        case 0x21: case 0x25: case 0x31: case 0x35:
            attitude(slotOf(op), in[0], in[1], in[2], in[3]);
            break;
        case 0x02: case 0x12: case 0x22: case 0x32:
            parameter();
            break;
        case 0x03: case 0x13: case 0x23: case 0x33:
            subjective(slotOf(op));
            break;
        case 0x09: case 0x0d: case 0x19: case 0x1d:
        case 0x29: case 0x2d: case 0x39: case 0x3d:
            objective(slotOf(op));
            break;
        case 0x0b: case 0x1b: case 0x2b: case 0x3b: {
            const int16_t* m = &matrix[slotOf(op)][0][0];
            push((((int)in[0] * m[0] + (int)in[1] * m[3] + (int)in[2] * m[6]) >> 15));
            break;
        }
        case 0x06: case 0x16: case 0x26: case 0x36:
            project();
            break;
        case 0x0a:
            vs = in[0];
            streaming = true;
            rasterAt(vs, nullptr);
            break;
        case 0x0e: case 0x1e: case 0x2e: case 0x3e:
            target();
            break;
        case 0x07: case 0x0f:
            push(0);
            break;
        case 0x27: case 0x2f:
            push(0x0100); // original DSP-1 version word
            break;
        default:
            break;
        }
        if(dscore::snesTraceEnabled && op != 0x0a)
            dscore::snesTraceDsp(op, in, got, out, nout, nullptr);
        if (dscore::snesDspLogArmed && op != 0x0a)
            dscore::snesDspLogWrite(op, in, got, out, nout);
    }

    uint16_t wordAt(int index) const {
        if (index >= 0 && index < nout) return (uint16_t)out[index];
        return 0;
    }

    void commandReady() {
        phase = 0;
        drc = true;
        drs = false;
        streaming = false;
        dr = 0x0080;
        dataCount = 0;
    }

    void finishCommand() {
        run();
        // 0x1F-family reads back a block of data words. The program ROM is absent, so the words are 0.
        wordsOut = (op == 0x17 || op == 0x1f || op == 0x37 || op == 0x3f) ? 1024 : nout;
        if (wordsOut <= 0) {
            commandReady();
            return;
        }
        phase = 2;
        drc = false;
        drs = false;
        dataCount = 0;
        dr = wordAt(0);
    }

    void beginCommand(uint8_t byte) {
        // 0x40-0xFF are not opcodes. 0x80 is the boot resync/NOP, not multiply.
        if (byte & 0xc0) {
            if (dscore::snesDspLogArmed) dscore::snesDspLogNop(byte);
            return;
        }
        op = byte;
        if (op == 0x1a || op == 0x2a || op == 0x3a) {
            freeze = true;
            if (dscore::snesTraceEnabled) dscore::snesTraceDsp(op, nullptr, 0, nullptr, 0, "freeze");
            if (dscore::snesDspLogArmed) dscore::snesDspLogWrite(op, nullptr, 0, nullptr, 0);
            return;
        }
        int inn = 0, outn = 0;
        counts(op, inn, outn);
        (void)outn;
        need = inn;
        got = 0;
        nout = 0;
        dataCount = 0;
        streaming = false;
        drc = false;
        drs = false;
        phase = 1;
        if (need <= 0) finishCommand();
    }

    // One data-register access. A command byte is 8-bit. Data words are low byte, then high byte.
    uint8_t access(bool read, uint8_t data) {
        if (freeze) return 0;
        if (read) data = drs ? (uint8_t)(dr >> 8) : (uint8_t)dr;
        else if (drs) dr = (uint16_t)((dr & 0x00ff) | (data << 8));
        else dr = (uint16_t)((dr & 0xff00) | data);

        if (phase == 0) {
            if (!read) beginCommand(data);
            return data;
        }

        drs = !drs;
        if (drs) return data;

        if (phase == 1) {
            if (got < 8) in[got] = (int16_t)dr;
            ++got;
            if (got >= need) finishCommand();
            return data;
        }

        // A completed word before the end of this line is discarded. The write
        // still consumes that output slot, so a mid-line $8000 does not end
        // the stream. $8000 ends it only when it is the word that finishes the line.
        ++dataCount;
        if (dataCount >= wordsOut) {
            if (streaming && op == 0x0a && !read && dr == 0x8000) {
                if (dscore::snesTraceEnabled) dscore::snesTraceDsp(0x8000, nullptr, 0, nullptr, 0, "raster end");
                commandReady();
                return data;
            }
            if (streaming && op == 0x0a) {
                vs = s16(vs + 1);
                rasterAt(vs, "next");
                wordsOut = nout;
                dataCount = 0;
                drs = false;
                dr = wordAt(0);
                return data;
            }
            commandReady();
            return data;
        }
        dr = wordAt(dataCount);
        return data;
    }

    uint8_t statusByte() const {
        if (freeze) return 0x04; // RQM clear, DRC stays set
        uint8_t s = 0x80;             // RQM: the result is already waiting
        if (drc) s |= 0x04;           // 8-bit command port; DRS reads as 0
        else if (drs) s |= 0x10;      // 16-bit port, high byte next
        return s;
    }

    void writeByte(uint8_t b) { access(false, b); }
    uint8_t readByte() { return access(true, 0); }
};

Chip chip;

} // namespace

void dsp1Reset() { chip.reset(); }
void dsp1Write(uint8_t data) {
    if (snesDspRawArmed) snesDspRawByte(1, data);
    chip.writeByte(data);
}
uint8_t dsp1Read() {
    uint8_t data = chip.readByte();
    if (snesDspRawArmed) snesDspRawByte(0, data);
    return data;
}
uint8_t dsp1Status() { return chip.statusByte(); }

} // namespace dscore
