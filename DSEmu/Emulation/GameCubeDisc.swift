// Copyright (c) 2026 Charlie Rodriguez Garcia. All rights reserved.
import Foundation

/// GameCube disc images the library can import. Nothing here is a ROM, BIOS or IPL.
enum GameCubeDisc {
    static let extensions: Set<String> = ["iso", "gcm", "rvz", "ciso", "gcz", "zip"]

    /// Shown in the GameCube section on iPhone and iPad. English is the String Catalog key.
    static let englishNotice = "GameCube is built for a modern iPhone or iPad (iPhone 15 Pro or newer, or an iPad with an M-series chip). Older devices may run slowly."

    static let wiiRejected = "This is a Wii game. TwinPlay plays GameCube games only."

    /// iPhone and iPad only. A Mac build keeps Dolphin's JIT and does not show this.
    static var showsOnThisPlatform: Bool {
        #if os(iOS)
        true
        #else
        false
        #endif
    }

    enum ImageKind: Equatable { case gamecube, wii, unknown }

    /// Raw disc header. Compressed images (.rvz, .gcz, .ciso, .zip) do not carry this at byte 0.
    static func kind(header: Data) -> ImageKind {
        guard header.count >= 0x20 else { return .unknown }
        let b = [UInt8](header.prefix(0x20))
        if b[0x18] == 0x5D && b[0x19] == 0x1C && b[0x1A] == 0x9E && b[0x1B] == 0xA3 { return .wii }
        if b[0x1C] == 0xC2 && b[0x1D] == 0x33 && b[0x1E] == 0x9F && b[0x1F] == 0x3D { return .gamecube }
        return .unknown
    }
}
