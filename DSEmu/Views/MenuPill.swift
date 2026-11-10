// Copyright (c) 2026 Charlie Rodriguez Garcia. All rights reserved.
import SwiftUI
import UIKit

/// The small dark rubber "MENU" pill of the classic handheld shells, used on every skin to open
/// the in-game menu (it replaced the glass bubble). Movable in Edit Layout; the spot is saved per
/// skin and layout.
struct MenuPill: View {
    /// Label colour follows the shell under the pill.
    var darkBody: Bool
    /// DS reference shell: a small round button in the shell's colour with "MENU" on its left.
    var round: SkinPalette? = nil
    static let hitSize = CGSize(width: 56, height: 40)

    var body: some View {
        if let p = round {
            HStack(spacing: 5) {
                Text("MENU").font(.system(size: 9, weight: .semibold, design: .rounded))
                    .foregroundStyle(darkBody ? Color.white.opacity(0.62) : Color.black.opacity(0.45))
                ShellDot(fill: p.pillFill, darkBody: darkBody).frame(width: 17, height: 17)
            }
            .frame(width: Self.hitSize.width + 10, height: Self.hitSize.height)
            .contentShape(Rectangle())
        } else {
            pill
        }
    }

    private var pill: some View {
        VStack(spacing: 2) {
            Capsule().fill(LinearGradient(colors: [Color(white: 0.30), Color(white: 0.14)], startPoint: .top, endPoint: .bottom))
                .overlay(Capsule().stroke(Color.black.opacity(0.6), lineWidth: 1.5).blur(radius: 0.8).offset(y: 0.8).clipShape(Capsule()))
                .shadow(color: .white.opacity(darkBody ? 0.12 : 0.5), radius: 0, y: 0.8)
                .frame(width: 34, height: 9)
            Text("MENU").font(.system(size: 7, weight: .bold, design: .rounded))
                .foregroundStyle(darkBody ? Color.white.opacity(0.62) : Color.black.opacity(0.5))
        }
        .frame(width: Self.hitSize.width, height: Self.hitSize.height)
        .contentShape(Rectangle())
    }

    /// Dark shell (or no drawn shell: the plain dark background) -> light label.
    static func isDark(_ palette: SkinPalette) -> Bool {
        guard palette.drawsShell else { return true }
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(palette.shellTop).getRed(&r, green: &g, blue: &b, alpha: &a)
        return 0.299 * r + 0.587 * g + 0.114 * b < 0.45
    }
}

/// Small round shell button (START / SELECT / MENU of the DS reference shell): a convex cap
/// sitting in a shallow ring.
struct ShellDot: View {
    var fill: Color
    var darkBody: Bool
    var isDown = false

    var body: some View {
        ZStack {
            Circle().fill(Color.black.opacity(darkBody ? 0.45 : 0.22)).scaleEffect(1.12).blur(radius: 0.6)
            Circle().fill(fill)
            Circle().fill(LinearGradient(colors: [.white.opacity(isDown ? 0.1 : 0.55), .white.opacity(0), .black.opacity(0.18)],
                                         startPoint: .top, endPoint: .bottom))
            Circle().strokeBorder(Color.black.opacity(0.28), lineWidth: 0.8)
        }
        .shadow(color: .black.opacity(isDown ? 0.1 : 0.3), radius: isDown ? 0.4 : 1.2, y: isDown ? 0.3 : 1)
        .scaleEffect(isDown ? 0.92 : 1)
    }
}

/// TwinPlay's mark (two stacked screens of the app icon), debossed into the shell. Replaces the
/// triangle between the face buttons of the DS reference shell.
struct TwinPlayMark: View {
    var darkBody: Bool
    var body: some View {
        let ink = darkBody ? Color.black.opacity(0.45) : Color.black.opacity(0.22)
        let lip = darkBody ? Color.white.opacity(0.16) : Color.white.opacity(0.75)
        let glyph = VStack(spacing: 1.6) {
            RoundedRectangle(cornerRadius: 1.6).strokeBorder(lineWidth: 1.6).frame(width: 13, height: 8)
            RoundedRectangle(cornerRadius: 1.6).strokeBorder(lineWidth: 1.6).frame(width: 11, height: 7)
        }
        ZStack { glyph.foregroundStyle(lip).offset(y: 0.8); glyph.foregroundStyle(ink) }
            .accessibilityHidden(true)
    }
}
