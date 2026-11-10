// Copyright (c) 2026 Charlie Rodriguez Garcia. All rights reserved.
// Original clean-room 3D engine, written from the public GBATEK description of
// the DS geometry engine and rendering engine. Simplifications (documented in
// the README roadmap): commands execute instantly (no FIFO timing), the
// rasterizer uses floating point, no anti-aliasing, shadow polygons are skipped,
// box test always reports "visible", no rear-plane bitmap.
#include <climits>
#include <cstdlib>
#include "GPU3D.hpp"
#include <chrono>
#include <algorithm>
#include <cmath>
#include <cstring>
#if defined(__APPLE__)
#include <pthread.h>
#include <sys/qos.h>
#endif

namespace dscore {

namespace {
constexpr int kW = 256, kH = 192;
const u8 kParamCount[256] = {
    // 0x00..0x0F
    0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,
    // 0x10..0x1F
    1,0,1,1,1,0,16,12,16,12,9,3,3,0,0,0,
    // 0x20..0x2F
    1,1,1,2,1,1,1,1,1,1,1,1,0,0,0,0,
    // 0x30..0x3F
    1,1,1,1,32,0,0,0,0,0,0,0,0,0,0,0,
    // 0x40..0x4F
    1,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,
    // 0x50..
    1,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,
    1,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,
    3,2,1,0,0,0,0,0,0,0,0,0,0,0,0,0,
};
inline bool validCmd(u8 c) {
    return (c >= 0x10 && c <= 0x1C) || (c >= 0x20 && c <= 0x2B) || (c >= 0x30 && c <= 0x34) ||
           c == 0x40 || c == 0x41 || c == 0x50 || c == 0x60 || (c >= 0x70 && c <= 0x72);
}
inline s32 sext(u32 v, int bits) { return s32(v << (32 - bits)) >> (32 - bits); }
inline int c5to6(int c) { return c ? c * 2 + 1 : 0; }
} // namespace

GPU3D::GPU3D(const u8* aio, VRAM& vram)
    : aio_(aio), vram_(vram), out_(kW * kH), depth_(kW * kH), polyId_(kW * kH), flags_(kW * kH),
      r_(kW * kH), g_(kW * kH), b_(kW * kH), a_(kW * kH), hi_(kW * kH) {
    reset();
}

void GPU3D::setScale(int scale) {
    scale = std::clamp(scale, 1, 4);
    if (scale == scale_) return;
    scale_ = scale;
    reconfigure();
}

void GPU3D::setAntiAlias(AntiAlias m) {
    if (m == aa_) return;
    aa_ = m;
    reconfigure();
}

void GPU3D::reconfigure() {
    ss_ = aa_ == AntiAlias::Ssaa2x ? 2 : 1;
    W_ = kW * scale_ * ss_; H_ = kH * scale_ * ss_;
    OW_ = kW * scale_; OH_ = kH * scale_;
    size_t n = size_t(W_) * size_t(H_);
    depth_.assign(n, 0); polyId_.assign(n, 0); flags_.assign(n, 0);
    r_.assign(n, 0); g_.assign(n, 0); b_.assign(n, 0); a_.assign(n, 0);
    hi_.assign(size_t(OW_) * size_t(OH_), 0);
    // Upscale the current 1x picture so the first frame after a change is not blank.
    for (int y = 0; y < OH_; ++y)
        for (int x = 0; x < OW_; ++x) hi_[size_t(y) * size_t(OW_) + size_t(x)] = out_[size_t(y / scale_) * kW + size_t(x / scale_)];
}

GPU3D::~GPU3D() { setRenderThreads(0); }

namespace {
// One spin iteration: a CPU hint, so a waiting thread does not hog the core's pipeline.
inline void cpuRelax() {
#if defined(__aarch64__) || defined(__arm__)
    __asm__ __volatile__("yield");
#elif defined(__x86_64__) || defined(__i386__)
    __builtin_ia32_pause();
#endif
}
// The passes of one frame (clear+raster, edge marking, fog, output) arrive back to back, so
// pool threads poll for a few tens of microseconds before sleeping. Waking a sleeping thread
// costs far more than that on phones (the core may be parked), and it is paid on every pass.
constexpr int kSpin = 20000;   // roughly 20-60 us
} // namespace

void GPU3D::setRenderThreads(int n) {
    n = std::clamp(n, 0, 7);
    {
        std::lock_guard<std::mutex> lk(poolMutex_);
        poolStop_.store(true);
    }
    poolWake_.notify_all();
    for (auto& t : workers_) t.join();
    workers_.clear();
    poolStop_.store(false);
    // Each worker starts from the generation current *now* (on the calling thread, before any
    // new job). Reading it inside the new thread raced with the next runParallel: a thread that
    // started late took the new generation as "already seen", never ran it, and the caller waited
    // for it forever (frozen picture). (The older code started at 0 and could run a stale job.)
    const u64 startGen = jobGeneration_.load(std::memory_order_acquire);
    for (int i = 0; i < n; ++i) {
        workers_.emplace_back([this, startGen] {
#if defined(__APPLE__)
            // Same class as the emulation thread: the frame waits for these threads, so they
            // must not be scheduled like background work (efficiency cores, late wake-ups).
            pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0);
#endif
            u64 seen = startGen;
            for (;;) {
                u64 g = seen;
                for (int s = 0; s < kSpin; ++s) {
                    g = jobGeneration_.load(std::memory_order_acquire);
                    if (g != seen || poolStop_.load(std::memory_order_acquire)) break;
                    cpuRelax();
                }
                if (g == seen && !poolStop_.load(std::memory_order_acquire)) {
                    std::unique_lock<std::mutex> lk(poolMutex_);
                    poolWake_.wait(lk, [&] { return poolStop_.load() || jobGeneration_.load() != seen; });
                }
                if (poolStop_.load(std::memory_order_acquire)) return;
                seen = jobGeneration_.load(std::memory_order_acquire);
                runChunks(*job_);
                if (jobsLeft_.fetch_sub(1, std::memory_order_acq_rel) == 1) {
                    std::lock_guard<std::mutex> lk(poolMutex_);
                    poolDone_.notify_one();
                }
            }
        });
    }
}

// Threads pull small row chunks from a shared counter, so a screen whose polygons sit in
// one area still keeps every core busy (fixed bands left most threads idle).
void GPU3D::runChunks(const std::function<void(int, int)>& band) {
    for (;;) {
        int c = nextChunk_.fetch_add(1, std::memory_order_relaxed);
        if (c >= chunkCount_) return;
        int yb = c * chunkRows_;
        band(yb, std::min(H_, yb + chunkRows_));
    }
}

void GPU3D::runParallel(const std::function<void(int, int)>& band) {
    if (workers_.empty()) { band(0, H_); return; }
    int parts = int(workers_.size()) + 1;
    chunkRows_ = std::max(8, H_ / (parts * 4));
    chunkCount_ = (H_ + chunkRows_ - 1) / chunkRows_;
    nextChunk_.store(0, std::memory_order_relaxed);
    job_ = &band;
    jobsLeft_.store(int(workers_.size()), std::memory_order_relaxed);
    {
        std::lock_guard<std::mutex> lk(poolMutex_);   // publishes job_, chunk layout and count
        jobGeneration_.fetch_add(1, std::memory_order_acq_rel);
    }
    poolWake_.notify_all();
    runChunks(band);
    for (int s = 0; s < kSpin && jobsLeft_.load(std::memory_order_acquire) != 0; ++s) cpuRelax();
    if (jobsLeft_.load(std::memory_order_acquire) != 0) {
        std::unique_lock<std::mutex> lk(poolMutex_);
        // Timed wait as a safety net: if a wake-up was ever lost, wake the workers again instead of
        // blocking the emulation thread forever. Counted so the app can report it.
        while (!poolDone_.wait_for(lk, std::chrono::milliseconds(100),
                                   [&] { return jobsLeft_.load(std::memory_order_acquire) == 0; })) {
            poolStalls_.fetch_add(1, std::memory_order_relaxed);
            poolWake_.notify_all();
        }
    }
}

