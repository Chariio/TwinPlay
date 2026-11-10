// Copyright (c) 2026 Charlie Rodriguez Garcia. All rights reserved.
// Original skin designs. No third-party logos, trademarks or trade dress.
import SwiftUI

/// Which console a game (or a skin) belongs to.
enum GameSystem: String, CaseIterable, Identifiable, Codable {
    case ds, gba, gb, gbc, nes, snes, n64, n3ds
    var id: String { rawValue }
    var label: String {
        switch self {
        case .ds: return "DS"
        case .gba: return "GBA"
        case .gb: return "GB"
        case .gbc: return "GBC"
        case .nes: return "NES"
        case .snes: return "SNES"
        case .n64: return "N64"
        case .n3ds: return "3DS"
        }
    }
    var longName: String {
        switch self {
        case .ds: return "DS"
        case .gba: return "Game Boy Advance"
        case .gb: return "Game Boy"
        case .gbc: return "Game Boy Color"
        case .nes: return "NES"
        case .snes: return "Super NES"
        case .n64: return "N64"
        case .n3ds: return "3DS"
        }
    }
    /// One screen instead of the DS's two. 3DS keeps the DS pair.
    var isSingleScreen: Bool { self != .ds && self != .n3ds }
    var isGameBoy: Bool { self == .gb || self == .gbc }
    /// Picture width / height. DS is one screen of the pair.
    var screenAspect: CGFloat {
        switch self {
        case .ds: return 256.0 / 192.0
        case .gba: return 240.0 / 160.0
        case .gb, .gbc: return 160.0 / 144.0
        case .nes: return 256.0 / 240.0
        case .snes: return 256.0 / 224.0
        case .n64, .n3ds: return 4.0 / 3.0
        }
    }
    /// Which skin catalogue this console uses. Game Boy and Game Boy Color share the GBA catalogue.
    /// NES and Super NES have their own.
    var skinSystem: GameSystem {
        switch self {
        case .ds: return .ds
        case .nes: return .nes
        case .snes: return .snes
        case .n64: return .n64
        case .n3ds: return .n3ds
        case .gba, .gb, .gbc: return .gba
        }
    }
    /// Library key used for the "skin" setting of this system.
    var skinKey: String {
        switch skinSystem {
        case .ds: return "skin"
        case .nes: return "skinNES"
        case .snes: return "skinSNES"
        case .n64: return "skinN64"
        case .n3ds: return "skinN3DS"
        default: return "skinGBA"
        }
    }
    var defaultSkin: Skin {
        switch self {
        case .nes: return .nesFog
        case .snes: return .snesFog
        case .n64: return .n64Original
        case .n3ds: return .n3dsPearl
        default: return skinSystem == .ds ? .classicGray : .gbaIndigo
        }
    }
}

/// Visual style of the emulator screen: the body behind the screens and the on-screen controls.
/// All designs are original colour schemes drawn with SwiftUI shapes (no logos or trademarks);
/// the colour names only describe the colours.
enum Skin: String, CaseIterable, Identifiable {
    // DS-style shells
    case classicGray, polarWhite, onyxBlack, cobaltBlue, crimsonRed, pink, iceBlue
    // GBA-style shells
    case gbaIndigo, gbaGlacier, gbaBlack, gbaOrange, gbaSilverSP
    // Classic handheld pack (Game Boy family; also the closed iPhone Duo landscape shell)
    case gbClassicGray, gbSlimSilver, gbcGrape, gbcAtomic, gbcTeal, gbcKiwi, gbcDandelion, gbcBerry, gbaPlatinum, gbaSpice
    // Realistic shells: detailed original artwork (bevels, grilles, LEDs, screws, textures)
    case twinPearl = "duoPearl"   // raw value kept: persisted in the "skin" setting
    case twinBlossom
    // Clear-plastic DS shells (#9): see-through tinted plastic over the insides.
    case dsClearIce, dsClearGrape
    // Vivid clear-plastic rainbow (DS, 3DS, GB/GBC, N64). dsClearIce / dsClearGrape
    // keep their persisted raw values (Ice and Purple).
    case dsClearRed, dsClearOrange, dsClearYellow, dsClearLime, dsClearGreen, dsClearDarkGreen, dsClearTeal, dsClearBlue, dsClearPink
    case n3dsClearRed, n3dsClearOrange, n3dsClearYellow, n3dsClearLime, n3dsClearGreen, n3dsClearDarkGreen, n3dsClearTeal, n3dsClearBlue, n3dsClearPurple, n3dsClearPink, n3dsClearIce
    case gbClearRed, gbClearOrange, gbClearYellow, gbClearLime, gbClearGreen, gbClearDarkGreen, gbClearTeal, gbClearBlue, gbClearPurple, gbClearPink, gbClearIce
    case n64ClearRed, n64ClearOrange, n64ClearYellow, n64ClearLime, n64ClearGreen, n64ClearDarkGreen, n64ClearTeal, n64ClearBlue, n64ClearPurple, n64ClearPink, n64ClearIce
    case realDSPhatRed, realDSLite, realDSLiteCobalt, realDS3DWhite, realDSWhite, realDSGraphite, realGBA, realGBASP, realGBASPRed, realGB, realGBC
    // Phone-style single-screen slabs
    case phoneMatte, phoneWhite, phoneIndigo, phoneDMG, phoneBlack
    // Home-console shells. Original shapes and colours; no logos or product names on the shell.
    case nesFog, nesGraphite
    case snesFog, snesLilac
    case n64Original, n64Charcoal, n64Forest
    case n3dsPearl, n3dsInk
    // #22 Heritage pack: shells modelled on the classic handhelds' shapes, colours and parts
    // (bezels, grilles, LEDs, button layouts). No third-party logos, names or wordmarks.
    case heritageBrick
    case heritageColorBerry, heritageColorGrape, heritageColorAtomic, heritageColorTeal, heritageColorDandelion, heritageColorKiwi
    case heritageWideIndigo, heritageWideGlacier, heritageWideBlack
    case heritageFlipSilver, heritageFlipCobalt, heritageFlipFlame
    case heritagePhatPlatinum, heritagePhatOnyx, heritageCamBlack, heritageCamWhite
    // Both systems
    case dark
    var id: String { rawValue }

