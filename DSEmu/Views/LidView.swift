// Copyright (c) 2026 Charlie Rodriguez Garcia. All rights reserved.
// Original lid design drawn with SwiftUI shapes. No third-party logos, trademarks or trade dress.
import SwiftUI

/// Material of the closed lid, derived from the current skin.
struct LidStyle {
    var light: Color      // highlight side of the lid
    var dark: Color       // shadow side
    var edge: Color       // bevel / rim
    var hinge: Color      // hinge barrel
    var gloss: Double     // 0 = matte, 1 = piano gloss
    var translucent = false
}

extension Skin {
    /// Every skin maps to a lid finish.
    var lid: LidStyle {
        func c(_ r: Double, _ g: Double, _ b: Double) -> Color { Color(red: r, green: g, blue: b) }
        if isHeritage { return heritageLid }
        if let hue = clearHue { return hue.lid() }
        switch self {
        case .twinPearl:    return LidStyle(light: c(0.99, 0.99, 0.985), dark: c(0.88, 0.88, 0.875), edge: c(0.70, 0.70, 0.71), hinge: c(0.84, 0.84, 0.85), gloss: 0.7)
        case .twinBlossom: return LidStyle(light: c(0.98, 0.82, 0.88), dark: c(0.92, 0.70, 0.79), edge: c(0.78, 0.52, 0.63), hinge: c(0.90, 0.68, 0.77), gloss: 0.7)
        case .classicGray: return LidStyle(light: c(0.88, 0.88, 0.89), dark: c(0.72, 0.72, 0.74), edge: c(0.58, 0.58, 0.60), hinge: c(0.62, 0.62, 0.64), gloss: 0.25)
        case .polarWhite:  return LidStyle(light: c(0.99, 0.99, 1.00), dark: c(0.86, 0.87, 0.90), edge: c(0.74, 0.75, 0.78), hinge: c(0.80, 0.81, 0.84), gloss: 0.85)
        case .onyxBlack:   return LidStyle(light: c(0.24, 0.24, 0.26), dark: c(0.06, 0.06, 0.07), edge: c(0.02, 0.02, 0.02), hinge: c(0.12, 0.12, 0.13), gloss: 0.95)
        case .cobaltBlue:  return LidStyle(light: c(0.26, 0.40, 0.72), dark: c(0.10, 0.18, 0.42), edge: c(0.06, 0.11, 0.28), hinge: c(0.12, 0.20, 0.44), gloss: 0.8)
        case .crimsonRed:  return LidStyle(light: c(0.86, 0.18, 0.20), dark: c(0.50, 0.05, 0.08), edge: c(0.32, 0.03, 0.05), hinge: c(0.52, 0.06, 0.09), gloss: 0.85)
        case .pink:        return LidStyle(light: c(1.00, 0.82, 0.88), dark: c(0.90, 0.58, 0.70), edge: c(0.76, 0.44, 0.56), hinge: c(0.88, 0.56, 0.68), gloss: 0.75)
        case .iceBlue:     return LidStyle(light: c(0.86, 0.94, 0.99), dark: c(0.60, 0.77, 0.89), edge: c(0.46, 0.62, 0.75), hinge: c(0.60, 0.76, 0.87), gloss: 0.75)
        case .gbClassicGray, .gbSlimSilver, .gbcGrape, .gbcAtomic, .gbcTeal, .gbcKiwi, .gbcDandelion, .gbcBerry, .gbaPlatinum, .gbaSpice:
            let p = palette
            return LidStyle(light: p.shellTop, dark: p.shellBottom, edge: p.shellBottom.opacity(0.8), hinge: p.shellBottom, gloss: 0.3,
                            translucent: self == .gbcAtomic)
        case .gbaIndigo:   return LidStyle(light: c(0.48, 0.42, 0.78), dark: c(0.27, 0.21, 0.52), edge: c(0.18, 0.14, 0.38), hinge: c(0.28, 0.22, 0.52), gloss: 0.2)
        case .gbaGlacier:  return LidStyle(light: c(0.78, 0.86, 0.98), dark: c(0.50, 0.62, 0.86), edge: c(0.36, 0.46, 0.68), hinge: c(0.50, 0.60, 0.82), gloss: 0.9, translucent: true)
        case .gbaBlack:    return LidStyle(light: c(0.20, 0.20, 0.22), dark: c(0.06, 0.06, 0.07), edge: c(0.02, 0.02, 0.02), hinge: c(0.10, 0.10, 0.11), gloss: 0.2)
        case .gbaOrange:   return LidStyle(light: c(1.00, 0.64, 0.26), dark: c(0.86, 0.40, 0.08), edge: c(0.64, 0.28, 0.04), hinge: c(0.82, 0.38, 0.08), gloss: 0.3)
        case .gbaSilverSP: return LidStyle(light: c(0.93, 0.94, 0.96), dark: c(0.64, 0.66, 0.70), edge: c(0.48, 0.50, 0.54), hinge: c(0.58, 0.60, 0.64), gloss: 0.6)
        case .realDSPhatRed: return LidStyle(light: c(0.95, 0.32, 0.26), dark: c(0.72, 0.12, 0.10), edge: c(0.45, 0.06, 0.05), hinge: c(0.84, 0.22, 0.18), gloss: 0.4)
        case .realGBASPRed: return LidStyle(light: c(0.95, 0.28, 0.22), dark: c(0.70, 0.10, 0.08), edge: c(0.44, 0.05, 0.04), hinge: c(0.82, 0.18, 0.15), gloss: 0.5)
        case .realDS3DWhite: return LidStyle(light: c(0.98, 0.98, 0.97), dark: c(0.86, 0.86, 0.85), edge: c(0.72, 0.72, 0.71), hinge: c(0.86, 0.86, 0.85), gloss: 0.6)
        case .phoneMatte:  return LidStyle(light: c(0.14, 0.14, 0.15), dark: c(0.05, 0.05, 0.06), edge: c(0.0, 0.0, 0.0), hinge: c(0.08, 0.08, 0.09), gloss: 0.1)
        case .phoneWhite:  return LidStyle(light: c(0.97, 0.96, 0.94), dark: c(0.86, 0.85, 0.83), edge: c(0.72, 0.71, 0.69), hinge: c(0.84, 0.83, 0.81), gloss: 0.3)
        case .phoneIndigo: return LidStyle(light: c(0.48, 0.42, 0.90), dark: c(0.26, 0.20, 0.66), edge: c(0.16, 0.12, 0.44), hinge: c(0.30, 0.24, 0.70), gloss: 0.9, translucent: true)
        case .phoneDMG:    return LidStyle(light: c(0.88, 0.87, 0.83), dark: c(0.76, 0.75, 0.71), edge: c(0.60, 0.59, 0.56), hinge: c(0.70, 0.69, 0.66), gloss: 0.1)
        case .phoneBlack:  return LidStyle(light: c(0.18, 0.18, 0.19), dark: c(0.06, 0.06, 0.07), edge: c(0.0, 0.0, 0.0), hinge: c(0.10, 0.10, 0.11), gloss: 0.6)
        case .realDSLite:  return LidStyle(light: c(1.0, 1.0, 1.0), dark: c(0.88, 0.89, 0.91), edge: c(0.74, 0.75, 0.78), hinge: c(0.84, 0.85, 0.87), gloss: 1.0)
        case .realDSLiteCobalt: return LidStyle(light: c(0.28, 0.40, 0.76), dark: c(0.07, 0.12, 0.34), edge: c(0.04, 0.07, 0.22), hinge: c(0.10, 0.16, 0.38), gloss: 1.0)
        case .realDSWhite: return LidStyle(light: c(0.99, 0.99, 0.98), dark: c(0.84, 0.84, 0.83), edge: c(0.70, 0.70, 0.69), hinge: c(0.80, 0.80, 0.79), gloss: 0.9)
        case .dsClearIce: return LidStyle(light: c(0.80, 0.90, 0.98), dark: c(0.52, 0.68, 0.86), edge: c(0.36, 0.50, 0.68), hinge: c(0.56, 0.72, 0.88), gloss: 0.95, translucent: true)
        case .dsClearGrape: return LidStyle(light: c(0.60, 0.44, 0.80), dark: c(0.32, 0.20, 0.52), edge: c(0.20, 0.12, 0.36), hinge: c(0.38, 0.25, 0.58), gloss: 0.95, translucent: true)
        case .realDSGraphite: return LidStyle(light: c(0.28, 0.29, 0.31), dark: c(0.08, 0.08, 0.09), edge: c(0.03, 0.03, 0.03), hinge: c(0.15, 0.15, 0.16), gloss: 0.9)
        case .realGBA:     return LidStyle(light: c(0.46, 0.39, 0.76), dark: c(0.26, 0.20, 0.50), edge: c(0.17, 0.13, 0.36), hinge: c(0.27, 0.21, 0.50), gloss: 0.15)
        case .realGBASP:   return LidStyle(light: c(0.92, 0.93, 0.95), dark: c(0.60, 0.62, 0.66), edge: c(0.45, 0.47, 0.51), hinge: c(0.55, 0.57, 0.61), gloss: 0.7)
        case .realGB:      return LidStyle(light: c(0.84, 0.83, 0.80), dark: c(0.70, 0.69, 0.66), edge: c(0.56, 0.55, 0.52), hinge: c(0.66, 0.65, 0.62), gloss: 0.1)
        case .realGBC:     return LidStyle(light: c(0.70, 0.16, 0.44), dark: c(0.42, 0.05, 0.25), edge: c(0.28, 0.03, 0.16), hinge: c(0.45, 0.06, 0.27), gloss: 0.35)
        case .dark:        return LidStyle(light: c(0.14, 0.14, 0.15), dark: c(0.03, 0.03, 0.03), edge: c(0.0, 0.0, 0.0), hinge: c(0.08, 0.08, 0.09), gloss: 0.5)
        case .nesFog, .nesGraphite, .snesFog, .snesLilac, .n64Original, .n64Charcoal, .n64Forest, .n3dsPearl, .n3dsInk:
            let p = palette
            return LidStyle(light: p.shellTop, dark: p.shellBottom, edge: p.shellBottom.opacity(0.85), hinge: p.shellBottom, gloss: 0.35)
        default:           return heritageLid
        }
    }
}

