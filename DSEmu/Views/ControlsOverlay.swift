// Copyright (c) 2026 Charlie Rodriguez Garcia. All rights reserved.
import SwiftUI
import UIKit

/// Draws the on-screen controls from `TouchPadLayout`. Purely visual: every touch goes to
/// `TouchInputLayer`, which shares the same zones, so what you see is what you can press.
struct ControlsOverlay: View {
    let pad: TouchPadLayout
    @ObservedObject var state: PadVisualState
    let opacity: Double
    /// Buttons held by Hold Buttons (or picked while choosing them): drawn pressed.
    var held: DSButton = []
    @Environment(\.skin) private var skin

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(Array(pad.zones.enumerated()), id: \.offset) { _, z in
                Group {
                    if z.isDPad {
                        DPadFace(current: state.pressed.union(held).intersection(z.button))
                    } else if z.shape == .stick {
                        StickFace(offset: state.stick)
                    } else {
                        PadButtonFace(label: z.label, shape: z.shape, isDown: state.pressed.union(held).contains(z.button))
                    }
                }
                .frame(width: z.rect.width, height: z.rect.height)
                .position(x: z.rect.midX, y: z.rect.midY)
            }
            // DS reference shell: TwinPlay's mark in the middle of X / Y / A / B.
            if skin.shellStyle == .twin, let x = pad.zones.first(where: { $0.button == .x }), let b = pad.zones.first(where: { $0.button == .b }) {
                TwinPlayMark(darkBody: MenuPill.isDark(skin.palette)).position(x: x.rect.midX, y: (x.rect.midY + b.rect.midY) / 2)
            }
        }
        .opacity(opacity)
        .overlay(zoneOutlines)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

extension ControlsOverlay {
    /// Testing aid (screenshots): -TwinPlayShowTouchZones YES outlines the invisible hit areas.
    @ViewBuilder var zoneOutlines: some View {
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "TwinPlayShowTouchZones") {
            ZStack(alignment: .topLeading) {
                ForEach(Array(pad.zones.enumerated()), id: \.offset) { _, z in
                    Group {
                        if let r = z.hitRadius { Circle().stroke(Color.yellow, style: StrokeStyle(lineWidth: 1, dash: [3, 3])).frame(width: r * 2, height: r * 2) }
                        else { Rectangle().stroke(Color.yellow, style: StrokeStyle(lineWidth: 1, dash: [3, 3])).frame(width: z.hit.width, height: z.hit.height) }
                    }
                    .position(x: z.hit.midX, y: z.hit.midY)
                }
                if let st = pad.stylus {
                    Rectangle().stroke(Color.cyan, lineWidth: 1.5).frame(width: st.width, height: st.height).position(x: st.midX, y: st.midY)
                }
            }
        }
        #endif
    }
}

/// Physical-looking button: drop shadow, recessed well in the shell, convex cap with a
/// specular highlight, embossed label. Static layers are rasterised once (drawingGroup);
/// only the pressed state changes.
struct PadButtonFace: View {
    let label: String
    let shape: PadShape
    let isDown: Bool
    @Environment(\.skin) private var skin

