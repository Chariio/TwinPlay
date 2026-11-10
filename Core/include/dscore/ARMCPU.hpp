// Copyright (c) 2026 Charlie Rodriguez Garcia. All rights reserved.
// Original clean-room ARM interpreter written from public ARM architecture
// documentation (ARMv4T / ARMv5TE) and GBATEK. No third-party code.
#pragma once
#include "dscore/Bus.hpp"
#include "dscore/StateIO.hpp"
#include <cstring>
#include <functional>
#include <string>

namespace dscore {

class ARMCPU {
public:
    enum class Arch { ARMv4T, ARMv5TE };   // ARM7TDMI / ARM946E-S
    enum Mode : u32 { USR = 0x10, FIQ = 0x11, IRQ = 0x12, SVC = 0x13, ABT = 0x17, UND = 0x1B, SYS = 0x1F };
    static constexpr u32 FlagN = 1u << 31, FlagZ = 1u << 30, FlagC = 1u << 29, FlagV = 1u << 28;
    static constexpr u32 FlagI = 1u << 7, FlagF = 1u << 6, FlagT = 1u << 5;

    ARMCPU(Arch arch, Bus& bus);

    void reset(u32 entry, bool thumb = false);
    // Executes one instruction; returns consumed cycles (simplified: 1).
    int step();
    // Requests an IRQ exception (taken if CPSR.I is clear). Returns true if taken.
    bool raiseIRQ();

    u32 reg(int i) const { return r[i]; }
    void setReg(int i, u32 v) { r[i] = v; }
    u32 pc() const { return r[15]; }           // address of the next instruction
    u32 cpsr() const { return cpsr_; }
    void setCPSR(u32 v);                       // switches register banks
    void setBankedSP(Mode m, u32 sp);
    bool thumb() const { return (cpsr_ & FlagT) != 0; }

    bool halted = false;          // waiting for an interrupt (HLE Halt)
    // Set when an MSR clears CPSR.I (IRQs re-enabled). The system must re-check pending IRQs
    // before the next instruction: a game that enables IRQs for only a few instructions
    // (e.g. halt -> enable -> disable wait loops) would otherwise never see the interrupt.
    bool irqUnmasked = false;
    bool faulted = false;         // hit an unimplemented instruction
    std::string faultMessage;
    u64 instructionsExecuted = 0;

    // HLE hooks (no Nintendo BIOS required).
    std::function<void(ARMCPU&, u32 comment)> onSWI;
    // Coprocessor 15 (ARM9 only): return value for MRC, notification for MCR.
    std::function<u32(u32 cn, u32 cm, u32 op2)> onMRC;
    std::function<void(u32 cn, u32 cm, u32 op2, u32 value)> onMCR;
    // Called when the IRQ exception is taken. Must redirect PC (HLE BIOS).
    std::function<void(ARMCPU&)> onIRQ;

    Bus& bus() { return bus_; }

    // Fast memory: tables of 16 KB page pointers for addresses below 0x08000000
    // (nullptr entries fall back to the Bus). Owned by the system.
    static constexpr u32 kPageShift = 14, kFastLimit = 0x08000000u;
    void setFastPages(u8* const* readPages, u8* const* writePages) { fastRead_ = readPages; fastWrite_ = writePages; fastPagesChanged(); }
    // Must be called whenever the contents of the page tables change (memory remaps): drops the
    // cached instruction-fetch page.
    void fastPagesChanged() { codeBase_ = 0xFFFFFFFFu; codePage_ = nullptr; }

    // Idle-loop skipping: a short backward loop that repeats with identical
    // registers and no memory writes puts the CPU to sleep until woken.
    bool idleSkipEnabled = true;
    bool idle = false;
    void wake() { idle = false; idleTarget_ = 0xFFFFFFFFu; }
    u64 writes() const { return writeCount_; }
    bool sleeping() const { return halted || idle || faulted; }

    u8 rd8(u32 a) {
        if (a < kFastLimit && fastRead_) { if (u8* p = fastRead_[a >> kPageShift]) return p[a & 0x3FFF]; }
        return bus_.read8(a);
    }
    u16 rd16(u32 a) {
        if (a < kFastLimit && fastRead_) { if (u8* p = fastRead_[a >> kPageShift]) { u16 v; std::memcpy(&v, p + (a & 0x3FFE), 2); return v; } }
        return bus_.read16(a);
    }
    u32 rd32(u32 a) {
        if (a < kFastLimit && fastRead_) { if (u8* p = fastRead_[a >> kPageShift]) { u32 v; std::memcpy(&v, p + (a & 0x3FFC), 4); return v; } }
        return bus_.read32(a);
    }
    void wr8(u32 a, u8 v) {
        ++writeCount_;
        if (a < kFastLimit && fastWrite_) { if (u8* p = fastWrite_[a >> kPageShift]) { p[a & 0x3FFF] = v; return; } }
        bus_.write8(a, v);
    }
    // When set, STR/STRH pass the unaligned address to the Bus (GBA 8-bit save RAM needs it);
    // otherwise addresses are aligned first.
    bool rawStoreAddresses = false;
    void wr16(u32 a, u16 v) {
        ++writeCount_;
        if (!rawStoreAddresses) a &= ~1u;
        if (a < kFastLimit && fastWrite_) { if (u8* p = fastWrite_[a >> kPageShift]) { std::memcpy(p + (a & 0x3FFE), &v, 2); return; } }
        bus_.write16(a, v);
    }
    void wr32(u32 a, u32 v) {
        ++writeCount_;
        if (!rawStoreAddresses) a &= ~3u;
        if (a < kFastLimit && fastWrite_) { if (u8* p = fastWrite_[a >> kPageShift]) { std::memcpy(p + (a & 0x3FFC), &v, 4); return; } }
        bus_.write32(a, v);
    }
    Arch arch() const { return arch_; }