/// Where the drawn lid goes and which of its edges is the hinge (#20h).
///
/// The iPhone Duo folds like a DS: open in portrait, the crease runs across the middle, the
/// upper half (top DS screen) is the lid and closes onto the lower half (touch screen and
/// controls). So on the inner display the lid covers the half below the hinge, hinged at the
/// crease (its top edge in portrait) and swings down over it. Once shut the app is on the outer
/// display, which is the back of that lid: the lid covers it all, hinge bar along the top of the
/// window and emblem upright, in whatever interface orientation the scene has.
enum LidGeometry {
    struct Placement: Equatable {
        var cover: CGRect      // area the lid lies over when shut
        var hinge: Edge        // edge of `cover` the lid swings from
    }

    /// - Parameters:
    ///   - outer: the game is on the Duo's outer display (laid out at its size).
    ///   - duo: the window belongs to an iPhone Duo. Other iPhones keep the full-screen lid
    ///     that slides down from the top (face-down pause), as before.
    ///   - crease: the hinge band on the inner display, when known.
    ///   - held: the interface orientation that matches how the phone is held right now (from
    ///     the device orientation), when known; the outer lid's hinge goes on that side's top.
    static func placement(full: CGSize, duo: Bool, outer: Bool, orientation: UIInterfaceOrientation,
                          crease: CGRect? = nil, held: UIInterfaceOrientation? = nil) -> Placement {
        let all = CGRect(origin: .zero, size: full)
        guard duo else { return Placement(cover: all, hinge: .top) }
        let portraitWindow = full.height >= full.width
        // #20i Outer display: the closed lid reads like a closed DS in the interface orientation
        // the scene actually has (hinge bar on top, emblem upright), whichever way the system
        // turned it. The physical-edge mapping of #20h came out 180 degrees off on the real Duo.
        // #20j While the Duo is being folded the scene can still be in the other landscape for a
        // moment before the system turns it to match the hold: the lid follows how the phone is
        // actually held (device orientation) from the first frame, so it never shows upside down.
        if outer { return Placement(cover: all, hinge: upEdge(current: orientation, held: held)) }
        // Inner display: the half that is the DS's lower half (native bottom of the device).
        let o: UIInterfaceOrientation = orientation == .unknown ? (portraitWindow ? .portrait : .landscapeRight) : orientation
        let vertical = o == .landscapeLeft || o == .landscapeRight      // crease runs top to bottom
        let c = crease ?? FoldGeometry.defaultHinge(full: full)
        if vertical {
            let mid = (crease != nil && c.height > c.width) ? c : CGRect(x: full.width / 2, y: 0, width: 0, height: full.height)
            if o == .landscapeRight {   // native bottom on the right
                return Placement(cover: CGRect(x: mid.maxX, y: 0, width: full.width - mid.maxX, height: full.height), hinge: .leading)
            }
            return Placement(cover: CGRect(x: 0, y: 0, width: mid.minX, height: full.height), hinge: .trailing)
        }
        let mid = (crease != nil && c.width >= c.height) ? c : CGRect(x: 0, y: full.height / 2, width: full.width, height: 0)
        if o == .portraitUpsideDown {
            return Placement(cover: CGRect(x: 0, y: 0, width: full.width, height: mid.minY), hinge: .bottom)
        }
        return Placement(cover: CGRect(x: 0, y: mid.maxY, width: full.width, height: full.height - mid.maxY), hinge: .top)
    }