    var label: String { englishLabel.loc }
    /// English source text (the String Catalog key).
    var englishLabel: String {
        if let label = clearRainbowLabel { return label }
        switch self {
        case .classicGray: return "Classic Gray"
        case .polarWhite: return "Polar White"
        case .onyxBlack: return "Onyx Black"
        case .cobaltBlue: return "Cobalt Blue"
        case .crimsonRed: return "Crimson Red"
        case .pink: return "Pink"
        case .iceBlue: return "Ice Blue"
        case .gbaIndigo: return "Indigo"
        case .gbaGlacier: return "Glacier (translucent)"
        case .gbaBlack: return "Black"
        case .gbaOrange: return "Orange"
        case .gbaSilverSP: return "Silver (clamshell style)"
        case .gbClassicGray: return "Classic Gray"
        case .gbSlimSilver: return "Slim Silver"
        case .gbcGrape: return "Grape"
        case .gbcAtomic: return "Atomic Purple (translucent)"
        case .gbcTeal: return "Teal"
        case .gbcKiwi: return "Kiwi"
        case .gbcDandelion: return "Dandelion"
        case .gbcBerry: return "Berry"
        case .gbaPlatinum: return "Platinum"
        case .gbaSpice: return "Spice Orange"
        case .dark: return "Dark (minimal)"
        case .realDSPhatRed: return "Classic · Flame Red"
        case .realDS3DWhite: return "Lite 3D · Ice White"
        case .realGBASPRed: return "Clamshell · Flame Red"
        case .phoneMatte: return "Slab · Matte Black"
        case .phoneWhite: return "Slab · Chalk (colour buttons)"
        case .phoneIndigo: return "Slab · Indigo Clear"
        case .phoneDMG: return "Slab · Pocket Gray"
        case .phoneBlack: return "Slab · Midnight"
        case .nesFog: return "Console · Fog Gray"
        case .nesGraphite: return "Console · Graphite"
        case .snesFog: return "Super · Fog Gray"
        case .snesLilac: return "Super · Lilac"
        case .n64Original: return "N64 · Original"
        case .n64Charcoal: return "N64 · Charcoal"
        case .n64Forest: return "N64 · Forest"
        case .n3dsPearl: return "3DS · Pearl"
        case .n3dsInk: return "3DS · Ink"
        case .twinPearl: return "Twin · Pearl White"
        case .twinBlossom: return "Twin · Blossom Pink"
        case .dsClearIce: return "Clear · Ice (translucent)"
        case .dsClearGrape: return "Clear · Atomic Purple (translucent)"
        case .realDSLite: return "Lite · Gloss White"
        case .realDSLiteCobalt: return "Lite · Cobalt"
        case .realDSWhite: return "Classic · Arctic White"
        case .realDSGraphite: return "Classic · Graphite"
        case .realGBA: return "Advance · Indigo"
        case .realGBASP: return "Clamshell · Silver"
        case .realGB: return "Pocket Brick · Gray"
        case .realGBC: return "Pocket Color · Berry"
        case .heritageBrick: return "Heritage Brick · Original Gray"
        case .heritageColorBerry: return "Heritage Color · Berry"
        case .heritageColorGrape: return "Heritage Color · Grape"
        case .heritageColorAtomic: return "Heritage Color · Atomic Purple"
        case .heritageColorTeal: return "Heritage Color · Teal"
        case .heritageColorDandelion: return "Heritage Color · Dandelion"
        case .heritageColorKiwi: return "Heritage Color · Kiwi"
        case .heritageWideIndigo: return "Heritage Wide · Indigo"
        case .heritageWideGlacier: return "Heritage Wide · Glacier (clear)"
        case .heritageWideBlack: return "Heritage Wide · Black"
        case .heritageFlipSilver: return "Heritage Flip · Platinum Silver"
        case .heritageFlipCobalt: return "Heritage Flip · Cobalt"
        case .heritageFlipFlame: return "Heritage Flip · Flame"
        case .heritagePhatPlatinum: return "Heritage Phat · Platinum"
        case .heritagePhatOnyx: return "Heritage Phat · Onyx"
        case .heritageCamBlack: return "Heritage Cam · Matte Black"
        case .heritageCamWhite: return "Heritage Cam · Matte White"
        default: return clearRainbowLabel ?? rawValue
        }
    }

    var systems: Set<GameSystem> {
        switch self {
        case .twinPearl, .twinBlossom, .dsClearIce, .dsClearGrape, .classicGray, .polarWhite, .onyxBlack, .cobaltBlue, .crimsonRed, .pink, .iceBlue, .realDSPhatRed, .realDSLite, .realDSLiteCobalt, .realDS3DWhite, .realDSWhite, .realDSGraphite,
             .dsClearRed, .dsClearOrange, .dsClearYellow, .dsClearLime, .dsClearGreen, .dsClearDarkGreen, .dsClearTeal, .dsClearBlue, .dsClearPink,
             .heritagePhatPlatinum, .heritagePhatOnyx, .heritageCamBlack, .heritageCamWhite: return [.ds]
        case .gbaIndigo, .gbaGlacier, .gbaBlack, .gbaOrange, .gbaSilverSP, .realGBA,
             .gbClassicGray, .gbSlimSilver, .gbcGrape, .gbcAtomic, .gbcTeal, .gbcKiwi, .gbcDandelion, .gbcBerry, .gbaPlatinum, .gbaSpice, .realGBASP, .realGBASPRed, .realGB, .realGBC,
             .gbClearRed, .gbClearOrange, .gbClearYellow, .gbClearLime, .gbClearGreen, .gbClearDarkGreen, .gbClearTeal, .gbClearBlue, .gbClearPurple, .gbClearPink, .gbClearIce,
             .phoneMatte, .phoneWhite, .phoneIndigo, .phoneDMG, .phoneBlack,
             .heritageBrick, .heritageColorBerry, .heritageColorGrape, .heritageColorAtomic, .heritageColorTeal, .heritageColorDandelion, .heritageColorKiwi,
             .heritageWideIndigo, .heritageWideGlacier, .heritageWideBlack, .heritageFlipSilver, .heritageFlipCobalt, .heritageFlipFlame: return [.gba]
        case .nesFog, .nesGraphite: return [.nes]
        case .snesFog, .snesLilac: return [.snes]
        case .n64Original, .n64Charcoal, .n64Forest,
             .n64ClearRed, .n64ClearOrange, .n64ClearYellow, .n64ClearLime, .n64ClearGreen, .n64ClearDarkGreen, .n64ClearTeal, .n64ClearBlue, .n64ClearPurple, .n64ClearPink, .n64ClearIce: return [.n64]
        case .n3dsPearl, .n3dsInk,
             .n3dsClearRed, .n3dsClearOrange, .n3dsClearYellow, .n3dsClearLime, .n3dsClearGreen, .n3dsClearDarkGreen, .n3dsClearTeal, .n3dsClearBlue, .n3dsClearPurple, .n3dsClearPink, .n3dsClearIce: return [.n3ds]
        case .dark: return [.ds, .gba]
        }
    }

    /// #22 Heritage pack (classic-handheld look). Shown as its own group in the skin picker.
    var isHeritage: Bool { rawValue.hasPrefix("heritage") }

