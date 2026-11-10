// Copyright (c) 2026 Charlie Rodriguez Garcia. All rights reserved.
import SwiftUI

// Liquid Glass for TwinPlay's own chrome (iOS 26+), with a material fallback on older systems.
// System menus, toolbars, sheets, forms and alerts adopt glass by themselves; these helpers
// cover the custom pieces (pills, cards, toasts, overlay buttons). Never used on the game
// picture itself: only small chrome sits over a running game.

extension View {
    /// A glass panel in `shape`. `interactive` makes it react to touches (buttons).
    @ViewBuilder
    func glassSurface<S: Shape>(_ shape: S, interactive: Bool = false, tint: Color? = nil) -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffect(Self.glass(interactive: interactive, tint: tint), in: shape)
        } else if let tint {
            self.background(shape.fill(tint))
        } else {
            self.background(.ultraThinMaterial, in: shape)
        }
    }

    /// Glass button style (prominent = tinted, for the main action).
    @ViewBuilder
    func glassButton(prominent: Bool = false) -> some View {
        if #available(iOS 26.0, *) {
            if prominent { self.buttonStyle(.glassProminent) } else { self.buttonStyle(.glass) }
        } else {
            if prominent { self.buttonStyle(.borderedProminent) } else { self.buttonStyle(.bordered) }
        }
    }

    @available(iOS 26.0, *)
    private static func glass(interactive: Bool, tint: Color?) -> Glass {
        var g = Glass.regular
        if let tint { g = g.tint(tint) }
        if interactive { g = g.interactive() }
        return g
    }
}

/// Groups nearby glass shapes so they blend and morph together (iOS 26+).
struct GlassGroup<Content: View>: View {
    var spacing: CGFloat = 12
    @ViewBuilder var content: Content
    var body: some View {
        if #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) { content }
        } else {
            content
        }
    }
}