    /// Clockwise angle, from the device's native top, of the window's "up" in each orientation.
    static func upAngle(_ o: UIInterfaceOrientation) -> Int? {
        switch o {
        case .portrait: return 0
        case .landscapeRight: return 90
        case .portraitUpsideDown: return 180
        case .landscapeLeft: return 270
        default: return nil
        }
    }

    /// Window edge that is physically up when the phone is held as `held` while the scene is
    /// still in `current` (top when they match or either is unknown).
    static func upEdge(current: UIInterfaceOrientation, held: UIInterfaceOrientation?) -> Edge {
        guard let h = held, let a = upAngle(h), let c = upAngle(current) else { return .top }
        switch ((a - c) % 360 + 360) % 360 {
        case 90: return .trailing
        case 180: return .bottom
        case 270: return .leading
        default: return .top
        }
    }

    /// Interface orientation matching a device orientation (nil when flat / unknown).
    static func interface(for d: UIDeviceOrientation) -> UIInterfaceOrientation? {
        switch d {
        case .portrait: return .portrait
        case .landscapeLeft: return .landscapeRight
        case .landscapeRight: return .landscapeLeft
        default: return nil     // face up / down / unknown; upside down is not used on iPhone
        }
    }

    /// Turn that maps the lid drawn with its hinge on top onto `edge`.
    static func turn(for edge: Edge) -> Double {
        switch edge { case .top: return 0; case .trailing: return 90; case .bottom: return 180; case .leading: return -90 }
    }