GPU3D::Mtx GPU3D::identity() { Mtx m{}; m.m[0] = m.m[5] = m.m[10] = m.m[15] = 0x1000; return m; }

void GPU3D::mul(Mtx& dst, const s32* a, const Mtx& b) {
    Mtx r;
    for (int i = 0; i < 4; ++i)
        for (int j = 0; j < 4; ++j) {
            s64 acc = 0;
            for (int k = 0; k < 4; ++k) acc += s64(a[i * 4 + k]) * b.m[k * 4 + j];
            r.m[i * 4 + j] = s32(acc >> 12);
        }
    dst = r;
}

void GPU3D::reset() {
    std::memset(regs_, 0, sizeof regs_);
    packCount_ = packIndex_ = paramCount_ = portCount_ = 0; portCmd_ = 0; halfLatch_ = 0;
    deferred_.clear();
    mtxMode_ = 0;
    proj_ = pos_ = vec_ = tex_ = clip_ = identity();
    projStack_ = texStack_ = identity();
    for (auto& m : posStack_) m = identity();
    for (auto& m : vecStack_) m = identity();
    projSP_ = posSP_ = texSP_ = 0; stackError_ = false; clipDirty_ = true;
    vx_ = vy_ = vz_ = 0;
    color_[0] = color_[1] = color_[2] = 31;
    texS_ = texT_ = rawS_ = rawT_ = 0;
    polyAttr_ = polyAttrActive_ = texParam_ = palBase_ = 0;
    diffuse_ = ambient_ = specular_ = emission_ = 0; useShininess_ = false;
    std::memset(shininess_, 0, sizeof shininess_);
    std::memset(light_, 0, sizeof light_); std::memset(lightColor_, 0, sizeof lightColor_);
    viewport_ = 0xBFFF0000u;
    primType_ = 0; inBegin_ = false; stripCount_ = stripParity_ = 0;
    std::memset(posTest_, 0, sizeof posTest_); std::memset(vecTest_, 0, sizeof vecTest_);
    boxResult_ = true; vertexCount_ = 0;
    polys_.clear(); swapPending_ = false; swapParam_ = 0; lastPolys_ = lastVerts_ = 0;
    renderPolys_.clear(); renderPending_ = false; renderSwapParam_ = 0;
    std::fill(out_.begin(), out_.end(), 0u);
}

// ------------------------------------------------------------------ I/O
void GPU3D::write(u32 off, u32 v, int size) {
    if (swapPending_ && off >= 0x400 && off < 0x600) {       // geometry stalls until VBlank
        if (deferred_.size() < (1u << 20)) { deferred_.push_back(off | (u32(size) << 28)); deferred_.push_back(v); }
        return;
    }
    if (off >= 0x400 && off < 0x600) {
        u32 word;
        if (size == 4) word = v;
        else if (size == 2) {                                 // halfword writes: commit on the upper half
            if (!(off & 2)) { halfLatch_ = (halfLatch_ & 0xFFFF0000u) | (v & 0xFFFF); return; }
            word = (halfLatch_ & 0xFFFF) | (v << 16); off &= ~3u;
        } else return;
        if (off < 0x440) packedWrite(word);
        else portWrite(u8((off - 0x400) >> 2), word);
        return;
    }
    if (off >= 0x600 && off < 0x604) {                       // GXSTAT: IRQ mode bits 30-31, bit 15 acks errors
        for (int i = 0; i < size; ++i) {
            u32 o = off + u32(i); u8 b = u8(v >> (8 * i));
            if (o == 0x601 && (b & 0x80)) { stackError_ = false; projSP_ = 0; }
            if (o == 0x603) regs_[0x303] = u8(b & 0xC0);
        }
        return;
    }
    if (off >= 0x300 && off < 0x700)
        for (int i = 0; i < size && off + i < 0x700; ++i) regs_[off + i - 0x300] = u8(v >> (8 * i));
}

u32 GPU3D::read(u32 off, int size) const {
    u32 v = 0;
    auto get = [&](u32 o) -> u8 {
        u32 word = 0, base = o & ~3u;
        if (base == 0x600) {
            word = (boxResult_ ? 2u : 0u) | (u32(posSP_ & 31) << 8) | (u32(projSP_ & 1) << 13) |
                   (stackError_ ? 0x8000u : 0u) | (1u << 25) | (1u << 26) | (swapPending_ ? (1u << 27) : 0u) |
                   (u32(regs_[0x303] & 0xC0) << 24);
        } else if (base == 0x604) {
            word = u32(std::min<size_t>(polys_.size(), kMaxPolys)) | (u32(std::min(vertexCount_, kMaxVerts)) << 16);
        } else if (base >= 0x620 && base < 0x630) word = u32(posTest_[(base - 0x620) / 4]);
        else if (base >= 0x630 && base < 0x636) {
            u32 i = (base - 0x630) / 2; word = u16(vecTest_[std::min(i, 2u)]) | (u32(u16(vecTest_[std::min(i + 1, 2u)])) << 16);
            if (o & 2) word = u16(vecTest_[std::min((o - 0x630) / 2, 2u)]) << 16;
        } else if (base >= 0x640 && base < 0x680) {
            const_cast<GPU3D*>(this)->updateClip();
            word = u32(clip_.m[(base - 0x640) / 4]);
        } else if (base >= 0x680 && base < 0x6A4) {
            u32 i = (base - 0x680) / 4; word = u32(vec_.m[(i / 3) * 4 + (i % 3)]);
        } else return regs_[o - 0x300];
        return u8(word >> ((o & 3) * 8));
    };
    for (int i = 0; i < size; ++i) v |= u32(get(off + u32(i))) << (8 * i);
    return v;
}

bool GPU3D::irqPending() const {
    u32 mode = regs_[0x303] >> 6;
    return mode == 1 || mode == 2;                        // FIFO is always empty / less than half full
}

void GPU3D::vblank() {
    if (!swapPending_) return;
    swapPending_ = false;
    renderPolys_.swap(polys_);
    renderSwapParam_ = swapParam_;
    renderPending_ = true;
    lastPolys_ = int(renderPolys_.size()); lastVerts_ = vertexCount_;
    polys_.clear(); vertexCount_ = 0;
    std::vector<u32> d; d.swap(deferred_);
    for (size_t i = 0; i + 1 < d.size(); i += 2) {
        write(d[i] & 0x0FFFFFFFu, d[i + 1], int(d[i] >> 28));
        if (swapPending_) {                                   // another swap: keep the rest for next VBlank
            deferred_.insert(deferred_.end(), d.begin() + long(i) + 2, d.end());
            break;
        }
    }
}

void GPU3D::renderPending(bool skip) {
    // When the next picture is skipped, keep the latched list pending instead of dropping it.
    // Games that swap 3D buffers every other frame (30 fps titles) otherwise lost whole 3D frames
    // under frame skip: the next drawn picture reused stale 3D, so motion stuttered at 15-20 fps.
    if (!renderPending_ || skip) return;
    renderPending_ = false;
    render();
}

void GPU3D::packedWrite(u32 v) {
    if (packCount_ == 0) {                                    // new packet of up to 4 commands
        packCount_ = 0; packIndex_ = 0; paramCount_ = 0;
        for (int i = 0; i < 4; ++i) packCmds_[packCount_++] = u8(v >> (8 * i));
        while (packCount_ > 0 && packCmds_[packCount_ - 1] == 0) --packCount_;   // trailing NOPs
        // Execute leading zero-parameter commands.
        while (packIndex_ < packCount_ && kParamCount[packCmds_[packIndex_]] == 0) {
            if (validCmd(packCmds_[packIndex_])) command(packCmds_[packIndex_], params_);
            ++packIndex_;
        }
        if (packIndex_ >= packCount_) packCount_ = 0;
        return;
    }
    params_[paramCount_++] = v;
    u8 c = packCmds_[packIndex_];
    if (paramCount_ >= kParamCount[c]) {
        if (validCmd(c)) command(c, params_);
        paramCount_ = 0; ++packIndex_;
        while (packIndex_ < packCount_ && kParamCount[packCmds_[packIndex_]] == 0) {
            if (validCmd(packCmds_[packIndex_])) command(packCmds_[packIndex_], params_);
            ++packIndex_;
        }
        if (packIndex_ >= packCount_) packCount_ = 0;
    }
}