    /// Skins included with the free tier; the rest need Plus. The Heritage pack is free.
    var isFree: Bool { isHeritage || isClearRainbow || self == .twinPearl || self == .twinBlossom || self == .classicGray || self == .gbaIndigo || self == .gbClassicGray || self == .gbcGrape || self == .nesFog || self == .snesFog || self == .n64Original || self == .n64Charcoal || self == .n3dsPearl || self == .dark }

    static func skins(for system: GameSystem) -> [Skin] {
        allCases.filter { $0.systems.contains(system.skinSystem) && !$0.isRetiredOpaqueColor }
    }

    /// Stored skin for a system, falling back to its default if the stored one is for the other system.
    static func current(for system: GameSystem, raw: String?) -> Skin {
        if let raw, let s = Skin(rawValue: raw), s.systems.contains(system.skinSystem), s.isFree || Store.allows(.extraSkins) { return s }
        return system.defaultSkin
    }

    /// Colour swatch for pickers.
    /// Closed iPhone Duo (outer display, landscape): the default shell per console. Any skin the
    /// user picked is kept; only the stored default (Indigo) is swapped.
    static func outerDefault(for system: GameSystem) -> Skin {
        switch system {
        case .gb: return .gbClassicGray
        case .gbc: return .gbcGrape
        case .nes: return .nesFog
        case .snes: return .snesFog
        case .n64: return .n64Original
        case .n3ds: return .n3dsPearl
        default: return .gbaIndigo
        }
    }

    /// Classic handheld pack colours: body, buttons (black like the hardware, purple on the 1989 gray).
    private var packPalette: SkinPalette {
        func rgb(_ r: Double, _ g: Double, _ b: Double) -> Color { Color(red: r, green: g, blue: b) }
        let ink = rgb(0.10, 0.10, 0.11)
        var p: SkinPalette
        switch self {
        case .gbClassicGray:
            p = .shell(top: rgb(0.80, 0.80, 0.76), bottom: rgb(0.72, 0.72, 0.68), buttons: rgb(0.56, 0.16, 0.36), dpad: ink, dark: false)
            p.pillFill = rgb(0.52, 0.52, 0.55); p.faceText = rgb(0.30, 0.22, 0.40)
        case .gbSlimSilver:
            p = .shell(top: rgb(0.80, 0.81, 0.84), bottom: rgb(0.66, 0.67, 0.71), buttons: rgb(0.20, 0.20, 0.23), dpad: ink, dark: false)
        case .gbcGrape: p = .shell(top: rgb(0.45, 0.28, 0.62), bottom: rgb(0.33, 0.19, 0.48), buttons: ink, dpad: ink, dark: true)
        case .gbcAtomic:
            p = .shell(top: rgb(0.50, 0.36, 0.68).opacity(0.62), bottom: rgb(0.36, 0.24, 0.52).opacity(0.62), buttons: rgb(0.16, 0.12, 0.22), dpad: ink, dark: true)
            p.background = rgb(0.10, 0.07, 0.14)
        case .gbcTeal: p = .shell(top: rgb(0.16, 0.62, 0.64), bottom: rgb(0.10, 0.48, 0.50), buttons: ink, dpad: ink, dark: true)
        case .gbcKiwi: p = .shell(top: rgb(0.62, 0.80, 0.22), bottom: rgb(0.48, 0.66, 0.14), buttons: ink, dpad: ink, dark: false)
        case .gbcDandelion: p = .shell(top: rgb(0.99, 0.84, 0.20), bottom: rgb(0.92, 0.72, 0.10), buttons: ink, dpad: ink, dark: false)
        case .gbcBerry: p = .shell(top: rgb(0.88, 0.20, 0.42), bottom: rgb(0.72, 0.12, 0.32), buttons: ink, dpad: ink, dark: true)
        case .gbaPlatinum: p = .shell(top: rgb(0.86, 0.87, 0.90), bottom: rgb(0.74, 0.75, 0.79), buttons: rgb(0.30, 0.30, 0.34), dpad: ink, dark: false)
        default: p = .shell(top: rgb(0.97, 0.56, 0.18), bottom: rgb(0.86, 0.44, 0.10), buttons: ink, dpad: ink, dark: true)
        }
        // Dark caps everywhere (like the hardware): light labels on the pills and face buttons.
        if self != .gbClassicGray { p.pillFill = rgb(0.22, 0.22, 0.25) }
        p.pillText = Color(white: 0.92); p.buttonText = Color(white: 0.88)
        return p
    }

    var swatch: Color { palette.drawsShell ? palette.shellTop : .black }

    /// Which detailed shell the background draws (plain = the simple rounded shell).
    var shellStyle: ShellStyle {
        // #9: every DS skin (all colours) uses the DS reference shell: speaker dots beside the top
        // screen, an L / MIC / R hinge bar, round START / SELECT / MENU and TwinPlay's mark.
        if systems == [.ds] { return .twin }
        switch self {
        case .gbClassicGray, .gbSlimSilver: return .brick
        case .gbcGrape, .gbcAtomic, .gbcTeal, .gbcKiwi, .gbcDandelion, .gbcBerry: return .color
        case .gbaPlatinum, .gbaSpice: return .gba
        case .realGBA: return .gba
        case .realGBASP, .realGBASPRed: return .clamshell
        case .phoneMatte, .phoneWhite, .phoneIndigo, .phoneDMG, .phoneBlack: return .phone
        case .realGB: return .brick
        case .realGBC: return .color
        case .gbaSilverSP: return .clamshell
        case .gbaIndigo, .gbaGlacier, .gbaBlack, .gbaOrange: return .gba
        case .nesFog, .nesGraphite, .n64Original, .n64Charcoal, .n64Forest,
             .n64ClearRed, .n64ClearOrange, .n64ClearYellow, .n64ClearLime, .n64ClearGreen, .n64ClearDarkGreen, .n64ClearTeal, .n64ClearBlue, .n64ClearPurple, .n64ClearPink, .n64ClearIce: return .nes
        case .snesFog, .snesLilac: return .snes
        case .n3dsPearl, .n3dsInk,
             .n3dsClearRed, .n3dsClearOrange, .n3dsClearYellow, .n3dsClearLime, .n3dsClearGreen, .n3dsClearDarkGreen, .n3dsClearTeal, .n3dsClearBlue, .n3dsClearPurple, .n3dsClearPink, .n3dsClearIce: return .twin
        case .gbClearRed, .gbClearOrange, .gbClearYellow, .gbClearLime, .gbClearGreen, .gbClearDarkGreen, .gbClearTeal, .gbClearBlue, .gbClearPurple, .gbClearPink, .gbClearIce: return .color
        case .heritageBrick: return .brick
        case .heritageColorBerry, .heritageColorGrape, .heritageColorAtomic, .heritageColorTeal, .heritageColorDandelion, .heritageColorKiwi: return .color
        case .heritageWideIndigo, .heritageWideGlacier, .heritageWideBlack: return .gba
        case .heritageFlipSilver, .heritageFlipCobalt, .heritageFlipFlame: return .clamshell
        default: return .plain
        }
    }

