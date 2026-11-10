// One-frame Super NES trace for the race harness. Off unless a frame is armed.
// The checks on the CPU and PPU paths are a single flag load.
#pragma once
#include <cstdint>
#include <cstdio>
#include <string>

namespace dscore {

extern bool snesTraceEnabled;

void snesTraceLatch(int vcounter, int dot, int bgMode, int m7sel,
                    int a, int b, int c, int d, int x, int y, int hofs, int vofs);
void snesTraceHdmaSetup(int channel, int enable, int mode, int indirect, int bbus,
                        uint32_t table, int vcounter, int dot);
void snesTraceHdmaByte(int channel, int bbus, int data, int vcounter, int dot);
void snesTraceHdmaHold(int channel, int vcounter, int dot);
// One indirect (or direct) HDMA source byte. addr is the full 24-bit A-bus address.
void snesTraceHdmaSource(int channel, uint32_t addr, int bank, int vcounter, int dot, uint8_t data);
void snesTraceDsp(int command, const int16_t* inputs, int inputCount,
                  const int16_t* outputs, int outputCount, const char* tag);
// Attach the projection registers used by the raster line just logged.
void snesTraceRasterState(int sinAzs, int vOffset, int centreZC, int centreZE);
// Raw DSP-1 bus byte. isWrite is 0 for a read. addr bit 0 is the status port.
// source: 0 = CPU, 1 = general-purpose DMA, 2 = HDMA. channel is the DMA channel or -1.
void snesTraceDspBus(int isWrite, uint32_t addr, uint8_t data, int vcounter, int dot, int source, int channel);
// A general-purpose DMA byte whose A-bus address is a DSP-1 port. fullAddr is the 24-bit address.
void snesTraceDmaDsp(int channel, int isWrite, uint32_t fullAddr, uint8_t data, int vcounter, int dot);
// A write into WRAM (offset is the $7E0000-relative address; mirrors are folded in).
// who is the CPU PC for a CPU store, or the DMA channel number for a DMA store.
void snesTraceWram(int isDma, uint32_t who, uint32_t offset, uint8_t data, int vcounter, int dot);
void snesTraceCpuPpu(uint32_t address, uint8_t data, int vcounter, int dot);

// Arm recording. The next emulator activity is appended until End.
void superFamicomTraceBegin();
// Stop recording and return the log. Safe to call when recording is already off.
std::string superFamicomTraceEnd();

// Cheap write watch. Independent of snesTraceEnabled: arming it does not turn on
// the full frame trace, and it does not read or write any emulator register.
// via: 0 = CPU (channel ignored, pc is the 24-bit PC), 1 = DMA, 2 = HDMA.
extern bool snesWatchEnabled;
void snesWatchWram(int via, int channel, uint32_t pc, uint32_t offset, uint8_t data, int vcounter);
void snesWatchWmadd(int via, int channel, uint32_t reg, uint8_t data, uint32_t addr, uint32_t pc, int vcounter);
void snesWatchDma(int channel, int direction, int bbus, uint32_t abus, int size, int fixedTransfer, int mode, uint32_t pc, int vcounter);
void superFamicomWatchOpenFrame(int frame, uint32_t buttons);
// Disarm and return this frame's block. Safe if the watch was not open.
std::string superFamicomWatchCloseFrame();

// Unique instruction PCs in one bank. Armed only on the frames the harness names.
// The hot path is one flag load; it does not read or write any CPU register.
extern bool snesPcTraceArmed;
extern int snesPcTraceBank;
void snesPcTraceHit(uint32_t pc);
void snesPcTraceClear();
// Sorted unique PCs from the armed frame. Clears the set. Returns the count.
int snesPcTraceCollect(uint32_t* pcs, int cap);

// Compact DSP-1 command log. Independent of the full frame trace.
// One line per finished command: frame, opcode, inputs, outputs.
extern bool snesDspLogArmed;
void snesDspLogAttach(std::FILE* file);
void snesDspLogSetFrame(int frame, bool armed);
void snesDspLogWrite(int op, const int16_t* in, int nin, const int16_t* out, int nout);
void snesDspLogNop(uint8_t raw);

// Every data-port byte, write or read. Independent of the command log.
extern bool snesDspRawArmed;
void snesDspRawAttach(std::FILE* file);
void snesDspRawSetFrame(int frame, bool armed);
void snesDspRawByte(int isWrite, uint8_t data);

} // namespace dscore
