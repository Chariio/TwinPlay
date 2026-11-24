# Dreamcast

This branch adds Sega Dreamcast by loading [Flycast](https://github.com/flyinghead/flycast)'s libretro core in-process, the same way TwinPlay already hosts Mupen64Plus and Azahar. The base is `main` (`1603fe0c`). This public repository has no other branches; there is no `macos-1.5` (or any Mac app target) in the tree. The Mac build here is the Dreamcast host (`TwinPlayFlycastProbe`) plus the Flycast dylib. The iOS app target is unchanged apart from the new system.

No ROMs, BIOS files or games are in the repo, and none are downloaded.

## What is linked

| Piece | Pin | Licence |
|---|---|---|
| Flycast | `105342d53fc181493cd372c8f1ebf5c49621ed1a` | GPL-2.0-or-later |

The pin is `Core/third_party/flycast-pin.txt`. `scripts/fetch-flycast.sh` clones it into `Core/third_party/flycast` (gitignored). `scripts/build-flycast.sh` writes:

- `Core/third_party/build/flycast/macos/flycast_libretro.dylib` — dynarec on
- `Core/third_party/build/flycast/iphoneos/flycast_libretro.dylib` — `-DTARGET_NO_REC`

`TARGET_NO_REC` is Flycast's switch. It sets `FEAT_SHREC`, `FEAT_AREC` and `FEAT_DSPREC` to `DYNAREC_NONE`, so the SH4 recompiler, the ARM7 recompiler and the AICA DSP recompiler are not compiled. iOS uses `Get_Sh4Interpreter()` only. There is no JIT and no StikDebug. The iOS dylib is checked for the absence of `Get_Sh4Recompiler`.

Flycast does not have a separate cached interpreter. The dynarec is the translated cache; the other CPU is the interpreter.

## How a frame is shown

The libretro core renders with OpenGL ES 3 on iOS and OpenGL on Mac. The host reads the framebuffer back and scales it into the same 256×192 picture the other single-screen systems use, so the existing Metal presenter draws it. Flycast's threaded renderer is turned on, so GPU work overlaps the interpreter. On iOS the internal resolution stays at 640×480, the DSP is off, alpha sorting is per-strip, and auto frame skip is "some" when a frame runs long. macOS keeps the dynarec, the DSP, and per-triangle sorting.

A MoltenVK presentation path (Flycast's Vulkan renderer into a Metal layer, without the readback) is not wired. Flycast's libretro Vulkan images are not created with transfer-src, so a correct Metal blit needs a new shader path. The interpreter, not the GPU, is the limit on A17-class chips.

## Library

`GameSystem.dreamcast` is its own library section and Classic menu folder. Add Games accepts `.cdi`, `.gdi` (plus the track files named in the cue sheet), `.chd`, `.cue`/`.bin` and `.zip`. A `.gdi` or `.cue` is stored in its own folder with its tracks.

BIOS is optional. Flycast's HLE BIOS is the default. Settings can import `dc_boot.bin` (2 MB) and `dc_flash.bin` (128 KB). Nothing is bundled.

On iPhone and iPad the Dreamcast section shows: "Designed for modern iPhone and iPad (iPhone 15 Pro or newer, or an iPad with an M-series chip). Older devices may run slowly." Spanish is in `Localizable.xcstrings`.

## Performance

Not measured on a device in this change (no phone, no discs in CI). What the interpreter build implies, from how Flycast's two CPUs compare:

- The dynarec is several times the interpreter on the SH4. iOS cannot use it.
- On an iPhone 15 Pro / 16 Pro / 17-class chip or an M-series iPad, lighter 2D and fighting games (many 2D fighters, some shmups) are the ones that can approach a playable speed, often with auto frame skip.
- Heavier 3D games — Sonic Adventure, Crazy Taxi, Soulcalibur, Jet Set Radio, Shenmue, Skies of Arcadia — are the ones likely to stay well under full speed on a phone. An M4 iPad has more room and should do better, and still should not be expected to lock 60 fps on those.
- macOS keeps the dynarec, which is the build that can run those games at full speed.

Charlie can time a few of each on an iPhone 15 Pro or newer and on an M-series iPad; CI only proves the binaries link.
