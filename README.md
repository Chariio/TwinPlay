# TwinPlay — emulator for iPhone and iPad

A SwiftUI app (iOS 16+, iPhone and iPad). The DS, GBA, GB and GBC cores are original
C++. NES and Super NES use [ares](https://github.com/ares-emulator/ares) (ISC). N64 uses
Mupen64Plus (cached interpreter, no dynarec) with GLideN64 and the HLE RSP. 3DS uses
Azahar's FastInterp (no JIT). **This tree is licensed under GPL-3.0-or-later** — see
`LICENSE`, `NOTICE.md` and `THIRD_PARTY_NOTICES.md`. **No ROMs, BIOS or Nintendo firmware
are included.** Users supply their own dumps.

*Versión en español: [README.es.md](README.es.md).*

This public repository is a single squashed snapshot of the 1.4 / `n64-3ds` work,
prepared so the App Store binary has corresponding source. It is not the history of
the private development repo.

## License

TwinPlay as a whole is **GPL-3.0-or-later**. That is required because the N64 and 3DS
cores (Mupen64Plus, GLideN64, Azahar) are GPL. Copyright for TwinPlay's original
code is held by Charlie Rodriguez Garcia.

## Build the app

1. On a Mac with macOS 14+ and Xcode 15+ (iOS platform support installed):
   ```bash
   git clone https://github.com/Chariio/TwinPlay.git
   cd TwinPlay
   ./scripts/generate-project.sh
   open DSEmu.xcodeproj
   ```
2. In Xcode, choose the **DSEmu** target ▸ Signing & Capabilities, pick your Team,
   and change the bundle id if `com.charlie.dsemu` is not available to you.
3. The N64 and 3DS cores are included in this snapshot at the pins in
   `Core/third_party/n64-3ds-pins.txt`. The first Xcode build runs
   `scripts/build-n64-3ds.sh`, which compiles `libtwinplay_n64.a` and
   `libtwinplay_3ds.a` into `Core/third_party/build/` (that folder is gitignored).
   You need `cmake` and `ninja` (Homebrew is fine). To re-fetch the cores instead
   of using the vendored trees, run `./scripts/fetch-n64-3ds.sh`.
4. Prebuilt `MoltenVK.xcframework` (Apache-2.0) is in `Core/third_party/MoltenVK`
   for the 3DS renderer. Corresponding source is
   [MoltenVK v1.4.1](https://github.com/KhronosGroup/MoltenVK/tree/v1.4.1).

The original step-by-step Xcode / Simulator / device notes follow below. Ignore any
older "unzip ds-emu.zip" wording; start from a clone of this repository.

---

---

## 1. What you need (all free)

- A Mac with macOS 14 or later.
- **Xcode** (free on the Mac App Store), version 15 or newer.
- Your **regular Apple ID** (the paid developer program is not needed).
- To test on an iPhone: a USB/USB‑C cable.

## 2. Install Xcode

1. Open the **App Store** on the Mac, search for **Xcode** and click **Get**. It takes a while (>7 GB).
2. Open it once and accept the licence. If it asks to install "additional components", accept.
3. When it asks which platforms you want, tick **iOS** (includes the Simulator).
   If it didn't ask: Xcode ▸ Settings ▸ **Components** ▸ download **iOS**.

## 3. Open the project

1. Unzip `ds-emu.zip` (double-click). You get a folder called `ds-emu`.
2. Open **Terminal** (Applications ▸ Utilities ▸ Terminal) and type:
   ```bash
   cd ~/Downloads/ds-emu          # or wherever you put the folder
   ./scripts/generate-project.sh
   ```
   This downloads XcodeGen (a free tool, first time only) and creates `DSEmu.xcodeproj`.
   If macOS says "permission denied", run `chmod +x scripts/*.sh` first.
3. Open the project: `open DSEmu.xcodeproj` (or double-click the file).
   The project and target are still called **DSEmu**; the app installed on the device is called **TwinPlay**.

## 4. Sign with your Apple ID

1. Xcode ▸ **Settings** ▸ **Accounts** ▸ **+** button ▸ **Apple ID** ▸ sign in.
2. In the left panel click the **DSEmu** project (blue icon) ▸ **DSEmu** target ▸
   **Signing & Capabilities** tab.
3. Leave **Automatically manage signing** ticked and under **Team** pick
   **"Your Name (Personal Team)"**.
4. If you get an error saying the Bundle Identifier is unavailable, change
   `com.charlie.dsemu` to something unique, e.g. `com.charlierodriguez.dsemu2026`.

## 5. Run in the Simulator

1. At the top, next to the ▶︎ button, choose a simulator (e.g. **iPhone 16 Pro** or an **iPad**).
2. Press **▶︎ (Cmd+R)**. The first build takes a little while.
3. In the app tap **"Test mode"**: you'll see colour bars on top and a gradient below.
   - Press buttons: small red squares light up on the top screen.
   - Touch the bottom screen: a cross appears where you touch.
   - Hold **A**: a 440 Hz tone plays.
   - Rotate the simulator (Cmd+←/→) for the landscape layout; in the (⋯) menu you can choose
     "Stacked" or "Side by side".

## 6. Run on your iPhone (free)

1. Connect the iPhone with the cable and unlock it. If it asks "Trust this computer?", tap **Trust**.
2. On the iPhone enable **Developer Mode**: Settings ▸ Privacy & Security ▸
   **Developer Mode** ▸ on ▸ restart ▸ confirm. (It appears after connecting to Xcode once.)
3. In Xcode pick your iPhone in the device list and press **▶︎**.
4. The first time, the iPhone will say the developer is not trusted. Go to
   Settings ▸ General ▸ **VPN & Device Management** ▸ your Apple ID ▸ **Trust**.
5. Press ▶︎ in Xcode again (or open the app on the iPhone).

### 7-day limit (free account)
With a free Apple ID the app **expires after 7 days** and stops opening. To renew it, just
connect the iPhone and press ▶︎ in Xcode again (your imported games, saves and states are kept).
A free account also allows at most 3 apps installed this way at the same time.

## 7. Import your games

- In the app tap **+** and choose your `.nds`, `.gba`, `.gb`, `.gbc`, `.nes`, `.sfc`, `.smc`, `.n64`, `.z64`, `.v64`, `.3ds`, `.cci` or `.cxi` files (from iCloud Drive, "On My iPhone", etc.).
  They are copied into the app's folder (`Documents/ROMs`), also visible in the Files app ▸ TwinPlay.
- Only use copies of games you own. The app does not include or download games or BIOS files.
- Cartridge saves go to `Documents/Saves/<game>.sav`; save states to `Documents/States`.
- **Optional:** some ROM dumps have an *encrypted secure area*. To decrypt it the core needs a
  key table that only exists in the console's ARM7 BIOS. If you have dumped **your own** console's
  BIOS, import it in **Settings ▸ Use my own BIOS/firmware ▸ Import BIOS / firmware files…** (TwinPlay Pro). You can pick several files at once (ARM9 4 KB, ARM7 16 KB, firmware 256/512 KB, GBA 16 KB, GB/GBC boot ROMs); each is recognized by size and CRC32 whatever its name or extension (e.g. `biosnds7.rom`). The legacy `Documents/BIOS/biosnds7.bin` (Files ▸ TwinPlay ▸ BIOS) is still read. It is never required,
  never bundled and never downloaded; most dumps are already decrypted and do not need it.

## 8. Game controllers

Works with iPhone- and iPad-compatible controllers (Xbox, PlayStation, Switch Pro, MFi) over Bluetooth, in any window size including Split View and Stage Manager.
Position-based layout: right face button = A, bottom = B, top = X, left = Y;
triggers/bumpers = L/R; Menu = Start; Options = Select; D-pad or stick = direction.
NES games use A, B, Start, Select and the D-pad. Super NES games use the full set, including X, Y, L and R.

---

## Features

- **Library**: a grid of your games showing the icon and title stored in each ROM's own banner. You can sort it (name, recently added, recently played) and search it. Long-press a game to Rename or Delete it, or to change its Cover:
  - Choose from Photos, Choose from Files, or Paste image.
  - Search Google Images opens an in-app browser. Save an image you like, then pick it with Photos or Files.
  - Reset to built-in icon.
  - On iPad, you can also drag an image onto a game.
  - Covers are stored in `Documents/Covers/<rom>.png`. The app never includes or downloads cover art by itself.
- **Save states**: an auto slot (written when you leave the game or the app goes to the background) plus 5 manual slots, each with a thumbnail and a timestamp. Open them from the ⋯ menu → Save states…; quick save and quick load use slot 1.
- **Fast-forward**: tap the » button (top right) or hold the right-stick click on a controller. Speeds are x2, x3 or Unlimited. While fast-forwarding, sound is muted (default) or played at a higher pitch. Set this in ⋯ → Fast-forward.
- **Video**: 3D internal resolution 1x–4x (default 2x), 3D anti-aliasing (Off / Edge smoothing (default) / Supersampling 2x), Smooth 3D textures, and Widescreen 3D (experimental, per game, stretches the top screen to 16:9). Screen filters: Sharp, Smooth, Scanlines, Sharp bilinear and Edge-directed upscaling. Colour: brightness, contrast, saturation, gamma and an LCD colour-correction toggle. All in ⋯ → Video.
- **Saves**: the save chip is detected automatically by watching the game's commands; you can force it per game in ⋯ → Game save. Infrared Pokémon cartridges are supported.
- **On-screen controls**: Automatic (hidden while a controller is connected), Always show, or Always hide. With the controls hidden, the screens grow larger.
- **Controllers**: ⋯ → Controller buttons…, or the library menu → Controllers. Tap an action, then press a button. A profile is saved for each controller model. Shortcuts: fast-forward, quick save, quick load, and open save slots.

## Project structure

```
ds-emu/
├── project.yml                 # Project definition (XcodeGen) → DSEmu.xcodeproj
├── scripts/
│   ├── generate-project.sh     # Generates the .xcodeproj (downloads XcodeGen if missing)
│   └── run-core-tests.sh       # Builds and runs the core unit tests on the Mac
├── DSEmu/                      # iOS app (SwiftUI)
│   ├── App/DSEmuApp.swift
│   ├── Views/                  # Library, emulator screen, layout, controls, touch
│   ├── Emulation/              # Emulation session/thread, audio, controllers, ROM library
│   └── Bridge/                 # Objective-C++ bridge to the C++ core
├── Core/                       # C++20 core. DS/GBA/GB original; NES/SNES are ares (ISC)
│   ├── include/dscore/         # EmulatorCore (interface), ARMCPU, Bus, types, AudioRing, StateIO
│   ├── src/                    # ARM/Thumb interpreter, DS system, 2D/3D, sound, saves, RTC, KEY1
│   └── tests/core_tests.cpp    # Unit tests
├── docs/APP_STORE_COMPLIANCE.md
├── LICENSE  (proprietary, all rights reserved)
├── README.es.md                # Spanish copy of this file
└── NOTICE.md
```

### Core interface (`Core/include/dscore/EmulatorCore.hpp`)
`loadROM`, `reset`, `runFrame`, `framebuffer(0|1)` (256×192, ARGB), `setButtons`,
`setTouch`, `readAudio` (48 kHz stereo), `saveState`/`loadState`, cartridge save data,
optional `setARM7BIOS`, `romInfo`, `statusText`.
Two implementations: `TestPattern` (test mode) and `Interpreter` (DS core).

### What the DS core already does
- Cartridge header (title, code, CRC16, ARM9/ARM7 binaries) and HLE direct boot:
  **no BIOS or firmware needed** (an original generic firmware block with user settings and touch calibration is generated).
- ARM9 (ARMv5TE) and ARM7 (ARMv4T) CPUs: ARM and Thumb, covering the usual instructions (data processing, long and DSP
  multiplies, LDR/STR/LDRH/LDRD, LDM/STM including the user bank `^`, SWP, B/BL/BX/BLX, CLZ, MRS/MSR, CP15).
- Memory: 4 MB RAM, shared WRAM (WRAMCNT), ARM7 WRAM, ITCM/DTCM configured through CP15, palette, OAM.
- **VRAM with real A–I bank mapping** (VRAMCNT): engine A/B backgrounds and objects, LCDC, ARM7,
  extended BG/OBJ palettes, **3D texture and texture-palette slots**.
- **2D engines A and B**, line by line: text, affine, extended and large-bitmap backgrounds, sprites
  (normal, affine, bitmap, semi-transparent, object window), windows, alpha blending / brighten / darken,
  master brightness, VRAM display mode, screen swap.
- **3D engine** (new):
  - Geometry engine: all matrix commands (projection, position, vector and texture matrices; push/pop/store/
    restore stacks with overflow flag), packed GX FIFO and direct command ports, GX FIFO DMA and IRQ,
    vertex formats (16-bit, 10-bit, XY/XZ/YZ, diff), triangles/quads/strips, clipping against the view volume,
    far-plane rule, front/back culling, viewport, texture-coordinate transforms, **hardware lighting**
    (4 lights, diffuse/ambient/specular/emission, shininess table), position/vector tests, RAM_COUNT,
    clip and vector matrix read-back, SWAP_BUFFERS at VBlank (geometry stalls until then).
  - Software rasterizer: perspective-correct colours and texture coordinates, Z-buffer and W-buffer,
    "depth equal" test, **all 7 texture formats** (A3I5, 4/16/256-colour, 4×4 compressed, A5I3, direct),
    repeat/flip/clamp, colour-0 transparency, modulate/decal/toon/highlight, translucency with blending and
    same-polygon-ID rule, alpha test, wireframe, opaque-then-translucent order with Y-sorting,
    **fog** (table, colour, alpha-only mode), **edge marking**, clear colour/depth/ID.
  - Output as **engine A BG0**, with BG0 scroll and per-pixel 3D alpha blending against the layer below.
- **Real-time clock** on ARM7 port 0x138 (date/time from the device clock, status and alarm registers).
- **BIOS decompression and helpers (HLE)**: BitUnPack, LZ77 (8/16-bit writes), Huffman (4/8-bit),
  RLE (8/16-bit writes), Diff8/Diff16 unfilter, the "read by callback" variants (they call the
  game's own callback functions), GetSineTable and GetPitchTable, plus IntrWait/VBlankIntrWait, Halt,
  Div, Sqrt, CpuSet, CpuFastSet and GetCRC16.
- **Cartridge protocol and encryption**: raw, KEY1 and main-data modes (header read, chip ID, secure-area
  blocks, B7 reads). KEY2 is applied symmetrically by the console and the card, so it is transparent
  to software and needs no emulation. The **KEY1** algorithm is implemented from GBATEK; encrypted
  secure areas are decrypted automatically when the user provides their own ARM7 BIOS (optional).
- **Save states** for the DS core: CPUs, all memories, VRAM, 2D/3D state, sound, timers/DMA/IPC,
  cartridge, save chip and RTC. Each state checks the game code and header CRC, and a damaged
  state is rejected without changing the running game.
- **Cartridge saves** (AUXSPI): EEPROM 512 B, EEPROM/FRAM 8–64 KB and Flash 256/512 KB with type auto-detection.
- **Sound**: 16 channels (PCM8, PCM16, IMA-ADPCM, PSG square, noise), mixed to 48 kHz stereo.
- **Performance (no JIT)**: ARM decode table, page-pointer fast memory, VRAM page pointers, tile-based text BGs,
  idle-loop skipping. On the build server: ~7.7 ms/frame for the 2D + sound worst case, and
  ~11.7 ms/frame with **1,500 textured, fogged, edge-marked polygons per frame** (the 3D rasterizer runs once per frame).

Tests: 21 unit-test groups with hand-built test ROMs. New in this milestone:
3D geometry, depth and matrices; textures, translucency and fog; RTC protocol;
BIOS decompression; KEY1 round trip; save states, including rejection of a damaged state.
Run them on the Mac: `./scripts/run-core-tests.sh` (they also pass on Linux under ASan/UBSan).

---

## Core roadmap (what is still missing)

**Suggested next milestone — compatibility:**
1. Test with free homebrew and commercial games you own; fix what breaks (memory timings, exact
   sprite priorities, mosaic, display capture, main-memory display FIFO, sound capture).
2. 3D accuracy: box test, shadow polygons, anti-aliasing, 1-dot polygons, rear-plane bitmap, toon/edge details,
   GX FIFO timing (commands are executed instantly today).
3. Remaining BIOS functions (e.g. GetVolumeTable), firmware writes, microphone, Wi-Fi stub.

Later: Metal output, control customisation, cover art in the library, multithreaded 3D rendering.

Project rule: always implement from public hardware documentation (GBATEK, ARM manuals);
never copy code from other emulators (many are GPL and would force the app's code to be released).

## Troubleshooting
- **"No account for team" / "Signing requires a development team"**: repeat step 4.
- **"Failed to register bundle identifier"**: change the Bundle Identifier (step 4.4).
- **"Untrusted Developer"** on the iPhone: step 6.4.
- **The app stopped opening after a week**: that's the 7-day limit; press ▶︎ in Xcode again.
- **`generate-project.sh` can't download**: install XcodeGen with Homebrew (`brew install xcodegen`) and retry.
- **"Encrypted secure area" message**: the ROM needs your own ARM7 BIOS: import it in Settings (section 7).

## Core tests (Linux or Mac)

```bash
cd Core && make test
```

`make test` builds the DS/GBA/GB suite and the NES/Super NES suite. The NES/Super NES
tests build their own ROMs (no copyrighted games): an iNES picture, a pulse tone, an
MMC3 image, a LoROM backdrop, and a LoROM that completes the SPC700 boot handshake.
Pass a public-domain blargg NES CPU test on the command line to score it
(`./build/nes_snes_tests path/to/01-basics.nes` — result byte `$6000` must be 0).

## Headless runner (debugging)
`Core/tools/headless.cpp` runs a DS ROM. Build it with the same objects as `make test`
(C++20, plus the ares objects). `./headless game.nds -frames 600 -every 60 -out frames/`
writes PNG frames and `trace.log` (IO, SWI, FIFO, PC samples).
Options: `-press F:MASK` (hold buttons for 6 frames from frame F), `-bench` (ms/frame per 100 frames, no tracing), `-threads N` (3D raster threads), `-skip N` (frame skip).

## Performance
- The emulation thread is paced by the display link and nudged by the audio queue (~50 ms target), so sound does not underrun or drift.
- Frames are double-buffered in the bridge; both screens always come from the same emulated frame and are drawn with Metal from one texture (Core Graphics fallback in the menu).
- The 3D frame is rasterized at scanline 215 (late VBlank, like the hardware) in horizontal bands on worker threads; output is identical to single-threaded.
- Frame skip (Auto/Off/1/2) drops pictures only; emulation always runs at full speed.