    /// Hardware model for control placement.
    var padModel: PadModel {
        switch self {
        case .realDSPhatRed, .realDSWhite, .realDSGraphite, .classicGray: return .phat
        case .heritagePhatPlatinum, .heritagePhatOnyx: return .phat
        case .realGB, .phoneDMG, .heritageBrick: return .brick
        default: return .standard
        }
    }

    var palette: SkinPalette {
        if isHeritage { return heritagePalette }
        if let hue = clearHue { return hue.palette() }
        switch self {
        case .realDSPhatRed:
            var p = SkinPalette.shell(top: rgb(0.93, 0.27, 0.22), bottom: rgb(0.80, 0.16, 0.13), buttons: rgb(0.17, 0.17, 0.19),
                                      dpad: rgb(0.15, 0.15, 0.17), dark: true)
            p.bezel = rgb(0.08, 0.08, 0.09); p.hinge = rgb(0.84, 0.22, 0.18)
            p.pillFill = rgb(0.18, 0.18, 0.20); p.shoulderFill = rgb(0.14, 0.14, 0.16)
            return p
        case .realGBASPRed:
            var p = SkinPalette.shell(top: rgb(0.92, 0.22, 0.18), bottom: rgb(0.78, 0.13, 0.11), buttons: rgb(0.22, 0.22, 0.25),
                                      dpad: rgb(0.17, 0.17, 0.19), dark: true)
            p.bezel = rgb(0.07, 0.07, 0.08); p.hinge = rgb(0.82, 0.18, 0.15)
            p.pillFill = rgb(0.20, 0.20, 0.22)
            return p
        case .realDS3DWhite:
            var p = SkinPalette.shell(top: rgb(0.95, 0.95, 0.94), bottom: rgb(0.88, 0.88, 0.87), buttons: rgb(0.93, 0.93, 0.93),
                                      dpad: rgb(0.92, 0.92, 0.92), dark: false)
            p.bezel = rgb(0.07, 0.07, 0.08); p.hinge = rgb(0.86, 0.86, 0.85)
            p.dpadArrow = rgb(0.6, 0.6, 0.62); p.pillFill = rgb(0.88, 0.88, 0.88)
            p.faceColors = ["X": rgb(0.22, 0.45, 0.85), "A": rgb(0.86, 0.22, 0.25), "Y": rgb(0.24, 0.62, 0.36), "B": rgb(0.93, 0.74, 0.18)]
            p.faceText = .white
            return p
        case .phoneMatte:
            var p = SkinPalette.shell(top: rgb(0.11, 0.11, 0.12), bottom: rgb(0.07, 0.07, 0.08), buttons: rgb(0.06, 0.06, 0.07),
                                      dpad: rgb(0.05, 0.05, 0.06), dark: true)
            p.bezel = rgb(0.03, 0.03, 0.04); p.buttonText = rgb(0.30, 0.30, 0.32); p.pillFill = rgb(0.05, 0.05, 0.06)
            p.shoulderFill = rgb(0.05, 0.05, 0.06)
            return p
        case .phoneWhite:
            var p = SkinPalette.shell(top: rgb(0.95, 0.94, 0.92), bottom: rgb(0.89, 0.88, 0.86), buttons: rgb(0.93, 0.92, 0.90),
                                      dpad: rgb(0.93, 0.92, 0.90), dark: false)
            p.bezel = rgb(0.10, 0.10, 0.11); p.dpadArrow = rgb(0.62, 0.62, 0.62); p.pillFill = rgb(0.84, 0.83, 0.81)
            p.faceColors = ["A": rgb(0.88, 0.20, 0.24), "B": rgb(0.93, 0.72, 0.20), "L": rgb(0.30, 0.62, 0.42), "R": rgb(0.24, 0.42, 0.78)]
            p.faceText = .white
            return p
        case .phoneIndigo:
            var p = SkinPalette.shell(top: rgb(0.42, 0.36, 0.86), bottom: rgb(0.30, 0.24, 0.72), buttons: rgb(0.86, 0.86, 0.92),
                                      dpad: rgb(0.88, 0.88, 0.93), dark: true)
            p.bezel = rgb(0.12, 0.10, 0.22); p.buttonText = rgb(0.45, 0.42, 0.62); p.dpadArrow = rgb(0.6, 0.58, 0.72)
            p.pillFill = rgb(0.80, 0.80, 0.88); p.pillText = rgb(0.30, 0.28, 0.48); p.shoulderFill = rgb(0.80, 0.80, 0.88)
            p.shoulderText = rgb(0.30, 0.28, 0.48)
            return p
        case .phoneDMG:
            var p = SkinPalette.shell(top: rgb(0.86, 0.85, 0.81), bottom: rgb(0.80, 0.79, 0.75), buttons: rgb(0.56, 0.16, 0.36),
                                      dpad: rgb(0.17, 0.17, 0.19), dark: false)
            p.bezel = rgb(0.38, 0.39, 0.46); p.buttonText = rgb(0.30, 0.30, 0.50); p.buttonPressed = rgb(0.40, 0.08, 0.24)
            p.pillFill = rgb(0.45, 0.46, 0.52); p.pillText = rgb(0.25, 0.27, 0.45); p.shoulderFill = rgb(0.16, 0.16, 0.18)
            return p
        case .phoneBlack:
            var p = SkinPalette.shell(top: rgb(0.14, 0.14, 0.15), bottom: rgb(0.09, 0.09, 0.10), buttons: rgb(0.10, 0.10, 0.11),
                                      dpad: rgb(0.08, 0.08, 0.09), dark: true)
            p.bezel = rgb(0.03, 0.03, 0.04); p.buttonText = rgb(0.40, 0.40, 0.42); p.pillFill = rgb(0.08, 0.08, 0.09)
            return p
        case .twinPearl:
            // Pearl white Lite-style shell with light-gray screen bezels (iPhone Duo default).
            var p = SkinPalette.shell(top: rgb(0.985, 0.985, 0.98), bottom: rgb(0.93, 0.93, 0.925), buttons: rgb(0.97, 0.97, 0.965),
                                      dpad: rgb(0.95, 0.95, 0.945), dark: false)
            p.bezel = rgb(0.86, 0.86, 0.865); p.hinge = rgb(0.92, 0.92, 0.915)
            p.buttonText = rgb(0.50, 0.50, 0.52); p.dpadArrow = rgb(0.58, 0.58, 0.60)
            p.pillFill = rgb(0.93, 0.93, 0.925); p.pillText = rgb(0.50, 0.50, 0.52)
            p.shoulderFill = rgb(0.95, 0.95, 0.945); p.shoulderText = rgb(0.45, 0.45, 0.47)
            return p
        case .twinBlossom:
            // Same Twin shell in a soft blossom pink with pink-tinted bezels and hinge.
            var p = SkinPalette.shell(top: rgb(0.97, 0.79, 0.86), bottom: rgb(0.93, 0.72, 0.80), buttons: rgb(0.96, 0.78, 0.85),
                                      dpad: rgb(0.95, 0.76, 0.84), dark: false)
            p.bezel = rgb(0.90, 0.68, 0.77); p.hinge = rgb(0.94, 0.75, 0.83)
            p.buttonText = rgb(0.62, 0.40, 0.50); p.dpadArrow = rgb(0.70, 0.48, 0.58)
            p.pillFill = rgb(0.94, 0.75, 0.83); p.pillText = rgb(0.58, 0.38, 0.47)
            p.shoulderFill = rgb(0.95, 0.77, 0.84); p.shoulderText = rgb(0.55, 0.36, 0.45)
            return p
        case .dsClearIce:
            var p = SkinPalette.shell(top: rgb(0.72, 0.86, 0.96).opacity(0.5), bottom: rgb(0.56, 0.74, 0.90).opacity(0.5),
                                      buttons: rgb(0.84, 0.92, 0.99).opacity(0.8), dpad: rgb(0.70, 0.82, 0.94).opacity(0.85), dark: false)
            p.background = rgb(0.09, 0.12, 0.18); p.pillFill = rgb(0.82, 0.90, 0.98).opacity(0.8); p.shoulderFill = rgb(0.74, 0.86, 0.96).opacity(0.8)
            p.buttonText = rgb(0.22, 0.32, 0.45); p.dpadArrow = rgb(0.38, 0.50, 0.64)
            return p
        case .dsClearGrape:
            var p = SkinPalette.shell(top: rgb(0.52, 0.36, 0.72).opacity(0.55), bottom: rgb(0.36, 0.22, 0.56).opacity(0.55),
                                      buttons: rgb(0.44, 0.30, 0.62).opacity(0.85), dpad: rgb(0.30, 0.20, 0.44).opacity(0.9), dark: true)
            p.background = rgb(0.09, 0.06, 0.13); p.pillFill = rgb(0.42, 0.28, 0.60).opacity(0.85); p.shoulderFill = rgb(0.46, 0.32, 0.64).opacity(0.8)
            return p
        case .realDSLite:
            var p = SkinPalette.shell(top: rgb(0.995, 0.995, 1.0), bottom: rgb(0.90, 0.91, 0.93), buttons: rgb(0.96, 0.96, 0.97),
                                      dpad: rgb(0.93, 0.93, 0.94), dark: false)
            p.bezel = rgb(0.06, 0.06, 0.07); p.hinge = rgb(0.86, 0.87, 0.89)
            p.buttonText = rgb(0.45, 0.46, 0.50); p.dpadArrow = rgb(0.55, 0.56, 0.60)
            p.pillFill = rgb(0.86, 0.87, 0.89); p.shoulderFill = rgb(0.88, 0.89, 0.91)
            return p
        case .realDSLiteCobalt:
            var p = SkinPalette.shell(top: rgb(0.20, 0.30, 0.62), bottom: rgb(0.08, 0.13, 0.36), buttons: rgb(0.10, 0.12, 0.20),
                                      dpad: rgb(0.08, 0.10, 0.18), dark: true)
            p.bezel = rgb(0.04, 0.04, 0.06); p.hinge = rgb(0.10, 0.16, 0.38)
            return p
        case .realDSWhite:
            var p = SkinPalette.shell(top: rgb(0.97, 0.97, 0.96), bottom: rgb(0.88, 0.88, 0.87), buttons: rgb(0.93, 0.93, 0.92),
                                      dpad: rgb(0.20, 0.20, 0.21), dark: false)
            p.bezel = rgb(0.09, 0.09, 0.10); p.hinge = rgb(0.82, 0.82, 0.81)
            p.pillFill = rgb(0.80, 0.80, 0.79); p.shoulderFill = rgb(0.84, 0.84, 0.83)
            return p
        case .realDSGraphite:
            var p = SkinPalette.shell(top: rgb(0.23, 0.24, 0.26), bottom: rgb(0.13, 0.13, 0.15), buttons: rgb(0.16, 0.16, 0.18),
                                      dpad: rgb(0.08, 0.08, 0.09), dark: true)
            p.bezel = rgb(0.05, 0.05, 0.06); p.hinge = rgb(0.18, 0.18, 0.20)
            return p
        case .realGBA:
            var p = SkinPalette.shell(top: rgb(0.40, 0.33, 0.70), bottom: rgb(0.30, 0.23, 0.57), buttons: rgb(0.70, 0.68, 0.78),
                                      dpad: rgb(0.17, 0.15, 0.26), dark: true)
            p.bezel = rgb(0.10, 0.09, 0.14); p.buttonText = rgb(0.25, 0.22, 0.36)
            p.pillFill = rgb(0.22, 0.19, 0.36)
            return p
        case .realGBASP:
            var p = SkinPalette.shell(top: rgb(0.86, 0.87, 0.89), bottom: rgb(0.66, 0.68, 0.72), buttons: rgb(0.30, 0.31, 0.34),
                                      dpad: rgb(0.22, 0.23, 0.25), dark: false)
            p.bezel = rgb(0.06, 0.06, 0.07); p.buttonText = rgb(0.85, 0.86, 0.88)
            p.pillFill = rgb(0.36, 0.37, 0.40); p.pillText = rgb(0.86, 0.87, 0.89)
            return p
        case .realGB:
            var p = SkinPalette.shell(top: rgb(0.80, 0.79, 0.76), bottom: rgb(0.74, 0.73, 0.70), buttons: rgb(0.55, 0.10, 0.31),
                                      dpad: rgb(0.13, 0.13, 0.15), dark: false)
            p.bezel = rgb(0.33, 0.34, 0.41); p.buttonText = rgb(0.95, 0.85, 0.90); p.buttonPressed = rgb(0.40, 0.06, 0.22)
            p.pillFill = rgb(0.52, 0.53, 0.58); p.pillText = rgb(0.20, 0.22, 0.38)
            return p
        case .realGBC:
            var p = SkinPalette.shell(top: rgb(0.62, 0.12, 0.38), bottom: rgb(0.48, 0.07, 0.29), buttons: rgb(0.20, 0.17, 0.22),
                                      dpad: rgb(0.12, 0.11, 0.13), dark: true)
            p.bezel = rgb(0.07, 0.07, 0.09)
            return p
        case .dark:
            return SkinPalette(
                background: .black, shellTop: .black, shellBottom: .black, shellEdge: .clear,
                bezel: .black, hinge: .clear,
                buttonFill: .white.opacity(0.22), buttonPressed: .white.opacity(0.55), buttonStroke: .white.opacity(0.6),
                buttonText: .white,
                dpadFill: .white.opacity(0.22), dpadArrow: .white.opacity(0.7), dpadArrowOn: .white,
                pillFill: .white.opacity(0.22), pillText: .white,
                shoulderFill: .white.opacity(0.22), shoulderText: .white,
                menuTint: .white.opacity(0.75), drawsShell: false, portraitOpacity: 0.9, landscapeOpacity: 0.45)
        case .classicGray:
            return SkinPalette(
                background: Color(white: 0.16),
                shellTop: Color(white: 0.86), shellBottom: Color(white: 0.76), shellEdge: Color(white: 0.62),
                bezel: Color(white: 0.20), hinge: Color(white: 0.66),
                buttonFill: Color(white: 0.60), buttonPressed: Color(white: 0.45), buttonStroke: Color(white: 0.42),
                buttonText: Color(white: 0.20),
                dpadFill: Color(white: 0.30), dpadArrow: Color(white: 0.62), dpadArrowOn: Color(white: 0.92),
                pillFill: Color(white: 0.52), pillText: Color(white: 0.18),
                shoulderFill: Color(white: 0.66), shoulderText: Color(white: 0.25),
                menuTint: Color(white: 0.35), drawsShell: true, portraitOpacity: 1.0, landscapeOpacity: 0.8)
        case .polarWhite:
            return .shell(top: rgb(0.97, 0.97, 0.98), bottom: rgb(0.90, 0.91, 0.93), buttons: rgb(0.80, 0.81, 0.84),
                          dpad: rgb(0.22, 0.23, 0.25), dark: false)
        case .onyxBlack:
            return .shell(top: rgb(0.20, 0.20, 0.22), bottom: rgb(0.10, 0.10, 0.11), buttons: rgb(0.32, 0.32, 0.35),
                          dpad: rgb(0.06, 0.06, 0.07), dark: true)
        case .cobaltBlue:
            return .shell(top: rgb(0.20, 0.32, 0.62), bottom: rgb(0.12, 0.21, 0.47), buttons: rgb(0.13, 0.15, 0.24),
                          dpad: rgb(0.08, 0.09, 0.15), dark: true)
        case .crimsonRed:
            return .shell(top: rgb(0.78, 0.13, 0.16), bottom: rgb(0.58, 0.07, 0.10), buttons: rgb(0.20, 0.07, 0.08),
                          dpad: rgb(0.12, 0.04, 0.05), dark: true)
        case .pink:
            // Reference shell (ds-skin-ref): buttons and D-pad in the shell's own pink.
            var p = SkinPalette.shell(top: rgb(0.98, 0.80, 0.86), bottom: rgb(0.95, 0.74, 0.81), buttons: rgb(0.97, 0.80, 0.86),
                                      dpad: rgb(0.96, 0.78, 0.84), dark: false)
            p.buttonText = rgb(0.98, 0.97, 0.98); p.dpadArrow = rgb(0.99, 0.95, 0.97); p.dpadArrowOn = .white
            p.pillFill = rgb(0.97, 0.82, 0.87); p.shoulderFill = rgb(0.97, 0.82, 0.87); p.shoulderText = rgb(0.66, 0.50, 0.56)
            return p
        case .iceBlue:
            return .shell(top: rgb(0.80, 0.91, 0.97), bottom: rgb(0.66, 0.82, 0.92), buttons: rgb(0.93, 0.97, 1.0),
                          dpad: rgb(0.25, 0.36, 0.45), dark: false)
        case .gbaIndigo:
            return .shell(top: rgb(0.42, 0.36, 0.72), bottom: rgb(0.31, 0.25, 0.58), buttons: rgb(0.62, 0.60, 0.70),
                          dpad: rgb(0.16, 0.14, 0.24), dark: true)
        case .gbClassicGray, .gbSlimSilver, .gbcGrape, .gbcAtomic, .gbcTeal, .gbcKiwi, .gbcDandelion, .gbcBerry, .gbaPlatinum, .gbaSpice:
            return packPalette
        case .gbaGlacier:
            var p = SkinPalette.shell(top: rgb(0.70, 0.80, 0.95).opacity(0.55), bottom: rgb(0.55, 0.66, 0.88).opacity(0.55),
                                      buttons: rgb(0.85, 0.90, 1.0).opacity(0.75), dpad: rgb(0.30, 0.38, 0.55), dark: false)
            p.background = rgb(0.10, 0.13, 0.20)
            return p
        case .gbaBlack:
            return .shell(top: rgb(0.16, 0.16, 0.18), bottom: rgb(0.08, 0.08, 0.09), buttons: rgb(0.30, 0.30, 0.33),
                          dpad: rgb(0.04, 0.04, 0.05), dark: true)
        case .gbaOrange:
            return .shell(top: rgb(0.98, 0.58, 0.20), bottom: rgb(0.90, 0.45, 0.10), buttons: rgb(0.25, 0.20, 0.18),
                          dpad: rgb(0.18, 0.14, 0.12), dark: true)
        case .gbaSilverSP:
            return .shell(top: rgb(0.88, 0.89, 0.91), bottom: rgb(0.70, 0.72, 0.75), buttons: rgb(0.55, 0.57, 0.62),
                          dpad: rgb(0.25, 0.26, 0.29), dark: false)
        case .nesFog:
            var nes = SkinPalette.shell(top: rgb(0.78, 0.78, 0.76), bottom: rgb(0.62, 0.62, 0.60), buttons: rgb(0.72, 0.16, 0.18),
                                         dpad: rgb(0.16, 0.16, 0.17), dark: false)
            nes.bezel = rgb(0.10, 0.10, 0.11)
            nes.buttonText = rgb(0.98, 0.94, 0.90)
            nes.pillFill = rgb(0.22, 0.22, 0.24)
            nes.pillText = rgb(0.92, 0.92, 0.90)
            return nes
        case .nesGraphite:
            var graph = SkinPalette.shell(top: rgb(0.28, 0.28, 0.30), bottom: rgb(0.14, 0.14, 0.15), buttons: rgb(0.62, 0.12, 0.14),
                                           dpad: rgb(0.08, 0.08, 0.09), dark: true)
            graph.bezel = rgb(0.04, 0.04, 0.05)
            graph.buttonText = rgb(0.98, 0.94, 0.90)
            graph.pillFill = rgb(0.18, 0.18, 0.20)
            return graph
        case .snesFog:
            var snes = SkinPalette.shell(top: rgb(0.86, 0.86, 0.88), bottom: rgb(0.70, 0.70, 0.74), buttons: rgb(0.82, 0.82, 0.86),
                                          dpad: rgb(0.55, 0.56, 0.60), dark: false)
            snes.bezel = rgb(0.12, 0.12, 0.14)
            snes.dpadArrow = rgb(0.22, 0.22, 0.24)
            snes.pillFill = rgb(0.42, 0.40, 0.48)
            snes.pillText = rgb(0.95, 0.95, 0.97)
            snes.shoulderFill = rgb(0.55, 0.56, 0.62)
            snes.shoulderText = rgb(0.96, 0.96, 0.98)
            // Face colours follow the console's diamond so each button is recognisable.
            snes.faceColors = ["X": rgb(0.20, 0.38, 0.78), "Y": rgb(0.22, 0.55, 0.32),
                               "A": rgb(0.78, 0.18, 0.22), "B": rgb(0.86, 0.72, 0.16)]
            snes.faceText = rgb(0.98, 0.98, 0.99)
            return snes
        case .snesLilac:
            var lilac = SkinPalette.shell(top: rgb(0.62, 0.56, 0.78), bottom: rgb(0.46, 0.40, 0.64), buttons: rgb(0.90, 0.88, 0.96),
                                           dpad: rgb(0.36, 0.32, 0.50), dark: true)
            lilac.bezel = rgb(0.16, 0.12, 0.24)
            lilac.buttonText = rgb(0.20, 0.16, 0.28)
            lilac.pillFill = rgb(0.34, 0.28, 0.48)
            lilac.shoulderFill = rgb(0.40, 0.34, 0.58)
            lilac.faceColors = ["X": rgb(0.20, 0.38, 0.78), "Y": rgb(0.22, 0.55, 0.32),
                                "A": rgb(0.78, 0.18, 0.22), "B": rgb(0.86, 0.72, 0.16)]
            lilac.faceText = .white
            return lilac
        case .n64Original:
            // Official N64 controller colours: gray body, blue A, green B, yellow C cluster, red Start.
            var original = SkinPalette.shell(top: rgb(0.58, 0.59, 0.61), bottom: rgb(0.46, 0.47, 0.48), buttons: rgb(0.50, 0.51, 0.52),
                                         dpad: rgb(0.10, 0.10, 0.11), dark: false)
            original.background = rgb(0.52, 0.53, 0.54)
            original.bezel = rgb(0.22, 0.22, 0.23)
            original.pillFill = rgb(0.82, 0.10, 0.12)
            original.pillText = .white
            original.shoulderFill = rgb(0.50, 0.51, 0.52)
            original.shoulderText = rgb(0.18, 0.18, 0.19)
            let n64Blue = rgb(0.12, 0.32, 0.72)
            let n64Green = rgb(0.07, 0.55, 0.28)
            let n64Yellow = rgb(0.96, 0.80, 0.08)
            let n64Gray = rgb(0.50, 0.51, 0.52)
            original.faceColors = ["A": n64Blue, "B": n64Green,
                                   "C": n64Yellow, "C↑": n64Yellow, "C↓": n64Yellow, "C←": n64Yellow, "C→": n64Yellow,
                                   "START": rgb(0.82, 0.10, 0.12),
                                   "L": n64Gray, "R": n64Gray, "Z": rgb(0.36, 0.37, 0.38)]
            original.faceText = .white
            return original
        case .n64Charcoal:
            var n64 = SkinPalette.shell(top: rgb(0.22, 0.24, 0.26), bottom: rgb(0.12, 0.13, 0.14), buttons: rgb(0.18, 0.45, 0.78),
                                         dpad: rgb(0.10, 0.10, 0.11), dark: true)
            n64.bezel = rgb(0.05, 0.05, 0.06)
            n64.faceColors = ["A": rgb(0.20, 0.45, 0.82), "B": rgb(0.20, 0.62, 0.38),
                              "C": rgb(0.86, 0.72, 0.18)]
            n64.faceText = .white
            return n64
        case .n64Forest:
            var forest = SkinPalette.shell(top: rgb(0.18, 0.36, 0.28), bottom: rgb(0.10, 0.22, 0.16), buttons: rgb(0.86, 0.86, 0.84),
                                           dpad: rgb(0.08, 0.12, 0.10), dark: true)
            forest.bezel = rgb(0.05, 0.07, 0.06)
            forest.faceColors = ["A": rgb(0.20, 0.45, 0.82), "B": rgb(0.20, 0.62, 0.38),
                                 "C": rgb(0.86, 0.72, 0.18)]
            forest.faceText = .white
            return forest
        case .n3dsPearl:
            var pearl = SkinPalette.shell(top: rgb(0.93, 0.94, 0.95), bottom: rgb(0.78, 0.80, 0.82), buttons: rgb(0.90, 0.91, 0.92),
                                           dpad: rgb(0.25, 0.27, 0.30), dark: false)
            pearl.bezel = rgb(0.12, 0.13, 0.15)
            pearl.hinge = rgb(0.70, 0.72, 0.75)
            return pearl
        case .n3dsInk:
            var ink = SkinPalette.shell(top: rgb(0.16, 0.17, 0.20), bottom: rgb(0.08, 0.08, 0.10), buttons: rgb(0.22, 0.24, 0.28),
                                         dpad: rgb(0.06, 0.06, 0.08), dark: true)
            ink.bezel = rgb(0.03, 0.03, 0.04)
            ink.hinge = rgb(0.12, 0.13, 0.16)
            return ink
        default: return heritagePalette
        }
    }
}