    /// Hinge-lid rule once a fold has settled: all or nothing.
    static func settled(_ raw: Double) -> Double { raw >= 0.5 ? 1 : 0 }
}

/// Closed handheld lid with an embossed TwinPlay logo. `progress` runs from 0 (open, hidden) to
/// 1 (fully closed).
/// - With a `placement` (iPhone Duo) the lid is an opaque panel over `placement.cover`, hinged at
///   `placement.hinge`; it swings down about the hinge like a DS lid (edge-on at 0, flat at 1).
/// - Without one (other iPhones, face-down pause) it slides in from the top over the whole view.
struct LidView: View {
    let style: LidStyle
    var progress: Double = 1
    var placement: LidGeometry.Placement? = nil

    var body: some View {
        GeometryReader { geo in
            let p = min(max(progress, 0), 1)
            let eased = 1 - pow(1 - p, 3)
            if let pl = placement {
                swinging(full: geo.size, pl: pl, p: p, eased: eased)
            } else {
                sliding(s: geo.size, p: p, eased: eased)
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(progress > 0.01)
        .accessibilityElement()
        .accessibilityLabel(progress >= 1 ? "Closed. Open the device to resume." : "Closing")
    }

    /// DS lid on the Duo: drawn with the hinge on top, swung about it, then turned to the hinge edge.
    @ViewBuilder private func swinging(full: CGSize, pl: LidGeometry.Placement, p: Double, eased: Double) -> some View {
        let sideways = pl.hinge == .leading || pl.hinge == .trailing
        let cs = sideways ? CGSize(width: pl.cover.height, height: pl.cover.width) : pl.cover.size
        // 90 degrees = standing up at the hinge (edge-on), 0 = lying shut. Linear in the hinge
        // angle so the drawn lid follows the Duo's own half as it comes down.
        let swing = 85 * (1 - p)
        ZStack(alignment: .topLeading) {
            // The other half faces the closing lid: it darkens as the lid comes down.
            Color.black.opacity(0.55 * eased)
            // Shadow the lid casts on the half it closes over.
            Rectangle().fill(Color.black.opacity(0.35 + 0.5 * eased))
                .frame(width: pl.cover.width, height: pl.cover.height)
                .position(x: pl.cover.midX, y: pl.cover.midY)
            panel(s: cs, p: p, shade: 0.4 * (1 - eased))              // less light while it stands up
                .frame(width: cs.width, height: cs.height)
                .rotation3DEffect(.degrees(swing), axis: (x: 1, y: 0, z: 0), anchor: .top, perspective: 0.2)
                .rotationEffect(.degrees(LidGeometry.turn(for: pl.hinge)))
                .position(x: pl.cover.midX, y: pl.cover.midY)
                .opacity(p <= 0.001 ? 0 : 1)
        }
        .frame(width: full.width, height: full.height)
    }

    /// Regular iPhone (face-down): unchanged slide from the top over the whole view.
    @ViewBuilder private func sliding(s: CGSize, p: Double, eased: Double) -> some View {
        ZStack(alignment: .top) {
            // Ambient shadow the closing half casts on the screen underneath.
            Color.black.opacity(0.75 * eased).ignoresSafeArea()
            panel(s: s, p: p)
                .shadow(color: .black.opacity(0.5 * eased), radius: 18 * eased, y: 10 * eased)
                .offset(y: -s.height * (1 - eased))
                .opacity(p <= 0.001 ? 0 : 0.25 + 0.75 * eased)
                .frame(width: s.width, height: s.height)
        }
        .frame(width: s.width, height: s.height)
    }

    /// The lid itself, hinge bar along the top edge, emblem upright relative to the hinge.
    private func panel(s: CGSize, p: Double, shade: Double = 0) -> some View {
        let r = min(s.width, s.height) * 0.07
        let shape = RoundedRectangle(cornerRadius: r, style: .continuous)
        let hingeH = max(s.height * 0.09, 28)
        return ZStack {
            // Base colour with a light gradient that rotates as the lid swings down.
            shape.fill(LinearGradient(colors: [style.light, style.dark],
                                      startPoint: UnitPoint(x: 0.2, y: 0.0 - 0.3 * (1 - p)),
                                      endPoint: UnitPoint(x: 0.8, y: 1.0 + 0.6 * (1 - p))))
                .opacity(style.translucent ? 0.88 : 1)
            // Outer bevel: light top-left rim, dark bottom-right rim.
            shape.strokeBorder(LinearGradient(colors: [.white.opacity(0.55), style.edge.opacity(0.9)],
                                              startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 3)
            // Soft light pooled on the lid's upper left (reference closed lid).
            shape.fill(RadialGradient(colors: [.white.opacity(0.22), .white.opacity(0)], center: UnitPoint(x: 0.35, y: 0.3),
                                      startRadius: 0, endRadius: s.width * 0.6)).blendMode(.screen)
            // Moulded rim just inside the edge, lit on the left, shaded on the right and bottom.
            RoundedRectangle(cornerRadius: r * 0.8, style: .continuous)
                .strokeBorder(LinearGradient(colors: [.white.opacity(0.45), style.edge.opacity(0.55)],
                                             startPoint: .leading, endPoint: .trailing), lineWidth: 1.5)
                .padding(5).padding(.top, hingeH)
            // Gloss sweep that slides with the angle.
            shape.fill(LinearGradient(stops: [
                .init(color: .white.opacity(0), location: 0),
                .init(color: .white.opacity(0.42 * style.gloss), location: 0.42 + 0.2 * (1 - p)),
                .init(color: .white.opacity(0), location: 0.62 + 0.2 * (1 - p))],
                startPoint: .topLeading, endPoint: .bottomTrailing))
                .blendMode(.screen)
            // Matte grain for low-gloss finishes.
            shape.fill(Color.black.opacity(0.06 * (1 - style.gloss)))
            // Hinge bar along the top edge, edge to edge: end segments, joints and the LEDs.
            VStack(spacing: 0) {
                ZStack {
                    Rectangle().fill(LinearGradient(stops: [.init(color: style.hinge, location: 0), .init(color: .white.opacity(0.75), location: 0.3),
                                                            .init(color: style.light, location: 0.55), .init(color: style.edge, location: 1)],
                                                    startPoint: .top, endPoint: .bottom))
                    HStack(spacing: 0) {
                        Spacer().frame(width: s.width * 0.185)
                        Rectangle().fill(Color.black.opacity(0.22)).frame(width: 1)
                        Spacer()
                        HStack(spacing: 3) {
                            RoundedRectangle(cornerRadius: 1).fill(Color(red: 1.0, green: 0.55, blue: 0.12)).frame(width: 3.5, height: hingeH * 0.42)
                                .shadow(color: .orange.opacity(0.8), radius: 2)
                            RoundedRectangle(cornerRadius: 1).fill(Color(white: 0.6)).frame(width: 3.5, height: hingeH * 0.42)
                        }
                        Spacer().frame(width: s.width * 0.03)
                        Rectangle().fill(Color.black.opacity(0.22)).frame(width: 1)
                        Spacer().frame(width: s.width * 0.185)
                    }
                    Rectangle().fill(Color.black.opacity(0.25)).frame(height: 1).frame(maxHeight: .infinity, alignment: .bottom)
                }
                .frame(height: hingeH)
                .shadow(color: .black.opacity(0.3), radius: 2, y: 2)
                Spacer()
            }
            TwinPlayEmblem(style: style, width: s.width * 0.42)
            if shade > 0 { shape.fill(Color.black.opacity(shade)) }
        }
        .frame(width: s.width, height: s.height)
        .clipShape(shape)
        .compositingGroup()
    }
}

/// Embossed TwinPlay logo: an oval plate pressed into the lid, with lettering lit from the top left.
struct TwinPlayEmblem: View {
    let style: LidStyle
    let width: CGFloat

    var body: some View {
        let h = width * 0.36
        let font = Font.system(size: h * 0.56, weight: .heavy, design: .rounded)
        // Debossed straight into the lid, like the reference's logo: a light lower-right lip and
        // a darker upper-left cut, in the lid's own colour.
        ZStack {
            word(font, h).foregroundStyle(Color.white.opacity(0.6)).offset(x: 1, y: 1.4)
            word(font, h).foregroundStyle(Color.black.opacity(0.22)).offset(x: -0.8, y: -1)
            word(font, h).foregroundStyle(LinearGradient(colors: [style.dark, style.light], startPoint: .top, endPoint: .bottom))
        }
        .frame(width: width, height: h)
    }

    private func word(_ font: Font, _ h: CGFloat) -> some View {
        Text("TwinPlay").font(font).kerning(h * 0.04).lineLimit(1).minimumScaleFactor(0.3)
    }
}
