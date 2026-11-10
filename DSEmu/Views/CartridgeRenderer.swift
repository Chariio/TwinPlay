// Copyright (c) 2026 Charlie Rodriguez Garcia. All rights reserved.
// Photoreal-ish cartridge renderer in pure Core Graphics (portable to macOS for previews).
// Shells follow the real proportions of each cartridge, drawn as original shapes.
// No logos, trademarks or console names are drawn. Box art sits in the label recess.

import CoreGraphics
import Foundation

enum CartColor: String, CaseIterable, Identifiable, Codable {
    case gray, darkGray, black, white, ruby, sapphire, emerald, fireRed, leafGreen, clear
    var id: String { rawValue }
    var label: String { englishLabel.loc }
    /// English source text (the String Catalog key).
    var englishLabel: String {
        switch self {
        case .gray: return "Gray"
        case .darkGray: return "Dark Gray"
        case .black: return "Black"
        case .white: return "White"
        case .ruby: return "Translucent Red"
        case .sapphire: return "Translucent Blue"
        case .emerald: return "Translucent Emerald"
        case .fireRed: return "Translucent Orange-Red"
        case .leafGreen: return "Translucent Green"
        case .clear: return "Clear"
        }
    }
    /// Base RGB and opacity (translucent shells < 1).
    var rgba: (CGFloat, CGFloat, CGFloat, CGFloat) {
        switch self {
        case .gray: return (0.66, 0.66, 0.68, 1)
        case .darkGray: return (0.27, 0.27, 0.29, 1)
        case .black: return (0.09, 0.09, 0.10, 1)
        case .white: return (0.92, 0.92, 0.93, 1)
        case .ruby: return (0.78, 0.10, 0.14, 0.82)
        case .sapphire: return (0.12, 0.28, 0.80, 0.82)
        case .emerald: return (0.10, 0.62, 0.40, 0.78)
        case .fireRed: return (0.92, 0.32, 0.14, 0.82)
        case .leafGreen: return (0.34, 0.72, 0.22, 0.80)
        case .clear: return (0.85, 0.88, 0.92, 0.55)
        }
    }
    var translucent: Bool { rgba.3 < 1 }

    /// Known shell colors by 3-letter game code; otherwise the system default.
    static func known(gameCode: String?, system: GameSystem) -> CartColor {
        switch system {
        case .gb: return .gray
        case .gbc: return .black          // colour-only paks were usually dark
        case .nes, .snes, .n64, .n3ds: return .gray
        case .gba: return known(gameCode: gameCode, isGBA: true)
        case .ds: return known(gameCode: gameCode, isGBA: false)
        }
    }
    static func known(gameCode: String?, isGBA: Bool) -> CartColor {
        let c = String((gameCode ?? "").prefix(3)).uppercased()
        let gba: [String: CartColor] = ["AXV": .ruby, "AXP": .sapphire, "BPE": .emerald, "BPR": .fireRed, "BPG": .leafGreen]
        let ds: [String: CartColor] = ["IRB": .black, "IRE": .black, "IRA": .white, "IRD": .white]
        if let k = (isGBA ? gba : ds)[c] { return k }
        return .darkGray
    }
}

enum CartridgeRenderer {
    /// Body size in millimetres (without the depth band).
    static func bodyMM(gba: Bool, gb: Bool = false, gbc: Bool = false, nes: Bool = false, snes: Bool = false) -> CGSize {
        if gb || gbc { return CGSize(width: 50, height: 66) }
        if gba { return CGSize(width: 58, height: 36) }
        if nes { return CGSize(width: 44, height: 64) }
        if snes { return CGSize(width: 66, height: 48) }
        return CGSize(width: 36, height: 32)   // small card, slightly wider than tall
    }
    static let depthMM: CGFloat = 1.6
    static let marginMM: CGFloat = 2.0
    /// Full canvas in mm (body + depth + shadow margin).
    static func canvasMM(gba: Bool, gb: Bool = false, gbc: Bool = false, nes: Bool = false, snes: Bool = false) -> CGSize {
        let b = bodyMM(gba: gba, gb: gb, gbc: gbc, nes: nes, snes: snes)
        return CGSize(width: b.width + marginMM * 2, height: b.height + depthMM + marginMM * 2)
    }