void GPU3D::portWrite(u8 c, u32 v) {
    if (!validCmd(c)) return;
    if (kParamCount[c] == 0) { command(c, params_); return; }
    if (portCmd_ != c) { portCmd_ = c; portCount_ = 0; }
    portParams_[portCount_++] = v;
    if (portCount_ >= kParamCount[c]) { command(c, portParams_); portCount_ = 0; }
}

// -------------------------------------------------------------- geometry
void GPU3D::updateClip() {
    if (!clipDirty_) return;
    mul(clip_, pos_.m, proj_);
    clipDirty_ = false;
}

void GPU3D::command(u8 cmd, const u32* p) {
    auto curMtx = [&](auto fn) {                               // apply fn to the matrices selected by MTX_MODE
        switch (mtxMode_) {
        case 0: fn(proj_); clipDirty_ = true; break;
        case 1: fn(pos_); clipDirty_ = true; break;
        case 2: fn(pos_); fn(vec_); clipDirty_ = true; break;
        default: fn(tex_); break;
        }
    };
    switch (cmd) {
    case 0x10: mtxMode_ = p[0] & 3; break;
    case 0x11:                                                // MTX_PUSH
        if (mtxMode_ == 0) { if (projSP_ >= 1) stackError_ = true; projStack_ = proj_; projSP_ = std::min(projSP_ + 1, 1); }
        else if (mtxMode_ == 3) { texStack_ = tex_; texSP_ = 1; }
        else { if (posSP_ >= 31) stackError_ = true; posStack_[posSP_ & 31] = pos_; vecStack_[posSP_ & 31] = vec_; posSP_ = std::min(posSP_ + 1, 31); }
        break;
    case 0x12: {                                              // MTX_POP
        if (mtxMode_ == 0) { projSP_ = std::max(projSP_ - 1, 0); proj_ = projStack_; clipDirty_ = true; }
        else if (mtxMode_ == 3) { tex_ = texStack_; texSP_ = 0; }
        else {
            int n = sext(p[0], 6); int sp = posSP_ - n;
            if (sp < 0 || sp > 30) stackError_ = true;
            posSP_ = std::clamp(sp, 0, 31);
            pos_ = posStack_[posSP_ & 31]; vec_ = vecStack_[posSP_ & 31]; clipDirty_ = true;
        }
        break;
    }
    case 0x13: {                                              // MTX_STORE
        if (mtxMode_ == 0) projStack_ = proj_;
        else if (mtxMode_ == 3) texStack_ = tex_;
        else { int i = int(p[0] & 31); if (i == 31) stackError_ = true; posStack_[i] = pos_; vecStack_[i] = vec_; }
        break;
    }
    case 0x14: {                                              // MTX_RESTORE
        if (mtxMode_ == 0) { proj_ = projStack_; clipDirty_ = true; }
        else if (mtxMode_ == 3) tex_ = texStack_;
        else { int i = int(p[0] & 31); if (i == 31) stackError_ = true; pos_ = posStack_[i]; vec_ = vecStack_[i]; clipDirty_ = true; }
        break;
    }
    case 0x15: curMtx([](Mtx& m) { m = identity(); }); break;
    case 0x16: curMtx([&](Mtx& m) { for (int i = 0; i < 16; ++i) m.m[i] = s32(p[i]); }); break;
    case 0x17: curMtx([&](Mtx& m) {
        for (int r = 0; r < 4; ++r) for (int c = 0; c < 3; ++c) m.m[r * 4 + c] = s32(p[r * 3 + c]);
        m.m[3] = m.m[7] = m.m[11] = 0; m.m[15] = 0x1000; }); break;
    case 0x18: { s32 a[16]; for (int i = 0; i < 16; ++i) a[i] = s32(p[i]); curMtx([&](Mtx& m) { mul(m, a, m); }); break; }
    case 0x19: {
        s32 a[16] = {}; for (int r = 0; r < 4; ++r) for (int c = 0; c < 3; ++c) a[r * 4 + c] = s32(p[r * 3 + c]);
        a[15] = 0x1000; curMtx([&](Mtx& m) { mul(m, a, m); }); break;
    }
    case 0x1A: {
        s32 a[16] = {}; for (int r = 0; r < 3; ++r) for (int c = 0; c < 3; ++c) a[r * 4 + c] = s32(p[r * 3 + c]);
        a[15] = 0x1000; curMtx([&](Mtx& m) { mul(m, a, m); }); break;
    }
    case 0x1B: {                                              // MTX_SCALE (not applied to the vector matrix)
        s32 a[16] = {}; a[0] = s32(p[0]); a[5] = s32(p[1]); a[10] = s32(p[2]); a[15] = 0x1000;
        if (mtxMode_ == 2) { mul(pos_, a, pos_); clipDirty_ = true; }
        else curMtx([&](Mtx& m) { mul(m, a, m); });
        break;
    }
    case 0x1C: {                                              // MTX_TRANS
        s32 a[16] = {}; a[0] = a[5] = a[10] = a[15] = 0x1000; a[12] = s32(p[0]); a[13] = s32(p[1]); a[14] = s32(p[2]);
        curMtx([&](Mtx& m) { mul(m, a, m); });
        break;
    }
    case 0x20: color_[0] = p[0] & 31; color_[1] = (p[0] >> 5) & 31; color_[2] = (p[0] >> 10) & 31; break;
    case 0x21: {                                              // NORMAL
        s32 nx = sext(p[0] & 0x3FF, 10) << 3, ny = sext((p[0] >> 10) & 0x3FF, 10) << 3, nz = sext((p[0] >> 20) & 0x3FF, 10) << 3;
        if ((texParam_ >> 30) == 2) {                         // texture coordinates from the normal
            s64 s = (s64(nx) * tex_.m[0] + s64(ny) * tex_.m[4] + s64(nz) * tex_.m[8]) >> 20;
            s64 t = (s64(nx) * tex_.m[1] + s64(ny) * tex_.m[5] + s64(nz) * tex_.m[9]) >> 20;
            texS_ = s16(rawS_ + s); texT_ = s16(rawT_ + t);
        }
        computeLighting(nx, ny, nz);
        break;
    }
    case 0x22: {                                              // TEXCOORD
        rawS_ = s16(p[0] & 0xFFFF); rawT_ = s16(p[0] >> 16);
        if ((texParam_ >> 30) == 1) {
            texS_ = s16((s64(rawS_) * tex_.m[0] + s64(rawT_) * tex_.m[4] + tex_.m[8] + tex_.m[12]) >> 12);
            texT_ = s16((s64(rawS_) * tex_.m[1] + s64(rawT_) * tex_.m[5] + tex_.m[9] + tex_.m[13]) >> 12);
        } else { texS_ = rawS_; texT_ = rawT_; }
        break;
    }
    case 0x23: addVertex(sext(p[0] & 0xFFFF, 16), sext(p[0] >> 16, 16), sext(p[1] & 0xFFFF, 16)); break;
    case 0x24: addVertex(sext(p[0] & 0x3FF, 10) << 6, sext((p[0] >> 10) & 0x3FF, 10) << 6, sext((p[0] >> 20) & 0x3FF, 10) << 6); break;
    case 0x25: addVertex(sext(p[0] & 0xFFFF, 16), sext(p[0] >> 16, 16), vz_); break;
    case 0x26: addVertex(sext(p[0] & 0xFFFF, 16), vy_, sext(p[0] >> 16, 16)); break;
    case 0x27: addVertex(vx_, sext(p[0] & 0xFFFF, 16), sext(p[0] >> 16, 16)); break;
    case 0x28: addVertex(vx_ + sext(p[0] & 0x3FF, 10), vy_ + sext((p[0] >> 10) & 0x3FF, 10), vz_ + sext((p[0] >> 20) & 0x3FF, 10)); break;
    case 0x29: polyAttr_ = p[0]; break;
    case 0x2A: texParam_ = p[0]; break;
    case 0x2B: palBase_ = p[0] & 0x1FFF; break;
    case 0x30:
        diffuse_ = p[0] & 0x7FFF; ambient_ = (p[0] >> 16) & 0x7FFF;
        if (p[0] & 0x8000) { color_[0] = diffuse_ & 31; color_[1] = (diffuse_ >> 5) & 31; color_[2] = (diffuse_ >> 10) & 31; }
        break;
    case 0x31: specular_ = p[0] & 0x7FFF; emission_ = (p[0] >> 16) & 0x7FFF; useShininess_ = p[0] & 0x8000; break;
    case 0x32: {                                              // LIGHT_VECTOR (transformed by the vector matrix)
        int i = int(p[0] >> 30);
        s32 l[3] = {sext(p[0] & 0x3FF, 10) << 3, sext((p[0] >> 10) & 0x3FF, 10) << 3, sext((p[0] >> 20) & 0x3FF, 10) << 3};
        for (int c = 0; c < 3; ++c) light_[i][c] = s32((s64(l[0]) * vec_.m[c] + s64(l[1]) * vec_.m[4 + c] + s64(l[2]) * vec_.m[8 + c]) >> 12);
        break;
    }
    case 0x33: lightColor_[p[0] >> 30] = p[0] & 0x7FFF; break;
    case 0x34: for (int i = 0; i < 32; ++i) for (int k = 0; k < 4; ++k) shininess_[i * 4 + k] = u8(p[i] >> (8 * k)); break;
    case 0x40: primType_ = p[0] & 3; inBegin_ = true; stripCount_ = 0; stripParity_ = 0; polyAttrActive_ = polyAttr_; break;
    case 0x41: inBegin_ = false; break;
    case 0x50: swapPending_ = true; swapParam_ = p[0] & 3; break;
    case 0x60: viewport_ = p[0]; break;
    case 0x70: boxResult_ = true; break;
    case 0x71: {                                              // POS_TEST
        vx_ = sext(p[0] & 0xFFFF, 16); vy_ = sext(p[0] >> 16, 16); vz_ = sext(p[1] & 0xFFFF, 16);
        updateClip();
        for (int c = 0; c < 4; ++c)
            posTest_[c] = s32((s64(vx_) * clip_.m[c] + s64(vy_) * clip_.m[4 + c] + s64(vz_) * clip_.m[8 + c] + s64(0x1000) * clip_.m[12 + c]) >> 12);
        if (widescreen_) posTest_[0] = posTest_[0] * 3 / 4;
        break;
    }
    case 0x72: {                                              // VEC_TEST
        s32 n[3] = {sext(p[0] & 0x3FF, 10) << 3, sext((p[0] >> 10) & 0x3FF, 10) << 3, sext((p[0] >> 20) & 0x3FF, 10) << 3};
        for (int c = 0; c < 3; ++c) {
            s32 v = s32((s64(n[0]) * vec_.m[c] + s64(n[1]) * vec_.m[4 + c] + s64(n[2]) * vec_.m[8 + c]) >> 12);
            vecTest_[c] = s16(sext(u32(v) & 0x1FFF, 13));
        }
        break;
    }
    default: break;
    }
}