private func rgb(_ r: Double, _ g: Double, _ b: Double) -> Color { Color(red: r, green: g, blue: b) }

extension SkinPalette {
    /// Builds a full handheld palette from a shell colour, a button colour and a D-pad colour.
    static func shell(top: Color, bottom: Color, buttons: Color, dpad: Color, dark: Bool) -> SkinPalette {
        let text: Color = dark ? Color(white: 0.92) : Color(white: 0.18)
        return SkinPalette(
            background: Color(white: dark ? 0.06 : 0.16),
            shellTop: top, shellBottom: bottom, shellEdge: Color.black.opacity(0.25),
            bezel: Color(white: 0.14), hinge: bottom.opacity(0.9),
            buttonFill: buttons, buttonPressed: buttons.opacity(0.6), buttonStroke: Color.black.opacity(0.35),
            buttonText: text,
            dpadFill: dpad, dpadArrow: Color(white: 0.62), dpadArrowOn: Color(white: 0.95),
            pillFill: buttons.opacity(0.85), pillText: text,
            shoulderFill: bottom, shoulderText: text,
            menuTint: dark ? Color(white: 0.85) : Color(white: 0.30), drawsShell: true, portraitOpacity: 1.0, landscapeOpacity: 0.8)
    }
}

struct SkinPalette {
    var background, shellTop, shellBottom, shellEdge, bezel, hinge: Color
    var buttonFill, buttonPressed, buttonStroke, buttonText: Color
    var dpadFill, dpadArrow, dpadArrowOn: Color
    var pillFill, pillText: Color
    var shoulderFill, shoulderText: Color
    var menuTint: Color
    var drawsShell: Bool
    var portraitOpacity, landscapeOpacity: Double
    /// Per-button cap colours ("A", "B", "X", "Y", "L", "R", "Z", "START", "C", "C↑"…); missing ones use buttonFill / shoulderFill.
    var faceColors: [String: Color] = [:]
    var faceText: Color? = nil
}

