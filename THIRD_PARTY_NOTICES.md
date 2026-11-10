# Third-party notices — N64 and 3DS

TwinPlay as a whole is licensed under GPL-3.0-or-later (see `LICENSE` and `NOTICE.md`).
TwinPlay's own DS, GBA, GB and GBC cores, the SwiftUI app and the bridge are original work
by Charlie Rodriguez Garcia, now offered under that same licence. NES and Super NES remain ares (ISC).

N64 and 3DS are different. They are existing GPL emulators, pinned in
`Core/third_party/n64-3ds-pins.txt` and fetched by `scripts/fetch-n64-3ds.sh`.

| Component | Commit | Licence | Role |
|---|---|---|---|
| Mupen64Plus core | `a9ca8ec0b7decd17390c76c6341cf423d5d79321` | GPL-2.0-or-later | N64 CPU, RCP, memory. Built with `NO_ASM=1` so the dynarec is not compiled. Runtime mode is the cached interpreter. |
| mupen64plus-rsp-hle | `dd09c7dcdc6d2cff584aacb9d519600d47d61039` | GPL-2.0-or-later | High-level RSP. No RSP JIT. |
| GLideN64 | `a04081ad6a966a9413bea63a55f502e0dc98bb18` | GPL-2.0-or-later in the source headers | Video plugin. Renders with OpenGL / OpenGL ES, then the frame is read back. |
| TwinPlay N64 audio and input plugins (`Core/n64/audio_plugin.cpp`, `input_plugin.cpp`) | this repo | GPL-2.0-or-later | Shims. They are GPL because they implement the Mupen plugin ABI. |
| TwinPlay N64 frontend (`Core/n64/twinplay_n64.cpp`, `vidext_egl.cpp`) | this repo | GPL-2.0-or-later | Front-end that links the pieces above. |
| Azahar | `6b4e7f2e694514fdf2f72dc20368609b7cd4912e` (tag `2127.0-rc2`) | GPL-3.0-or-later (file headers such as `src/core/core.cpp`); `LICENSE.txt` is the GPL-3 text | 3DS core. Intended CPU is FastInterp, not dynarmic. Built by `scripts/build-n64-3ds.sh` as `libtwinplay_3ds.a` (FastInterp, no dynarmic/JIT) and linked in the 1.4 app. |
| MoltenVK | v1.4.1 (KhronosGroup release `MoltenVK-all.tar`; static `MoltenVK.xcframework` ios-arm64 / ios-arm64_x86_64-simulator) | Apache License 2.0 (`Core/third_party/MoltenVK/LICENSE`) | Vulkan-on-Metal driver for the 3DS Azahar renderer. Statically linked. Not a Nintendo BIOS, key, or ROM. |

Full licence texts ship inside each upstream tree (`LICENSES`, `LICENSE`, `LICENSE.txt`).
They are not copied into the app bundle by this change.

## What GPL compliance requires before an App Store binary

Linking these libraries into TwinPlay produces a combined work. The proprietary `LICENSE`
cannot cover that binary.

1. **Licence of the combination.** Mupen64Plus, RSP-HLE and the GLideN64 *source headers*
   are GPL-2.0-or-later, so they can be used under GPL-3.0. Azahar's core files are
   GPL-3.0-or-later. The combined N64+3DS binary has to be offered under **GPL-3.0**.
   Confirm no vendored file is GPL-2.0-only (the GLideN64 top-level `LICENSE` summary says
   "version 2" while the file headers say "or later"). A GPL-2.0-only file cannot be linked
   with GPL-3.0-only code.
2. **Corresponding source.** Anyone who receives the binary must be able to get the complete
   source of the app and of these cores, including the build scripts and the exact pins, for
   at least three years (GPL-3 §6). A binary-only App Store listing does not do that by itself.
3. **Notices.** Keep this file, the upstream copyright lines and a copy of the GPL-3 text
   with the distribution.
4. **No extra restrictions.** GPL-3 §10 forbids further restrictions on the rights the licence
   grants. Apple's App Store terms restrict redistribution and modification. That conflict is
   real (it is why some GPL apps have left the store). It needs a decision before upload:
   ship the GPL build outside the store, get a store-compatible licence from every copyright
   holder, or accept the legal risk. This branch does not upload anything.
5. **Installation information.** If the binary is shipped on a device the user cannot freely
   reinstall, GPL-3 may also require installation information. A normal iOS app installed by
   the user from a source build does not have that problem; an App Store build might.
6. **Dynarmic stays out.** It is a JIT (0BSD for dynarmic itself, but it is still a JIT, which
   the App Store forbids). FastInterp is the 3DS CPU. The N64 dynarec objects are not compiled.
7. **No Nintendo material.** Do not enable Azahar's `ENABLE_BUILTIN_KEYBLOB`. Do not commit
   ROMs, BIOS, firmware, or keys. Users supply their own images.

`NDUO_TESTER_UNLOCK` is not defined in the Xcode project. Do not turn it on for a Release build.
