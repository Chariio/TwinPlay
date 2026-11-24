# GameCube

TwinPlay's GameCube section drives Dolphin from the existing library. The branch is `gamecube`, cut from `main` at `1603fe0c` (the public 1.4 snapshot). This repository has no other branches. There is no `macos-1.5` (or any Mac-target) branch here; the app target is still iOS, built on a Mac.

No game, IPL, or DSP ROM is in the tree, and the build scripts do not download any.

## What is integrated

- Library system **GameCube**, in the standard grid and the classic menu folder.
- **Add Games** accepts `.iso`, `.gcm`, `.rvz`, `.ciso`, `.gcz` and `.zip`. A raw `.iso` / `.gcm` whose header is a Wii disc is refused. Wii is not emulated.
- iPhone and iPad show a short note in that section: it is meant for a modern iPhone (iPhone 15 Pro or newer) or an iPad with an M-series chip, and older devices may run slowly. English is the source string; Spanish is in the String Catalog.
- `Core/src/GameCubeCore.cpp` is the session. It talks to `twinplay_gc_*`.
- The default Xcode target links `Core/gamecube/twinplay_gc_stub.cpp`. Opening a game then says the core is not linked.
- `Core/gamecube/twinplay_gc_host.cpp` is the real Dolphin call. `scripts/build-dolphin.sh` compiles it. It is not in the Xcode sources.
- Mac host: `PowerPC::CPUCore::JITARM64`, Metal, fastmem, dual core left off (8 GB Macs are already tight).
- iOS host: `PowerPC::CPUCore::CachedInterpreter`, Metal, dual core (`CPUThread`), backend multithreading, internal resolution 1, EFB copies stored as textures, immediate XFB, skip duplicate XFBs, idle skipping, DSP HLE, skip IPL. No JIT and no fast-math. No StikDebug.

Dolphin's own CPU thread is the fast path. `twinplay_gc_run_frame` only drains host jobs.

## Build

On a Mac with Xcode, CMake and Ninja:

```bash
export CODE_SIGNING_ALLOWED=NO
./scripts/build-dolphin.sh macos   # ARM64 JIT, Metal, Vulkan via bundled MoltenVK
./scripts/build-dolphin.sh ios     # ARM64, -DENABLE_GENERIC=ON, Metal, no JIT
```

The pin is `Core/third_party/dolphin-pin.txt` (`0318069674bbd7971f0db434fe1f7bd9f1c5750e` on `dolphin-emu/dolphin`). The checkout is gitignored.

GitHub Actions (`.github/workflows/dolphin-gamecube.yml`) runs both on `macos-26` (Xcode 26, AppleClang 21, which this Dolphin pin requires) with `CODE_SIGNING_ALLOWED=NO`. It does not sign, and it does not upload to App Store Connect or TestFlight. No secrets.

`scripts/check-dolphin-build.py` fails the macOS job unless `JitArm64`, Metal and Vulkan were compiled, and fails the iOS job if `JitArm64` was compiled, if `_M_GENERIC` is missing, or if `-ffast-math` appears.

## What is not done

- The host object is not linked into `TwinPlay.app`. Boot, pad, pixels and audio are implemented only as far as the host file; the app you run from Xcode still hits the stub.
- `BootManager::BootCore` is called with a headless window. There is no `CAMetalLayer` in TwinPlay's screen, so Dolphin has nowhere to draw. `twinplay_gc_copy_frame` returns no pixels. Lid, orientation and window code were left alone.
- GameCube pad bits are stored in the session and not yet written into Dolphin's serial interface.
- Audio is not copied back into TwinPlay's 48 kHz ring. The iOS CMake build still tries Cubeb; if that fails, the log is the source of truth.
- Save states are not wired. A real boot would use Dolphin's memory card under the user directory (the game's save folder). That directory is set only when the host is linked.
- Official Dolphin has no iOS app target. The iOS job cross-compiles the `core` and `videometal` libraries. If that job fails, GameCube still appears in the library and the stub explains that the core is not linked. The known iOS port is [dolphin-ios](https://github.com/OatmealDome/dolphin-ios); this branch stays on `dolphin-emu/dolphin`, as requested.

## Performance

These are expectations, not timings. This branch does not contain a game, and the core was not run on an M1, an iPhone or an iPad.

Dolphin's cached interpreter is the fastest CPU that does not emit code. It still calls through a function pointer for every PowerPC instruction. Dolphin's own notes on that CPU (cached-interpreter work in 2024–2025, including about a 10% gain from speculative devirtualization) treat it as several times slower than the JIT, and DolphiniOS's no-JIT mode is described by its authors as very slow even on a recent phone unless speed hacks and a high-end device are used. This build turns on the speed path listed above. It does not underclock the emulated CPU, because that changes game timing.

**M1 iMac, 8 GB, Mac host (JIT, Metal).** This is Dolphin's normal Mac path. Light games are the ones that usually hold full speed at native resolution: Mario Kart: Double Dash!!, Super Smash Bros. Melee, Luigi's Mansion, Animal Crossing, and the quieter parts of Paper Mario: The Thousand-Year Door and Super Mario Sunshine. F-Zero GX, Rogue Squadron II, and busy Wind Waker or Metroid Prime scenes often dip even with the JIT. 8 GB is tight once macOS and a 1.4 GB disc are in memory; other apps should be closed. Dolphin will hitch if the machine starts swapping.

**iPhone 17 Pro Max and iPad Pro M4, iOS host (cached interpreter, Metal, no JIT).** Full speed is not the expected result. A reasonable reading of Dolphin's JIT-versus-interpreter gap is that the interpreter lands around one tenth to one quarter of the JIT on the same chip, before the speed hacks. The M4 iPad has more single-thread headroom than an M1, not a measured Dolphin number. That can move a light, slow-paced game from a slideshow into something you can walk around, often still well under 30 fps. It does not make a 60 fps racer playable.

Games that might be interactive, not comfortable, on those two devices:

- Animal Crossing, and other games where a low frame rate is still playable.
- Luigi's Mansion and Paper Mario: The Thousand-Year Door in quiet rooms.
- Menus and title screens of many games.

Games that are unlikely to be playable without the JIT:

- Mario Kart: Double Dash!!, Super Smash Bros. Melee, F-Zero GX, Super Mario Sunshine, Metroid Prime, Star Wars Rogue Squadron II, and Wind Waker in combat.

iPhone 15 Pro (A17 Pro) is the floor named in the on-screen note. Expect it to be slower than an M4 iPad. Phones and iPads older than that can run the same build; the note says they may run slowly, and many games will not be playable.

## Only Charlie can do

- Run `scripts/build-dolphin.sh` on his Mac and link `twinplay_gc_host.cpp` plus Dolphin's static libraries into the app. The CI job compiles them; it does not produce an `.ipa`.
- Give Dolphin a Metal surface in the existing game view without changing lid, orientation or window behaviour, then copy or present that drawable.
- Feed the GameCube pad into Dolphin's controller, and the audio back into the ring buffer.
- Read the Actions run. If the iOS job fails, official Dolphin still does not have an iOS port; deciding to rebase onto dolphin-ios is his call.
- Sign the app. This branch forces signing off and does not talk to App Store Connect.
- Keep shipping the iOS generic build, not the Mac JIT binary, if this goes to the App Store. The GPL notes in `THIRD_PARTY_NOTICES.md` still apply.