    var body: some View {
        let p = skin.palette
        let base: Color = {
            switch shape {
            case .capsule: return p.pillFill
            case .shoulder: return p.shoulderFill
            default: return p.buttonFill
            }
        }()
        let custom = p.faceColors[label] ?? (label.hasPrefix("C") && label != "C" ? p.faceColors["C"] : nil)
        let fill = isDown ? (custom.map { $0.opacity(0.75) } ?? p.buttonPressed) : (custom ?? base)
        let text: Color = custom != nil ? (p.faceText ?? p.buttonText)
            : (shape == .circle ? p.buttonText : (shape == .capsule ? p.pillText : p.shoulderText))
        let style = skin.shellStyle
        // Per-model cap size: Lite small and glossy, Classic chunky, Pocket Brick large.
        let capScale: CGFloat = shape == .circle ? (style == .twin ? 0.94 : style == .lite ? 0.80 : style == .ds ? 0.96 : style == .brick ? 1.0 : 0.9) : 1
        GeometryReader { g in
            let s = min(g.size.width, g.size.height) * capScale
            ZStack {
                switch shape {
                case .capsule:
                    // Pocket Brick pills are short, slanted rubber strips.
                    cap(Capsule(), fill: fill, s: s, rubber: true)
                        .frame(width: style == .brick ? g.size.width * 0.75 : nil, height: style == .brick ? g.size.height * 0.6 : nil)
                        .rotationEffect(.degrees(style == .brick ? -25 : 0))
                case .shoulder where style == .twin:
                    // DS reference shell: L / R are the hinge bar's end segments (a cylinder).
                    RoundedRectangle(cornerRadius: g.size.height * 0.42, style: .continuous)
                        .fill(LinearGradient(stops: [.init(color: fill.opacity(0.9), location: 0), .init(color: .white.opacity(0.85), location: 0.3),
                                                     .init(color: fill, location: 0.62), .init(color: .black.opacity(0.18), location: 1)],
                                             startPoint: .top, endPoint: .bottom))
                        .background(RoundedRectangle(cornerRadius: g.size.height * 0.42, style: .continuous).fill(fill))
                        .overlay(RoundedRectangle(cornerRadius: g.size.height * 0.42, style: .continuous).strokeBorder(Color.black.opacity(0.16), lineWidth: 0.8))
                        .shadow(color: .black.opacity(isDown ? 0.1 : 0.28), radius: isDown ? 0.5 : 2, y: isDown ? 0.5 : 1.5)
                        .padding(.vertical, g.size.height * 0.12)
                case .shoulder: cap(UnevenShoulder(), fill: fill, s: s, rubber: false, shoulder: true)
                case .dot:
                    HStack(spacing: 6) {
                        ShellDot(fill: custom ?? p.pillFill, darkBody: MenuPill.isDark(p), isDown: isDown)
                            .frame(width: g.size.height * 0.8, height: g.size.height * 0.8)
                        Text(label).font(.system(size: 9, weight: .semibold, design: .rounded))
                            .foregroundStyle(MenuPill.isDark(p) ? Color.white.opacity(0.62) : Color.black.opacity(0.45))
                            .lineLimit(1).fixedSize()
                        Spacer(minLength: 0)
                    }
                default: cap(Circle(), fill: fill, s: s, rubber: false, gloss: style == .lite || style == .twin)
                    .frame(width: s, height: s)
                }
                // Embossed label: dark cut with a light lower lip (dots carry their own label).
                if shape != .dot { Text(label).font(.system(size: shape == .circle ? max(14, s * 0.36) : (style == .twin && shape == .shoulder ? 13 : 11), weight: style == .twin && shape == .shoulder ? .medium : .heavy, design: .rounded))
                    .foregroundColor(text.opacity(0.92))
                    .shadow(color: .white.opacity(0.35), radius: 0, x: 0, y: 0.8)
                    .shadow(color: .black.opacity(0.45), radius: 0, x: 0, y: -0.6)
                    .minimumScaleFactor(0.6).lineLimit(1)
                    .offset(y: isDown ? 1 : 0) }
            }
            .frame(width: g.size.width, height: g.size.height)
        }
        .scaleEffect(isDown && shape != .dot ? 0.95 : 1)
    }

    @ViewBuilder private func cap<S: Shape>(_ sh: S, fill: Color, s: CGFloat, rubber: Bool, shoulder: Bool = false, gloss: Bool = false) -> some View {
        ZStack {
            // Well in the shell around the button.
            sh.fill(Color.black.opacity(0.35)).scaleEffect(1.08).blur(radius: 1.2)
            // Cap body with drop shadow (smaller when pressed).
            sh.fill(fill)
                .shadow(color: .black.opacity(isDown ? 0.25 : 0.5), radius: isDown ? 1 : 3, x: 0, y: isDown ? 1 : 3)
            // Convex shading: lit top, shaded bottom.
            sh.fill(LinearGradient(stops: [.init(color: .white.opacity(rubber ? 0.18 : 0.38), location: 0),
                                           .init(color: .white.opacity(0), location: 0.45),
                                           .init(color: .black.opacity(rubber ? 0.20 : 0.30), location: 1)],
                                   startPoint: shoulder ? .top : .topLeading, endPoint: shoulder ? .bottom : .bottomTrailing))
            if !rubber && !shoulder {
                // Specular highlight.
                Ellipse().fill(RadialGradient(colors: [.white.opacity(isDown ? 0.15 : 0.55), .clear], center: .center, startRadius: 0, endRadius: s * 0.22))
                    .frame(width: s * 0.5, height: s * 0.32).offset(x: -s * 0.12, y: -s * 0.2)
                    .opacity(gloss ? 1.4 : 1)
            }
            if shoulder {
                // Ridged top edge of a shoulder button.
                VStack(spacing: 2) { ForEach(0..<3, id: \.self) { _ in Rectangle().fill(Color.white.opacity(0.18)).frame(height: 0.8) } }
                    .padding(.horizontal, s * 0.4).padding(.top, 4).frame(maxHeight: .infinity, alignment: .top)
                    .clipShape(sh)
            }
            sh.stroke(LinearGradient(colors: [.white.opacity(0.45), .black.opacity(0.5)], startPoint: .top, endPoint: .bottom), lineWidth: 1.2)
        }
        // Rasterised with room for the shadow and well (padding in, padding out): no square cut-off.
        .padding(10).drawingGroup().padding(-10)
    }
}

/// Shoulder-button outline: small radius on top, large radius below (works on iOS 16).
struct UnevenShoulder: Shape {
    func path(in r: CGRect) -> Path {
        let top = min(r.height * 0.25, 8), bottom = min(r.height * 0.5, r.width * 0.3)
        var p = Path()
        p.move(to: CGPoint(x: r.minX + top, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX - top, y: r.minY))
        p.addQuadCurve(to: CGPoint(x: r.maxX, y: r.minY + top), control: CGPoint(x: r.maxX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY - bottom))
        p.addQuadCurve(to: CGPoint(x: r.maxX - bottom, y: r.maxY), control: CGPoint(x: r.maxX, y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX + bottom, y: r.maxY))
        p.addQuadCurve(to: CGPoint(x: r.minX, y: r.maxY - bottom), control: CGPoint(x: r.minX, y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX, y: r.minY + top))
        p.addQuadCurve(to: CGPoint(x: r.minX + top, y: r.minY), control: CGPoint(x: r.minX, y: r.minY))
        p.closeSubpath()
        return p
    }
}

