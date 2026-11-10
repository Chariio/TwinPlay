// Copyright (c) 2026 Charlie Rodriguez Garcia. All rights reserved.
// Cheat code engine (Action Replay DS, GBA GameShark v1/v2 raw + CodeBreaker raw, GB GameShark,
// GB Game Genie), written from public format descriptions. Encrypted GBA codes are rejected.
#include "Cheats.hpp"
#include <cctype>

namespace dscore {

namespace {
std::vector<std::string> hexTokens(const std::string& text) {
    std::vector<std::string> out; std::string cur;
    auto flush = [&] { if (!cur.empty()) { out.push_back(cur); cur.clear(); } };
    for (char ch : text) {
        if (std::isxdigit(u8(ch))) cur.push_back(char(std::toupper(u8(ch))));
        else if (ch == '-' ) cur.push_back('-');
        else flush();
    }
    flush();
    return out;
}
bool hexVal(const std::string& s, u32& v) {
    if (s.empty() || s.size() > 8) return false;
    v = 0;
    for (char c : s) { if (!std::isxdigit(u8(c))) return false; v = (v << 4) | u32(std::isdigit(u8(c)) ? c - '0' : c - 'A' + 10); }
    return true;
}
int hexDigit(char c) { return std::isdigit(u8(c)) ? c - '0' : c - 'A' + 10; }
} // namespace

bool parseCheat(const std::string& system, const std::string& text, Cheat& out, std::string& error) {
    out = Cheat{};
    auto tok = hexTokens(text);
    if (tok.empty()) { error = "No code found."; return false; }
    if (system == "gb") {
        for (auto& t : tok) {
            if (t.find('-') != std::string::npos) {                     // Game Genie ABC-DEF(-GHI)
                std::string d; for (char c : t) if (c != '-') d.push_back(c);
                if (d.size() != 6 && d.size() != 9) { error = "Game Genie codes look like ABC-DEF or ABC-DEF-GHI."; return false; }
                RomPatch p;
                p.value = u8((hexDigit(d[0]) << 4) | hexDigit(d[1]));
                p.addr = u16(((hexDigit(d[5]) ^ 0xF) << 12) | (hexDigit(d[2]) << 8) | (hexDigit(d[3]) << 4) | hexDigit(d[4]));
                if (d.size() == 9) {
                    u8 c = u8((hexDigit(d[6]) << 4) | hexDigit(d[8]));
                    c = u8((c >> 2) | (c << 6)); c ^= 0xBA;                   // rotate right 2, xor 0xBA
                    p.compare = c;
                }
                if (p.addr >= 0x8000) { error = "Game Genie address must be in ROM."; return false; }
                out.patches.push_back(p);
                out.format = CheatFormat::GBGameGenie;
            } else {                                                    // GameShark 0TVVAAAA
                u32 v; if (t.size() != 8 || !hexVal(t, v)) { error = "GameShark codes have 8 digits (01VVAAAA)."; return false; }
                out.lines.push_back({v, 0});
                out.format = CheatFormat::GBGameShark;
            }
        }
        if (!out.lines.empty() && !out.patches.empty()) { error = "Use one code type per cheat."; return false; }
        return true;
    }
    if (tok.size() % 2) { error = "Codes come in pairs: XXXXXXXX YYYYYYYY."; return false; }
    bool cb = system == "gba" && tok[1].size() == 4;
    for (size_t i = 0; i < tok.size(); i += 2) {
        u32 a, b;
        if (tok[i].size() != 8 || !hexVal(tok[i], a) || !hexVal(tok[i + 1], b)) { error = "Each line is XXXXXXXX YYYYYYYY" + std::string(system == "gba" ? " (or XXXXXXXX YYYY)." : "."); return false; }
        if (system == "gba" && (tok[i + 1].size() == 4) != cb) { error = "Mixed GameShark and CodeBreaker lines."; return false; }
        if (system != "gba" && tok[i + 1].size() != 8) { error = "Each line is XXXXXXXX YYYYYYYY."; return false; }
        out.lines.push_back({a, b});
    }
    if (system == "ds") out.format = CheatFormat::ActionReplayDS;
    else if (cb) {
        out.format = CheatFormat::GBACodeBreaker;
        for (auto& l : out.lines) if ((l.a >> 28) == 9) { error = "Encrypted CodeBreaker codes aren't supported; use the decrypted (raw) code."; return false; }
    } else {
        out.format = CheatFormat::GBAGameSharkRaw;
        for (auto& l : out.lines) {
            u32 t = l.a >> 28;
            if (t > 2 && t != 0xD) { error = "Only raw (decrypted) GameShark codes are supported."; return false; }
            if (t <= 2 && ((l.a & 0x0FFFFFFF) >> 24) > 0x0E) { error = "Only raw (decrypted) GameShark codes are supported."; return false; }
        }
    }
    return true;
}

void CheatEngine::set(std::vector<Cheat> cheats) { cheats_ = std::move(cheats); }

std::vector<RomPatch> CheatEngine::romPatches() const {
    std::vector<RomPatch> p;
    for (auto& c : cheats_) p.insert(p.end(), c.patches.begin(), c.patches.end());
    return p;
}

void CheatEngine::apply(EmulatorCore& core) const {
    for (auto& c : cheats_) {
        switch (c.format) {
        case CheatFormat::ActionReplayDS: runAR(core, c.lines); break;
        case CheatFormat::GBAGameSharkRaw: runGBAGS(core, c.lines); break;
        case CheatFormat::GBACodeBreaker: runCB(core, c.lines); break;
        case CheatFormat::GBGameShark: runGBGS(core, c.lines); break;
        default: break;
        }
    }
}

// Action Replay DS: types 0-2 writes, 3-6 32-bit and 7-A masked 16-bit conditionals, B offset load,
// C loop (repeat block), D0 endif, D1 next, D2 end, D3-DC offset/data register ops, E patch, F copy.
void CheatEngine::runAR(EmulatorCore& m, const std::vector<CheatLine>& l) {
    u32 offset = 0, data = 0;
    std::vector<bool> cond;                 // condition stack; code runs while all are true
    size_t loopStart = 0; u32 loopCount = 0; bool inLoop = false;
    auto active = [&] { for (bool b : cond) if (!b) return false; return true; };
    for (size_t i = 0; i < l.size(); ++i) {
        u32 a = l[i].a, v = l[i].b, t = a >> 28, x = a & 0x0FFFFFFF;
        bool on = active();
        if (t >= 3 && t <= 0xA) {
            if (!on) { cond.push_back(false); continue; }
            u32 addr = x ? x : offset;
            bool r;
            if (t <= 6) {
                u32 mv = m.cheatRead(addr, 4);
                r = t == 3 ? v > mv : t == 4 ? v < mv : t == 5 ? v == mv : v != mv;
            } else {
                u32 mask = v >> 16, val = v & 0xFFFF, mv = m.cheatRead(addr, 2) & ~mask & 0xFFFF;
                r = t == 7 ? val > mv : t == 8 ? val < mv : t == 9 ? val == mv : val != mv;
            }
            cond.push_back(r);
            continue;
        }
        if (t == 0xD) {
            u32 op = a >> 24;
            if (op == 0xD0) { if (!cond.empty()) cond.pop_back(); continue; }
            if (op == 0xD1) { if (inLoop && on && loopCount) { --loopCount; i = loopStart; } else inLoop = false; continue; }
            if (op == 0xD2) {
                if (inLoop && on && loopCount) { --loopCount; i = loopStart; continue; }
                cond.clear(); offset = 0; data = 0; inLoop = false; continue;
            }
            if (!on) continue;
            switch (op) {
            case 0xD3: offset = v; break;
            case 0xD4: data += v; break;
            case 0xD5: data = v; break;
            case 0xD6: m.cheatWrite(v + offset, data, 4); offset += 4; break;
            case 0xD7: m.cheatWrite(v + offset, data & 0xFFFF, 2); offset += 2; break;
            case 0xD8: m.cheatWrite(v + offset, data & 0xFF, 1); offset += 1; break;
            case 0xD9: data = m.cheatRead(v + offset, 4); break;
            case 0xDA: data = m.cheatRead(v + offset, 2) & 0xFFFF; break;
            case 0xDB: data = m.cheatRead(v + offset, 1) & 0xFF; break;
            case 0xDC: offset += v; break;
            default: break;
            }
            continue;
        }
        if (t == 0xE) {                                   // patch: v bytes follow in the next lines
            u32 n = v, words = (n + 7) / 8;
            if (on) {
                for (u32 k = 0; k < n; ++k) {
                    size_t li = i + 1 + k / 8; if (li >= l.size()) break;
                    u32 w = (k % 8) < 4 ? l[li].a : l[li].b;
                    m.cheatWrite(x + offset + k, (w >> (8 * (k % 4))) & 0xFF, 1);
                }
            }
            i += words;
            continue;
        }
        if (!on) continue;
        switch (t) {
        case 0x0: m.cheatWrite(x + offset, v, 4); break;
        case 0x1: m.cheatWrite(x + offset, v & 0xFFFF, 2); break;
        case 0x2: m.cheatWrite(x + offset, v & 0xFF, 1); break;
        case 0xB: offset = m.cheatRead(x + offset, 4); break;
        case 0xC: loopStart = i; loopCount = v; inLoop = true; break;
        case 0xF: for (u32 k = 0; k < v; ++k) m.cheatWrite(x + k, m.cheatRead(offset + k, 1), 1); break;
        default: break;
        }
    }
}

// GBA GameShark v1/v2, raw (decrypted): 0=8-bit, 1=16-bit, 2=32-bit write; D = if 16-bit equal, next line.
void CheatEngine::runGBAGS(EmulatorCore& m, const std::vector<CheatLine>& l) {
    for (size_t i = 0; i < l.size(); ++i) {
        u32 t = l[i].a >> 28, a = l[i].a & 0x0FFFFFFF, v = l[i].b;
        switch (t) {
        case 0x0: m.cheatWrite(a, v & 0xFF, 1); break;
        case 0x1: m.cheatWrite(a, v & 0xFFFF, 2); break;
        case 0x2: m.cheatWrite(a, v, 4); break;
        case 0xD: if ((m.cheatRead(a, 2) & 0xFFFF) != (v & 0xFFFF)) ++i; break;
        default: break;
        }
    }
}

// GBA CodeBreaker, raw: 3=8-bit, 8=16-bit write; 2 OR, 6 AND, E add (16-bit);
// 7 ==, A !=, B >, C <, F AND-test (skip the next line when false); 0/1/D/4/5 ignored.
void CheatEngine::runCB(EmulatorCore& m, const std::vector<CheatLine>& l) {
    for (size_t i = 0; i < l.size(); ++i) {
        u32 t = l[i].a >> 28, a = l[i].a & 0x0FFFFFFF, v = l[i].b & 0xFFFF;
        u32 cur = m.cheatRead(a, 2) & 0xFFFF;
        switch (t) {
        case 0x3: m.cheatWrite(a, v & 0xFF, 1); break;
        case 0x8: m.cheatWrite(a, v, 2); break;
        case 0x2: m.cheatWrite(a, cur | v, 2); break;
        case 0x6: m.cheatWrite(a, cur & v, 2); break;
        case 0xE: m.cheatWrite(a, (cur + v) & 0xFFFF, 2); break;
        case 0x7: if (cur != v) ++i; break;
        case 0xA: if (cur == v) ++i; break;
        case 0xB: if (!(cur > v)) ++i; break;
        case 0xC: if (!(cur < v)) ++i; break;
        case 0xF: if (!(cur & v)) ++i; break;
        default: break;
        }
    }
}

// GB/GBC GameShark 0TVVAAAA: T = RAM bank type (01 = normal), VV value, AAAA little-endian address.
void CheatEngine::runGBGS(EmulatorCore& m, const std::vector<CheatLine>& l) {
    for (auto& c : l) {
        u32 w = c.a;
        u32 val = (w >> 16) & 0xFF, addr = ((w & 0xFF) << 8) | ((w >> 8) & 0xFF);
        m.cheatWrite(addr, val, 1);
    }
}

} // namespace dscore
