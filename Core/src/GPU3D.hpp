// Copyright (c) 2026 Charlie Rodriguez Garcia. All rights reserved.
// Original clean-room 3D engine: geometry engine (matrix stacks, lighting,
// primitive assembly, clipping) and a software rasterizer (textures, alpha,
// depth, fog, edge marking). Register and command layout from GBATEK.
#pragma once
#include "VRAM.hpp"
#include "dscore/StateIO.hpp"
#include <atomic>
#include <condition_variable>
#include <functional>
#include <mutex>
#include <thread>
#include <vector>

namespace dscore {

class GPU3D {
public:
    static constexpr int kMaxPolys = 2048, kMaxVerts = 6144;
    // disp3dcnt: pointer to engine A register block (DISP3DCNT lives at +0x60).
    GPU3D(const u8* engineAIo, VRAM& vram);
    ~GPU3D();
    GPU3D(const GPU3D&) = delete;
    GPU3D& operator=(const GPU3D&) = delete;

    // Rasterizer worker threads (0 = render on the calling thread). Output is identical
    // for any count: the screen is split into horizontal bands rendered independently.
    void setRenderThreads(int n);
    // Scanline at which a swapped frame is rasterized (late VBlank, like the hardware,
    // so textures uploaded during VBlank are already in place).
    static constexpr int kRenderLine = 215;
    // Internal resolution multiplier (1..4). Takes effect from the next rendered frame.
    void setScale(int scale);
    int scale() const { return scale_; }
    // Enhancements (not hardware behaviour; all off by default).
    enum class AntiAlias { Off = 0, Fxaa = 1, Ssaa2x = 2 };
    void setAntiAlias(AntiAlias m);
    AntiAlias antiAlias() const { return aa_; }
    void setTextureFilter(bool bilinear) { texFilter_ = bilinear; }
    bool textureFilter() const { return texFilter_; }
    // Widescreen hack: squeezes clip-space X by 3/4 so a 16:9 stretch of the screen
    // shows a wider field of view with correct proportions.
    void setWidescreen(bool on) { widescreen_ = on; }
    bool widescreen() const { return widescreen_; }
    // High-resolution frame: (256*scale) x (192*scale), same pixel format as output().
    const u32* outputHiRes() const { return hi_.data(); }

    void reset();
    // ARM9 I/O 0x04000320..0x040006A3 (offset relative to 0x04000000).
    static bool handles(u32 off) { return off >= 0x320 && off < 0x6A4; }
    void write(u32 off, u32 value, int size);
    u32 read(u32 off, int size) const;

    // Called at the start of VBlank: performs a pending SWAP_BUFFERS (latches the polygon list).
    void vblank();
    // Rasterizes the latched polygon list if there is one (NDSSystem calls this at kRenderLine).
    // skip = true drops the frame (frame skip) and keeps the previous output.
    void renderPending(bool skip = false);
    u64 poolStalls() const { return poolStalls_.load(std::memory_order_relaxed); }
    bool irqPending() const;                       // GXFIFO IRQ condition (FIFO is always drained)
    bool swapPending() const { return swapPending_; }

    // Rendered frame: 256x192, bits 0-14 BGR555, bits 16-20 alpha (0 = transparent).
    const u32* output() const { return out_.data(); }

    void serialize(StateIO& s);

    // Statistics for tests.
    int lastPolygonCount() const { return lastPolys_; }
    int lastVertexCount() const { return lastVerts_; }
    u32 lastSwapParam() const { return swapParam_; }
    struct Stats { u64 submitted = 0, culled = 0, clippedAway = 0, farDropped = 0, overflow = 0, shadow = 0; };
    Stats stats;

private:
    struct Vtx {                                   // clip-space vertex with attributes
        float x, y, z, w;
        float r, g, b;                             // 0..63
        float s, t;                                // texels
    };
    struct Poly {
        int n;
        Vtx v[10];
        u32 attr, texParam, palBase;
        bool translucent;
        bool wBuffer;
    };
    struct Mtx { s32 m[16]; };