void GPU3D::computeLighting(s32 nx, s32 ny, s32 nz) {
    s32 n[3];
    for (int c = 0; c < 3; ++c) n[c] = s32((s64(nx) * vec_.m[c] + s64(ny) * vec_.m[4 + c] + s64(nz) * vec_.m[8 + c]) >> 12);
    s32 out[3];
    for (int c = 0; c < 3; ++c) out[c] = (emission_ >> (5 * c)) & 31;
    for (int i = 0; i < 4; ++i) {
        if (!(polyAttr_ & (1u << i))) continue;
        s32 dot = s32((s64(light_[i][0]) * n[0] + s64(light_[i][1]) * n[1] + s64(light_[i][2]) * n[2]) >> 12);
        s32 diff = std::clamp(-dot, 0, 0x1000);
        // Half-way vector between the light and the line of sight (0,0,-1).
        s32 h[3] = {light_[i][0] / 2, light_[i][1] / 2, (light_[i][2] - 0x1000) / 2};
        s32 hd = s32((s64(h[0]) * n[0] + s64(h[1]) * n[1] + s64(h[2]) * n[2]) >> 12);
        s32 spec = std::clamp(-hd, 0, 0x1000);
        spec = s32((s64(spec) * spec) >> 12);
        if (useShininess_) spec = s32(shininess_[std::min(spec >> 5, 127)]) << 4;
        for (int c = 0; c < 3; ++c) {
            s32 lc = (lightColor_[i] >> (5 * c)) & 31;
            s32 d = (diffuse_ >> (5 * c)) & 31, a = (ambient_ >> (5 * c)) & 31, s = (specular_ >> (5 * c)) & 31;
            out[c] += ((s * lc * spec) >> 17) + ((d * lc * diff) >> 17) + ((a * lc) >> 5);
        }
    }
    for (int c = 0; c < 3; ++c) color_[c] = u8(std::clamp(out[c], 0, 31));
}

void GPU3D::addVertex(s32 x, s32 y, s32 z) {
    vx_ = x; vy_ = y; vz_ = z;
    if (!inBegin_) return;
    updateClip();
    s64 cv[4];
    for (int c = 0; c < 4; ++c)
        cv[c] = (s64(x) * clip_.m[c] + s64(y) * clip_.m[4 + c] + s64(z) * clip_.m[8 + c] + s64(0x1000) * clip_.m[12 + c]) >> 12;
    if ((texParam_ >> 30) == 3) {                             // texture coordinates from the vertex position
        texS_ = s16(rawS_ + ((s64(x) * tex_.m[0] + s64(y) * tex_.m[4] + s64(z) * tex_.m[8]) >> 24));
        texT_ = s16(rawT_ + ((s64(x) * tex_.m[1] + s64(y) * tex_.m[5] + s64(z) * tex_.m[9]) >> 24));
    }
    if (widescreen_) cv[0] = cv[0] * 3 / 4;
    Vtx v;
    v.x = float(cv[0]); v.y = float(cv[1]); v.z = float(cv[2]); v.w = float(cv[3]);
    v.r = float(c5to6(color_[0])); v.g = float(c5to6(color_[1])); v.b = float(c5to6(color_[2]));
    v.s = texS_ / 16.0f; v.t = texT_ / 16.0f;
    strip_[stripCount_++] = v;
    switch (primType_) {
    case 0:                                                   // separate triangles
        if (stripCount_ == 3) { emitPolygon(strip_, 3); stripCount_ = 0; }
        break;
    case 1:                                                   // separate quads
        if (stripCount_ == 4) { emitPolygon(strip_, 4); stripCount_ = 0; }
        break;
    case 2:                                                   // triangle strip
        if (stripCount_ == 3) {
            if (stripParity_) { Vtx t[3] = {strip_[1], strip_[0], strip_[2]}; emitPolygon(t, 3); }
            else emitPolygon(strip_, 3);
            stripParity_ ^= 1;
            strip_[0] = strip_[1]; strip_[1] = strip_[2]; stripCount_ = 2;
        }
        break;
    default:                                                  // quad strip: v0 v1 v3 v2
        if (stripCount_ == 4) {
            Vtx q[4] = {strip_[0], strip_[1], strip_[3], strip_[2]};
            emitPolygon(q, 4);
            strip_[0] = strip_[2]; strip_[1] = strip_[3]; stripCount_ = 2;
        }
        break;
    }
}