    /// Right half, from the top center to the bottom center, then its mirror.
    private static func mirrored(_ right: [CGPoint], width: CGFloat) -> CGPath {
        var pts = right
        for p in right.dropFirst().dropLast().reversed() {
            pts.append(CGPoint(x: width - p.x, y: p.y))
        }
        let path = CGMutablePath()
        guard let first = pts.first else { return path }
        path.move(to: first)
        for p in pts.dropFirst() { path.addLine(to: p) }
        path.closeSubpath()
        return path
    }

    private static func quad(_ a: CGPoint, _ c: CGPoint, _ b: CGPoint, _ n: Int) -> [CGPoint] {
        var out: [CGPoint] = []
        for i in 1...n {
            let t = CGFloat(i) / CGFloat(n), u = 1 - t
            out.append(CGPoint(x: u * u * a.x + 2 * u * t * c.x + t * t * b.x,
                               y: u * u * a.y + 2 * u * t * c.y + t * t * b.y))
        }
        return out
    }

    /// Wide shell. Straight top, a short raised center, flat bottom. Symmetric.
    private static func snesOutline() -> CGPath {
        let w: CGFloat = 66, h: CGFloat = 48, r: CGFloat = 1.3, mid = w / 2
        var right: [CGPoint] = [
            CGPoint(x: mid, y: 0),
            CGPoint(x: mid + 10, y: 0),
            CGPoint(x: mid + 13.2, y: 2.4),
            CGPoint(x: w - r, y: 2.4),
        ]
        right += quad(CGPoint(x: w - r, y: 2.4), CGPoint(x: w, y: 2.4), CGPoint(x: w, y: 2.4 + r), 4)
        right.append(CGPoint(x: w, y: h - r))
        right += quad(CGPoint(x: w, y: h - r), CGPoint(x: w, y: h), CGPoint(x: w - r, y: h), 4)
        right.append(CGPoint(x: mid, y: h))
        return mirrored(right, width: w)
    }

    /// Short wide shell. Rounded top with one central bump. Symmetric.
    private static func gbaOutline() -> CGPath {
        let w: CGFloat = 58, h: CGFloat = 36, r: CGFloat = 1.4, mid = w / 2
        var right: [CGPoint] = [CGPoint(x: mid, y: 0.2)]
        right += quad(CGPoint(x: mid, y: 0.2), CGPoint(x: mid + 8, y: 0.2), CGPoint(x: mid + 14, y: 3.4), 6)
        right += quad(CGPoint(x: mid + 14, y: 3.4), CGPoint(x: w - 6, y: 5.2), CGPoint(x: w, y: 8), 5)
        right.append(CGPoint(x: w, y: h - r))
        right += quad(CGPoint(x: w, y: h - r), CGPoint(x: w, y: h), CGPoint(x: w - r, y: h), 4)
        right.append(CGPoint(x: mid, y: h))
        return mirrored(right, width: w)
    }

