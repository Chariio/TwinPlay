MoltenVK v1.4.1 (KhronosGroup)
https://github.com/KhronosGroup/MoltenVK/releases/download/v1.4.1/MoltenVK-all.tar
License: Apache License 2.0 (see LICENSE)

This folder keeps the official static MoltenVK.xcframework slices used on iOS
(device arm64 and the iOS Simulator). TwinPlay links the static library; it is
not JIT and is not a Nintendo BIOS/key/ROM.

Do not replace this with a later build that ships only a dynamic dylib unless
the Xcode project is updated to match.