void GPU3D::emitPolygon(const Vtx* in, int n) {
    ++stats.submitted;
    if (polys_.size() >= size_t(kMaxPolys)) { ++stats.overflow; return; }
    u32 attr = polyAttrActive_;
    if (((attr >> 4) & 3) == 3) { ++stats.shadow; return; }                       // shadow polygons: not supported yet
    // Far-plane handling: polygons crossing it are dropped unless attr bit 12.
    bool crossesFar = false;
    for (int i = 0; i < n; ++i) if (in[i].z > in[i].w) crossesFar = true;
    if (crossesFar && !(attr & (1u << 12))) { ++stats.farDropped; return; }

    // Sutherland-Hodgman clipping against the 6 planes of the view volume.
    Vtx buf[2][10]; int cnt = n;
    std::copy(in, in + n, buf[0]);
    int cur = 0;
    for (int plane = 0; plane < 6 && cnt > 0; ++plane) {
        int axis = plane >> 1; float sign = (plane & 1) ? -1.0f : 1.0f;
        auto dist = [&](const Vtx& v) { float c = axis == 0 ? v.x : axis == 1 ? v.y : v.z; return v.w - sign * c; };
        int outN = 0;
        for (int i = 0; i < cnt && outN < 10; ++i) {
            const Vtx& a = buf[cur][i]; const Vtx& b = buf[cur][(i + 1) % cnt];
            float da = dist(a), db = dist(b);
            if (da >= 0) buf[cur ^ 1][outN++] = a;
            if ((da >= 0) != (db >= 0) && outN < 10) {
                float t = da / (da - db);
                Vtx m;
                m.x = a.x + (b.x - a.x) * t; m.y = a.y + (b.y - a.y) * t; m.z = a.z + (b.z - a.z) * t; m.w = a.w + (b.w - a.w) * t;
                m.r = a.r + (b.r - a.r) * t; m.g = a.g + (b.g - a.g) * t; m.b = a.b + (b.b - a.b) * t;
                m.s = a.s + (b.s - a.s) * t; m.t = a.t + (b.t - a.t) * t;
                buf[cur ^ 1][outN++] = m;
            }
        }
        cnt = outN; cur ^= 1;
    }
    if (cnt < 3) { ++stats.clippedAway; return; }

    // Viewport transform to screen space (x,y in pixels, z = NDC depth, w kept).
    float x1 = float(viewport_ & 0xFF), y1 = float((viewport_ >> 8) & 0xFF);
    float x2 = float((viewport_ >> 16) & 0xFF), y2 = float(viewport_ >> 24);
    float vw = x2 - x1 + 1, vh = y2 - y1 + 1;
    Poly p;
    p.n = cnt;
    for (int i = 0; i < cnt; ++i) {
        Vtx v = buf[cur][i];
        float w = v.w <= 0 ? 1e-6f : v.w;
        v.x = (v.x / w + 1.0f) * vw * 0.5f + x1;
        v.y = 192.0f - ((v.y / w + 1.0f) * vh * 0.5f + y1);
        v.z = v.z / w;
        v.w = w;
        p.v[i] = v;
    }
    // Culling by screen-space winding. With y growing downwards, a negative shoelace sum is the
    // front face (verified against a commercial title: the opposite sign culled all track ground).
    float area = 0;
    for (int i = 0; i < cnt; ++i) { const Vtx& a = p.v[i]; const Vtx& b = p.v[(i + 1) % cnt]; area += a.x * b.y - b.x * a.y; }
    bool front = area <= 0;
    if (front && !(attr & 0x80)) { ++stats.culled; return; }
    if (!front && !(attr & 0x40)) { ++stats.culled; return; }

    // Vertex RAM holds the vertices of stored polygons (strips share theirs; approximated per polygon).
    if (vertexCount_ + cnt > kMaxVerts) { ++stats.overflow; return; }
    vertexCount_ += cnt;
    p.attr = attr; p.texParam = texParam_; p.palBase = palBase_;
    u32 alpha = (attr >> 16) & 31, fmt = (texParam_ >> 26) & 7;
    p.translucent = (alpha != 0 && alpha != 31) || fmt == 1 || fmt == 6;
    p.wBuffer = false;
    polys_.push_back(p);
}

// -------------------------------------------------------------- rendering
bool GPU3D::sampleTexture(const Poly& p, float fs, float ft, int& R, int& G, int& B, int& A) const {
    u32 fmt = (p.texParam >> 26) & 7;
    if (!texFilter_ || fmt == 0)
        return sampleTexel(p, s32(std::floor(fs)), s32(std::floor(ft)), R, G, B, A);
    // Optional bilinear filtering (enhancement): weighted average of the 4 nearest texels.
    // Formats with 1-bit transparency keep a hard (but smoothed) cut-out edge at 50 % coverage;
    // A3I5 / A5I3 blend their alpha.
    float u = fs - 0.5f, v = ft - 0.5f;
    s32 s0 = s32(std::floor(u)), t0 = s32(std::floor(v));
    float fu = u - float(s0), fv = v - float(t0);
    float wsum = 0, r = 0, g = 0, b = 0, a = 0;
    const float wt[4] = {(1 - fu) * (1 - fv), fu * (1 - fv), (1 - fu) * fv, fu * fv};
    for (int k = 0; k < 4; ++k) {
        int tr, tg, tb, ta;
        if (!sampleTexel(p, s0 + (k & 1), t0 + (k >> 1), tr, tg, tb, ta)) continue;
        float w = wt[k] * float(ta);
        r += float(tr) * w; g += float(tg) * w; b += float(tb) * w;
        a += w; wsum += wt[k];
    }
    bool alphaFormat = fmt == 1 || fmt == 6;
    if (alphaFormat ? a <= 0.0f : wsum < 0.5f) return false;
    R = int(r / a + 0.5f); G = int(g / a + 0.5f); B = int(b / a + 0.5f);
    A = alphaFormat ? int(a + 0.5f) : 31;
    return A > 0;
}

bool GPU3D::sampleTexel(const Poly& p, s32 s, s32 t, int& R, int& G, int& B, int& A) const {
    u32 tp = p.texParam, fmt = (tp >> 26) & 7;
    u32 w = 8u << ((tp >> 20) & 7), h = 8u << ((tp >> 23) & 7);
    auto wrapc = [](s32 c, u32 size, bool repeat, bool flip) -> u32 {
        if (!repeat) return u32(std::clamp(c, 0, s32(size) - 1));
        if (flip) { u32 m = u32(c) & (size * 2 - 1); return m >= size ? size * 2 - 1 - m : m; }
        return u32(c) & (size - 1);
    };
    u32 us = wrapc(s, w, tp & (1u << 16), tp & (1u << 18));
    u32 ut = wrapc(t, h, tp & (1u << 17), tp & (1u << 19));
    u32 base = (tp & 0xFFFF) * 8u;
    u32 texel = ut * w + us;
    bool zeroTransparent = tp & (1u << 29);
    u32 palAddr = p.palBase * 16u;
    u16 c = 0; A = 31;
    switch (fmt) {
    case 1: {                                                 // A3I5
        u8 v = tex8(base + texel);
        c = texPal(palAddr + (v & 31) * 2u);
        u32 a3 = v >> 5; A = int((a3 << 2) + (a3 >> 1));
        break;
    }
    case 2: {                                                 // 4-colour
        u8 v = tex8(base + texel / 4); u32 idx = (v >> ((texel & 3) * 2)) & 3;
        if (zeroTransparent && idx == 0) return false;
        c = texPal(p.palBase * 8u + idx * 2u);
        break;
    }
    case 3: {                                                 // 16-colour
        u8 v = tex8(base + texel / 2); u32 idx = (texel & 1) ? (v >> 4) : (v & 15);
        if (zeroTransparent && idx == 0) return false;
        c = texPal(palAddr + idx * 2u);
        break;
    }
    case 4: {                                                 // 256-colour
        u8 idx = tex8(base + texel);
        if (zeroTransparent && idx == 0) return false;
        c = texPal(palAddr + idx * 2u);
        break;
    }
    case 5: {                                                 // 4x4 compressed
        u32 block = (ut / 4) * (w / 4) + (us / 4);
        u32 addr = base + block * 4;
        u8 row = tex8(addr + (ut & 3));
        u32 idx = (row >> ((us & 3) * 2)) & 3;
        u32 slot = (addr >> 17) & 3;
        u16 info = u16(tex8(0x20000u + ((addr & 0x1FFFC) >> 1) + (slot == 2 ? 0x10000u : 0u)) |
                   (tex8(0x20000u + ((addr & 0x1FFFC) >> 1) + (slot == 2 ? 0x10000u : 0u) + 1) << 8));
        u32 pa = palAddr + (info & 0x3FFF) * 4u, mode = info >> 14;
        auto col = [&](u32 i) { return texPal(pa + i * 2); };
        auto mix = [](u16 a, u16 b, int wa, int wb, int div) {
            u16 o = 0;
            for (int sh = 0; sh < 15; sh += 5) o |= u16(((((a >> sh) & 31) * wa + ((b >> sh) & 31) * wb) / div) << sh);
            return o;
        };
        switch (idx) {
        case 0: c = col(0); break;
        case 1: c = col(1); break;
        case 2: c = mode == 1 ? mix(col(0), col(1), 1, 1, 2) : mode == 3 ? mix(col(0), col(1), 5, 3, 8) : col(2); break;
        default:
            if (mode == 0 || mode == 1) return false;
            c = mode == 3 ? mix(col(0), col(1), 3, 5, 8) : col(3);
            break;
        }
        break;
    }
    case 6: {                                                 // A5I3
        u8 v = tex8(base + texel);
        c = texPal(palAddr + (v & 7) * 2u);
        A = v >> 3;
        break;
    }
    case 7: {                                                 // direct colour
        c = u16(tex8(base + texel * 2) | (tex8(base + texel * 2 + 1) << 8));
        if (!(c & 0x8000)) return false;
        break;
    }
    default: R = G = B = 63; A = 31; return true;
    }
    R = c5to6(c & 31); G = c5to6((c >> 5) & 31); B = c5to6((c >> 10) & 31);
    return A > 0;
}

