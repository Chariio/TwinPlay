// Copyright (c) 2026 Charlie Rodriguez Garcia. All rights reserved.
// Original clean-room ARM interpreter written from public ARM architecture
// documentation (ARMv4T / ARMv5TE) and GBATEK. No third-party code.
#include "dscore/ARMCPU.hpp"
#include <cstdio>

namespace dscore {

static inline u32 ror32(u32 v, u32 n) { n &= 31; return n ? (v >> n) | (v << (32 - n)) : v; }
static inline u32 bits(u32 v, int hi, int lo) { return (v >> lo) & ((1u << (hi - lo + 1)) - 1); }
static inline bool bit(u32 v, int b) { return (v >> b) & 1; }
static inline s32 signExtend(u32 v, int width) { u32 m = 1u << (width - 1); return s32((v ^ m) - m); }
static inline int popcount16(u32 v) { int c = 0; for (int i = 0; i < 16; ++i) c += (v >> i) & 1; return c; }

ARMCPU::ARMCPU(Arch arch, Bus& bus) : arch_(arch), bus_(bus) {}

int ARMCPU::bankIndex(u32 mode) {
    switch (mode & 0x1F) {
    case FIQ: return 1; case IRQ: return 2; case SVC: return 3;
    case ABT: return 4; case UND: return 5; default: return 0;
    }
}

void ARMCPU::reset(u32 entry, bool thumbState) {
    for (auto& x : r) x = 0;
    for (int i = 0; i < 6; ++i) bankSP_[i] = bankLR_[i] = bankSPSR_[i] = 0;
    cpsr_ = SYS | FlagI | FlagF;
    halted = faulted = false;
    wake();
    faultMessage.clear();
    instructionsExecuted = 0;
    irqUnmasked = false;
    branchTo(entry, thumbState);
}

void ARMCPU::setCPSR(u32 v) {
    u32 oldMode = cpsr_ & 0x1F, newMode = v & 0x1F;
    if (oldMode != newMode) {
        int ob = bankIndex(oldMode), nb = bankIndex(newMode);
        bankSP_[ob] = r[13]; bankLR_[ob] = r[14];
        if (ob != nb && (ob == 1 || nb == 1)) {
            if (ob == 1) { for (int i = 0; i < 5; ++i) { fiqR8_12_[i] = r[8 + i]; r[8 + i] = usrR8_12_[i]; } }
            else         { for (int i = 0; i < 5; ++i) { usrR8_12_[i] = r[8 + i]; r[8 + i] = fiqR8_12_[i]; } }
        }
        r[13] = bankSP_[nb]; r[14] = bankLR_[nb];
    }
    cpsr_ = v;
}

void ARMCPU::setBankedSP(Mode m, u32 sp) {
    if (bankIndex(cpsr_) == bankIndex(m)) r[13] = sp; else bankSP_[bankIndex(m)] = sp;
}

u32 ARMCPU::spsr() const { int b = bankIndex(cpsr_); return b ? bankSPSR_[b] : cpsr_; }
void ARMCPU::setSPSR(u32 v) { int b = bankIndex(cpsr_); if (b) bankSPSR_[b] = v; }

u32 ARMCPU::userReg(int i) const {
    int b = bankIndex(cpsr_);
    if (i >= 8 && i <= 12) return b == 1 ? usrR8_12_[i - 8] : r[i];
    if (i == 13 || i == 14) return b == 0 ? r[i] : (i == 13 ? bankSP_[0] : bankLR_[0]);
    return r[i];
}

void ARMCPU::setUserReg(int i, u32 v) {
    int b = bankIndex(cpsr_);
    if (i >= 8 && i <= 12) { if (b == 1) usrR8_12_[i - 8] = v; else r[i] = v; return; }
    if (i == 13 || i == 14) { if (b == 0) r[i] = v; else (i == 13 ? bankSP_[0] : bankLR_[0]) = v; return; }
    r[i] = v;
}

void ARMCPU::branchTo(u32 addr, bool thumbState) {
    if (thumbState) { cpsr_ |= FlagT; r[15] = addr & ~1u; }
    else            { cpsr_ &= ~FlagT; r[15] = addr & ~3u; }
    branched_ = true;
}

void ARMCPU::loopBranch(u32 target, bool thumbState) {
    u32 here = r[15] - (thumbState ? 4 : 8);
    if (idleSkipEnabled && target <= here && here - target <= 0x40) {
        if (target == idleTarget_ && writeCount_ == idleWrites_ && cpsr_ == idleCPSR_ &&
            std::memcmp(idleRegs_, r, sizeof idleRegs_) == 0) {
            idle = true;
        } else {
            idleTarget_ = target; idleWrites_ = writeCount_; idleCPSR_ = cpsr_;
            std::memcpy(idleRegs_, r, sizeof idleRegs_);
        }
    }
    branchTo(target, thumbState);
}

void ARMCPU::writeReg(int rd, u32 v) {
    if (rd == 15) branchTo(v, thumb());
    else r[rd] = v;
}

void ARMCPU::writePCInterwork(u32 v) { branchTo(v, (v & 1) != 0); }

void ARMCPU::fault(const char* what, u32 instr) {
    char buf[160];
    std::snprintf(buf, sizeof buf, "%s %s 0x%08X at 0x%08X", arch_ == Arch::ARMv5TE ? "ARM9" : "ARM7",
                  what, instr, r[15] - (thumb() ? 4 : 8));
    faultMessage = buf;
    faulted = true;
}

namespace {
// cond (0-15) x NZCV (cpsr bits 31-28) -> passed; built once from the same rules as the old switch.
struct CondTable {
    u16 t[16];   // bit k of t[cond] = result for NZCV == k
    CondTable() {
        for (u32 cond = 0; cond < 16; ++cond) {
            t[cond] = 0;
            for (u32 k = 0; k < 16; ++k) {
                bool n = k & 8, z = k & 4, c = k & 2, v = k & 1, r = false;
                switch (cond) {
                case 0x0: r = z; break;            case 0x1: r = !z; break;
                case 0x2: r = c; break;            case 0x3: r = !c; break;
                case 0x4: r = n; break;            case 0x5: r = !n; break;
                case 0x6: r = v; break;            case 0x7: r = !v; break;
                case 0x8: r = c && !z; break;      case 0x9: r = !c || z; break;
                case 0xA: r = n == v; break;       case 0xB: r = n != v; break;
                case 0xC: r = !z && n == v; break; case 0xD: r = z || n != v; break;
                case 0xE: r = true; break;         default: r = false; break;
                }
                if (r) t[cond] |= u16(1u << k);
            }
        }
    }
};
const CondTable kCond;
} // namespace

bool ARMCPU::conditionPassed(u32 cond) const {
    return (kCond.t[cond & 15] >> (cpsr_ >> 28)) & 1;
}

u32 ARMCPU::loadWord(u32 addr) { return ror32(rd32(addr & ~3u), (addr & 3) * 8); }
u32 ARMCPU::loadHalf(u32 addr) {
    u32 v = rd16(addr & ~1u);
    if (arch_ == Arch::ARMv4T && (addr & 1)) v = ror32(v, 8);
    return v;
}

u32 ARMCPU::shift(u32 type, u32 value, u32 amount, bool byRegister, bool& carry) const {
    if (byRegister) {
        amount &= 0xFF;
        if (amount == 0) return value;
    }
    switch (type) {
    case 0: // LSL
        if (amount == 0) return value;
        if (amount < 32) { carry = bit(value, 32 - amount); return value << amount; }
        carry = (amount == 32) ? (value & 1) : false; return 0;
    case 1: // LSR (#0 encodes #32 for immediates)
        if (amount == 0) amount = 32;
        if (amount < 32) { carry = bit(value, amount - 1); return value >> amount; }
        carry = (amount == 32) ? bit(value, 31) : false; return 0;
    case 2: // ASR
        if (amount == 0) amount = 32;
        if (amount < 32) { carry = bit(value, amount - 1); return u32(s32(value) >> amount); }
        carry = bit(value, 31); return carry ? 0xFFFFFFFFu : 0;
    default: // ROR / RRX
        if (amount == 0) { bool c = carry; carry = value & 1; return (value >> 1) | (u32(c) << 31); } // RRX (imm only)
        if ((amount & 31) == 0) { carry = bit(value, 31); return value; }
        { u32 res = ror32(value, amount); carry = bit(res, 31); return res; }
    }
}

u32 ARMCPU::aluOp(u32 op, u32 a, u32 b, bool s, bool shc, bool& writes) {
    writes = !(op >= 8 && op <= 11);
    auto add = [&](u32 x, u32 y, u32 cin) {
        u64 wide = u64(x) + u64(y) + cin; u32 res = u32(wide);
        if (s) { setNZ(res); setFlagC(wide >> 32); setFlagV(((~(x ^ y)) & (x ^ res)) >> 31); }
        return res;
    };
    u32 res;
    switch (op) {
    case 0x0: case 0x8: res = a & b;  if (s) { setNZ(res); setFlagC(shc); } return res;
    case 0x1: case 0x9: res = a ^ b;  if (s) { setNZ(res); setFlagC(shc); } return res;
    case 0x2: case 0xA: return add(a, ~b, 1);
    case 0x3:           return add(b, ~a, 1);
    case 0x4: case 0xB: return add(a, b, 0);
    case 0x5:           return add(a, b, flagC());
    case 0x6:           return add(a, ~b, flagC());
    case 0x7:           return add(b, ~a, flagC());
    case 0xC: res = a | b;  if (s) { setNZ(res); setFlagC(shc); } return res;
    case 0xD: res = b;      if (s) { setNZ(res); setFlagC(shc); } return res;
    case 0xE: res = a & ~b; if (s) { setNZ(res); setFlagC(shc); } return res;
    default:  res = ~b;     if (s) { setNZ(res); setFlagC(shc); } return res;
    }
}

void ARMCPU::enterException(u32 mode, u32 vector, u32 returnAddr) {
    u32 old = cpsr_;
    setCPSR((cpsr_ & ~(0x1Fu | FlagT)) | mode | FlagI);
    setSPSR(old);
    r[14] = returnAddr;
    u32 base = (arch_ == Arch::ARMv5TE) ? 0xFFFF0000u : 0;
    branchTo(base + vector, false);
}

bool ARMCPU::raiseIRQ() {
    if (cpsr_ & FlagI) return false;
    halted = false;
    wake();
    // r[15] holds the next instruction; LR_irq = next + 4 so "SUBS PC, LR, #4" resumes it.
    enterException(IRQ, 0x18, r[15] + 4);
    if (onIRQ) onIRQ(*this);
    return true;
}

u32 ARMCPU::callGuest(u32 addr, u32 a0, u32 a1, u32 a2, u32 maxSteps) {
    constexpr u32 kReturnMagic = 0xFFFF0300u;          // unmapped BIOS address used as return target
    u32 savedR[16]; std::memcpy(savedR, r, sizeof r);
    u32 savedCPSR = cpsr_;
    bool savedBranched = branched_, savedHalted = halted, savedIdle = idle;
    bool savedIdleSkip = idleSkipEnabled;
    idleSkipEnabled = false; halted = false; idle = false;
    r[0] = a0; r[1] = a1; r[2] = a2; r[14] = kReturnMagic;
    branchTo(addr, addr & 1);
    for (u32 n = 0; n < maxSteps && !faulted; ++n) {
        if ((r[15] & ~1u) == kReturnMagic) break;
        step();
    }
    u32 result = r[0];
    setCPSR(savedCPSR);
    std::memcpy(r, savedR, sizeof r);
    branched_ = savedBranched; halted = savedHalted; idle = savedIdle; idleSkipEnabled = savedIdleSkip;
    return result;
}

u16 ARMCPU::fetchSlow16(u32 a) {
    if (a < kFastLimit && fastRead_) {
        if (u8* p = fastRead_[a >> kPageShift]) { codeBase_ = a & ~0x3FFFu; codePage_ = p; u16 v; std::memcpy(&v, p + (a & 0x3FFE), 2); return v; }
    }
    return bus_.read16(a);
}

u32 ARMCPU::fetchSlow32(u32 a) {
    if (a < kFastLimit && fastRead_) {
        if (u8* p = fastRead_[a >> kPageShift]) { codeBase_ = a & ~0x3FFFu; codePage_ = p; u32 v; std::memcpy(&v, p + (a & 0x3FFC), 4); return v; }
    }
    return bus_.read32(a);
}

int ARMCPU::step() {
    if (halted || faulted || idle) return 1;
    branched_ = false;
    u32 addr = r[15];
    if (thumb()) {
        u16 instr = fetch16(addr);
        r[15] = addr + 4;
        executeThumb(instr);
        if (!branched_) r[15] = addr + 2;
    } else {
        u32 instr = fetch32(addr);
        r[15] = addr + 8;
        executeARM(instr);
        if (!branched_) r[15] = addr + 4;
    }
    ++instructionsExecuted;
    return 1;
}

// ---------------------------------------------------------------- ARM state

namespace {
// Coarse decode table indexed by instruction bits 27-20 and 7-4.
enum ArmClass : u8 { kSlow, kDataProc, kSingle, kBlock, kBranch };
struct ArmDecodeTable {
    u8 t[4096];
    ArmDecodeTable() {
        for (u32 k = 0; k < 4096; ++k) {
            u32 hi = k >> 4, lo = k & 15;            // hi = bits 27-20, lo = bits 7-4
            u32 top = hi >> 5;                       // bits 27-25
            bool misc = ((hi >> 3) & 3) == 2 && !(hi & 1);   // opcode 10xx with S=0
            u8 c = kSlow;
            if (top == 0) c = ((lo & 9) == 9 || misc) ? kSlow : kDataProc;
            else if (top == 1) c = misc ? kSlow : kDataProc;
            else if (top == 2) c = kSingle;
            else if (top == 3) c = (lo & 1) ? kSlow : kSingle;
            else if (top == 4) c = kBlock;
            else if (top == 5) c = kBranch;
            t[k] = c;
        }
    }
};
const ArmDecodeTable kArmDecode;
} // namespace

void ARMCPU::executeARM(u32 instr) {
    u32 cond = instr >> 28;
    if (cond == 0xE || (cond != 0xF && conditionPassed(cond))) {
        switch (kArmDecode.t[((instr >> 16) & 0xFF0) | ((instr >> 4) & 0xF)]) {
        case kDataProc: armDataProcessing(instr); return;
        case kSingle: armSingleTransfer(instr); return;
        case kBlock: armBlockTransfer(instr); return;
        case kBranch:
            if (bit(instr, 24)) r[14] = r[15] - 4;
            loopBranch(r[15] + (u32(signExtend(bits(instr, 23, 0), 24)) << 2), false);
            return;
        default: break;                              // fall through to the full decoder
        }
    } else if (cond != 0xF) return;
    if (cond == 0xF) {
        if (arch_ == Arch::ARMv5TE && (instr & 0x0E000000) == 0x0A000000) { // BLX imm
            u32 target = r[15] + (u32(signExtend(bits(instr, 23, 0), 24)) << 2) + (bit(instr, 24) << 1);
            r[14] = r[15] - 4;
            branchTo(target, true);
            return;
        }
        if (arch_ == Arch::ARMv5TE && (instr & 0x0D70F000) == 0x0550F000) return; // PLD
        fault("undefined (cond=NV)", instr);
        return;
    }
    if (!conditionPassed(cond)) return;

    if ((instr & 0x0FF000F0) == 0x01200070) return;                                           // BKPT: ignored
    if ((instr & 0x0FFFFFF0) == 0x012FFF10) { writePCInterwork(r[instr & 15]); return; }        // BX
    if (arch_ == Arch::ARMv5TE && (instr & 0x0FFFFFF0) == 0x012FFF30) {                         // BLX reg
        u32 target = r[instr & 15]; r[14] = r[15] - 4; writePCInterwork(target); return;
    }
    if (arch_ == Arch::ARMv5TE && (instr & 0x0FFF0FF0) == 0x016F0F10) {                         // CLZ
        u32 v = r[instr & 15], n = 0; if (!v) n = 32; else while (!(v & 0x80000000u)) { v <<= 1; ++n; }
        writeReg(bits(instr, 15, 12), n); return;
    }
    if (arch_ == Arch::ARMv5TE && ((instr & 0x0F900090) == 0x01000080 || (instr & 0x0F9000F0) == 0x01000050)) {
        armDSP(instr); return;
    }
    if ((instr & 0x0FC000F0) == 0x00000090) { armMultiply(instr); return; }
    if ((instr & 0x0F8000F0) == 0x00800090) { armMultiplyLong(instr); return; }
    if ((instr & 0x0FB00FF0) == 0x01000090) { armSwap(instr); return; }
    if ((instr & 0x0E000090) == 0x00000090 && (instr & 0x60)) { armHalfwordTransfer(instr); return; }
    if ((instr & 0x0FBF0FFF) == 0x010F0000) { armMRS(instr); return; }
    if ((instr & 0x0DB0F000) == 0x0120F000) { armMSR(instr); return; }
    if ((instr & 0x0C000000) == 0x00000000) { armDataProcessing(instr); return; }
    if ((instr & 0x0C000000) == 0x04000000) {
        if ((instr & 0x02000010) == 0x02000010) { fault("undefined", instr); return; }
        armSingleTransfer(instr); return;
    }
    if ((instr & 0x0E000000) == 0x08000000) { armBlockTransfer(instr); return; }
    if ((instr & 0x0E000000) == 0x0A000000) {                                                   // B / BL
        if (bit(instr, 24)) r[14] = r[15] - 4;
        loopBranch(r[15] + (u32(signExtend(bits(instr, 23, 0), 24)) << 2), false);
        return;
    }
    if ((instr & 0x0F000010) == 0x0E000010) { armCoprocessor(instr); return; }
    if ((instr & 0x0E000000) == 0x0C000000) return;                                           // LDC/STC: no such coprocessors
    if ((instr & 0x0F000010) == 0x0E000000) return;                                           // CDP: no-op
    if ((instr & 0x0F000000) == 0x0F000000) {                                                   // SWI
        if (onSWI) onSWI(*this, bits(instr, 23, 16)); else enterException(SVC, 0x08, r[15] - 4);   // real BIOS (LLE)
        return;
    }
    fault("unimplemented", instr);
}

void ARMCPU::armDataProcessing(u32 instr) {
    u32 op = bits(instr, 24, 21), rn = bits(instr, 19, 16), rd = bits(instr, 15, 12);
    bool s = bit(instr, 20);
    bool carry = flagC();
    u32 op2;
    u32 a = r[rn];
    if (bit(instr, 25)) {
        u32 rot = bits(instr, 11, 8) * 2;
        op2 = ror32(instr & 0xFF, rot);
        if (rot) carry = bit(op2, 31);
    } else {
        u32 rm = instr & 15, type = bits(instr, 6, 5);
        u32 vm = r[rm];
        if (bit(instr, 4)) {                      // shift by register: PC reads +12
            if (rm == 15) vm += 4;
            if (rn == 15) a += 4;
            op2 = shift(type, vm, r[bits(instr, 11, 8)], true, carry);
        } else {
            op2 = shift(type, vm, bits(instr, 11, 7), false, carry);
        }
    }
    bool writes;
    bool flags = s && rd != 15;
    u32 res = aluOp(op, a, op2, flags, carry, writes);
    if (s && rd == 15) {                          // exception return: CPSR <- SPSR
        u32 sp = spsr();
        setCPSR(sp);
        if (writes) branchTo(res, (sp & FlagT) != 0);
        return;
    }
    if (writes) writeReg(rd, res);
}

void ARMCPU::armMultiply(u32 instr) {
    u32 rd = bits(instr, 19, 16), rn = bits(instr, 15, 12), rs = bits(instr, 11, 8), rm = instr & 15;
    u32 res = r[rm] * r[rs];
    if (bit(instr, 21)) res += r[rn];
    if (bit(instr, 20)) setNZ(res);
    writeReg(rd, res);
}

void ARMCPU::armMultiplyLong(u32 instr) {
    u32 hi = bits(instr, 19, 16), lo = bits(instr, 15, 12), rs = bits(instr, 11, 8), rm = instr & 15;
    u64 res = bit(instr, 22) ? u64(s64(s32(r[rm])) * s64(s32(r[rs]))) : u64(r[rm]) * u64(r[rs]);
    if (bit(instr, 21)) res += (u64(r[hi]) << 32) | r[lo];
    if (bit(instr, 20)) {
        cpsr_ = (cpsr_ & ~(FlagN | FlagZ)) | ((res >> 63) ? FlagN : 0) | (res == 0 ? FlagZ : 0);
    }
    r[lo] = u32(res); r[hi] = u32(res >> 32);
}

void ARMCPU::armDSP(u32 instr) {
    u32 op = bits(instr, 22, 21);
    u32 rd = bits(instr, 19, 16), rn = bits(instr, 15, 12), rs = bits(instr, 11, 8), rm = instr & 15;
    constexpr u32 FlagQ = 1u << 27;
    auto sat = [&](s64 v) -> u32 {
        if (v > 0x7FFFFFFFLL) { cpsr_ |= FlagQ; return 0x7FFFFFFFu; }
        if (v < -0x80000000LL) { cpsr_ |= FlagQ; return 0x80000000u; }
        return u32(s32(v));
    };
    if ((instr & 0xF0) == 0x50) {                 // QADD / QSUB / QDADD / QDSUB
        s64 m = s32(r[rm]), n = s32(r[rn]);
        if (op & 2) n = s32(sat(n * 2));
        r[rd] = sat((op & 1) ? m - n : m + n);
        return;
    }
    auto half = [](u32 v, bool top) -> s32 { return s16(top ? (v >> 16) : (v & 0xFFFF)); };
    bool x = bit(instr, 5), y = bit(instr, 6);
    switch (op) {
    case 0: { s64 p = s64(half(r[rm], x)) * half(r[rs], y); r[rd] = u32(p + s32(r[rn]));
              if (p + s64(s32(r[rn])) != s64(s32(r[rd]))) cpsr_ |= FlagQ; break; }       // SMLAxy
    case 1: { s64 p = (s64(s32(r[rm])) * half(r[rs], y)) >> 16;
              if (!x) { s64 sum = p + s32(r[rn]); r[rd] = u32(sum); if (sum != s64(s32(r[rd]))) cpsr_ |= FlagQ; } // SMLAWy
              else r[rd] = u32(p);                                                         // SMULWy
              break; }
    case 2: { s64 p = s64(half(r[rm], x)) * half(r[rs], y);                                  // SMLALxy
              u64 acc = ((u64(r[rd]) << 32) | r[rn]) + u64(p); r[rn] = u32(acc); r[rd] = u32(acc >> 32); break; }
    default: r[rd] = u32(s32(half(r[rm], x) * half(r[rs], y))); break;                         // SMULxy
    }
}

void ARMCPU::armSingleTransfer(u32 instr) {
    bool P = bit(instr, 24), U = bit(instr, 23), B = bit(instr, 22), W = bit(instr, 21), L = bit(instr, 20);
    u32 rn = bits(instr, 19, 16), rd = bits(instr, 15, 12);
    u32 offset;
    if (bit(instr, 25)) { bool c = flagC(); offset = shift(bits(instr, 6, 5), r[instr & 15], bits(instr, 11, 7), false, c); }
    else offset = instr & 0xFFF;
    u32 base = r[rn];
    u32 target = U ? base + offset : base - offset;
    u32 addr = P ? target : base;
    bool writeback = !P || W;
    if (L) {
        u32 v = B ? rd8(addr) : loadWord(addr);
        if (writeback && rn != rd) r[rn] = target;
        if (rd == 15) { if (arch_ == Arch::ARMv5TE) writePCInterwork(v); else branchTo(v, false); }
        else r[rd] = v;
    } else {
        u32 v = (rd == 15) ? r[15] + 4 : r[rd];
        if (B) wr8(addr, u8(v)); else wr32(addr, v);
        if (writeback) writeReg(rn, target);
    }
}

void ARMCPU::armHalfwordTransfer(u32 instr) {
    bool P = bit(instr, 24), U = bit(instr, 23), I = bit(instr, 22), W = bit(instr, 21), L = bit(instr, 20);
    u32 rn = bits(instr, 19, 16), rd = bits(instr, 15, 12), sh = bits(instr, 6, 5);
    u32 offset = I ? ((bits(instr, 11, 8) << 4) | (instr & 15)) : r[instr & 15];
    u32 base = r[rn];
    u32 target = U ? base + offset : base - offset;
    u32 addr = P ? target : base;
    bool writeback = !P || W;
    if (L) {
        u32 v;
        if (sh == 1) v = loadHalf(addr);
        else if (sh == 2) v = u32(s32(s8(rd8(addr))));
        else v = (arch_ == Arch::ARMv4T && (addr & 1)) ? u32(s32(s8(rd8(addr))))
                                                       : u32(s32(s16(rd16(addr & ~1u))));
        if (writeback && rn != rd) r[rn] = target;
        writeReg(rd, v);
        return;
    }
    if (sh == 1) {                                 // STRH
        u32 v = (rd == 15) ? r[15] + 4 : r[rd];
        wr16(addr, u16(v));
    } else if (arch_ == Arch::ARMv5TE) {           // LDRD (sh=2) / STRD (sh=3)
        if (rd & 1) { fault("LDRD/STRD odd register", instr); return; }
        if (sh == 2) { r[rd] = rd32(addr & ~3u); writeReg(rd + 1, rd32((addr + 4) & ~3u)); }
        else { wr32(addr & ~3u, r[rd]); wr32((addr + 4) & ~3u, r[rd + 1]); }
    } else { fault("undefined halfword op", instr); return; }
    if (writeback) writeReg(rn, target);
}

void ARMCPU::armBlockTransfer(u32 instr) {
    bool P = bit(instr, 24), U = bit(instr, 23), S = bit(instr, 22), W = bit(instr, 21), L = bit(instr, 20);
    u32 rn = bits(instr, 19, 16), list = instr & 0xFFFF;
    u32 base = r[rn];
    u32 n = popcount16(list);
    u32 span = n ? n * 4 : 0x40;
    u32 start = U ? (P ? base + 4 : base) : (P ? base - span : base - span + 4);
    u32 newBase = U ? base + span : base - span;
    u32 addr = start;
    if (!n && arch_ == Arch::ARMv4T) list = 0x8000;   // ARM7TDMI: empty list transfers PC, base moves by 0x40
    if (L) {
        bool loadsPC = bit(list, 15);
        bool userBank = S && !loadsPC;
        if (W && !bit(list, rn)) r[rn] = newBase;
        for (int i = 0; i < 15; ++i) if (bit(list, i)) {
            u32 v = rd32(addr & ~3u); addr += 4;
            if (userBank) setUserReg(i, v); else r[i] = v;
        }
        if (loadsPC) {
            u32 v = rd32(addr & ~3u);
            if (S) { u32 sp = spsr(); setCPSR(sp); branchTo(v, (sp & FlagT) != 0); }
            else if (arch_ == Arch::ARMv5TE) writePCInterwork(v);
            else branchTo(v, false);
        }
    } else {
        for (int i = 0; i < 16; ++i) if (bit(list, i)) {
            u32 v = (i == 15) ? r[15] + 4 : (S ? userReg(i) : r[i]);
            if (W && u32(i) == rn && (list & ((1u << rn) - 1))) v = newBase;   // base not first: new base stored
            wr32(addr & ~3u, v); addr += 4;
        }
        if (W) r[rn] = newBase;
    }
}

void ARMCPU::armSwap(u32 instr) {
    u32 rn = bits(instr, 19, 16), rd = bits(instr, 15, 12), rm = instr & 15;
    u32 addr = r[rn], src = r[rm];
    if (bit(instr, 22)) { u32 t = rd8(addr); wr8(addr, u8(src)); writeReg(rd, t); }
    else { u32 t = loadWord(addr); wr32(addr & ~3u, src); writeReg(rd, t); }
}

void ARMCPU::armMRS(u32 instr) {
    r[bits(instr, 15, 12)] = bit(instr, 22) ? spsr() : cpsr_;
}

void ARMCPU::armMSR(u32 instr) {
    u32 v = bit(instr, 25) ? ror32(instr & 0xFF, bits(instr, 11, 8) * 2) : r[instr & 15];
    u32 mask = 0;
    if (bit(instr, 19)) mask |= 0xFF000000u;
    if (bit(instr, 18)) mask |= 0x00FF0000u;
    if (bit(instr, 17)) mask |= 0x0000FF00u;
    if (bit(instr, 16)) mask |= 0x000000FFu;
    if (bit(instr, 22)) { setSPSR((spsr() & ~mask) | (v & mask)); return; }
    if ((cpsr_ & 0x1F) == USR) mask &= 0xFF000000u;
    mask &= ~FlagT;                                // MSR cannot change the T bit
    u32 before = cpsr_;
    setCPSR((cpsr_ & ~mask) | (v & mask));
    if ((before & FlagI) && !(cpsr_ & FlagI)) irqUnmasked = true;
}

void ARMCPU::armCoprocessor(u32 instr) {
    u32 cp = bits(instr, 11, 8);
    if (cp != 15 || arch_ != Arch::ARMv5TE) {
        // The ARM7 has a CP14 debug interface some games touch; treat as no-op.
        if (bit(instr, 20)) { u32 rd = bits(instr, 15, 12); if (rd != 15) r[rd] = 0; }
        return;
    }
    u32 cn = bits(instr, 19, 16), cm = instr & 15, op2 = bits(instr, 7, 5), rd = bits(instr, 15, 12);
    if (bit(instr, 20)) {
        u32 v = onMRC ? onMRC(cn, cm, op2) : 0;
        if (rd != 15) r[rd] = v; else cpsr_ = (cpsr_ & 0x0FFFFFFFu) | (v & 0xF0000000u);
    }
    else if (onMCR) onMCR(cn, cm, op2, r[rd]);
}

// -------------------------------------------------------------- Thumb state

void ARMCPU::executeThumb(u16 op) {
    u32 i = op;
    switch (i >> 13) {
    case 0: {
        if ((i & 0x1800) == 0x1800) {             // ADD/SUB register or imm3
            u32 rd = i & 7, rs = (i >> 3) & 7, rnImm = (i >> 6) & 7;
            u32 b = bit(i, 10) ? rnImm : r[rnImm];
            bool w; r[rd] = aluOp(bit(i, 9) ? 0x2 : 0x4, r[rs], b, true, false, w);
        } else {                                   // LSL/LSR/ASR imm5
            u32 rd = i & 7, rs = (i >> 3) & 7, amt = (i >> 6) & 31, type = (i >> 11) & 3;
            bool c = flagC();
            u32 res = shift(type, r[rs], amt, false, c);
            setNZ(res); setFlagC(c); r[rd] = res;
        }
        return;
    }
    case 1: {                                      // MOV/CMP/ADD/SUB imm8
        u32 rd = (i >> 8) & 7, imm = i & 0xFF, sub = (i >> 11) & 3;
        static const u32 ops[4] = {0xD, 0xA, 0x4, 0x2};
        bool w; u32 res = aluOp(ops[sub], r[rd], imm, true, flagC(), w);
        if (w) r[rd] = res;
        return;
    }
    case 2: {
        if ((i & 0xFC00) == 0x4000) {              // ALU operations
            u32 rd = i & 7, rs = (i >> 3) & 7, op = (i >> 6) & 15;
            bool c = flagC(), w; u32 res;
            switch (op) {
            case 0x2: case 0x3: case 0x4: case 0x7: {      // LSL LSR ASR ROR by register
                static const u32 t[] = {0, 0, 0, 1, 2, 0, 0, 3};
                res = shift(t[op], r[rd], r[rs], true, c); setNZ(res); setFlagC(c); r[rd] = res; return;
            }
            case 0x9: res = aluOp(0x3, r[rs], 0, true, c, w); r[rd] = res; return;   // NEG = RSB #0
            case 0xD: res = r[rd] * r[rs]; setNZ(res); r[rd] = res; return;          // MUL
            default: {
                static const u32 map[16] = {0x0, 0x1, 0, 0, 0, 0x5, 0x6, 0, 0x8, 0, 0xA, 0xB, 0xC, 0, 0xE, 0xF};
                res = aluOp(map[op], r[rd], r[rs], true, c, w);
                if (w) r[rd] = res;
                return;
            }
            }
        }
        if ((i & 0xFC00) == 0x4400) {              // Hi register ops / BX / BLX
            u32 rd = (i & 7) | ((i >> 4) & 8), rs = (i >> 3) & 15, op = (i >> 8) & 3;
            switch (op) {
            case 0: writeReg(rd, r[rd] + r[rs]); return;
            case 1: { bool w; aluOp(0xA, r[rd], r[rs], true, false, w); return; }
            case 2: writeReg(rd, r[rs]); return;
            default:
                if (bit(i, 7) && arch_ == Arch::ARMv5TE) { u32 t = r[rs]; r[14] = (r[15] - 2) | 1; writePCInterwork(t); }
                else writePCInterwork(r[rs]);
                return;
            }
        }
        if ((i & 0xF800) == 0x4800) {              // LDR Rd, [PC, #imm]
            r[(i >> 8) & 7] = rd32(((r[15] & ~3u) + ((i & 0xFF) << 2)));
            return;
        }
        // Load/store with register offset (0101xxx)
        u32 rd = i & 7, rb = (i >> 3) & 7, ro = (i >> 6) & 7;
        u32 addr = r[rb] + r[ro];
        switch ((i >> 9) & 7) {
        case 0: wr32(addr, r[rd]); return;                 // STR
        case 1: wr16(addr, u16(r[rd])); return;            // STRH
        case 2: wr8(addr, u8(r[rd])); return;                    // STRB
        case 3: r[rd] = u32(s32(s8(rd8(addr)))); return;          // LDRSB
        case 4: r[rd] = loadWord(addr); return;                          // LDR
        case 5: r[rd] = loadHalf(addr); return;                          // LDRH
        case 6: r[rd] = rd8(addr); return;                        // LDRB
        default: r[rd] = (arch_ == Arch::ARMv4T && (addr & 1)) ? u32(s32(s8(rd8(addr))))
                                                               : u32(s32(s16(rd16(addr & ~1u)))); return; // LDRSH
        }
    }
    case 3: {                                      // LDR/STR(B) imm5
        u32 rd = i & 7, rb = (i >> 3) & 7, off = (i >> 6) & 31;
        bool byte = bit(i, 12), load = bit(i, 11);
        u32 addr = r[rb] + (byte ? off : off << 2);
        if (load) r[rd] = byte ? rd8(addr) : loadWord(addr);
        else if (byte) wr8(addr, u8(r[rd])); else wr32(addr, r[rd]);
        return;
    }
    case 4: {
        if (!bit(i, 12)) {                         // LDRH/STRH imm5
            u32 rd = i & 7, rb = (i >> 3) & 7, addr = r[rb] + (((i >> 6) & 31) << 1);
            if (bit(i, 11)) r[rd] = loadHalf(addr); else wr16(addr, u16(r[rd]));
        } else {                                   // SP-relative LDR/STR
            u32 rd = (i >> 8) & 7, addr = r[13] + ((i & 0xFF) << 2);
            if (bit(i, 11)) r[rd] = loadWord(addr); else wr32(addr, r[rd]);
        }
        return;
    }
    case 5: {
        if (!bit(i, 12)) {                         // ADD Rd, PC/SP, #imm
            u32 rd = (i >> 8) & 7, imm = (i & 0xFF) << 2;
            r[rd] = bit(i, 11) ? r[13] + imm : (r[15] & ~3u) + imm;
            return;
        }
        if ((i & 0xFF00) == 0xB000) {              // ADD/SUB SP, #imm7
            u32 imm = (i & 0x7F) << 2; r[13] = bit(i, 7) ? r[13] - imm : r[13] + imm; return;
        }
        if ((i & 0xF600) == 0xB400) {              // PUSH / POP
            u32 list = i & 0xFF; bool R = bit(i, 8);
            if (!bit(i, 11)) {
                u32 n = popcount16(list) + (R ? 1 : 0);
                u32 addr = r[13] - n * 4; r[13] = addr;
                for (int k = 0; k < 8; ++k) if (bit(list, k)) { wr32(addr, r[k]); addr += 4; }
                if (R) wr32(addr, r[14]);
            } else {
                u32 addr = r[13];
                for (int k = 0; k < 8; ++k) if (bit(list, k)) { r[k] = rd32(addr); addr += 4; }
                if (R) { u32 v = rd32(addr); addr += 4; r[13] = addr;
                         if (arch_ == Arch::ARMv5TE) writePCInterwork(v); else branchTo(v, true); }
                else r[13] = addr;
            }
            return;
        }
        if ((i & 0xFF00) == 0xBE00) return;        // BKPT: ignored
        fault("unimplemented thumb", i);
        return;
    }
    case 6: {
        if (!bit(i, 12)) {                         // LDMIA / STMIA
            u32 rb = (i >> 8) & 7, list = i & 0xFF, addr = r[rb];
            if (!list && arch_ == Arch::ARMv4T) {      // empty list: transfers PC, base moves by 0x40
                if (bit(i, 11)) { r[rb] = addr + 0x40; branchTo(rd32(addr & ~3u), true); }
                else { wr32(addr & ~3u, r[15] + 2); r[rb] = addr + 0x40; }
                return;
            }
            if (bit(i, 11)) {
                for (int k = 0; k < 8; ++k) if (bit(list, k)) { r[k] = rd32(addr & ~3u); addr += 4; }
                if (!bit(list, rb)) r[rb] = addr;
            } else {
                u32 end = addr + popcount16(list) * 4;
                for (int k = 0; k < 8; ++k) if (bit(list, k)) {
                    u32 v = (u32(k) == rb && (list & ((1u << rb) - 1))) ? end : r[k];   // base not first: new base
                    wr32(addr & ~3u, v); addr += 4;
                }
                r[rb] = addr;
            }
            return;
        }
        u32 cond = (i >> 8) & 15;
        if (cond == 0xF) { if (onSWI) onSWI(*this, i & 0xFF); else enterException(SVC, 0x08, r[15] - 2); return; }
        if (cond == 0xE) { fault("undefined thumb", i); return; }
        if (conditionPassed(cond)) loopBranch(r[15] + (u32(signExtend(i & 0xFF, 8)) << 1), true);
        return;
    }
    default: {
        u32 kind = (i >> 11) & 3;
        if (kind == 0) { loopBranch(r[15] + (u32(signExtend(i & 0x7FF, 11)) << 1), true); return; } // B
        if (kind == 2) { r[14] = r[15] + (u32(signExtend(i & 0x7FF, 11)) << 12); return; }        // BL prefix
        u32 next = r[15] - 2;
        u32 target = r[14] + ((i & 0x7FF) << 1);
        r[14] = next | 1;
        if (kind == 3) branchTo(target, true);                                                    // BL suffix
        else if (arch_ == Arch::ARMv5TE) branchTo(target & ~3u, false);                           // BLX suffix
        else fault("BLX on ARMv4", i);
        return;
    }
    }
}

} // namespace dscore
