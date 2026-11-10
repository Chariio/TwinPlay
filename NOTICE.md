# NOTICE

The SwiftUI app, the Objective-C++ bridge, and the DS, GBA, GB and GBC cores in `Core/`
are original work owned by Charlie Rodriguez Garcia, written from public hardware
documentation (Martin Korth's GBATEK, ARM's ARMv4T/ARMv5TE architecture manuals, and the
public Game Boy documentation).

The NES and Super NES cores are ares (Famicom and Super Famicom), not original code.
ares is ISC, which allows use in a closed-source paid app as long as the copyright and
permission notice travel with the binary. The full text is `Core/third_party/ares/LICENSE`.
Only the interpreter cores are compiled. ares's SLJIT recompiler is not included (a stub
header satisfies the include). Nintendo firmware is not included: the 64-byte SPC700 boot
program in `Core/src/AresConsoles.cpp` is a clean-room implementation of the public port
protocol, and the Super Famicom board list is ares's own database.

- No code from melonDS, DeSmuME, NooDS, Nestopia, FCEUmm, QuickNES, Mesen, Snes9x, bsnes or higan.
- DSP-1 answers (`Core/src/DSP1HLE.cpp`) and the Cx4 data-ROM fill (`load.cpp`) are original
  math from public command lists (SNESdev wiki DSP-1, nocash Fullsnes). They are not
  firmware, not Snes9x, and not the Cx4 program ROM. That program ROM is copyrighted
  microcode and is not included, so Mega Man X2/X3 chip effects are unfinished.
- N64 and 3DS are the exception, and they are GPL. See `THIRD_PARTY_NOTICES.md` and
  `docs/N64_3DS.md`. Mupen64Plus (cached interpreter only; the dynarec is not compiled),
  mupen64plus-rsp-hle and GLideN64 are GPL-2.0-or-later. Azahar 2127.0-rc2 is GPL-3.0-or-later
  and is fetched but not linked until its no-JIT build is finished. Because those libraries are linked in the 1.4 app, TwinPlay as a whole is offered under GPL-3.0-or-later (`LICENSE`). No other GPL or LGPL code is included.
  NES and Super NES remain ares (ISC).
- No Nintendo ROMs, BIOS images, firmware, key tables, graphics or sounds.
  (The KEY1 algorithm is implemented from its public description; its key table is only read
  from a BIOS file the user supplies themselves, if they choose to.)
- Third-party code in the binary:
  - ares, nall and libco — ISC, `Core/third_party/ares/LICENSE`
  - ymfm (Aaron Giles) — BSD-3-Clause, required by the Famicom expansion chip, same LICENSE file
  - rcheevos — MIT, `Vendor/rcheevos`, licence text shipped as `rcheevos-LICENSE.txt`
  - Google Mobile Ads / UMP Swift packages
- Development tool (not shipped inside the app): XcodeGen (MIT licence), which
  `scripts/generate-project.sh` downloads to generate the `.xcodeproj`.
