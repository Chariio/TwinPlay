// Copyright (c) 2026 Charlie Rodriguez Garcia. All rights reserved.
// Vivid translucent "clear plastic" shells in a rainbow of colours, drawn with the
// existing skin system (movable controls, screens stay uncovered). Original artwork only.
import SwiftUI

/// The clear-plastic rainbow. At least eight dramatic tints, plus Ice from the earlier DS set.
enum ClearHue: String, CaseIterable {
    case red, orange, yellow, lime, green, darkGreen, teal, blue, purple, pink, ice

    /// Rainbow order for the picker (Ice last: paler, already existed as Clear · Ice).
    static let pickerOrder: [ClearHue] = [
        .red, .orange, .yellow, .lime, .green, .darkGreen, .teal, .blue, .purple, .pink, .ice
    ]

    var colorName: String {
        switch self {
        case .red: return "Red"
        case .orange: return "Orange"
        case .yellow: return "Yellow"
        case .lime: return "Lime"
        case .green: return "Green"
        case .darkGreen: return "Dark Green"
        case .teal: return "Teal"
        case .blue: return "Blue"
        case .purple: return "Purple"
        case .pink: return "Pink"
        case .ice: return "Ice"
        }
    }

    /// Highlight / shadow shell dyes and a dark inside colour seen through the plastic.
    var dyes: (light: (Double, Double, Double), dark: (Double, Double, Double), inside: (Double, Double, Double)) {
        switch self {
        case .red:        return ((0.98, 0.10, 0.12), (0.70, 0.04, 0.06), (0.12, 0.03, 0.04))
        case .orange:     return ((1.00, 0.46, 0.08), (0.82, 0.24, 0.02), (0.14, 0.06, 0.02))
        case .yellow:     return ((0.99, 0.86, 0.10), (0.90, 0.64, 0.04), (0.14, 0.11, 0.02))
        case .lime:       return ((0.72, 0.96, 0.14), (0.42, 0.72, 0.06), (0.06, 0.12, 0.02))
        case .green:      return ((0.10, 0.82, 0.28), (0.04, 0.52, 0.16), (0.02, 0.10, 0.05))
        case .darkGreen:  return ((0.08, 0.48, 0.26), (0.03, 0.26, 0.14), (0.02, 0.07, 0.05))
        case .teal:       return ((0.08, 0.82, 0.82), (0.04, 0.52, 0.58), (0.02, 0.10, 0.11))
        case .blue:       return ((0.12, 0.50, 0.98), (0.06, 0.24, 0.72), (0.03, 0.06, 0.14))
        case .purple:     return ((0.62, 0.30, 0.88), (0.36, 0.12, 0.58), (0.08, 0.03, 0.12))
        case .pink:       return ((0.99, 0.38, 0.66), (0.82, 0.16, 0.44), (0.14, 0.04, 0.08))
        case .ice:        return ((0.78, 0.92, 0.99), (0.42, 0.66, 0.88), (0.08, 0.12, 0.16))
        }
    }

    func palette() -> SkinPalette {
        let d = dyes
        func c(_ t: (Double, Double, Double), a: Double = 1) -> Color {
            Color(red: t.0, green: t.1, blue: t.2).opacity(a)
        }
        // Tinted see-through body, dark insides, black button caps (like the clear-plastic reference),
        // a silver hinge/rim so the shell reads as a moulded piece of candy-coloured plastic.
        var p = SkinPalette.shell(
            top: c(d.light, a: 0.52),
            bottom: c(d.dark, a: 0.52),
            buttons: Color(red: 0.10, green: 0.10, blue: 0.11).opacity(0.94),
            dpad: Color(red: 0.08, green: 0.08, blue: 0.09).opacity(0.96),
            dark: true
        )
        p.background = c(d.inside)
        p.bezel = Color(red: 0.07, green: 0.07, blue: 0.08)
        p.hinge = Color(red: 0.78, green: 0.80, blue: 0.84)
        p.shellEdge = Color.white.opacity(0.50)
        p.buttonText = Color.white.opacity(0.92)
        p.dpadArrow = Color.white.opacity(0.72)
        p.dpadArrowOn = .white
        p.pillFill = Color(red: 0.12, green: 0.12, blue: 0.14).opacity(0.90)
        p.pillText = Color.white.opacity(0.90)
        p.shoulderFill = c(d.light, a: 0.70)
        p.shoulderText = Color.white.opacity(0.90)
        p.menuTint = c(d.light)
        // N64 keeps the familiar A / B / C / Start colours on a clear body.
        let n64Blue = Color(red: 0.12, green: 0.32, blue: 0.72)
        let n64Green = Color(red: 0.07, green: 0.55, blue: 0.28)
        let n64Yellow = Color(red: 0.96, green: 0.80, blue: 0.08)
        p.faceColors = [
            "A": n64Blue, "B": n64Green,
            "C": n64Yellow, "C↑": n64Yellow, "C↓": n64Yellow, "C←": n64Yellow, "C→": n64Yellow,
            "START": Color(red: 0.82, green: 0.10, blue: 0.12),
            "X": Color(red: 0.22, green: 0.45, blue: 0.85),
            "Y": Color(red: 0.24, green: 0.62, blue: 0.36)
        ]
        p.faceText = .white
        return p
    }

    func lid() -> LidStyle {
        let d = dyes
        func c(_ t: (Double, Double, Double)) -> Color { Color(red: t.0, green: t.1, blue: t.2) }
        return LidStyle(
            light: c(d.light),
            dark: c(d.dark),
            edge: Color(red: 0.72, green: 0.74, blue: 0.78),
            hinge: Color(red: 0.78, green: 0.80, blue: 0.84),
            gloss: 0.96,
            translucent: true
        )
    }
}

extension Skin {
    /// Older opaque DS colour pack replaced in the picker by the clear rainbow.
    /// Persisted values still load; they are just no longer offered as new picks.
    var isRetiredOpaqueColor: Bool {
        switch self {
        case .polarWhite, .onyxBlack, .cobaltBlue, .crimsonRed, .pink, .iceBlue: return true
        default: return false
        }
    }

    var clearHue: ClearHue? {
        let raw = rawValue
        let prefixes = ["n3dsClear", "dsClear", "gbClear", "n64Clear"]
        guard let prefix = prefixes.first(where: { raw.hasPrefix($0) }) else { return nil }
        var rest = String(raw.dropFirst(prefix.count))
        if rest == "Grape" { rest = "Purple" }
        guard let first = rest.first else { return nil }
        let key = String(first).lowercased() + rest.dropFirst()
        return ClearHue(rawValue: key)
    }

    var isClearRainbow: Bool { clearHue != nil }

    var clearRainbowLabel: String? {
        guard let hue = clearHue else { return nil }
        if hue == .ice { return "Clear · Ice (translucent)" }
        return "Clear · \(hue.colorName)"
    }
}