    // Helpers usable by HLE code.
    void branchTo(u32 addr, bool thumb);
    u32 spsr() const;
    // User-mode register view (for LDM/STM with the ^ bit).
    u32 userReg(int i) const;
    void setUserReg(int i, u32 v);
    void setSPSR(u32 v);

    // Runs guest code at `addr` (HLE callbacks, e.g. BIOS decompression with a
    // user read callback) until it returns, then restores the caller's
    // registers except r0, whose final value is returned. maxSteps guards loops.
    u32 callGuest(u32 addr, u32 r0, u32 r1 = 0, u32 r2 = 0, u32 maxSteps = 1000000);

    void serialize(StateIO& s) {
        s.tag(0x43505530);
        s.bytes(r, sizeof r); s.pod(cpsr_);
        s.bytes(bankSP_, sizeof bankSP_); s.bytes(bankLR_, sizeof bankLR_); s.bytes(bankSPSR_, sizeof bankSPSR_);
        s.bytes(fiqR8_12_, sizeof fiqR8_12_); s.bytes(usrR8_12_, sizeof usrR8_12_);
        s.pod(halted); s.pod(faulted); s.pod(instructionsExecuted); s.str(faultMessage);
        if (!s.writing()) wake();
    }

private:
    Arch arch_;
    Bus& bus_;
    u32 r[16] = {};
    u32 cpsr_ = SYS;
    // Banks: 0 usr/sys, 1 fiq, 2 irq, 3 svc, 4 abt, 5 und
    u32 bankSP_[6] = {}, bankLR_[6] = {}, bankSPSR_[6] = {};
    u32 fiqR8_12_[5] = {}, usrR8_12_[5] = {};
    bool branched_ = false;
    u8* const* fastRead_ = nullptr;
    // Instruction fetch: the 16 KB page the PC is in (one compare instead of a table walk).
    u32 codeBase_ = 0xFFFFFFFFu;
    const u8* codePage_ = nullptr;
    u16 fetch16(u32 a) {
        if ((a & ~0x3FFFu) == codeBase_) { u16 v; std::memcpy(&v, codePage_ + (a & 0x3FFE), 2); return v; }
        return fetchSlow16(a);
    }
    u32 fetch32(u32 a) {
        if ((a & ~0x3FFFu) == codeBase_) { u32 v; std::memcpy(&v, codePage_ + (a & 0x3FFC), 4); return v; }
        return fetchSlow32(a);
    }
    u16 fetchSlow16(u32 a);
    u32 fetchSlow32(u32 a);
    u8* const* fastWrite_ = nullptr;
    u64 writeCount_ = 0, idleWrites_ = 0;
    u32 idleTarget_ = 0xFFFFFFFFu, idleCPSR_ = 0;
    u32 idleRegs_[15] = {};
    void loopBranch(u32 target, bool thumbState);   // taken B/Bcc: idle detection

    static int bankIndex(u32 mode);
    bool conditionPassed(u32 cond) const;
    void setNZ(u32 v) { cpsr_ = (cpsr_ & ~(FlagN | FlagZ)) | (v & FlagN) | (v == 0 ? FlagZ : 0); }
    void setFlagC(bool c) { cpsr_ = c ? (cpsr_ | FlagC) : (cpsr_ & ~FlagC); }
    void setFlagV(bool v) { cpsr_ = v ? (cpsr_ | FlagV) : (cpsr_ & ~FlagV); }
    bool flagC() const { return (cpsr_ & FlagC) != 0; }

    void writeReg(int rd, u32 v);              // handles PC writes
    void writePCInterwork(u32 v);              // BX semantics
    u32 shift(u32 type, u32 value, u32 amount, bool byRegister, bool& carry) const;
    __attribute__((always_inline)) u32 aluOp(u32 op, u32 a, u32 b, bool setFlags, bool shifterCarry, bool& writesResult);
    void enterException(u32 mode, u32 vector, u32 returnAddr);
    void fault(const char* what, u32 instr);

    // ARM state
    void executeARM(u32 instr);
    void armDataProcessing(u32 instr);
    void armMultiply(u32 instr);
    void armMultiplyLong(u32 instr);
    void armSingleTransfer(u32 instr);
    void armHalfwordTransfer(u32 instr);
    void armBlockTransfer(u32 instr);
    void armSwap(u32 instr);
    void armMRS(u32 instr);
    void armMSR(u32 instr);
    void armCoprocessor(u32 instr);
    void armDSP(u32 instr);

    // Thumb state
    void executeThumb(u16 instr);

    // Memory helpers with ARM rotation semantics
    u32 loadWord(u32 addr);
    u32 loadHalf(u32 addr);
};

} // namespace dscore
