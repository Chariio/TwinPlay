#include "dscore/SnesTrace.hpp"
#include <sfc/sfc.hpp>
#include <cstdio>
#include <cstring>
#include <vector>

namespace dscore {

bool snesTraceEnabled = false;
bool snesWatchEnabled = false;
bool snesPcTraceArmed = false;
int snesPcTraceBank = -1;
bool snesDspLogArmed = false;
bool snesDspRawArmed = false;

namespace {

struct Latch {
    int v, dot, bg, sel, a, b, c, d, x, y, hofs, vofs;
};
struct HdmaSetup {
    int ch, enable, mode, indirect, bbus, v, dot;
    uint32_t table;
};
struct HdmaByte {
    int ch, bbus, data, v, dot;
    bool hold;
};
struct DspCmd {
    int v, dot, cmd;
    std::vector<int16_t> in, out;
    const char* tag;
    int sinAzs = -1, vOff = 0, zc = 0, ze = 0;
};
struct PpuWrite {
    uint32_t addr;
    uint8_t data;
    int v, dot;
};
struct DspBus {
    int write, v, dot, source, channel;
    uint32_t addr;
    uint8_t data;
};
struct DmaDsp {
    int ch, write, v, dot;
    uint32_t addr;
    uint8_t data;
};
struct HdmaSrc {
    int ch, bank, v, dot;
    uint32_t addr;
    uint8_t data;
};
struct WramWrite {
    int dma, v, dot;
    uint32_t who, offset;
    uint8_t data;
};

std::vector<Latch> latches;
std::vector<HdmaSetup> setups;
std::vector<HdmaByte> hdma;
std::vector<DspCmd> dsp;
std::vector<DspBus> dspBus;
std::vector<DmaDsp> dmaDsp;
std::vector<HdmaSrc> hdmaSrc;
std::vector<WramWrite> wramWrites;
std::vector<PpuWrite> cpuPpu;
int traceWramTableStored = 0;
int traceWramTableDropped = 0;
int traceWramOtherStored = 0;

struct WatchFrame {
    int frame = -1;
    uint32_t buttons = 0;
    int wramCount = 0, wmaddCount = 0, dmaCount = 0;
    int wramLines = 0, wmaddLines = 0, dmaLines = 0;
    // Fixed slots. The CPU coroutine must not allocate while a store is committing.
    char wram[50][96]{};
    char wmadd[50][112]{};
    char dma[50][160]{};
};
WatchFrame watch;
uint8_t snesPcSeen[8192];

void where(int& v, int& dot) {
    v = (int)ares::SuperFamicom::cpu.vcounter();
    dot = (int)ares::SuperFamicom::cpu.hdot();
}

void hex16(std::string& o, int v) {
    char b[8];
    std::snprintf(b, sizeof b, "%04X", v & 0xFFFF);
    o += b;
}

void hex8(std::string& o, int v) {
    char b[8];
    std::snprintf(b, sizeof b, "%02X", v & 0xFF);
    o += b;
}

} // namespace

void snesTraceLatch(int vcounter, int dot, int bgMode, int m7sel,
                    int a, int b, int c, int d, int x, int y, int hofs, int vofs) {
    if (!snesTraceEnabled) return;
    latches.push_back({vcounter, dot, bgMode, m7sel, a, b, c, d, x, y, hofs, vofs});
}

void snesTraceHdmaSetup(int channel, int enable, int mode, int indirect, int bbus,
                        uint32_t table, int vcounter, int dot) {
    if (!snesTraceEnabled) return;
    setups.push_back({channel, enable, mode, indirect, bbus, vcounter, dot, table});
}

void snesTraceHdmaByte(int channel, int bbus, int data, int vcounter, int dot) {
    if (!snesTraceEnabled) return;
    hdma.push_back({channel, bbus, data, vcounter, dot, false});
}

void snesTraceHdmaHold(int channel, int vcounter, int dot) {
    if (!snesTraceEnabled) return;
    hdma.push_back({channel, 0, 0, vcounter, dot, true});
}

void snesTraceDsp(int command, const int16_t* inputs, int inputCount,
                  const int16_t* outputs, int outputCount, const char* tag) {
    if (!snesTraceEnabled) return;
    DspCmd cmd;
    where(cmd.v, cmd.dot);
    cmd.cmd = command;
    cmd.tag = tag;
    if (inputs && inputCount > 0) cmd.in.assign(inputs, inputs + inputCount);
    if (outputs && outputCount > 0) cmd.out.assign(outputs, outputs + outputCount);
    dsp.push_back(std::move(cmd));
}

void snesTraceRasterState(int sinAzs, int vOffset, int centreZC, int centreZE) {
    if (!snesTraceEnabled || dsp.empty()) return;
    dsp.back().sinAzs = sinAzs;
    dsp.back().vOff = vOffset;
    dsp.back().zc = centreZC;
    dsp.back().ze = centreZE;
}

void snesTraceDspBus(int isWrite, uint32_t addr, uint8_t data, int vcounter, int dot, int source, int channel) {
    if (!snesTraceEnabled) return;
    dspBus.push_back({isWrite, vcounter, dot, source, channel, addr, data});
}

void snesTraceDmaDsp(int channel, int isWrite, uint32_t fullAddr, uint8_t data, int vcounter, int dot) {
    if (!snesTraceEnabled) return;
    dmaDsp.push_back({channel, isWrite, vcounter, dot, fullAddr, data});
}

void snesTraceHdmaSource(int channel, uint32_t addr, int bank, int vcounter, int dot, uint8_t data) {
    if (!snesTraceEnabled) return;
    hdmaSrc.push_back({channel, bank, vcounter, dot, addr, data});
}

void snesTraceWram(int isDma, uint32_t who, uint32_t offset, uint8_t data, int vcounter, int dot) {
    if (!snesTraceEnabled) return;
    // Record after the store has committed. Cap so a traced frame cannot allocate
    // without bound and unwind out of the CPU (that desynchronises the button frame).
    bool table = offset >= 0x3C00 && offset <= 0xFFFF;
    if (table) {
        if (traceWramTableStored >= 2000) { ++traceWramTableDropped; return; }
        ++traceWramTableStored;
    } else if (traceWramOtherStored >= 400) {
        return;
    } else {
        ++traceWramOtherStored;
    }
    wramWrites.push_back({isDma, vcounter, dot, who, offset, data});
}

void snesTraceCpuPpu(uint32_t address, uint8_t data, int vcounter, int dot) {
    if (!snesTraceEnabled) return;
    cpuPpu.push_back({address, data, vcounter, dot});
}

void superFamicomTraceBegin() {
    latches.clear();
    setups.clear();
    hdma.clear();
    dsp.clear();
    dspBus.clear();
    dmaDsp.clear();
    hdmaSrc.clear();
    wramWrites.clear();
    cpuPpu.clear();
    traceWramTableStored = 0;
    traceWramTableDropped = 0;
    traceWramOtherStored = 0;
    snesTraceEnabled = true;
}

std::string superFamicomTraceEnd() {
    snesTraceEnabled = false;
    std::string o;
    o += "Super NES frame trace\n";
    o += "picture = vcounter - 1. PPU line 1 is the top line of the 224-line picture.\n";
    o += "HDMA runs at the end of a scanline and the latched row is what the renderer used for that vcounter.\n";
    o += "HDMA bbus is the low byte of $21xx (1B is $211B). A hold line repeated the previous transfer.\n";
    o += "M7SEL is bits 7 and 6 (vflip, hflip) and bits 1-0 (repeat), the value the renderer latched.\n";
    o += "CPU writes are $2100-$21FF from the CPU, not from HDMA.\n";
    o += "DSP cmd is the opcode after & 0x3F. 'next' is the following raster line. 'raster end' is a write of $8000.\n";
    o += "DSP bus addr bit 0 is status ($7xxx on 1K1X, $C000 on LoROM). Bit 0 clear is the data port.\n";
    o += "src=cpu|dma|hdma says who touched the coprocessor. DMA A-bus uses the same handlers.\n";
    o += "hdma source is the A-bus byte read for that channel line (indirect bank:address, first 8 bytes).\n";
    o += "wram writes list stores to $7E3C00-$7EFFFF (CPU, $2180, and DMA) plus other watched pages.\n";
    o += "A traced frame keeps the first 2000 table stores and the first 400 other stores.\n";
    o += "A raster line also logs sinAzs, vOff, zC and zE. A status read does not change them or DRS.\n\n";

    o += "latched scanlines\n";
    auto writeLatch = [&](const Latch& L) {
        int picture = L.v - 1;
        char head[64];
        std::snprintf(head, sizeof head, "picture=%d vcounter=%d dot=%d BGMODE=%X M7SEL=",
                      picture, L.v, L.dot, L.bg & 7);
        o += head;
        hex8(o, L.sel);
        o += " M7A="; hex16(o, L.a);
        o += " M7B="; hex16(o, L.b);
        o += " M7C="; hex16(o, L.c);
        o += " M7D="; hex16(o, L.d);
        o += " M7X="; hex16(o, L.x);
        o += " M7Y="; hex16(o, L.y);
        o += " M7HOFS="; hex16(o, L.hofs);
        o += " M7VOFS="; hex16(o, L.vofs);
        o += "\n";
    };
    for (int picture = 0; picture < 224; ++picture) {
        bool any = false;
        for (const Latch& L : latches) {
            if (L.v - 1 != picture) continue;
            writeLatch(L);
            any = true;
        }
        if (!any) {
            char line[48];
            std::snprintf(line, sizeof line, "picture=%d not latched\n", picture);
            o += line;
        }
    }
    for (const Latch& L : latches) {
        int picture = L.v - 1;
        if (picture >= 0 && picture < 224) continue;
        writeLatch(L);
    }

    o += "\nhdma setup\n";
    if (setups.empty()) o += "(none)\n";
    for (const HdmaSetup& s : setups) {
        char line[128];
        std::snprintf(line, sizeof line,
                      "vcounter=%d dot=%d ch=%d enable=%d mode=%d indirect=%d bbus=%02X table=%06X\n",
                      s.v, s.dot, s.ch, s.enable, s.mode, s.indirect, s.bbus & 0xFF, s.table & 0xFFFFFF);
        o += line;
    }

    o += "\nhdma bytes\n";
    if (hdma.empty()) o += "(none)\n";
    for (size_t i = 0; i < hdma.size();) {
        const HdmaByte& h = hdma[i];
        char head[80];
        std::snprintf(head, sizeof head, "vcounter=%d dot=%d ch=%d ", h.v, h.dot, h.ch);
        o += head;
        if (h.hold) {
            o += "hold\n";
            ++i;
            continue;
        }
        o += "bytes";
        size_t j = i;
        while (j < hdma.size() && !hdma[j].hold && hdma[j].ch == h.ch && hdma[j].v == h.v && hdma[j].dot == h.dot) {
            char byte[16];
            std::snprintf(byte, sizeof byte, " %04X=%02X", hdma[j].bbus & 0xFFFF, hdma[j].data & 0xFF);
            o += byte;
            ++j;
        }
        o += "\n";
        i = j;
    }

    o += "\nhdma source\n";
    if (hdmaSrc.empty()) o += "(none)\n";
    for (size_t i = 0; i < hdmaSrc.size();) {
        const HdmaSrc& h = hdmaSrc[i];
        char head[96];
        std::snprintf(head, sizeof head, "vcounter=%d dot=%d ch=%d bank=%02X addr=%06X bytes",
                      h.v, h.dot, h.ch, h.bank & 0xFF, h.addr & 0xFFFFFF);
        o += head;
        int n = 0;
        size_t j = i;
        while (j < hdmaSrc.size() && n < 8 && hdmaSrc[j].ch == h.ch && hdmaSrc[j].v == h.v && hdmaSrc[j].dot == h.dot) {
            char byte[8];
            std::snprintf(byte, sizeof byte, " %02X", hdmaSrc[j].data);
            o += byte;
            ++n;
            ++j;
        }
        o += "\n";
        while (j < hdmaSrc.size() && hdmaSrc[j].ch == h.ch && hdmaSrc[j].v == h.v && hdmaSrc[j].dot == h.dot) ++j;
        i = j;
    }

    o += "\ndma dsp\n";
    if (dmaDsp.empty()) o += "(none)\n";
    for (size_t i = 0; i < dmaDsp.size();) {
        const DmaDsp& d = dmaDsp[i];
        size_t j = i;
        while (j < dmaDsp.size() && dmaDsp[j].ch == d.ch && dmaDsp[j].write == d.write && dmaDsp[j].addr == d.addr) ++j;
        char head[96];
        std::snprintf(head, sizeof head, "ch=%d dir=%s count=%u addr=%06X bytes",
                      d.ch, d.write ? "write" : "read", (unsigned)(j - i), d.addr & 0xFFFFFF);
        o += head;
        size_t shown = i;
        int n = 0;
        while (shown < j && n < 32) {
            char byte[8];
            std::snprintf(byte, sizeof byte, " %02X", dmaDsp[shown].data);
            o += byte;
            ++shown;
            ++n;
        }
        if (shown < j) o += " ...";
        o += "\n";
        i = j;
    }

    o += "\ndsp bus\n";
    if (dspBus.empty()) o += "(none)\n";
    for (const DspBus& b : dspBus) {
        const char* src = b.source == 1 ? "dma" : b.source == 2 ? "hdma" : "cpu";
        char line[96];
        if (b.channel >= 0)
            std::snprintf(line, sizeof line, "%c vcounter=%d dot=%d src=%s ch=%d addr=%04X data=%02X\n",
                          b.write ? 'W' : 'R', b.v, b.dot, src, b.channel, b.addr & 0xFFFF, b.data);
        else
            std::snprintf(line, sizeof line, "%c vcounter=%d dot=%d src=%s addr=%04X data=%02X\n",
                          b.write ? 'W' : 'R', b.v, b.dot, src, b.addr & 0xFFFF, b.data);
        o += line;
    }

    o += "\ndsp1\n";
    if (dsp.empty()) o += "(none)\n";
    for (const DspCmd& c : dsp) {
        char head[64];
        std::snprintf(head, sizeof head, "vcounter=%d dot=%d cmd=%02X", c.v, c.dot, c.cmd & 0xFFFF);
        o += head;
        if (c.tag && c.tag[0]) { o += " "; o += c.tag; }
        o += " in=";
        if (c.in.empty()) o += "-";
        for (size_t i = 0; i < c.in.size(); ++i) {
            if (i) o += ",";
            hex16(o, c.in[i]);
        }
        o += " out=";
        if (c.out.empty()) o += "-";
        for (size_t i = 0; i < c.out.size(); ++i) {
            if (i) o += ",";
            hex16(o, c.out[i]);
        }
        if (c.sinAzs >= 0) {
            char st[80];
            std::snprintf(st, sizeof st, " sinAzs=%04X vOff=%04X zC=%04X zE=%04X",
                          c.sinAzs & 0xFFFF, c.vOff & 0xFFFF, c.zc & 0xFFFF, c.ze & 0xFFFF);
            o += st;
        }
        o += "\n";
    }

    o += "\nwram\n";
    bool page[512] = {};
    page[0] = true; // $7E:0000-07FF holds the HDMA tables around $0640
    page[1] = true;
    for (const HdmaSrc& h : hdmaSrc) {
        uint32_t off = h.addr & 0x1ffff;
        if ((h.addr & 0xfe0000) == 0x7e0000 || (h.addr & 0x40e000) == 0) {
            if ((h.addr & 0x40e000) == 0) off = h.addr & 0x1fff;
            unsigned p = (off >> 8) & 511;
            page[p] = true;
        }
    }
    int wramLines = 0;
    bool anyWram = false;
    for (const WramWrite& w : wramWrites) {
        bool table = w.offset >= 0x3C00 && w.offset <= 0xFFFF;
        unsigned p = (w.offset >> 8) & 511;
        if (!table && (p >= 512 || !page[p])) continue;
        if (!table && wramLines == 400) {
            o += "(further non-table writes omitted)\n";
            ++wramLines;
            continue;
        }
        if (!table && wramLines > 400) continue;
        char line[96];
        if (w.dma)
            std::snprintf(line, sizeof line, "dma ch=%u vcounter=%d dot=%d $7E%04X=%02X\n",
                          w.who, w.v, w.dot, w.offset & 0xFFFF, w.data);
        else
            std::snprintf(line, sizeof line, "cpu pc=%06X vcounter=%d dot=%d $7E%04X=%02X\n",
                          w.who & 0xFFFFFF, w.v, w.dot, w.offset & 0xFFFF, w.data);
        o += line;
        anyWram = true;
        if (!table) ++wramLines;
    }
    if (!anyWram) o += "(none)\n";
    if (traceWramTableDropped) {
        char extra[80];
        std::snprintf(extra, sizeof extra, "(further table writes omitted: %d)\n", traceWramTableDropped);
        o += extra;
    }

    o += "\ncpu $2100-$21FF\n";
    if (cpuPpu.empty()) o += "(none)\n";
    for (const PpuWrite& w : cpuPpu) {
        char line[64];
        std::snprintf(line, sizeof line, "vcounter=%d dot=%d $%04X=%02X\n",
                      w.v, w.dot, w.addr & 0xFFFF, w.data);
        o += line;
    }
    return o;
}

void snesWatchWram(int via, int channel, uint32_t pc, uint32_t offset, uint8_t data, int vcounter) {
    if (!snesWatchEnabled) return;
    if (offset < 0x3C00 || offset > 0xFFFF) return;
    ++watch.wramCount;
    if (watch.wramLines >= 50) return;
    char* line = watch.wram[watch.wramLines++];
    if (via == 0)
        std::snprintf(line, 96, "  wram vc=%d cpu pc=%06X $7E%04X=%02X\n",
                      vcounter, pc & 0xFFFFFF, offset & 0xFFFF, data);
    else
        std::snprintf(line, 96, "  wram vc=%d %s ch=%d $7E%04X=%02X\n",
                      vcounter, via == 2 ? "hdma" : "dma", channel, offset & 0xFFFF, data);
}

void snesWatchWmadd(int via, int channel, uint32_t reg, uint8_t data, uint32_t addr, uint32_t pc, int vcounter) {
    if (!snesWatchEnabled) return;
    ++watch.wmaddCount;
    if (watch.wmaddLines >= 50) return;
    char* line = watch.wmadd[watch.wmaddLines++];
    if (via == 0)
        std::snprintf(line, 112, "  wmadd vc=%d cpu pc=%06X $%04X=%02X wmadd=%05X\n",
                      vcounter, pc & 0xFFFFFF, reg & 0xFFFF, data, addr & 0x1FFFF);
    else
        std::snprintf(line, 112, "  wmadd vc=%d %s ch=%d $%04X=%02X wmadd=%05X\n",
                      vcounter, via == 2 ? "hdma" : "dma", channel, reg & 0xFFFF, data, addr & 0x1FFFF);
}

void snesWatchDma(int channel, int direction, int bbus, uint32_t abus, int size, int fixedTransfer, int mode, uint32_t pc, int vcounter) {
    if (!snesWatchEnabled) return;
    ++watch.dmaCount;
    if (watch.dmaLines >= 50) return;
    char* line = watch.dma[watch.dmaLines++];
    std::snprintf(line, 160,
                  "  dma setup vc=%d cpu pc=%06X ch=%d dir=%s bbus=%02X abus=%06X size=%04X fixed=%d mode=%d\n",
                  vcounter, pc & 0xFFFFFF, channel, direction ? "BtoA" : "AtoB",
                  bbus & 0xFF, abus & 0xFFFFFF, size & 0xFFFF, fixedTransfer ? 1 : 0, mode & 7);
}

void superFamicomWatchOpenFrame(int frame, uint32_t buttons) {
    watch.frame = frame;
    watch.buttons = buttons;
    watch.wramCount = watch.wmaddCount = watch.dmaCount = 0;
    watch.wramLines = watch.wmaddLines = watch.dmaLines = 0;
    snesWatchEnabled = true;
}

std::string superFamicomWatchCloseFrame() {
    snesWatchEnabled = false;
    if (watch.frame < 0) return {};
    std::string o;
    char head[128];
    std::snprintf(head, sizeof head, "frame %d buttons=%08X wram=%d wmadd=%d dma=%d\n",
                  watch.frame, watch.buttons, watch.wramCount, watch.wmaddCount, watch.dmaCount);
    o += head;
    for (int i = 0; i < watch.wramLines; ++i) o += watch.wram[i];
    for (int i = 0; i < watch.wmaddLines; ++i) o += watch.wmadd[i];
    for (int i = 0; i < watch.dmaLines; ++i) o += watch.dma[i];
    auto omitted = [&](const char* what, int count, int lines) {
        if (count <= lines) return;
        char extra[80];
        std::snprintf(extra, sizeof extra, "  (%d more %s)\n", count - lines, what);
        o += extra;
    };
    omitted("wram writes", watch.wramCount, watch.wramLines);
    omitted("wmadd writes", watch.wmaddCount, watch.wmaddLines);
    omitted("dma setups", watch.dmaCount, watch.dmaLines);
    watch.frame = -1;
    return o;
}

namespace {
std::FILE* dspLogFile = nullptr;
int dspLogFrame = 0;
}

void snesDspLogAttach(std::FILE* file) { dspLogFile = file; }

void snesDspLogSetFrame(int frame, bool armed) {
    dspLogFrame = frame;
    snesDspLogArmed = armed && dspLogFile != nullptr;
}

void snesDspLogWrite(int op, const int16_t* in, int nin, const int16_t* out, int nout) {
    if (!snesDspLogArmed || !dspLogFile) return;
    char line[192];
    int n = std::snprintf(line, sizeof line, "frame=%d raw=%02X op=%02X in=",
                          dspLogFrame, op & 0xFF, op & 0xFF);
    if (n < 0 || n >= (int)sizeof line) return;
    if (nin <= 0 || !in) {
        n += std::snprintf(line + n, sizeof line - (size_t)n, "-");
    } else {
        for (int i = 0; i < nin && n < (int)sizeof line; ++i)
            n += std::snprintf(line + n, sizeof line - (size_t)n, "%s%04X", i ? "," : "", in[i] & 0xFFFF);
    }
    if (n < (int)sizeof line)
        n += std::snprintf(line + n, sizeof line - (size_t)n, " out=");
    if (nout <= 0 || !out) {
        if (n < (int)sizeof line) std::snprintf(line + n, sizeof line - (size_t)n, "-\n");
    } else {
        for (int i = 0; i < nout && n < (int)sizeof line; ++i)
            n += std::snprintf(line + n, sizeof line - (size_t)n, "%s%04X", i ? "," : "", out[i] & 0xFFFF);
        if (n < (int)sizeof line) std::snprintf(line + n, sizeof line - (size_t)n, "\n");
    }
    std::fputs(line, dspLogFile);
}

void snesDspLogNop(uint8_t raw) {
    if (!snesDspLogArmed || !dspLogFile) return;
    std::fprintf(dspLogFile, "frame=%d raw=%02X nop\n", dspLogFrame, raw);
}

namespace {
std::FILE* dspRawFile = nullptr;
int dspRawFrame = 0;
}

void snesDspRawAttach(std::FILE* file) { dspRawFile = file; }

void snesDspRawSetFrame(int frame, bool armed) {
    dspRawFrame = frame;
    snesDspRawArmed = armed && dspRawFile != nullptr;
}

void snesDspRawByte(int isWrite, uint8_t data) {
    if (!snesDspRawArmed || !dspRawFile) return;
    std::fprintf(dspRawFile, "frame=%d %c %02X\n", dspRawFrame, isWrite ? 'W' : 'R', data);
}

void snesPcTraceHit(uint32_t pc) {
    if ((int)((pc >> 16) & 0xFF) != snesPcTraceBank) return;
    unsigned off = pc & 0xFFFF;
    snesPcSeen[off >> 3] |= (uint8_t)(1u << (off & 7));
}

void snesPcTraceClear() {
    std::memset(snesPcSeen, 0, sizeof snesPcSeen);
}

int snesPcTraceCollect(uint32_t* pcs, int cap) {
    int n = 0;
    int bank = snesPcTraceBank & 0xFF;
    for (unsigned off = 0; off < 65536; ++off) {
        if ((snesPcSeen[off >> 3] & (uint8_t)(1u << (off & 7))) == 0) continue;
        if (pcs && n < cap) pcs[n] = ((uint32_t)bank << 16) | off;
        ++n;
    }
    std::memset(snesPcSeen, 0, sizeof snesPcSeen);
    return n;
}

} // namespace dscore