void GPU3D::render() {
    u32 cnt = disp3dcnt();
    bool wbuf = renderSwapParam_ & 2;
    // Rear plane
    u32 cc = reg32(0x350);
    u16 cdepth = reg16(0x354) & 0x7FFF;
    u32 clearDepth = (u32(cdepth) << 9) | (cdepth == 0x7FFF ? 0x1FFu : 0u);
    int cr = c5to6(cc & 31), cg = c5to6((cc >> 5) & 31), cb = c5to6((cc >> 10) & 31), ca = int((cc >> 16) & 31);
    for (auto& p : renderPolys_) {
        p.wBuffer = wbuf;
        const float rs = float(scale_ * ss_);
        if (rs > 1) for (int i = 0; i < p.n; ++i) { p.v[i].x *= rs; p.v[i].y *= rs; }
    }
    // Opaque polygons first, then translucent ones (sorted by top Y unless manual sort).
    std::vector<const Poly*>& order = order_;
    order.clear();
    order.reserve(renderPolys_.size());
    for (auto& p : renderPolys_) if (!p.translucent) order.push_back(&p);
    size_t firstTrans = order.size();
    for (auto& p : renderPolys_) if (p.translucent) order.push_back(&p);
    if (!(renderSwapParam_ & 1)) {
        std::stable_sort(order.begin() + long(firstTrans), order.end(), [](const Poly* a, const Poly* b) {
            float ya = 1e9f, yb = 1e9f;
            for (int i = 0; i < a->n; ++i) ya = std::min(ya, a->v[i].y);
            for (int i = 0; i < b->n; ++i) yb = std::min(yb, b->v[i].y);
            return ya < yb;
        });
    }
    // Clear + rasterize in independent horizontal bands (one per worker thread).
    u8 clearId = u8((cc >> 24) & 63), clearFlags = u8((cc & 0x8000) ? 2 : 0);
    runParallel([&](int yb, int ye) {
        size_t a = size_t(yb) * size_t(W_), e = size_t(ye) * size_t(W_);
        std::fill(r_.begin() + long(a), r_.begin() + long(e), u8(cr)); std::fill(g_.begin() + long(a), g_.begin() + long(e), u8(cg));
        std::fill(b_.begin() + long(a), b_.begin() + long(e), u8(cb)); std::fill(a_.begin() + long(a), a_.begin() + long(e), u8(ca));
        std::fill(depth_.begin() + long(a), depth_.begin() + long(e), clearDepth);
        std::fill(polyId_.begin() + long(a), polyId_.begin() + long(e), clearId);
        std::fill(flags_.begin() + long(a), flags_.begin() + long(e), clearFlags);
        for (const Poly* p : order) rasterize(*p, yb, ye);
    });

    // Edge marking: opaque pixels bordering a different polygon ID that lies behind.
    if (cnt & 0x20) {
        emR_.resize(r_.size()); emG_.resize(g_.size()); emB_.resize(b_.size());   // reuses capacity
        u8 ecR[8], ecG[8], ecB[8];
        for (int k = 0; k < 8; ++k) { u16 ec = reg16(0x330 + k * 2); ecR[k] = u8(c5to6(ec & 31)); ecG[k] = u8(c5to6((ec >> 5) & 31)); ecB[k] = u8(c5to6((ec >> 10) & 31)); }
        runParallel([&](int yb, int ye) {
            size_t a = size_t(yb) * size_t(W_), e = size_t(ye) * size_t(W_);   // copy this band (was serial)
            std::copy(r_.begin() + long(a), r_.begin() + long(e), emR_.begin() + long(a));
            std::copy(g_.begin() + long(a), g_.begin() + long(e), emG_.begin() + long(a));
            std::copy(b_.begin() + long(a), b_.begin() + long(e), emB_.begin() + long(a));
            for (int y = yb; y < ye; ++y)
                for (int x = 0; x < W_; ++x) {
                    int i = y * W_ + x;
                    if (!(flags_[i] & 4) || (flags_[i] & 1)) continue;
                    const int nx[4] = {x - 1, x + 1, x, x}, ny[4] = {y, y, y - 1, y + 1};
                    for (int k = 0; k < 4; ++k) {
                        if (nx[k] < 0 || nx[k] >= W_ || ny[k] < 0 || ny[k] >= H_) continue;
                        int j = ny[k] * W_ + nx[k];
                        if (polyId_[j] != polyId_[i] && depth_[j] > depth_[i]) {
                            int e = polyId_[i] >> 3;
                            emR_[i] = ecR[e]; emG_[i] = ecG[e]; emB_[i] = ecB[e];
                            break;
                        }
                    }
                }
        });
        r_.swap(emR_); g_.swap(emG_); b_.swap(emB_);
    }
    // Fog
    if (cnt & 0x80) {
        u32 fc = reg32(0x358);
        int fr = c5to6(fc & 31), fg = c5to6((fc >> 5) & 31), fb = c5to6((fc >> 10) & 31), fa = int((fc >> 16) & 31);
        u32 offset = reg16(0x35C) & 0x7FFF, shift = (cnt >> 8) & 15;
        u32 step = 0x400u >> std::min(shift, 10u);
        if (step == 0) step = 1;
        bool alphaOnly = cnt & 0x40;
        runParallel([&](int yb, int ye) {
        for (int i = yb * W_; i < ye * W_; ++i) {
            if (!(flags_[i] & 2)) continue;
            u32 d = depth_[i] >> 9;
            int den;
            if (d < offset) den = regs_[0x60] & 0x7F;
            else {
                u32 idx = (d - offset) / step;
                den = regs_[0x60 + std::min(idx, 31u)] & 0x7F;
            }
            if (den == 127) den = 128;
            if (!alphaOnly) {
                r_[i] = u8((fr * den + r_[i] * (128 - den)) >> 7);
                g_[i] = u8((fg * den + g_[i] * (128 - den)) >> 7);
                b_[i] = u8((fb * den + b_[i] * (128 - den)) >> 7);
            }
            a_[i] = u8((fa * den + a_[i] * (128 - den)) >> 7);
        }
        });
    }
    // Optional edge smoothing (FXAA-style, enhancement) on the 3D buffer only.
    if (aa_ == AntiAlias::Fxaa) {
        aaR_.resize(r_.size()); aaG_.resize(g_.size()); aaB_.resize(b_.size());
        runParallel([&](int yb, int ye) {
            size_t a = size_t(yb) * size_t(W_), e = size_t(ye) * size_t(W_);
            std::copy(r_.begin() + long(a), r_.begin() + long(e), aaR_.begin() + long(a));
            std::copy(g_.begin() + long(a), g_.begin() + long(e), aaG_.begin() + long(a));
            std::copy(b_.begin() + long(a), b_.begin() + long(e), aaB_.begin() + long(a));
        });
        runParallel([&](int yb, int ye) { fxaaBand(aaR_, aaG_, aaB_, yb, ye); });
    }
    // Output conversion and the 1x picture for the 2D compositor (the centre sample of each
    // scale x scale block), both per band so they run on the pool too (they were serial).
    const int c0 = scale_ / 2;
    auto extract1x = [&](int hb, int he) {             // output rows [hb, he) of hi_ are final
        for (int y = (hb - c0 + scale_ - 1) / scale_; y < kH && y * scale_ + c0 < he; ++y) {
            if (y * scale_ + c0 < hb) continue;
            const u32* src = hi_.data() + size_t(y * scale_ + c0) * size_t(OW_) + size_t(c0);
            u32* dst = out_.data() + size_t(y) * kW;
            for (int x = 0; x < kW; ++x) dst[x] = src[size_t(x * scale_)];
        }
    };
    if (ss_ == 1) {
        runParallel([&](int yb, int ye) {
            const u8* R = r_.data(); const u8* G = g_.data(); const u8* B = b_.data(); const u8* A = a_.data(); u32* O = hi_.data();
            for (int i = yb * W_, e = ye * W_; i < e; ++i)       // simple loop: auto-vectorised (NEON / SSE)
                O[i] = u32(R[i] >> 1) | (u32(G[i] >> 1) << 5) | (u32(B[i] >> 1) << 10) | (u32(A[i] & 31) << 16);
            extract1x(yb, ye);
        });
    } else {                                              // supersampling: 2x2 box filter
        runParallel([&](int yb, int ye) {
            int ob = (yb + 1) / 2, oe = std::min(OH_, (ye + 1) / 2);   // output rows whose samples start in this band
            for (int y = ob; y < oe; ++y)
                for (int x = 0; x < OW_; ++x) {
                    int i0 = (2 * y) * W_ + 2 * x, i1 = i0 + W_;
                    int idx[4] = {i0, i0 + 1, i1, i1 + 1};
                    int r = 0, g = 0, b = 0, a = 0, n = 0;
                    for (int j : idx) { a += a_[j]; if (a_[j]) { r += r_[j]; g += g_[j]; b += b_[j]; ++n; } }
                    if (n) { r /= n; g /= n; b /= n; }        // colour of covered samples only (no dark fringes)
                    a = (a + 2) / 4;
                    hi_[size_t(y) * size_t(OW_) + size_t(x)] =
                        u32(r >> 1) | (u32(g >> 1) << 5) | (u32(b >> 1) << 10) | (u32(a & 31) << 16);
                }
            extract1x(ob, oe);
        });
    }
}