private struct SkinKey: EnvironmentKey { static let defaultValue: Skin = .classicGray }
extension EnvironmentValues {
    var skin: Skin {
        get { self[SkinKey.self] }
        set { self[SkinKey.self] = newValue }
    }
}

/// Everything around the shell during play (corners, safe areas, the gap at a Duo hinge): a deep
/// shade of the skin's own colour instead of a neutral gray, so the whole play area reads as the skin.
struct SkinSurround: View {
    let skin: Skin
    var body: some View {
        if skin.palette.drawsShell {
            ZStack {
                LinearGradient(colors: [skin.lid.light, skin.lid.dark], startPoint: .topLeading, endPoint: .bottomTrailing)
                Color.black.opacity(skin.lid.translucent ? 0.55 : 0.45)
            }
        } else {
            skin.palette.background
        }
    }
}

/// Handheld-style body drawn behind the screens: rounded shell, dark screen bezels and a
/// hinge bar between the two screens. Follows the adaptive DualScreenLayout.
struct SkinBackground: View {
    let layout: DualScreenLayout
    let size: CGSize
    @Environment(\.skin) private var skin

    var body: some View {
        let p = skin.palette
        let lid = skin.lid
        ZStack {
            SkinSurround(skin: skin)
            if skin.shellStyle != .plain {
                RealisticShell(style: skin.shellStyle, palette: p, lid: lid, layout: layout, size: size, variant: skin.rawValue)
            } else if p.drawsShell {
                let inset: CGFloat = 4
                let shell = RoundedRectangle(cornerRadius: 34, style: .continuous)
                // Same colour and finish as the lid: shell gradient, gloss sweep, matte grain, bevel.
                shell
                    .fill(LinearGradient(colors: [p.shellTop, p.shellBottom], startPoint: .top, endPoint: .bottom))
                    .overlay(shell.fill(LinearGradient(stops: [
                        .init(color: .white.opacity(0), location: 0),
                        .init(color: .white.opacity(0.30 * lid.gloss), location: 0.38),
                        .init(color: .white.opacity(0), location: 0.6)],
                        startPoint: .topLeading, endPoint: .bottomTrailing)).blendMode(.screen))
                    .overlay(shell.fill(Color.black.opacity(0.05 * (1 - lid.gloss))))
                    .overlay(shell.strokeBorder(LinearGradient(colors: [.white.opacity(0.45), lid.edge.opacity(0.9)],
                                                               startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 2.5))
                    .frame(width: size.width - inset * 2, height: size.height - inset * 2)
                    .position(x: size.width / 2, y: size.height / 2)

                if layout.isSingle {
                    bezel(for: layout.top, p)
                    // Speaker grille dots (decorative, original design).
                    speaker(p)
                } else {
                    hinge(p)
                    bezel(for: layout.top, p)
                    bezel(for: layout.bottom, p)
                }
            }
        }
    }

    @ViewBuilder private func hinge(_ p: SkinPalette) -> some View {
        if layout.isSideBySide {
            let x = (layout.top.maxX + layout.bottom.minX) / 2
            let h = max(layout.top.height, layout.bottom.height) + 36
            Capsule().fill(p.hinge)
                .overlay(Capsule().stroke(p.shellEdge, lineWidth: 1))
                .frame(width: 12, height: h)
                .position(x: x, y: layout.top.midY)
        } else {
            let y = (layout.top.maxY + layout.bottom.minY) / 2
            let w = max(layout.top.width, layout.bottom.width) + 36
            Capsule().fill(p.hinge)
                .overlay(Capsule().stroke(p.shellEdge, lineWidth: 1))
                .frame(width: w, height: 12)
                .position(x: layout.top.midX, y: y)
        }
    }

    @ViewBuilder private func speaker(_ p: SkinPalette) -> some View {
        let r = layout.top
        let x = layout.isPortrait ? r.maxX - 30 : r.maxX + 30
        let y = layout.isPortrait ? r.maxY + 34 : r.maxY - 20
        if x < size.width - 10 && y < size.height - 10 {
            VStack(spacing: 4) {
                ForEach(0..<3, id: \.self) { _ in
                    HStack(spacing: 4) { ForEach(0..<3, id: \.self) { _ in Circle().fill(p.shellEdge).frame(width: 4, height: 4) } }
                }
            }
            .position(x: x, y: y)
        }
    }

    private func bezel(for r: CGRect, _ p: SkinPalette) -> some View {
        let m: CGFloat = 8
        return RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(p.bezel)
            .frame(width: r.width + m * 2, height: r.height + m * 2)
            .position(x: r.midX, y: r.midY)
    }
}

/// Paints 3DS skin art over the unused parts of the opaque CAMetalLayer and draws
/// bezels around the LCDs Azahar already presents. Not a CALayer mask (those stalled presents).
struct N3DSSkinFitOverlay: View {
    let area: CGRect
    let top: CGRect
    let bottom: CGRect
    @Environment(\.skin) private var skin

