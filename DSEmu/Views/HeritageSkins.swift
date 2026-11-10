// Copyright (c) 2026 Charlie Rodriguez Garcia. All rights reserved.
// #22 Heritage pack: original artwork after the classic handhelds' shapes, colours and parts.
// TwinPlay branding only: no third-party logos, names, wordmarks or seals.
import SwiftUI

extension Skin {
    /// Colours of the Heritage pack, picked from the original shell plastics.
    var heritagePalette: SkinPalette {
        func c(_ r: Double, _ g: Double, _ b: Double) -> Color { Color(red: r, green: g, blue: b) }
        let ink = c(0.11, 0.11, 0.12)
        var p: SkinPalette
        switch self {
        case .heritageBrick:
            // Warm gray brick, slate screen surround, magenta A / B, black cross, gray rubber pills.
            p = .shell(top: c(0.80, 0.80, 0.77), bottom: c(0.75, 0.75, 0.72), buttons: c(0.60, 0.13, 0.38), dpad: c(0.14, 0.14, 0.16), dark: false)
            p.bezel = c(0.36, 0.37, 0.45); p.buttonText = c(0.96, 0.86, 0.92); p.buttonPressed = c(0.42, 0.07, 0.25)
            p.pillFill = c(0.55, 0.56, 0.60); p.pillText = c(0.20, 0.22, 0.44); p.faceText = nil
            p.shoulderFill = c(0.70, 0.70, 0.67); p.shoulderText = c(0.20, 0.22, 0.44)
            p.dpadArrow = c(0.40, 0.40, 0.44)
            return p
        case .heritageColorBerry: p = .shell(top: c(0.82, 0.10, 0.34), bottom: c(0.68, 0.06, 0.27), buttons: ink, dpad: ink, dark: true)
        case .heritageColorGrape: p = .shell(top: c(0.43, 0.26, 0.63), bottom: c(0.32, 0.18, 0.50), buttons: ink, dpad: ink, dark: true)
        case .heritageColorAtomic:
            p = .shell(top: c(0.50, 0.38, 0.70).opacity(0.58), bottom: c(0.36, 0.25, 0.54).opacity(0.58), buttons: c(0.18, 0.13, 0.25), dpad: c(0.14, 0.11, 0.20), dark: true)
            p.background = c(0.09, 0.06, 0.13)
        case .heritageColorTeal: p = .shell(top: c(0.09, 0.60, 0.65), bottom: c(0.05, 0.47, 0.53), buttons: ink, dpad: ink, dark: true)
        case .heritageColorDandelion: p = .shell(top: c(0.99, 0.83, 0.17), bottom: c(0.94, 0.71, 0.08), buttons: ink, dpad: ink, dark: false)
        case .heritageColorKiwi: p = .shell(top: c(0.66, 0.83, 0.20), bottom: c(0.52, 0.69, 0.12), buttons: ink, dpad: ink, dark: false)
        case .heritageWideIndigo:
            p = .shell(top: c(0.41, 0.34, 0.71), bottom: c(0.30, 0.24, 0.58), buttons: c(0.73, 0.71, 0.81), dpad: c(0.18, 0.16, 0.27), dark: true)
            p.buttonText = c(0.30, 0.27, 0.44); p.pillFill = c(0.22, 0.19, 0.36); p.shoulderFill = c(0.36, 0.30, 0.64)
        case .heritageWideGlacier:
            p = .shell(top: c(0.70, 0.82, 0.97).opacity(0.55), bottom: c(0.54, 0.68, 0.90).opacity(0.55), buttons: c(0.86, 0.92, 1.0).opacity(0.8),
                       dpad: c(0.62, 0.74, 0.90).opacity(0.9), dark: false)
            p.background = c(0.09, 0.12, 0.19); p.buttonText = c(0.24, 0.34, 0.50); p.dpadArrow = c(0.32, 0.44, 0.60)
            p.pillFill = c(0.80, 0.88, 0.98).opacity(0.8); p.shoulderFill = c(0.74, 0.84, 0.97).opacity(0.75)
        case .heritageWideBlack:
            p = .shell(top: c(0.16, 0.16, 0.18), bottom: c(0.09, 0.09, 0.10), buttons: c(0.28, 0.28, 0.31), dpad: c(0.05, 0.05, 0.06), dark: true)
        case .heritageFlipSilver:
            p = .shell(top: c(0.87, 0.88, 0.90), bottom: c(0.68, 0.70, 0.74), buttons: c(0.30, 0.31, 0.34), dpad: c(0.22, 0.23, 0.25), dark: false)
            p.buttonText = c(0.86, 0.87, 0.89); p.pillFill = c(0.36, 0.37, 0.40); p.pillText = c(0.86, 0.87, 0.89)
        case .heritageFlipCobalt:
            p = .shell(top: c(0.18, 0.27, 0.62), bottom: c(0.09, 0.15, 0.42), buttons: c(0.12, 0.15, 0.27), dpad: c(0.09, 0.11, 0.20), dark: true)
        case .heritageFlipFlame:
            p = .shell(top: c(0.88, 0.17, 0.14), bottom: c(0.72, 0.09, 0.08), buttons: c(0.20, 0.20, 0.23), dpad: c(0.16, 0.16, 0.18), dark: true)
        case .heritagePhatPlatinum:
            // Silver shell, charcoal screen surrounds, gray cross, pale silver face buttons.
            p = .shell(top: c(0.85, 0.86, 0.88), bottom: c(0.76, 0.77, 0.80), buttons: c(0.82, 0.83, 0.86), dpad: c(0.30, 0.31, 0.33), dark: false)
            p.bezel = c(0.22, 0.23, 0.25); p.buttonText = c(0.42, 0.43, 0.47); p.pillFill = c(0.80, 0.81, 0.84); p.shoulderFill = c(0.80, 0.81, 0.84)
            p.hinge = c(0.70, 0.71, 0.74)
            return p
        case .heritagePhatOnyx:
            p = .shell(top: c(0.18, 0.18, 0.20), bottom: c(0.11, 0.11, 0.12), buttons: c(0.24, 0.24, 0.26), dpad: c(0.10, 0.10, 0.11), dark: true)
            p.bezel = c(0.05, 0.05, 0.06); p.hinge = c(0.16, 0.16, 0.18)
            return p
        case .heritageCamBlack:
            p = .shell(top: c(0.14, 0.14, 0.15), bottom: c(0.10, 0.10, 0.11), buttons: c(0.17, 0.17, 0.18), dpad: c(0.12, 0.12, 0.13), dark: true)
            p.bezel = c(0.04, 0.04, 0.05); p.hinge = c(0.12, 0.12, 0.13); p.buttonText = c(0.55, 0.55, 0.57)
            return p
        default: // .heritageCamWhite
            p = .shell(top: c(0.95, 0.95, 0.94), bottom: c(0.89, 0.89, 0.88), buttons: c(0.97, 0.97, 0.96), dpad: c(0.93, 0.93, 0.92), dark: false)
            p.bezel = c(0.08, 0.08, 0.09); p.hinge = c(0.88, 0.88, 0.87); p.buttonText = c(0.55, 0.55, 0.57)
            p.dpadArrow = c(0.62, 0.62, 0.64); p.pillFill = c(0.93, 0.93, 0.92); p.shoulderFill = c(0.94, 0.94, 0.93)
            return p
        }
        // Colour and flip shells: dark caps with light labels, like the hardware.
        if shellStyle == .color { p.bezel = c(0.08, 0.08, 0.10); p.pillFill = c(0.22, 0.22, 0.25); p.pillText = Color(white: 0.92); p.buttonText = Color(white: 0.88) }
        if shellStyle == .clamshell { p.bezel = c(0.06, 0.06, 0.07) }
        if shellStyle == .gba { p.bezel = c(0.10, 0.09, 0.13) }
        return p
    }

    /// Lid finish of the Heritage pack: matte bricks, satin colour shells, glossy flips.
    var heritageLid: LidStyle {
        let p = heritagePalette
        let gloss: Double
        switch self {
        case .heritageBrick, .heritageCamBlack, .heritageCamWhite: gloss = 0.1
        case .heritageWideIndigo, .heritageWideBlack: gloss = 0.2
        case .heritagePhatPlatinum, .heritagePhatOnyx: gloss = 0.4
        case .heritageFlipSilver: gloss = 0.65
        case .heritageFlipCobalt, .heritageFlipFlame, .heritageWideGlacier, .heritageColorAtomic: gloss = 0.85
        default: gloss = 0.35
        }
        return LidStyle(light: p.shellTop, dark: p.shellBottom, edge: p.shellBottom.opacity(0.8), hinge: p.hinge, gloss: gloss,
                        translucent: self == .heritageColorAtomic || self == .heritageWideGlacier)
    }
}
