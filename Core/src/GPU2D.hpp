// Copyright (c) 2026 Charlie Rodriguez Garcia. All rights reserved.
// Original clean-room 2D graphics engine (engines A and B), from GBATEK.
#pragma once
#include "VRAM.hpp"
#include "dscore/StateIO.hpp"

namespace dscore {

class GPU2D {
public:
    // io: the engine's 0x70-byte register block (0x04000000 for A, 0x04001000 for B).
    GPU2D(bool engineA, const u8* io, const u8* palette, const u8* oam, VRAM& vram);

    void reset();
    void startFrame();                          // reload affine reference points
    void affineRegisterWritten(int bg);         // BG2/BG3 X/Y written -> reload that BG
    // Renders scanline y (0..191) into 256 ARGB8888 pixels.
    void renderLine(int y, u32* out);
    // Engine A display capture (DISPCAPCNT): call after renderLine for lines inside the capture
    // height. Writes 15-bit pixels with bit 15 set into the selected VRAM bank (A-D).
    void captureLine(int y, u32 dispcapcnt);
    u64 captureBlocked = 0;                              // capture lines dropped: bank not in LCDC mode
    // Lines captured for DISPCAPCNT size bits 20-21.
    static int captureHeight(u32 dispcapcnt) { static const int h[4] = {128, 64, 128, 192}; return h[(dispcapcnt >> 20) & 3]; }
    static int captureWidth(u32 dispcapcnt) { return ((dispcapcnt >> 20) & 3) == 0 ? 128 : 256; }
    // Set by NDSSystem: compose BG/OBJ even when the display mode shows VRAM (capture source A).
    void setCaptureActive(bool on) { captureActive_ = on; }
    // Frame skip: advances per-line state (affine reference points) without drawing.
    void skipLine(int y);
    // Engine A only: 3D frame (see GPU3D::output) shown as BG0 when DISPCNT bit 3 is set.
    void set3DSource(const u32* frame) { threeD_ = frame; }
    // After renderLine (engine A): per x, 1 if the pixel is the unmodified, opaque 3D layer
    // (so a high-resolution 3D sample may replace it); also the BG0 horizontal scroll used.
    const u8* pure3DMask() const { return pure3D_; }
    int bg0Scroll() const { return bg0Scroll_; }
    static u32 toARGB(u16 bgr555);
    void serialize(StateIO& s) { s.tag(0x32440001); s.bytes(refX_, sizeof refX_); s.bytes(refY_, sizeof refY_); }

private:
    struct Layer { u32 color[256]; };          // bit 31 set = opaque, low 15 bits = BGR555
    u16 io16(u32 off) const { return u16(io_[off] | (io_[off + 1] << 8)); }
    u32 io32(u32 off) const { return io16(off) | (u32(io16(off + 2)) << 16); }
    u16 pal(u32 index) const { return u16(palette_[index * 2] | (palette_[index * 2 + 1] << 8)); }
    u16 objPal(u32 index) const { return pal(0x100 + index); }
    u8 bg8(u32 off) const { return vram_.read8(bgRegion_, off); }
    u16 bg16(u32 off) const { return vram_.read16(bgRegion_, off); }
    u8 obj8(u32 off) const { return vram_.read8(objRegion_, off); }
    u16 obj16(u32 off) const { return vram_.read16(objRegion_, off); }

    void composeLine(int y, u32 dispcnt, u16* out15);
    void renderText(int bg, int y, u32 dispcnt, Layer& L);
    void renderAffine(int bg, u32 dispcnt, Layer& L, int kind);   // 0 classic, 1 extended, 2 large bitmap
    void renderObjects(int y, u32 dispcnt);
    static u16 blendAlpha(u16 a, u16 b, u32 eva, u32 evb);
    static u16 brighten(u16 c, u32 evy);
    static u16 darken(u16 c, u32 evy);

    bool isA_;
    const u8* io_;
    const u8* palette_;   // 1 KB block for this engine (BG 0x000, OBJ 0x200)
    const u8* oam_;       // 1 KB block for this engine
    VRAM& vram_;
    VRAM::Region bgRegion_, objRegion_;

    s32 refX_[2] = {}, refY_[2] = {};           // internal affine reference points (BG2, BG3)
    Layer bg_[4];
    u32 objColor_[256];                          // bit31 opaque
    u8 objPrio_[256];
    u8 objMode_[256];                            // 0 normal, 1 semi-transparent, 3 bitmap
    u8 objAlpha_[256];
    bool objWindow_[256];
    const u32* threeD_ = nullptr;
    u8 alpha3D_[256];
    bool bg0Is3D_ = false;
    u8 pure3D_[256] = {};
    int bg0Scroll_ = 0;
    bool captureActive_ = false;
    u16 composed_[256] = {};                     // last composed line before master brightness
    bool composedValid_ = false;
};

} // namespace dscore