    var body: some View {
        let p = skin.palette
        let clear = skin.lid.translucent
        Canvas { ctx, _ in
            var leftover = Path()
            leftover.addRect(area)
            leftover.addRect(top)
            leftover.addRect(bottom)
            let style = FillStyle(eoFill: true)
            // Even-odd fill leaves the LCD holes open so the skin never covers the screens.
            if clear {
                ctx.fill(leftover, with: .color(p.background.opacity(0.92)), style: style)
            }
            ctx.fill(leftover, with: .linearGradient(
                Gradient(colors: [p.shellTop, p.shellBottom]),
                startPoint: CGPoint(x: area.midX, y: area.minY),
                endPoint: CGPoint(x: area.midX, y: area.maxY)),
                       style: style)
        }
        .allowsHitTesting(false)
        bezel(for: top, p)
        bezel(for: bottom, p)
        // Thin hinge line in the hairline between the packed screens.
        let midY = (top.maxY + bottom.minY) / 2
        let hingeW = max(top.width, bottom.width) + 20
        Capsule()
            .fill(p.hinge)
            .frame(width: hingeW, height: 4)
            .position(x: (top.midX + bottom.midX) / 2, y: midY)
            .allowsHitTesting(false)
    }

    private func bezel(for r: CGRect, _ p: SkinPalette) -> some View {
        let m: CGFloat = 8
        return RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(p.bezel, lineWidth: 6)
            .frame(width: r.width + m * 2, height: r.height + m * 2)
            .position(x: r.midX, y: r.midY)
            .allowsHitTesting(false)
    }
}