// FXAA-style edge smoothing (original implementation): find local luma contrast, decide
// whether the edge runs horizontally or vertically, and blend across it in proportion to
// the contrast. Only pixels covered by polygons are touched.
void GPU3D::fxaaBand(const std::vector<u8>& sr, const std::vector<u8>& sg, const std::vector<u8>& sb, int yBegin, int yEnd) {
    auto luma = [&](int i) { return int(sr[size_t(i)]) * 2 + int(sg[size_t(i)]) * 5 + int(sb[size_t(i)]); };   // 0..504
    for (int y = std::max(yBegin, 1); y < std::min(yEnd, H_ - 1); ++y)
        for (int x = 1; x < W_ - 1; ++x) {
            int i = y * W_ + x;
            if (!(flags_[size_t(i)] & 4)) continue;
            int lc = luma(i), ln = luma(i - W_), ls = luma(i + W_), lw = luma(i - 1), le = luma(i + 1);
            int mx = std::max({lc, ln, ls, lw, le}), mn = std::min({lc, ln, ls, lw, le});
            int range = mx - mn;
            if (range < std::max(24, mx / 6)) continue;
            int lnw = luma(i - W_ - 1), lne = luma(i - W_ + 1), lsw = luma(i + W_ - 1), lse = luma(i + W_ + 1);
            int edgeH = std::abs(lnw + 2 * ln + lne - (lsw + 2 * ls + lse));   // horizontal edge (vertical gradient)
            int edgeV = std::abs(lnw + 2 * lw + lsw - (lne + 2 * le + lse));
            int j0, j1;
            if (edgeH >= edgeV) { j0 = i - W_; j1 = i + W_; } else { j0 = i - 1; j1 = i + 1; }
            // Sub-pixel amount: how different the centre is from its neighbourhood average.
            int avg = (ln + ls + lw + le) / 4;
            int sub = std::min(256, std::abs(avg - lc) * 256 / std::max(range, 1));
            int f = (sub * sub) >> 9;                           // 0..128 (smoothstep-ish)
            f = std::max(f, 48);
            auto blend = [&](u8& dst, const std::vector<u8>& src) {
                int nb = (int(src[size_t(j0)]) + int(src[size_t(j1)])) / 2;
                dst = u8((int(src[size_t(i)]) * (256 - f) + nb * f) >> 8);
            };
            blend(r_[size_t(i)], sr); blend(g_[size_t(i)], sg); blend(b_[size_t(i)], sb);
        }
}