    static func outline(gba: Bool, gb: Bool = false, gbc: Bool = false, nes: Bool = false, snes: Bool = false) -> CGPath {
        let p = CGMutablePath()
        if gb || gbc {
            // Tall pak. The top-right corner is cut. Bottom corners are small.
            let w: CGFloat = 50, h: CGFloat = 66, r: CGFloat = 1.6, cut: CGFloat = 8
            p.move(to: CGPoint(x: r, y: 0))
            p.addLine(to: CGPoint(x: w - cut, y: 0))
            p.addLine(to: CGPoint(x: w, y: cut))
            p.addLine(to: CGPoint(x: w, y: h - r))
            p.addQuadCurve(to: CGPoint(x: w - r, y: h), control: CGPoint(x: w, y: h))
            p.addLine(to: CGPoint(x: r, y: h))
            p.addQuadCurve(to: CGPoint(x: 0, y: h - r), control: CGPoint(x: 0, y: h))
            p.addLine(to: CGPoint(x: 0, y: r))
            p.addQuadCurve(to: CGPoint(x: r, y: 0), control: CGPoint(x: 0, y: 0))
        } else if nes {
            p.addPath(CGPath(roundedRect: CGRect(x: 0, y: 0, width: 44, height: 64), cornerWidth: 1.3, cornerHeight: 1.3, transform: nil))
        } else if snes {
            p.addPath(snesOutline())
        } else if gba {
            p.addPath(gbaOutline())
        } else {
            // Small card: beveled top, notch at the top-right. Not symmetric.
            let w: CGFloat = 36, h: CGFloat = 32, r: CGFloat = 1.5
            p.move(to: CGPoint(x: r, y: 0))
            p.addLine(to: CGPoint(x: w - 7.2, y: 0))
            p.addLine(to: CGPoint(x: w, y: 5.2))
            p.addLine(to: CGPoint(x: w, y: h - r))
            p.addQuadCurve(to: CGPoint(x: w - r, y: h), control: CGPoint(x: w, y: h))
            p.addLine(to: CGPoint(x: r, y: h))
            p.addQuadCurve(to: CGPoint(x: 0, y: h - r), control: CGPoint(x: 0, y: h))
            p.addLine(to: CGPoint(x: 0, y: r))
            p.addQuadCurve(to: CGPoint(x: r, y: 0), control: CGPoint(x: 0, y: 0))
        }
        p.closeSubpath()
        return p
    }

    static func labelRect(gba: Bool, gb: Bool = false, gbc: Bool = false, nes: Bool = false, snes: Bool = false) -> CGRect {
        if gbc { return CGRect(x: 3.2, y: 15.0, width: 43.6, height: 34) }
        if gb { return CGRect(x: 7.0, y: 16.0, width: 36, height: 30) }
        if gba { return CGRect(x: 4.0, y: 11.0, width: 50, height: 18.5) }
        if nes { return CGRect(x: 12.5, y: 8.0, width: 27, height: 34) }
        if snes {
            let lw: CGFloat = 50
            return CGRect(x: (66 - lw) / 2, y: 4.4, width: lw, height: 16.6)
        }
        return CGRect(x: 2.4, y: 5.8, width: 31.2, height: 20.2)   // under the white header strip
    }

    private static let noise: CGImage? = {
        let n = 128; var px = [UInt8](repeating: 0, count: n * n * 4); var s: UInt32 = 0x2545F491
        for i in 0..<(n * n) { s ^= s << 13; s ^= s >> 17; s ^= s << 5; let v = UInt8(truncatingIfNeeded: s)
            px[i * 4] = v; px[i * 4 + 1] = v; px[i * 4 + 2] = v; px[i * 4 + 3] = 255 }
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: &px, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n * 4, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        return ctx.makeImage()
    }()