/// Raised cross D-pad: drop shadow, bevelled arms, centre dimple, moulded arrows; held
/// directions press that arm in (diagonals press two).
struct DPadFace: View {
    let current: DSButton
    @Environment(\.skin) private var skin

    var body: some View {
        GeometryReader { geo in
            let s = min(geo.size.width, geo.size.height) * (skin.shellStyle == .lite ? 0.84 : 1)   // Lite: compact pad
            let f = skin.palette.dpadFill
            ZStack {
                CrossShape(arm: 0.34).fill(Color.black.opacity(0.35)).frame(width: s * 1.06, height: s * 1.06).blur(radius: 1.5)
                CrossShape(arm: 0.34).fill(f).frame(width: s, height: s)
                    .shadow(color: .black.opacity(0.55), radius: 3, y: 3)
                CrossShape(arm: 0.34).fill(LinearGradient(colors: [.white.opacity(0.28), .clear, .black.opacity(0.35)],
                                                          startPoint: .topLeading, endPoint: .bottomTrailing)).frame(width: s, height: s)
                CrossShape(arm: 0.34).stroke(LinearGradient(colors: [.white.opacity(0.4), .black.opacity(0.6)], startPoint: .top, endPoint: .bottom),
                                             lineWidth: 1.2).frame(width: s, height: s)
                // Pressed arms darken.
                press(.up, x: 0, y: -s * 0.33, w: s * 0.34, h: s * 0.33)
                press(.down, x: 0, y: s * 0.33, w: s * 0.34, h: s * 0.33)
                press(.left, x: -s * 0.33, y: 0, w: s * 0.33, h: s * 0.34)
                press(.right, x: s * 0.33, y: 0, w: s * 0.33, h: s * 0.34)
                // Centre dimple.
                Circle().fill(RadialGradient(colors: [.black.opacity(0.45), .white.opacity(0.10)], center: .center, startRadius: 0, endRadius: s * 0.1))
                    .frame(width: s * 0.2, height: s * 0.2)
                arrow("arrowtriangle.up.fill", on: current.contains(.up), s).offset(y: -s * 0.36)
                arrow("arrowtriangle.down.fill", on: current.contains(.down), s).offset(y: s * 0.36)
                arrow("arrowtriangle.left.fill", on: current.contains(.left), s).offset(x: -s * 0.36)
                arrow("arrowtriangle.right.fill", on: current.contains(.right), s).offset(x: s * 0.36)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }

    @ViewBuilder private func press(_ b: DSButton, x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat) -> some View {
        if current.contains(b) { Rectangle().fill(Color.black.opacity(0.28)).frame(width: w, height: h).offset(x: x, y: y) }
    }

    private func arrow(_ name: String, on: Bool, _ s: CGFloat) -> some View {
        Image(systemName: name).font(.system(size: max(10, s * 0.11)))
            .foregroundColor(on ? skin.palette.dpadArrowOn : skin.palette.dpadArrow.opacity(0.85))
            .shadow(color: .white.opacity(0.2), radius: 0, y: 0.8)
    }
}

struct StickFace: View {
    var offset: CGPoint
    @Environment(\.skin) private var skin
    var body: some View {
        GeometryReader { geo in
            let s = min(geo.size.width, geo.size.height)
            let knob = s * 0.42
            let dx = offset.x * (s - knob) / 2
            let dy = -offset.y * (s - knob) / 2
            ZStack {
                Circle().stroke(skin.palette.buttonStroke, lineWidth: 2).background(Circle().fill(skin.palette.dpadFill.opacity(0.55)))
                Circle().fill(skin.palette.buttonFill)
                    .frame(width: knob, height: knob)
                    .offset(x: dx, y: dy)
                    .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
            }
        }
    }
}

struct CrossShape: Shape {
    let arm: CGFloat
    func path(in r: CGRect) -> Path {
        let a = r.width * arm / 2, mx = r.midX, my = r.midY
        let pts = [CGPoint(x: mx - a, y: r.minY), CGPoint(x: mx + a, y: r.minY), CGPoint(x: mx + a, y: my - a),
                   CGPoint(x: r.maxX, y: my - a), CGPoint(x: r.maxX, y: my + a), CGPoint(x: mx + a, y: my + a),
                   CGPoint(x: mx + a, y: r.maxY), CGPoint(x: mx - a, y: r.maxY), CGPoint(x: mx - a, y: my + a),
                   CGPoint(x: r.minX, y: my + a), CGPoint(x: r.minX, y: my - a), CGPoint(x: mx - a, y: my - a)]
        var p = Path(); p.addLines(pts); p.closeSubpath()
        return p
    }
}
