// ares Famicom and Super Famicom, built as one translation unit.
// ISC license: Core/third_party/ares/LICENSE. No JIT (see no-jit/sljit.h).
#include <ares/ares.hpp>
#include <ares/debug/debug.cpp>
#include <ares/node/node.cpp>

namespace ares {
Platform* platform = nullptr;
atomic<bool> _runAhead = false;
const string Name = "ares";
const string Version = "v148";
const string Copyright = "2004-2025 ares team, Near et al";
const string License = "ISC";
const string LicenseURI = "https://opensource.org/licenses/ISC";
const string Website = "ares-emu.net";
const string WebsiteURI = "https://ares-emu.net/";
const u32 SerializerSignature = 0x31545342;
}

#include <fc/fc.cpp>
#include <sfc/sfc.cpp>
