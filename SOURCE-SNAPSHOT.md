# Source snapshot

This public tree is a **single squashed commit** taken from the private TwinPlay
`n64-3ds` branch at `a952d0f8f3cdb0bfb54021888627d82db82e8836` (`a952d0f`), then relicensed as GPL-3.0-or-later.

It is not a copy of that repository's history. A fresh history is used so private
credentials or path-only artifacts that may have existed in older commits are not
published.

## Included

- TwinPlay app, cores, scripts, and documentation.
- Pinned corresponding source for Mupen64Plus, mupen64plus-rsp-hle, GLideN64 and
  Azahar (see `Core/third_party/n64-3ds-pins.txt` and `scripts/fetch-n64-3ds.sh`).
- Build script `scripts/build-n64-3ds.sh`, which produces the prebuilt
  `libtwinplay_n64.a` / `libtwinplay_3ds.a` archives (those `.a` files themselves
  are not committed; they are built locally).
- Prebuilt MoltenVK xcframework (Apache-2.0). Corresponding source:
  https://github.com/KhronosGroup/MoltenVK/tree/v1.4.1
- Official GNU GPL-3.0 text in `LICENSE`.

## Excluded on purpose

- Git history of the private repo
- `Core/third_party/build/` (compiled `.a` / plugin artifacts)
- `.tmp-shots/`
- `.p8`, `.p12`, `.mobileprovision`, Fastlane / App Store Connect keys, `.env` files
- ROMs, BIOS, firmware, and Nintendo keys (none are supposed to be in the tree)
- Generated `DSEmu.xcodeproj/` and `Supporting/Info.plist` (run `scripts/generate-project.sh`;
  ATT usage text lives in `project.yml`)
- Nested `.git` directories from fetched third-party trees and Azahar submodules
- `*.bin` via `.gitignore`, so upstream test binaries in some Azahar externals are omitted

AdMob application / banner unit IDs are kept; they are public client identifiers.

Upstream Azahar ships cpp-jwt / LibreSSL *test* certificates under
`Core/third_party/azahar/externals/`. Those are not TwinPlay credentials.
