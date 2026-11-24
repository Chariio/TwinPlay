# App Store compliance notes (guideline 4.7 and related)

| Requirement | How the project meets it |
|---|---|
| No bundled or downloadable games | The app neither ships nor downloads ROMs. Users import their own `.nds`, `.gba`, `.gb`, `.gbc`, `.nes`, `.sfc`, `.smc`, `.n64`, `.z64`, `.v64`, `.3ds`, `.cci`, `.cxi`, `.iso`, `.gcm`, `.rvz`, `.ciso`, `.gcz` and `.zip` files from Files (`fileImporter`). GameCube does not bundle an IPL or DSP ROM (DSP is HLE, IPL is skipped). |
| No Nintendo BIOS/firmware | The DS core uses **HLE** and direct boot. It does not include Nintendo BIOS or firmware. An ARM7 BIOS the user dumped from their own console can optionally be placed in `Documents/BIOS` to decrypt encrypted secure areas. The Super NES core uses a clean-room SPC700 boot program (the public port protocol), not Nintendo's IPL ROM. The app never downloads firmware. |
| No JIT / no generated executable code | Interpreters only for DS, GBA, GB, NES, Super NES, N64 and 3DS. ares is built without SLJIT. N64 is Mupen64Plus with `NO_ASM=1` (cached interpreter; dynarec objects are not compiled) and RSP-HLE. 3DS is Azahar FastInterp with dynarmic left out of the link. GameCube on iOS is Dolphin built with `-DENABLE_GENERIC=ON`: the cached interpreter, no `JitArm64` objects, no StikDebug, no extra entitlements. The Mac Dolphin build does use the ARM64 JIT and must not be the iOS App Store binary. |
| No paid entitlements | Standard automatic signing only. Works with a free Apple ID. |
| Intellectual property | The app name is **TwinPlay**. Do not use "Nintendo", "DS", Nintendo logos, icons, fonts or screenshots of commercial games in the app name, icon, subtitle, keywords or App Store listing. Describe the app neutrally (e.g. "dual-screen handheld emulator") and only show homebrew or original content in screenshots. |
| Licences | DS, GBA, GB and GBC cores are original (see `NOTICE.md`). NES and Super NES are ares, ISC. N64 and 3DS are GPL (Mupen64Plus, GLideN64, Azahar). A combined binary has to be offered under GPL-3.0, with corresponding source. See `THIRD_PARTY_NOTICES.md`. Nestopia, FCEUmm, QuickNES, Mesen, bsnes, higan and Snes9x are still not used. No JIT. |
| Privacy | Collects no data. When publishing: "Data Not Collected". |
| Games vs. "emulator" | Apple has allowed retro console emulators since 2024, provided no unlicensed copyrighted content is included. Check the current guidelines before submitting. |

Publishing requires the Apple Developer Program (USD 99/year). Testing in the
Simulator or on your own iPhone does NOT require paying.