    void command(u8 cmd, const u32* p);
    void packedWrite(u32 v);
    void portWrite(u8 cmd, u32 v);
    void addVertex(s32 x, s32 y, s32 z);
    void emitPolygon(const Vtx* in, int n);
    void computeLighting(s32 nx, s32 ny, s32 nz);
    void updateClip();
    void render();
    void rasterize(const Poly& p, int yBegin, int yEnd);
    void renderBand(int yBegin, int yEnd);
    void runParallel(const std::function<void(int, int)>& band);
    void runChunks(const std::function<void(int, int)>& band);
    bool sampleTexture(const Poly& p, float s, float t, int& r, int& g, int& b, int& a) const;
    bool sampleTexel(const Poly& p, s32 s, s32 t, int& r, int& g, int& b, int& a) const;
    void reconfigure();
    void fxaaBand(const std::vector<u8>& sr, const std::vector<u8>& sg, const std::vector<u8>& sb, int yBegin, int yEnd);
    u16 texPal(u32 addr) const { return vram_.read16(VRAM::TEXPAL, addr); }   // one page lookup
    u8 tex8(u32 addr) const { return vram_.read8(VRAM::TEX, addr); }
    u16 reg16(u32 off) const { return u16(regs_[off - 0x300] | (regs_[off - 0x300 + 1] << 8)); }
    u32 reg32(u32 off) const { return reg16(off) | (u32(reg16(off + 2)) << 16); }
    u32 disp3dcnt() const { return u32(aio_[0x60] | (aio_[0x61] << 8)); }

    static void mul(Mtx& dst, const s32* left, const Mtx& right);   // dst = left * right
    static Mtx identity();

    const u8* aio_;
    VRAM& vram_;
    u8 regs_[0x400] = {};                          // shadow of 0x04000300..0x040006FF

    // Command input
    u8 packCmds_[4] = {}; int packCount_ = 0, packIndex_ = 0;
    u32 params_[32] = {}; int paramCount_ = 0;
    u8 portCmd_ = 0; u32 portParams_[32] = {}; int portCount_ = 0;
    u32 halfLatch_ = 0;
    std::vector<u32> deferred_;                    // (offset, value) pairs received while a swap is pending

    // Geometry state
    u32 mtxMode_ = 0;
    Mtx proj_, pos_, vec_, tex_, clip_;
    Mtx projStack_, posStack_[32], vecStack_[32], texStack_;
    int projSP_ = 0, posSP_ = 0, texSP_ = 0;
    bool stackError_ = false;
    bool clipDirty_ = true;
    s32 vx_ = 0, vy_ = 0, vz_ = 0;                 // last vertex (4.12)
    u8 color_[3] = {31, 31, 31};
    s16 texS_ = 0, texT_ = 0, rawS_ = 0, rawT_ = 0;
    u32 polyAttr_ = 0, polyAttrActive_ = 0, texParam_ = 0, palBase_ = 0;
    u16 diffuse_ = 0, ambient_ = 0, specular_ = 0, emission_ = 0;
    bool useShininess_ = false;
    u8 shininess_[128] = {};
    s32 light_[4][3] = {};
    u16 lightColor_[4] = {};
    u32 viewport_ = 0x00BFFF00u;                   // x1=0,y1=0,x2=255,y2=191
    u32 primType_ = 0; bool inBegin_ = false;
    Vtx strip_[4] = {}; int stripCount_ = 0, stripParity_ = 0;
    s32 posTest_[4] = {}; s16 vecTest_[3] = {};
    bool boxResult_ = true;
    int vertexCount_ = 0;

    // Polygon lists: geometry being built, and the one last rendered.
    std::vector<Poly> polys_;
    bool swapPending_ = false; u32 swapParam_ = 0;
    std::vector<Poly> renderPolys_;                // latched at the swap, rasterized at kRenderLine
    std::vector<const Poly*> order_;
    bool renderPending_ = false; u32 renderSwapParam_ = 0;
    int lastPolys_ = 0, lastVerts_ = 0;

    // Rendering buffers
    std::vector<u32> out_;                         // output (see output())
    std::vector<u32> depth_;
    std::vector<u8> polyId_, flags_;               // flags: 1 translucent, 2 fog, 4 drawn by a polygon
    std::vector<u8> r_, g_, b_, a_;                // 6-bit colour, 5-bit alpha (all at W_ x H_)
    std::vector<u32> hi_;                          // high-resolution output (OW_ x OH_)
    int scale_ = 1, W_ = 256, H_ = 192;           // output scale; render buffer size
    int ss_ = 1, OW_ = 256, OH_ = 192;            // supersampling factor; output size
    AntiAlias aa_ = AntiAlias::Off;
    bool texFilter_ = false, widescreen_ = false;
    std::vector<u8> aaR_, aaG_, aaB_;

    // Worker pool
    std::vector<std::thread> workers_;
    std::mutex poolMutex_;
    std::condition_variable poolWake_, poolDone_;
    const std::function<void(int, int)>* job_ = nullptr;
    std::atomic<u64> jobGeneration_{0}; std::atomic<int> jobsLeft_{0}; std::atomic<bool> poolStop_{false};
    std::atomic<u64> poolStalls_{0};   // timed-out waits for the workers (see runParallel)
    std::atomic<int> nextChunk_{0}; int chunkRows_ = 16, chunkCount_ = 0;   // dynamic row chunks (load balancing)
    std::vector<u8> emR_, emG_, emB_;              // edge-marking scratch (reused, no per-frame allocation)
};

} // namespace dscore