void GPU3D::rasterize(const Poly& p, int yBegin, int yEnd) {
    u32 cnt = disp3dcnt();
    u32 attr = p.attr;
    int polyAlpha = int((attr >> 16) & 31);
    bool wire = polyAlpha == 0;
    if (wire) polyAlpha = 31;
    u32 mode = (attr >> 4) & 3;
    u8 id = u8((attr >> 24) & 63);
    bool textured = (cnt & 1) && ((p.texParam >> 26) & 7) != 0;
    bool blend = cnt & 0x08;
    bool alphaTest = cnt & 0x04;
    int alphaRef = reg16(0x340) & 31;
    bool depthEqual = attr & (1u << 14);
    bool transDepthWrite = attr & (1u << 11);
    bool fogOn = attr & (1u << 15);

    float ymin = 1e9f, ymax = -1e9f;
    for (int i = 0; i < p.n; ++i) { ymin = std::min(ymin, p.v[i].y); ymax = std::max(ymax, p.v[i].y); }
    int y0 = std::max(0, int(std::ceil(ymin - 0.5f))), y1 = std::min(H_ - 1, int(std::ceil(ymax - 0.5f)) - 1);
    if (y1 < y0 && ymax - ymin < 1.0f && ymin >= 0 && ymin < H_) y0 = y1 = int(ymin);   // thin polygons
    bool thin = y0 == y1;
    const int wy0 = y0, wy1 = y1;                  // polygon's own top/bottom rows (wireframe)
    y0 = std::max(y0, yBegin); y1 = std::min(y1, yEnd - 1);

    if (y1 < y0) return;                           // polygon not in this chunk
    float ivw[10];                                 // per-vertex 1/w, hoisted out of the scanline loop
    for (int i = 0; i < p.n; ++i) ivw[i] = 1.0f / p.v[i].w;
    struct Edge { float x, iw, z, r, g, b, s, t; };
    const bool nearest = !texFilter_;
    s32 lastS = INT32_MIN, lastT = INT32_MIN; bool lastOk = false; int lastR = 0, lastG = 0, lastB = 0, lastA = 0;
    for (int y = y0; y <= y1; ++y) {
        float yc = y + 0.5f;
        Edge L{1e9f, 0, 0, 0, 0, 0, 0, 0}, R{-1e9f, 0, 0, 0, 0, 0, 0, 0};
        bool any = false;
        for (int i = 0; i < p.n; ++i) {
            int ib = i + 1 == p.n ? 0 : i + 1;
            const Vtx& a = p.v[i]; const Vtx& b = p.v[ib];
            float ya = a.y, yb = b.y;
            if (ya == yb) continue;
            float lo = std::min(ya, yb), hi = std::max(ya, yb);
            if (yc < lo || yc > hi) { if (!(thin && hi - lo < 1.0f)) continue; }
            float t = std::clamp((yc - ya) / (yb - ya), 0.0f, 1.0f);
            // Perspective-correct attribute interpolation along the edge.
            float iwa = ivw[i], iwb = ivw[ib];
            Edge e;
            e.x = a.x + (b.x - a.x) * t;
            e.iw = iwa + (iwb - iwa) * t;
            e.z = a.z + (b.z - a.z) * t;
            e.r = a.r * iwa + (b.r * iwb - a.r * iwa) * t;
            e.g = a.g * iwa + (b.g * iwb - a.g * iwa) * t;
            e.b = a.b * iwa + (b.b * iwb - a.b * iwa) * t;
            e.s = a.s * iwa + (b.s * iwb - a.s * iwa) * t;
            e.t = a.t * iwa + (b.t * iwb - a.t * iwa) * t;
            if (e.x < L.x) L = e;
            if (e.x > R.x) R = e;
            any = true;
        }
        if (!any) continue;
        int xs = std::max(0, int(std::ceil(L.x - 0.5f))), xe = std::min(W_ - 1, int(std::ceil(R.x - 0.5f)) - 1);
        if (xe < xs) { int xi = int(L.x); if (xi >= 0 && xi < W_ && R.x - L.x < 1.0f) xs = xe = xi; else continue; }
        float span = R.x - L.x; if (span < 1e-6f) span = 1e-6f;
        const float invSpan = 1.0f / span;
        for (int x = xs; x <= xe; ++x) {
            if (wire && !(x == xs || x == xe || y == wy0 || y == wy1)) continue;
            float t = std::clamp((x + 0.5f - L.x) * invSpan, 0.0f, 1.0f);
            float iw = L.iw + (R.iw - L.iw) * t;
            if (iw <= 0) continue;
            int i = y * W_ + x;
            // Z-buffered polygons: depth-test before the 1/w divide, so hidden pixels skip it
            // (same values as before, just computed in a different order).
            float w;
            u32 depth;
            if (p.wBuffer) { w = 1.0f / iw; depth = u32(std::clamp(w, 0.0f, 16777215.0f)); }
            else {
                float z = L.z + (R.z - L.z) * t;
                depth = u32(std::clamp((z * 0.5f + 0.5f) * 16777215.0f, 0.0f, 16777215.0f));
            }
            if (depthEqual) { if (std::abs(s32(depth) - s32(depth_[i])) > 0x200) continue; }
            else if (depth >= depth_[i]) continue;
            if (!p.wBuffer) w = 1.0f / iw;

            int vr = int((L.r + (R.r - L.r) * t) * w), vg = int((L.g + (R.g - L.g) * t) * w), vb = int((L.b + (R.b - L.b) * t) * w);
            vr = std::clamp(vr, 0, 63); vg = std::clamp(vg, 0, 63); vb = std::clamp(vb, 0, 63);
            int tr = 63, tg = 63, tb = 63, ta = 31;
            if (textured) {
                float s = (L.s + (R.s - L.s) * t) * w, tt = (L.t + (R.t - L.t) * t) * w;
                if (nearest) {
                    // Upscaled output hits the same texel several times in a row: reuse it.
                    s32 si = s32(std::floor(s)), ti = s32(std::floor(tt));
                    if (si != lastS || ti != lastT) {
                        lastS = si; lastT = ti;
                        lastOk = sampleTexel(p, si, ti, lastR, lastG, lastB, lastA);
                    }
                    if (!lastOk) continue;
                    tr = lastR; tg = lastG; tb = lastB; ta = lastA;
                } else if (!sampleTexture(p, s, tt, tr, tg, tb, ta)) continue;
            }
            int cr, cg, cb, ca;
            if (mode == 1 && textured) {                      // decal
                cr = (tr * ta + vr * (31 - ta)) / 31; cg = (tg * ta + vg * (31 - ta)) / 31; cb = (tb * ta + vb * (31 - ta)) / 31;
                ca = polyAlpha;
            } else if (mode == 2) {                           // toon / highlight
                u16 tc = reg16(0x380 + (vr >> 1) * 2);
                int sr = c5to6(tc & 31), sg = c5to6((tc >> 5) & 31), sb = c5to6((tc >> 10) & 31);
                if (cnt & 2) {                                // highlight: modulate by vertex colour, add toon
                    cr = std::min(63, ((tr + 1) * (vr + 1) - 1) / 64 + sr);
                    cg = std::min(63, ((tg + 1) * (vr + 1) - 1) / 64 + sg);
                    cb = std::min(63, ((tb + 1) * (vr + 1) - 1) / 64 + sb);
                } else {
                    cr = ((tr + 1) * (sr + 1) - 1) / 64; cg = ((tg + 1) * (sg + 1) - 1) / 64; cb = ((tb + 1) * (sb + 1) - 1) / 64;
                }
                ca = ((ta + 1) * (polyAlpha + 1) - 1) / 32;
            } else {                                          // modulate
                cr = ((tr + 1) * (vr + 1) - 1) / 64; cg = ((tg + 1) * (vg + 1) - 1) / 64; cb = ((tb + 1) * (vb + 1) - 1) / 64;
                ca = ((ta + 1) * (polyAlpha + 1) - 1) / 32;
            }
            if (ca <= 0) continue;
            if (alphaTest && ca <= alphaRef) continue;
            if (ca < 31) {                                    // translucent pixel
                if ((flags_[i] & 1) && polyId_[i] == id) continue;
                if (blend && a_[i] > 0) {
                    cr = (cr * (ca + 1) + r_[i] * (31 - ca)) / 32;
                    cg = (cg * (ca + 1) + g_[i] * (31 - ca)) / 32;
                    cb = (cb * (ca + 1) + b_[i] * (31 - ca)) / 32;
                    ca = std::max(ca, int(a_[i]));
                }
                r_[i] = u8(cr); g_[i] = u8(cg); b_[i] = u8(cb); a_[i] = u8(ca);
                if (transDepthWrite) depth_[i] = depth;
                flags_[i] = u8(1 | 4 | ((fogOn && (flags_[i] & 2)) ? 2 : 0));
                polyId_[i] = id;
            } else {
                r_[i] = u8(cr); g_[i] = u8(cg); b_[i] = u8(cb); a_[i] = 31;
                depth_[i] = depth; polyId_[i] = id;
                flags_[i] = u8(4 | (fogOn ? 2 : 0));
            }
        }
    }
}

void GPU3D::serialize(StateIO& s) {
    s.tag(0x33440001);
    s.bytes(regs_, sizeof regs_);
    s.bytes(packCmds_, sizeof packCmds_); s.pod(packCount_); s.pod(packIndex_);
    s.bytes(params_, sizeof params_); s.pod(paramCount_);
    s.pod(portCmd_); s.bytes(portParams_, sizeof portParams_); s.pod(portCount_); s.pod(halfLatch_);
    s.vec(deferred_);
    s.pod(mtxMode_); s.pod(proj_); s.pod(pos_); s.pod(vec_); s.pod(tex_); s.pod(clip_);
    s.pod(projStack_); s.bytes(posStack_, sizeof posStack_); s.bytes(vecStack_, sizeof vecStack_); s.pod(texStack_);
    s.pod(projSP_); s.pod(posSP_); s.pod(texSP_); s.pod(stackError_); s.pod(clipDirty_);
    s.pod(vx_); s.pod(vy_); s.pod(vz_); s.bytes(color_, sizeof color_);
    s.pod(texS_); s.pod(texT_); s.pod(rawS_); s.pod(rawT_);
    s.pod(polyAttr_); s.pod(polyAttrActive_); s.pod(texParam_); s.pod(palBase_);
    s.pod(diffuse_); s.pod(ambient_); s.pod(specular_); s.pod(emission_); s.pod(useShininess_);
    s.bytes(shininess_, sizeof shininess_); s.bytes(light_, sizeof light_); s.bytes(lightColor_, sizeof lightColor_);
    s.pod(viewport_); s.pod(primType_); s.pod(inBegin_); s.bytes(strip_, sizeof strip_); s.pod(stripCount_); s.pod(stripParity_);
    s.bytes(posTest_, sizeof posTest_); s.bytes(vecTest_, sizeof vecTest_); s.pod(boxResult_); s.pod(vertexCount_);
    s.vec(polys_); s.pod(swapPending_); s.pod(swapParam_); s.pod(lastPolys_); s.pod(lastVerts_);
    s.vec(renderPolys_); s.pod(renderPending_); s.pod(renderSwapParam_);
    s.vec(out_);
}

} // namespace dscore