    private static func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
        CGColor(colorSpace: CGColorSpaceCreateDeviceRGB(), components: [min(max(r, 0), 1), min(max(g, 0), 1), min(max(b, 0), 1), a])!
    }
    private static func gradient(_ cols: [CGColor], _ locs: [CGFloat]) -> CGGradient {
        CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: cols as CFArray, locations: locs)!
    }

    /// The plastic is cached per system, color and pixel density. The label is stamped on top.
    private final class ShellImage: NSObject { let image: CGImage; init(_ image: CGImage) { self.image = image } }
    private static let shellCache: NSCache<NSString, ShellImage> = {
        let c = NSCache<NSString, ShellImage>(); c.countLimit = 40; return c
    }()

    /// Renders a cartridge at `scale` pixels per mm. `label` is aspect-filled into the label recess.
    static func render(gba: Bool, gb: Bool = false, gbc: Bool = false, nes: Bool = false, snes: Bool = false, color shell: CartColor, label: CGImage?, pixelatedLabel: Bool, title: String, scale: CGFloat) -> CGImage? {
        let bucket = Int((scale * 8).rounded())
        let key = "\(gba)|\(gb)|\(gbc)|\(nes)|\(snes)|\(shell.rawValue)|\(bucket)" as NSString
        let base: CGImage
        if let hit = shellCache.object(forKey: key)?.image {
            base = hit
        } else if let made = drawShell(gba: gba, gb: gb, gbc: gbc, nes: nes, snes: snes, color: shell, scale: scale) {
            shellCache.setObject(ShellImage(made), forKey: key)
            base = made
        } else { return nil }
        return stampLabel(base, gba: gba, gb: gb, gbc: gbc, nes: nes, snes: snes, label: label, pixelated: pixelatedLabel, title: title, scale: scale)
    }

    /// Plastic only: outline, grip, recesses. No box art, so one image serves every game of that color.
    private static func drawShell(gba: Bool, gb: Bool = false, gbc: Bool = false, nes: Bool = false, snes: Bool = false, color shell: CartColor, scale: CGFloat) -> CGImage? {
        let cm = canvasMM(gba: gba, gb: gb, gbc: gbc, nes: nes, snes: snes)
        let W = Int((cm.width * scale).rounded()), H = Int((cm.height * scale).rounded())
        guard let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.translateBy(x: 0, y: CGFloat(H)); ctx.scaleBy(x: scale, y: -scale)   // top-left origin, mm units
        ctx.translateBy(x: marginMM, y: marginMM)
        ctx.interpolationQuality = .high
        let body = outline(gba: gba, gb: gb, gbc: gbc, nes: nes, snes: snes)
        let size = bodyMM(gba: gba, gb: gb, gbc: gbc, nes: nes, snes: snes)
        var (r, g, b, a) = shell.rgba
        let dark = shell == .black || shell == .darkGray
        var hi = (min(CGFloat(1), r + (dark ? 0.10 : 0.12)), min(CGFloat(1), g + (dark ? 0.10 : 0.12)), min(CGFloat(1), b + (dark ? 0.10 : 0.12)))
        var mid = (r, g, b)
        var lo = (r * 0.82, g * 0.82, b * 0.82)
        let ds = !gba && !gb && !gbc && !nes && !snes
        if snes && shell == .gray {
            // #9A9AA2
            hi = (0.70, 0.70, 0.73); mid = (0.604, 0.604, 0.635); lo = (0.48, 0.48, 0.51)
            r = 0.604; g = 0.604; b = 0.635; a = 1
        } else if nes && shell == .gray {
            // #8E8E8E
            hi = (0.66, 0.66, 0.66); mid = (0.557, 0.557, 0.557); lo = (0.40, 0.40, 0.40)
            r = 0.557; g = 0.557; b = 0.557; a = 1
        } else if gb && !gbc && shell == .gray {
            // #A8A8AC
            hi = (0.74, 0.74, 0.76); mid = (0.659, 0.659, 0.675); lo = (0.52, 0.52, 0.54)
            r = 0.659; g = 0.659; b = 0.675; a = 1
        } else if ds && (shell == .darkGray || shell == .black || shell == .gray) {
            // #2A2A2E
            hi = (0.22, 0.22, 0.24); mid = (0.165, 0.165, 0.180); lo = (0.09, 0.09, 0.10)
            r = 0.165; g = 0.165; b = 0.180; a = 1
        } else if gbc {
            a = shell.translucent ? a : 0.62
            if shell == .black || shell == .darkGray || shell == .gray {
                hi = (0.30, 0.32, 0.34); mid = (0.16, 0.17, 0.18); lo = (0.07, 0.08, 0.09)
                r = 0.16; g = 0.17; b = 0.18
            }
        }

        // Drop shadow + depth band (the cart's edge thickness seen from slightly above).
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: 1.2 * scale), blur: 2.2 * scale, color: color(0, 0, 0, 0.45))
        ctx.translateBy(x: 0, y: depthMM); ctx.addPath(body); ctx.setFillColor(color(r * 0.55, g * 0.55, b * 0.55, max(a, 0.9))); ctx.fillPath()
        ctx.restoreGState()
        for i in stride(from: depthMM, to: 0, by: -0.2) {
            ctx.saveGState(); ctx.translateBy(x: 0, y: i); ctx.addPath(body)
            let k = 0.5 + 0.25 * (1 - i / depthMM); ctx.setFillColor(color(r * k, g * k, b * k, max(a, 0.9))); ctx.fillPath(); ctx.restoreGState()
        }

        // Body: base material with a soft top-left key light.
        ctx.saveGState(); ctx.addPath(body); ctx.clip()
        if gbc {
            ctx.setFillColor(color(0.08, 0.45, 0.22, 1))
            ctx.fill(CGRect(x: 3.5, y: 11, width: size.width - 7, height: size.height - 16))
            ctx.setFillColor(color(0.04, 0.04, 0.05, 0.7))
            ctx.fill(CGRect(x: 8, y: 20, width: 14, height: 9))
            ctx.fill(CGRect(x: 26, y: 30, width: 10, height: 7))
        }
        ctx.drawLinearGradient(gradient([color(hi.0, hi.1, hi.2, a), color(mid.0, mid.1, mid.2, a), color(lo.0, lo.1, lo.2, a)], [0, 0.42, 1]),
                               start: CGPoint(x: 0, y: 0), end: CGPoint(x: size.width * 0.35, y: size.height), options: [])
        if shell.translucent && !gbc {   // hint of the board inside
            ctx.setFillColor(color(0.08, 0.30, 0.16, 0.35))
            ctx.fill(CGRect(x: size.width * 0.12, y: size.height * 0.30, width: size.width * 0.76, height: size.height * 0.62))
            ctx.setFillColor(color(0.05, 0.05, 0.05, 0.30)); ctx.fill(CGRect(x: size.width * 0.35, y: size.height * 0.45, width: size.width * 0.3, height: size.height * 0.2))
        }
        if let n = noise {       // subtle plastic grain
            ctx.setBlendMode(.overlay); ctx.setAlpha(dark ? 0.10 : 0.07)
            ctx.draw(n, in: CGRect(x: 0, y: 0, width: 32, height: 32), byTiling: true)
            ctx.setAlpha(1); ctx.setBlendMode(.normal)
        }
        ctx.restoreGState()

        // Bevel: bright upper rim, dark lower rim (inner half of a stroked gradient).
        ctx.saveGState(); ctx.addPath(body); ctx.clip()
        ctx.addPath(body); ctx.setLineWidth(1.1); ctx.replacePathWithStrokedPath(); ctx.clip()
        ctx.drawLinearGradient(gradient([color(1, 1, 1, dark ? 0.35 : 0.65), color(1, 1, 1, 0), color(0, 0, 0, 0.35)], [0, 0.5, 1]),
                               start: .zero, end: CGPoint(x: size.width * 0.15, y: size.height), options: [])
        ctx.restoreGState()
        ctx.addPath(body); ctx.setStrokeColor(color(0, 0, 0, 0.55)); ctx.setLineWidth(0.18); ctx.strokePath()

        func ridge(_ rect: CGRect, vertical: Bool = false) {
            let rr = CGPath(roundedRect: rect, cornerWidth: min(rect.width, rect.height) / 2, cornerHeight: min(rect.width, rect.height) / 2, transform: nil)
            ctx.saveGState(); ctx.addPath(rr); ctx.clip()
            ctx.drawLinearGradient(gradient([color(0, 0, 0, 0.45), color(0, 0, 0, 0.08), color(1, 1, 1, dark ? 0.18 : 0.45)], [0, 0.55, 1]),
                                   start: CGPoint(x: rect.minX, y: rect.minY), end: vertical ? CGPoint(x: rect.maxX, y: rect.minY) : CGPoint(x: rect.minX, y: rect.maxY), options: [])
            ctx.restoreGState()
        }

        func filledArrow(cx: CGFloat, top: CGFloat, aw: CGFloat, ah: CGFloat) {
            let t = CGMutablePath()
            t.move(to: CGPoint(x: cx - aw / 2, y: top))
            t.addLine(to: CGPoint(x: cx + aw / 2, y: top))
            t.addLine(to: CGPoint(x: cx, y: top + ah))
            t.closeSubpath()
            ctx.saveGState(); ctx.addPath(t); ctx.clip()
            ctx.drawLinearGradient(gradient([color(min(1, r + 0.10), min(1, g + 0.10), min(1, b + 0.10)), color(r * 0.68, g * 0.68, b * 0.70)], [0, 1]),
                                   start: CGPoint(x: cx, y: top), end: CGPoint(x: cx, y: top + ah), options: [])
            ctx.restoreGState()
        }

        if gb || gbc {
            // Plain recessed band where a wordmark would sit. One embossed line, no letters.
            let bandW: CGFloat = gbc ? size.width - 8 : 34
            let band = CGRect(x: (size.width - bandW) / 2, y: 3.0, width: bandW, height: 6.2)
            ctx.addPath(CGPath(roundedRect: band, cornerWidth: 0.6, cornerHeight: 0.6, transform: nil))
            ctx.setFillColor(color(0, 0, 0, gbc ? 0.18 : 0.14)); ctx.fillPath()
            ctx.move(to: CGPoint(x: band.minX + 4, y: band.midY))
            ctx.addLine(to: CGPoint(x: band.maxX - 4, y: band.midY))
            ctx.setStrokeColor(color(1, 1, 1, 0.35)); ctx.setLineWidth(0.25); ctx.strokePath()
            if !gbc {
                let frame = labelRect(gba: false, gb: true).insetBy(dx: -1.1, dy: -1.1)
                ctx.addPath(CGPath(roundedRect: frame, cornerWidth: 1.2, cornerHeight: 1.2, transform: nil))
                ctx.setStrokeColor(color(0, 0, 0, 0.28)); ctx.setLineWidth(0.45); ctx.strokePath()
                filledArrow(cx: size.width / 2, top: 49.5, aw: 8, ah: 5.2)
            }
        } else if gba {
            let gripW: CGFloat = 30
            for i in 0..<5 { ridge(CGRect(x: (size.width - gripW) / 2, y: 4.3 + CGFloat(i) * 1.05, width: gripW, height: 0.52)) }
            // Edge connector opening with gold fingers.
            let slot = CGRect(x: 5.5, y: 32.4, width: 46, height: 2.6)
            ctx.setFillColor(color(0.05, 0.05, 0.06)); ctx.fill(slot)
            ctx.setFillColor(color(0.06, 0.24, 0.12)); ctx.fill(slot.insetBy(dx: 0.3, dy: 0).offsetBy(dx: 0, dy: 0.5))
            let pins = 32, pw = (slot.width - 0.8) / CGFloat(pins)
            for i in 0..<pins {
                let pr = CGRect(x: slot.minX + 0.4 + CGFloat(i) * pw + pw * 0.18, y: slot.minY + 0.7, width: pw * 0.64, height: slot.height - 0.7)
                ctx.saveGState(); ctx.clip(to: pr)
                ctx.drawLinearGradient(gradient([color(0.98, 0.86, 0.46), color(0.80, 0.60, 0.18), color(0.58, 0.40, 0.10)], [0, 0.5, 1]),
                                       start: CGPoint(x: pr.minX, y: pr.minY), end: CGPoint(x: pr.maxX, y: pr.maxY), options: [])
                ctx.restoreGState()
            }
        } else if nes {
            // Grip column on the left, a shorter stack at the top-right. The real shell is not symmetric.
            for i in 0..<12 { ridge(CGRect(x: 1.5, y: 3.0 + CGFloat(i) * 2.15, width: 7.6, height: 1.25)) }
            for i in 0..<4 { ridge(CGRect(x: 28.5, y: 2.2 + CGFloat(i) * 1.7, width: 13, height: 1.05)) }
            ctx.setFillColor(color(r * 0.72, g * 0.72, b * 0.72))
            ctx.fill(CGRect(x: 0, y: size.height - 7.5, width: size.width, height: 7.5))
        } else if snes {
            // Six deep horizontal grips down each side. Built as a pair so they mirror.
            for i in 0..<6 {
                let y = 7.2 + CGFloat(i) * 3.15
                let groove = CGRect(x: 1.15, y: y, width: 3.6, height: 1.7)
                func paint(_ rect: CGRect) {
                    ctx.addPath(CGPath(roundedRect: rect, cornerWidth: 0.4, cornerHeight: 0.4, transform: nil))
                    ctx.setFillColor(color(0, 0, 0, 0.38)); ctx.fillPath()
                    ctx.setFillColor(color(1, 1, 1, 0.22))
                    ctx.fill(CGRect(x: rect.minX, y: rect.maxY - 0.35, width: rect.width, height: 0.28))
                }
                paint(groove)
                paint(CGRect(x: size.width - groove.maxX, y: groove.minY, width: groove.width, height: groove.height))
            }
            let recessW: CGFloat = 42, recessH: CGFloat = 16
            let recess = CGRect(x: (size.width - recessW) / 2, y: 24.2, width: recessW, height: recessH)
            ctx.addPath(CGPath(roundedRect: recess, cornerWidth: 2.2, cornerHeight: 2.2, transform: nil))
            ctx.setFillColor(color(r * 0.78, g * 0.78, b * 0.80)); ctx.fillPath()
            let inner = recess.insetBy(dx: 2.0, dy: 2.0)
            ctx.addPath(CGPath(roundedRect: inner, cornerWidth: 1.4, cornerHeight: 1.4, transform: nil))
            ctx.setFillColor(color(min(1, r + 0.06), min(1, g + 0.06), min(1, b + 0.06))); ctx.fillPath()
            for sx in [CGFloat(4.4), size.width - 4.4] {
                ctx.addEllipse(in: CGRect(x: sx - 1.05, y: size.height - 4.6, width: 2.1, height: 2.1))
                ctx.setFillColor(color(0.12, 0.12, 0.13)); ctx.fillPath()
                ctx.addEllipse(in: CGRect(x: sx - 0.45, y: size.height - 4.15, width: 0.7, height: 0.7))
                ctx.setFillColor(color(0.75, 0.75, 0.78)); ctx.fillPath()
            }
        } else if !gba {
            // White header above the art, and a blank code strip along the bottom.
            let header = CGRect(x: 2.4, y: 2.6, width: 31.2, height: 2.7)
            ctx.addPath(CGPath(roundedRect: header, cornerWidth: 0.4, cornerHeight: 0.4, transform: nil))
            ctx.setFillColor(color(0.93, 0.93, 0.94)); ctx.fillPath()
            let codeW: CGFloat = 16
            let code = CGRect(x: (size.width - codeW) / 2, y: 27.4, width: codeW, height: 2.1)
            ctx.addPath(CGPath(roundedRect: code, cornerWidth: 0.3, cornerHeight: 0.3, transform: nil))
            ctx.setFillColor(color(0.08, 0.08, 0.09)); ctx.fillPath()
        }

        // Label recess: a thin dark inset on the wide shell, a softer well on the others.
        let lr = labelRect(gba: gba, gb: gb, gbc: gbc, nes: nes, snes: snes)
        let border: CGFloat = snes ? 0.32 : 0.5
        let recess = CGPath(roundedRect: lr.insetBy(dx: -border, dy: -border), cornerWidth: snes ? 1.2 : 1.0, cornerHeight: snes ? 1.2 : 1.0, transform: nil)
        ctx.addPath(recess); ctx.setFillColor(snes ? color(0.12, 0.12, 0.13, 0.9) : color(r * 0.7, g * 0.7, b * 0.7, max(a, 0.95))); ctx.fillPath()
        ctx.saveGState(); ctx.addPath(recess); ctx.clip()
        ctx.drawLinearGradient(gradient([color(0, 0, 0, 0.45), color(0, 0, 0, 0), color(1, 1, 1, dark ? 0.15 : 0.4)], [0, 0.2, 1]),
                               start: CGPoint(x: 0, y: lr.minY - 0.5), end: CGPoint(x: 0, y: lr.maxY + 0.5), options: [])
        ctx.restoreGState()
        let labelRadius: CGFloat = snes ? 1.05 : 0.7
        let labelPath = CGPath(roundedRect: lr, cornerWidth: labelRadius, cornerHeight: labelRadius, transform: nil)
        ctx.saveGState(); ctx.addPath(labelPath); ctx.clip()
        ctx.setFillColor(color(0.97, 0.97, 0.96)); ctx.fill(lr)
        drawTitle(ctx, "", in: lr.insetBy(dx: 1.5, dy: 1.5))
        ctx.restoreGState()
        ctx.addPath(labelPath); ctx.setStrokeColor(color(0, 0, 0, 0.25)); ctx.setLineWidth(0.12); ctx.strokePath()
        return ctx.makeImage()
    }

    /// Box art, cropped to fill the recess, then the gloss. The plastic underneath is already cached.
    private static func stampLabel(_ shell: CGImage, gba: Bool, gb: Bool, gbc: Bool, nes: Bool, snes: Bool, label: CGImage?, pixelated: Bool, title: String, scale: CGFloat) -> CGImage? {
        let W = shell.width, H = shell.height
        guard let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(shell, in: CGRect(x: 0, y: 0, width: CGFloat(W), height: CGFloat(H)))
        ctx.translateBy(x: 0, y: CGFloat(H)); ctx.scaleBy(x: scale, y: -scale)
        ctx.translateBy(x: marginMM, y: marginMM)
        ctx.interpolationQuality = .high
        let lr = labelRect(gba: gba, gb: gb, gbc: gbc, nes: nes, snes: snes)
        let labelRadius: CGFloat = snes ? 1.05 : 0.7
        let labelPath = CGPath(roundedRect: lr, cornerWidth: labelRadius, cornerHeight: labelRadius, transform: nil)
        ctx.saveGState(); ctx.addPath(labelPath); ctx.clip()
        if let img = label {
            let iw = CGFloat(img.width), ih = CGFloat(img.height)
            let s = max(lr.width / iw, lr.height / ih)
            let dw = iw * s, dh = ih * s
            let dst = CGRect(x: lr.midX - dw / 2, y: lr.midY - dh / 2, width: dw, height: dh)
            ctx.interpolationQuality = pixelated ? .none : .high
            ctx.saveGState(); ctx.translateBy(x: dst.minX, y: dst.maxY); ctx.scaleBy(x: 1, y: -1)
            ctx.draw(img, in: CGRect(origin: .zero, size: dst.size)); ctx.restoreGState()
        } else if !title.isEmpty {
            drawTitle(ctx, title, in: lr.insetBy(dx: 1.5, dy: 1.5))
        }
        ctx.setBlendMode(.screen)
        ctx.drawLinearGradient(gradient([color(1, 1, 1, 0.34), color(1, 1, 1, 0.08), color(1, 1, 1, 0)], [0, 0.28, 0.55]),
                               start: CGPoint(x: lr.minX, y: lr.minY), end: CGPoint(x: lr.maxX, y: lr.minY + lr.height * 0.55), options: [])
        ctx.setBlendMode(.normal)
        ctx.restoreGState()
        return ctx.makeImage()
    }

    private static func drawTitle(_ ctx: CGContext, _ title: String, in rect: CGRect) {
        // Simple block glyph fallback: dark band with stripes when no art exists (text needs UIKit/AppKit).
        ctx.setFillColor(color(0.20, 0.22, 0.30)); ctx.fill(rect)
        ctx.setFillColor(color(1, 1, 1, 0.85))
        for i in 0..<3 { ctx.fill(CGRect(x: rect.minX + 2, y: rect.midY - 3 + CGFloat(i) * 2.2, width: rect.width * (0.8 - CGFloat(i) * 0.2), height: 1.0)) }
    }
}
