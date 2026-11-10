// Copyright (c) 2026 Charlie Rodriguez Garcia. All rights reserved.
import CoreGraphics
import Foundation

// On-screen touch controls: geometry, hit testing and touch tracking. Pure logic (no UIKit), so
// it is unit-tested; TouchInputView feeds it raw touches and ControlsOverlay draws its zones.

/// `dot`: small round button with its label beside it (START / SELECT of the DS shell).
enum PadShape: Equatable { case circle, capsule, shoulder, dpad, dot, stick }

/// Which system's controls to lay out.
enum PadSystem: Equatable { case ds, gba, gameBoy, nes, snes, n64, n3ds }

extension PadSystem {
    /// L and R exist on DS, GBA and Super NES. NES and Game Boy do not have shoulder buttons.
    var showsShoulders: Bool { self == .ds || self == .gba || self == .snes || self == .n64 || self == .n3ds }
    /// Four face buttons in a diamond (X above, B below, Y left, A right).
    var diamondFace: Bool { self == .ds || self == .snes || self == .n3ds }
}

/// One on-screen control: what it draws (`rect`) and where it can be touched (`hit`, larger).
struct PadZone: Equatable {
    var button: DSButton            // for the D-pad: all four directions
    var label: String
    var shape: PadShape
    var rect: CGRect
    var hit: CGRect
    /// Round buttons are hit-tested as a circle of this radius around the centre (else `hit`).
    var hitRadius: CGFloat?
    /// A finger already on the screen can slide onto it (face/shoulder buttons). Start/Select
    /// only react to a finger that lands on them, so a sliding thumb never pauses the game.
    var slideIn: Bool

    var isDPad: Bool { shape == .dpad }

    func contains(_ p: CGPoint) -> Bool {
        if let r = hitRadius {
            let c = CGPoint(x: rect.midX, y: rect.midY)
            return hypot(p.x - c.x, p.y - c.y) <= r && hit.contains(p)
        }
        return hit.contains(p)
    }

    /// The control as drawn contains `p` (beats the touch screen where they overlap).
    func visuallyContains(_ p: CGPoint) -> Bool {
        if shape == .circle {
            return hypot(p.x - rect.midX, p.y - rect.midY) <= rect.width / 2
        }
        return rect.contains(p)
    }
}

/// #8 When an on-screen press should buzz: once for every button that goes down and every
/// change to a new D-pad direction, never on a release or on the same direction held.
enum PressHaptic {
    static func shouldBuzz(from old: DSButton, to new: DSButton) -> Bool {
        let added = new.subtracting(old)
        return !added.isEmpty
    }
}

/// User settings for the touch controls (UserDefaults keys shared with @AppStorage).
enum TouchSettings {
    static let scaleKey = "touchScale"            // 0.8 ... 1.3
    static let opacityKey = "touchOpacity"        // 0 = skin default, else 0.2 ... 1
    static let hapticsKey = "touchHaptics"        // Bool, default on
    static let touchOnlyKey = "dsTouchOnly"       // DS: hide the buttons, stylus only
    static let stylusOffsetKey = "stylusOffset"   // points the touch point is raised above the finger
    static let stylusCursorKey = "stylusCursor"   // Bool: draw a cursor where the stylus lands

    static let scaleRange: ClosedRange<Float> = 0.8...1.3
    static let minTarget: CGFloat = 44           // Apple HIG minimum touch target

    static var scale: CGFloat {
        let v = UserDefaults.standard.object(forKey: scaleKey) as? Double ?? 1
        return CGFloat(min(max(v, Double(scaleRange.lowerBound)), Double(scaleRange.upperBound)))
    }
    static var haptics: Bool { UserDefaults.standard.object(forKey: hapticsKey) as? Bool ?? true }
    static var stylusOffset: CGFloat { CGFloat(UserDefaults.standard.double(forKey: stylusOffsetKey)) }
    static var stylusCursor: Bool { UserDefaults.standard.bool(forKey: stylusCursorKey) }
    static var touchOnly: Bool { UserDefaults.standard.bool(forKey: touchOnlyKey) }
}

// MARK: - Layout

/// Hardware model a skin imitates; changes where some controls sit in portrait.
enum PadModel: Equatable {
    case standard
    case phat     // original DS (Start/Select stay at the bottom of the shell, out of the way)
    case brick    // pocket brick: steep A/B diagonal, Start/Select centred low
}

struct TouchPadLayout: Equatable {
    var zones: [PadZone] = []
    /// DS touch screen in the same coordinates (nil for GBA / Game Boy, or no touch screen shown).
    var stylus: CGRect?
    /// The game screens; controls are kept off them whenever the space allows.
    var screens: [CGRect] = []

    static func make(layout: DualScreenLayout, system: PadSystem, showsButtons: Bool,
                     scale: CGFloat = 1, stylus: CGRect?, model: PadModel = .standard) -> TouchPadLayout {
        var out = TouchPadLayout()
        out.stylus = (system == .ds || system == .n3ds) ? stylus : nil
        out.screens = layout.isSingle ? [layout.top] : [layout.top, layout.bottom]
        let s = min(max(scale, 0.8), 1.3)
        if showsButtons {
            if layout.outer { out.zones = outer(layout, system, s) }
            else if system == .n3ds && layout.bottom.minX >= 60 {
                // Physical 3DS: pads sit beside the bottom LCD, not in a strip under the stack.
                out.zones = n3dsSurround(layout, s, model)
            }
            else if layout.compactUnit > 0 { out.zones = compact(layout, system, s) }
            else if layout.isPortrait { out.zones = portrait(layout, system, s, model) }
            else { out.zones = landscape(layout, system, s) }
        } else if system == .ds {
            out.zones = touchOnlyPills(layout)
        }
        // DS: the touch screen keeps its full area. Invisible margins never reach into it.
        if let st = out.stylus {
            out.zones = out.zones.map { z in var z = z; z.hit = trim(z.hit, keeping: z.rect, avoiding: st); return z }
        }
        return out
    }

    /// Regular physical 3DS: circle pad upper-left of the bottom screen, D-pad below it on
    /// the same side, ABXY diamond on the right, L/R at the hinge corners, Start/Select
    /// (and room for Home/Menu) centered under the bottom LCD. Never cover either screen.
    private static func n3dsSurround(_ l: DualScreenLayout, _ s: CGFloat, _ model: PadModel) -> [PadZone] {
        let top = l.top, bot = l.bottom
        let full = l.controlsArea
        let fullW = max(full.maxX, bot.maxX + 8)
        let fullH = max(full.maxY, bot.maxY + 80)
        let leftW = max(bot.minX, 1)
        let rightW = max(fullW - bot.maxX, 1)
        func overlapsScreen(_ r: CGRect) -> Bool {
            r.intersects(top.insetBy(dx: -1, dy: -1)) || r.intersects(bot.insetBy(dx: -1, dy: -1))
        }

        let shH: CGFloat = 30
        let shW = min(max(min(leftW, rightW) - 8, 56), 108)
        var lRect = CGRect(x: 4, y: bot.minY - shH / 2, width: shW, height: shH)
        var rRect = CGRect(x: fullW - 4 - shW, y: bot.minY - shH / 2, width: shW, height: shH)
        if overlapsScreen(lRect) { lRect.origin.y = bot.minY + 4 }
        if overlapsScreen(rRect) { rRect.origin.y = bot.minY + 4 }

        // Circle pad in the left gutter, just under L; D-pad under the pad; both beside the bottom LCD.
        let availH = max(bot.maxY - 8 - (lRect.maxY + 6), 80)
        let stickU = min(max(min(leftW - 12, 108) * min(s, 1.15), 56), availH * 0.50, leftW - 10)
        var stickC = CGPoint(x: leftW / 2, y: lRect.maxY + 8 + stickU / 2)
        if stickC.y + stickU / 2 > bot.maxY - 4 {
            stickC.y = bot.maxY - 4 - stickU / 2
        }
        let dpadU = min(stickU * 0.84, max(52, availH - stickU - 14), leftW - 14)
        var dpadC = CGPoint(x: leftW / 2, y: stickC.y + stickU / 2 + 10 + dpadU / 2)
        if dpadC.y + dpadU / 2 > bot.maxY - 2 {
            dpadC.y = bot.maxY - 2 - dpadU / 2
        }

        // ABXY diamond on the right, roughly level with the circle pad.
        let faceU = min(max(min(rightW - 10, 112) * min(s, 1.15), 64), rightW - 8, stickU + 16)
        var faceC = CGPoint(x: bot.maxX + rightW / 2, y: stickC.y + 8)
        let faceHalf = faceU * 0.30 + faceU * 0.34 / 2
        if faceC.y - faceHalf < bot.minY + 4 { faceC.y = bot.minY + 4 + faceHalf }
        if faceC.y + faceHalf > bot.maxY - 4 { faceC.y = bot.maxY - 4 - faceHalf }

        var z = analogClusters(.n3ds, unit: faceU, left: stickC, right: faceC)
        // analogClusters sizes the stick to `unit` (faceU). Replace with the intended stick size.
        z.removeAll { $0.shape == .stick }
        let stick = CGRect(x: stickC.x - stickU / 2, y: stickC.y - stickU / 2, width: stickU, height: stickU)
        z.insert(PadZone(button: [], label: "Circle", shape: .stick, rect: stick,
                         hit: stick.insetBy(dx: -stickU * 0.08, dy: -stickU * 0.08), hitRadius: nil, slideIn: false), at: 0)

        let dRect = CGRect(x: dpadC.x - dpadU / 2, y: dpadC.y - dpadU / 2, width: dpadU, height: dpadU)
        z.append(PadZone(button: [.up, .down, .left, .right], label: "D-pad", shape: .dpad, rect: dRect,
                         hit: dRect.insetBy(dx: -dpadU * 0.18, dy: -dpadU * 0.18), hitRadius: nil, slideIn: false))

        z.append(shoulder("L", .l, lRect))
        z.append(shoulder("R", .r, rRect))

        let py = min(max(bot.maxY + 24, bot.maxY + 16), fullH - 50)
        let gap: CGFloat = model == .brick ? 70 : 80
        z.append(pill("SELECT", .select, center: CGPoint(x: bot.midX - gap, y: py)))
        z.append(pill("START", .start, center: CGPoint(x: bot.midX + gap, y: py)))

        // Drop anything that still covers a screen (hit insets are trimmed later against the stylus).
        z = z.filter { !overlapsScreen($0.rect) }
        return z
    }

    // Portrait (regular iPhone, Duo book with side-by-side panels): clusters at thumb height in
    // the area under the screens, L/R on the top corners of that area, Start/Select at the bottom.
    private static func portrait(_ l: DualScreenLayout, _ sys: PadSystem, _ s: CGFloat, _ model: PadModel = .standard) -> [PadZone] {
        let a = l.controlsArea
        let base = min(max(min(a.width, a.height) * 0.42, 120), 190) * s
        let unit = max(min(base, a.height - 104, a.width * 0.44), 96)
        let pad = max(unit * 0.12, 14)
        let hasShoulders = sys.showsShoulders
        let topLimit = a.minY + (hasShoulders ? 52 : 12) + unit / 2
        let bottomLimit = a.maxY - 52 - unit / 2
        // Slightly below the middle: where thumbs rest when holding the phone.
        let y = min(max(a.midY + unit * 0.06, topLimit), max(bottomLimit, topLimit))
        var z = clusters(sys, unit: unit, left: CGPoint(x: a.minX + unit / 2 + pad, y: y),
                         right: CGPoint(x: a.maxX - unit / 2 - pad, y: y), steep: model == .brick)
        if hasShoulders {
            let w: CGFloat = 96 * min(s, 1.15), h: CGFloat = 38
            z.append(shoulder("L", .l, CGRect(x: a.minX + pad, y: a.minY + 8, width: w, height: h)))
            z.append(shoulder("R", .r, CGRect(x: a.maxX - pad - w, y: a.minY + 8, width: w, height: h)))
            if sys == .n64 {
                z.append(shoulder("Z", .z, CGRect(x: a.midX - w / 2, y: a.minY + 8, width: w, height: h)))
            } else if sys == .n3ds {
                z.append(shoulder("ZL", .zl, CGRect(x: a.minX + pad, y: a.minY + 50, width: w * 0.7, height: h * 0.8)))
                z.append(shoulder("ZR", .zr, CGRect(x: a.maxX - pad - w * 0.7, y: a.minY + 50, width: w * 0.7, height: h * 0.8)))
            }
        }
        if sys == .n3ds, let stick = z.first(where: { $0.shape == .stick }) {
            // Real 3DS: D-pad sits inward of the circle pad. Keep it off the screens and Start/Select.
            let d = min(unit * 0.70, 88)
            let cx = min(stick.rect.midX + unit * 0.62, a.midX - d / 2 - 8)
            let cy = stick.rect.midY + unit * 0.10
            let dRect = CGRect(x: cx - d / 2, y: cy - d / 2, width: d, height: d)
            if a.insetBy(dx: 4, dy: 4).contains(dRect), !l.top.intersects(dRect), !l.bottom.intersects(dRect) {
                z.append(PadZone(button: [.up, .down, .left, .right], label: "D-pad", shape: .dpad, rect: dRect,
                                 hit: dRect.insetBy(dx: -d * 0.18, dy: -d * 0.18), hitRadius: nil, slideIn: false))
            }
        }
        let py = a.maxY - 24
        let gap: CGFloat = model == .brick ? 40 : 46
        z.append(pill("SELECT", .select, center: CGPoint(x: a.midX - gap, y: py)))
        z.append(pill("START", .start, center: CGPoint(x: a.midX + gap, y: py)))
        return z
    }

    // Landscape: everything in the gutters beside the screens so nothing covers the game.
    private static func landscape(_ l: DualScreenLayout, _ sys: PadSystem, _ s: CGFloat) -> [PadZone] {
        let a = l.controlsArea
        let scr = l.isSingle ? l.top : l.top.union(l.bottom)
        let gutterL = max(scr.minX - a.minX, 0), gutterR = max(a.maxX - scr.maxX, 0)
        let g = min(gutterL, gutterR)
        let wanted = min(max(a.height * 0.36, 120), 180) * s
        let unit = max(min(wanted, g - 16), 96)          // below 96 the screen gets overlapped
        let lx = a.minX + max(gutterL / 2, unit / 2 + 10)
        let rx = a.maxX - max(gutterR / 2, unit / 2 + 10)
        let hasShoulders = sys.showsShoulders
        // The top bar (44pt) owns the first strip; shoulders sit just below it.
        let shoulderTop = a.minY + 50
        let topLimit = (hasShoulders ? shoulderTop + 40 + 10 : a.minY + 56) + unit / 2
        let bottomLimit = a.maxY - 50 - unit / 2
        let y = min(max(a.minY + a.height * 0.58, topLimit), max(bottomLimit, topLimit))
        var z = clusters(sys, unit: unit, left: CGPoint(x: lx, y: y), right: CGPoint(x: rx, y: y))
        if hasShoulders {
            let w = min(max(g - 16, 84), 120), h: CGFloat = 40
            z.append(shoulder("L", .l, CGRect(x: lx - w / 2, y: shoulderTop, width: w, height: h)))
            z.append(shoulder("R", .r, CGRect(x: rx - w / 2, y: shoulderTop, width: w, height: h)))
        }
        // Select under the D-pad, Start under the buttons: reachable, but away from the thumbs.
        let py = a.maxY - 24
        z.append(pill("SELECT", .select, center: CGPoint(x: lx, y: py)))
        z.append(pill("START", .start, center: CGPoint(x: rx, y: py)))
        return z
    }

    // iPhone Duo open with stacked panels: narrow side columns beside the DS touch screen.
    private static func compact(_ l: DualScreenLayout, _ sys: PadSystem, _ s: CGFloat) -> [PadZone] {
        if l.twin { return twin(l, sys, s) }
        let a = l.controlsArea
        let unit = max(l.compactUnit * min(s, 1.1), 60)
        let sideW = l.bottom.minX - a.minX
        let y = (l.bottom.minY + a.maxY - 34) / 2
        var z = clusters(sys, unit: unit, left: CGPoint(x: a.minX + sideW / 2, y: y),
                         right: CGPoint(x: a.maxX - sideW / 2, y: y))
        if sys.showsShoulders {
            let w = max(sideW - 6, 44), h: CGFloat = 26
            z.append(shoulder("L", .l, CGRect(x: a.minX + sideW / 2 - w / 2, y: a.maxY - 30, width: w, height: h)))
            z.append(shoulder("R", .r, CGRect(x: a.maxX - sideW / 2 - w / 2, y: a.maxY - 30, width: w, height: h)))
        }
        let py = (l.bottom.maxY + a.maxY) / 2
        z.append(pill("SELECT", .select, center: CGPoint(x: l.bottom.midX - 40, y: py), size: CGSize(width: 64, height: 24)))
        z.append(pill("START", .start, center: CGPoint(x: l.bottom.midX + 40, y: py), size: CGSize(width: 64, height: 24)))
        return z
    }

    // iPhone Duo pearl shell: D-pad left and X/Y/A/B right of the touch screen, small START /
    // SELECT stacked under the face buttons, L/R at the outer ends just under the hinge bar.
    private static func twin(_ l: DualScreenLayout, _ sys: PadSystem, _ s: CGFloat) -> [PadZone] {
        let sp = l.twinSpots
        let unit = max(l.compactUnit * min(s, 1.1), 60)
        var z = clusters(sys, unit: unit, left: sp.dpad, right: sp.face)
        // L / R: the end segments of the hinge bar. NES has no shoulders; every other console
        // that reaches this Duo shell keeps them (including Game Boy, which already did).
        if sys != .nes {
            let bar = DualScreenLayout.twinBar(hinge: l.hinge)
            let lw = max(sp.endWidth - 8, 44), lh = max(bar.height + 6, 30)
            z.append(shoulder("L", .l, CGRect(x: sp.lLabel.x - lw / 2, y: sp.lLabel.y - lh / 2, width: lw, height: lh)))
            z.append(shoulder("R", .r, CGRect(x: sp.rLabel.x - lw / 2, y: sp.rLabel.y - lh / 2, width: lw, height: lh)))
        }
        // START / SELECT: small round buttons with the label to their right, under the face buttons.
        z.append(dot("START", .start, center: sp.start))
        z.append(dot("SELECT", .select, center: sp.select))
        return z
    }

    private static func dot(_ label: String, _ b: DSButton, center c: CGPoint) -> PadZone {
        let r = CGRect(x: c.x - 36, y: c.y - 11, width: 72, height: 22)
        return PadZone(button: b, label: label, shape: .dot, rect: r, hit: minTarget(r.insetBy(dx: -4, dy: -4)),
                       hitRadius: nil, slideIn: false)
    }

    // Closed iPhone Duo, landscape outer display: classic handheld shell controls.
    private static func outer(_ l: DualScreenLayout, _ sys: PadSystem, _ s: CGFloat) -> [PadZone] {
        let sp = l.outerSpots
        var z = clusters(sys, unit: sp.unit * min(s, 1.1), left: sp.dpad, right: sp.face, steep: sys == .gameBoy)
        let ps = CGSize(width: 54, height: 18)
        z.append(pill("SELECT", .select, center: sp.select, size: ps))
        z.append(pill("START", .start, center: sp.start, size: ps))
        if sys == .gba || sys == .snes {
            z.append(shoulder("L", .l, sp.l))
            z.append(shoulder("R", .r, sp.r))
        }
        return z
    }

    /// DS touch-only mode: just Start/Select, and only where they cover no screen.
    private static func touchOnlyPills(_ l: DualScreenLayout) -> [PadZone] {
        let screens = l.isSingle ? [l.top] : [l.top, l.bottom]
        let a = l.controlsArea
        var candidates: [(CGPoint, CGPoint)] = []
        if l.isPortrait || l.compactUnit > 0 {
            let lowest = screens.map(\.maxY).max() ?? a.minY
            candidates.append((CGPoint(x: a.midX - 46, y: (lowest + a.maxY) / 2), CGPoint(x: a.midX + 46, y: (lowest + a.maxY) / 2)))
        }
        let scr = screens.reduce(screens[0]) { $0.union($1) }
        candidates.append((CGPoint(x: (a.minX + scr.minX) / 2, y: a.maxY - 24), CGPoint(x: (scr.maxX + a.maxX) / 2, y: a.maxY - 24)))
        for (sel, st) in candidates {
            let z = [pill("SELECT", .select, center: sel), pill("START", .start, center: st)]
            let fits = z.allSatisfy { p in a.contains(p.rect) && !screens.contains { $0.intersects(p.rect) } }
            if fits { return z }
        }
        return []
    }

    // MARK: building blocks

    private static func clusters(_ sys: PadSystem, unit u: CGFloat, left: CGPoint, right: CGPoint, steep: Bool = false) -> [PadZone] {
        if sys == .n64 || sys == .n3ds { return analogClusters(sys, unit: u, left: left, right: right) }
        let dRect = CGRect(x: left.x - u / 2, y: left.y - u / 2, width: u, height: u)
        var z = [PadZone(button: [.up, .down, .left, .right], label: "D-pad", shape: .dpad, rect: dRect,
                         hit: dRect.insetBy(dx: -u * 0.22, dy: -u * 0.22), hitRadius: nil, slideIn: false)]
        func face(_ label: String, _ b: DSButton, _ dx: CGFloat, _ dy: CGFloat, _ d: CGFloat) -> PadZone {
            let c = CGPoint(x: right.x + dx, y: right.y + dy)
            let rect = CGRect(x: c.x - d / 2, y: c.y - d / 2, width: d, height: d)
            // Invisible margin: 30% beyond the drawn button, never under 22pt (44pt target).
            let r = max(d / 2 * 1.3, TouchSettings.minTarget / 2)
            return PadZone(button: b, label: label, shape: .circle, rect: rect,
                           hit: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2), hitRadius: r, slideIn: true)
        }
        if sys.diamondFace {
            // DS and Super NES: X above, B below, Y left, A right.
            let d = u * 0.36, o = u * 0.32
            z += [face("X", .x, 0, -o, d), face("B", .b, 0, o, d), face("Y", .y, -o, 0, d), face("A", .a, o, 0, d)]
        } else if sys == .nes {
            // NES controller: B on the left, A on the right, level with each other.
            let d = u * 0.40, gap = u * 0.24
            z += [face("B", .b, -gap, 0, d), face("A", .a, gap, 0, d)]
        } else {
            // GBA / Game Boy: B lower-left, A upper-right, slanted like the hardware.
            let d = u * 0.414
            // Pocket brick: steeper diagonal like the original.
            let dy = steep ? u * 0.17 : u * 0.12, dx = steep ? u * 0.20 : u * 0.22
            z += [face("B", .b, -dx, dy, d), face("A", .a, dx, -dy, d)]
        }
        return z
    }

    /// N64: analog stick, A/B and the four C buttons. 3DS: circle pad and the face diamond.
    private static func analogClusters(_ sys: PadSystem, unit u: CGFloat, left: CGPoint, right: CGPoint) -> [PadZone] {
        let stick = CGRect(x: left.x - u / 2, y: left.y - u / 2, width: u, height: u)
        var z = [PadZone(button: [], label: sys == .n64 ? "Stick" : "Circle", shape: .stick, rect: stick,
                         hit: stick.insetBy(dx: -u * 0.08, dy: -u * 0.08), hitRadius: nil, slideIn: false)]
        func face(_ label: String, _ b: DSButton, _ dx: CGFloat, _ dy: CGFloat, _ d: CGFloat) -> PadZone {
            let c = CGPoint(x: right.x + dx, y: right.y + dy)
            let rect = CGRect(x: c.x - d / 2, y: c.y - d / 2, width: d, height: d)
            let r = max(d / 2 * 1.25, TouchSettings.minTarget / 2)
            return PadZone(button: b, label: label, shape: .circle, rect: rect,
                           hit: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2), hitRadius: r, slideIn: true)
        }
        if sys == .n3ds {
            let d = u * 0.34, o = u * 0.30
            z += [face("X", .x, 0, -o, d), face("B", .b, 0, o, d), face("Y", .y, -o, 0, d), face("A", .a, o, 0, d)]
        } else {
            let d = u * 0.32, gap = u * 0.22
            z += [face("B", .b, -gap, gap * 0.6, d), face("A", .a, gap, -gap * 0.2, d)]
            // Compact C diamond just below A/B so it stays on-screen and can be moved as its own group.
            let c = u * 0.24, co = u * 0.26, cx = u * 0.08, cy = u * 0.62
            z += [face("C↑", .cUp, cx, cy - co, c), face("C↓", .cDown, cx, cy + co, c),
                  face("C←", .cLeft, cx - co, cy, c), face("C→", .cRight, cx + co, cy, c)]
        }
        return z
    }

    private static func shoulder(_ label: String, _ b: DSButton, _ r: CGRect) -> PadZone {
        PadZone(button: b, label: label, shape: .shoulder, rect: r, hit: minTarget(r.insetBy(dx: -10, dy: -10)),
                hitRadius: nil, slideIn: true)
    }

    private static func pill(_ label: String, _ b: DSButton, center c: CGPoint,
                             size: CGSize = CGSize(width: 72, height: 28)) -> PadZone {
        let r = CGRect(x: c.x - size.width / 2, y: c.y - size.height / 2, width: size.width, height: size.height)
        return PadZone(button: b, label: label, shape: .capsule, rect: r, hit: minTarget(r.insetBy(dx: -4, dy: -6)),
                       hitRadius: nil, slideIn: false)
    }

    /// Grows a rect around its centre to at least 44x44pt.
    static func minTarget(_ r: CGRect) -> CGRect {
        let m = TouchSettings.minTarget
        return r.insetBy(dx: min(0, (r.width - m) / 2), dy: min(0, (r.height - m) / 2))
    }

    /// Cuts the side of `hit` that reaches into `avoid`, but never into the drawn control.
    static func trim(_ hit: CGRect, keeping visual: CGRect, avoiding avoid: CGRect) -> CGRect {
        guard hit.intersects(avoid), !visual.intersects(avoid) else { return hit }
        var h = hit
        if visual.maxX <= avoid.minX { h.size.width = max(avoid.minX, visual.maxX) - h.minX }
        else if visual.minX >= avoid.maxX { let x = min(avoid.maxX, visual.minX); h.size.width = h.maxX - x; h.origin.x = x }
        else if visual.maxY <= avoid.minY { h.size.height = max(avoid.minY, visual.maxY) - h.minY }
        else if visual.minY >= avoid.maxY { let y = min(avoid.maxY, visual.minY); h.size.height = h.maxY - y; h.origin.y = y }
        return h
    }
}

// MARK: - D-pad

enum DPadMath {
    /// 8-way directions for a finger at (dx, dy) from the D-pad centre (y down). Cardinal
    /// sectors are 55° wide, diagonals 35°. A few degrees of hysteresis stop flicker on the
    /// boundaries. Inside the dead zone nothing is pressed.
    static func directions(dx: CGFloat, dy: CGFloat, deadZone: CGFloat, current: DSButton = []) -> DSButton {
        let dist = hypot(dx, dy)
        // Hysteresis on the dead zone too: once pressed, it holds until well inside the centre.
        let dead = current.isEmpty ? deadZone : deadZone * 0.7
        guard dist > dead else { return [] }
        let deg = atan2(-dy, dx) * 180 / .pi                    // 0 = right, 90 = up
        let a = deg < 0 ? deg + 360 : deg
        let half: CGFloat = 27.5, hyst: CGFloat = 4
        let cardinals: [(CGFloat, DSButton)] = [(0, .right), (90, .up), (180, .left), (270, .down)]
        let heldDiagonal = current.intersection([.up, .down]).rawValue != 0 && current.intersection([.left, .right]).rawValue != 0
        for (centre, b) in cardinals {
            let limit = current == b ? half + hyst : (heldDiagonal ? half - hyst : half)
            if angleDistance(a, centre) <= limit { return b }
        }
        let diagonals: [(CGFloat, DSButton)] = [(45, [.up, .right]), (135, [.up, .left]), (225, [.down, .left]), (315, [.down, .right])]
        var best: DSButton = [], bestD = CGFloat.greatestFiniteMagnitude
        for (centre, b) in diagonals { let d = angleDistance(a, centre); if d < bestD { bestD = d; best = b } }
        return best
    }

    static func angleDistance(_ a: CGFloat, _ b: CGFloat) -> CGFloat {
        let d = abs(a - b).truncatingRemainder(dividingBy: 360)
        return min(d, 360 - d)
    }
}

// MARK: - Stylus

enum StylusMapper {
    /// Maps a point inside the touch screen `rect` to DS coordinates (0...255, 0...191). Points
    /// outside are clamped to the nearest edge pixel, so dragging off the screen never drops the
    /// stylus. `raise` lifts the touch point above the finger (it hides what is under it).
    static func map(_ p: CGPoint, in rect: CGRect, raise: CGFloat = 0) -> (x: Int, y: Int) {
        guard rect.width > 0, rect.height > 0 else { return (0, 0) }
        let q = CGPoint(x: p.x, y: p.y - raise)
        let nx = (q.x - rect.minX) / rect.width * 256, ny = (q.y - rect.minY) / rect.height * 192
        return (min(max(Int(nx.rounded(.down)), 0), 255), min(max(Int(ny.rounded(.down)), 0), 191))
    }

    /// The point (in view coordinates) a DS pixel maps back to (its centre), for the cursor.
    static func point(x: Int, y: Int, in rect: CGRect) -> CGPoint {
        CGPoint(x: rect.minX + (CGFloat(x) + 0.5) / 256 * rect.width, y: rect.minY + (CGFloat(y) + 0.5) / 192 * rect.height)
    }
}

// MARK: - Touch tracking

/// Tracks every finger and turns them into pressed buttons and the DS stylus. Each finger owns
/// one thing: the D-pad, a set of face/shoulder buttons (re-evaluated as it slides, so A→B
/// rolls and the A+B overlap work), Start/Select (only where it landed), or the stylus.
struct PadTouchResolver {
    enum Owner: Equatable { case none, dpad(Int), buttons, locked(Int), stylus, stick(Int) }

    private(set) var layout = TouchPadLayout()
    private var fingers: [Int: (owner: Owner, pressed: DSButton)] = [:]
    private(set) var stylusFinger: Int?
    /// Margin around the touch screen where a landing finger still counts as the stylus (edges).
    var stylusEdge: CGFloat = 6

    init(layout: TouchPadLayout = TouchPadLayout()) { self.layout = layout }

    var pressed: DSButton { fingers.values.reduce(into: DSButton()) { $0.formUnion($1.pressed) } }
    /// Main analog (N64 stick / 3DS circle pad), each axis -1...1. Zero when the stick is free.
    var analog: (Float, Float) {
        for (id, finger) in fingers {
            if case .stick(let i) = finger.owner, let p = stickPoint[id] {
                return Self.stickValue(layout.zones[i], p)
            }
        }
        return (0, 0)
    }
    private var stickPoint: [Int: CGPoint] = [:]
    var activeFingers: Int { fingers.count }

    /// New geometry (rotation, resize, settings). Fingers on controls are released; a stylus
    /// drag keeps going.
    mutating func setLayout(_ l: TouchPadLayout) {
        guard l != layout else { return }
        layout = l
        let kept = fingers.filter { $0.value.owner == .stylus }
        stickPoint = stickPoint.filter { kept[$0.key] != nil }
        fingers = kept
        if l.stylus == nil, let f = stylusFinger { fingers[f] = nil; stylusFinger = nil }
    }

    mutating func reset() { fingers.removeAll(); stickPoint.removeAll(); stylusFinger = nil }

    /// Returns true when the finger became the stylus.
    @discardableResult
    mutating func began(_ id: Int, at p: CGPoint) -> Bool {
        let zones = layout.zones
        // 1. Anything drawn wins (also where controls overlap a screen).
        if let i = zones.firstIndex(where: { $0.visuallyContains(p) }) {
            claim(id, zoneIndex: i, at: p); return false
        }
        // 2. The touch screen (with a small edge margin), one stylus at a time.
        if let st = layout.stylus, stylusFinger == nil, st.insetBy(dx: -stylusEdge, dy: -stylusEdge).contains(p) {
            stylusFinger = id; fingers[id] = (.stylus, []); return true
        }
        // 3. Invisible margins: the D-pad first, then the closest button.
        if let i = zones.firstIndex(where: { $0.isDPad && $0.contains(p) }) { claim(id, zoneIndex: i, at: p); return false }
        if let i = nearest(p, in: zones.indices.filter { zones[$0].contains(p) }) { claim(id, zoneIndex: i, at: p); return false }
        fingers[id] = (.buttons, [])          // empty space: may slide onto a button later
        return false
    }

    mutating func moved(_ id: Int, to p: CGPoint) {
        guard let f = fingers[id] else { return }
        let now: DSButton
        switch f.owner {
        case .dpad(let i):
            now = dpad(layout.zones[i], p, current: f.pressed)
        case .buttons:
            now = slideButtons(at: p)
        case .locked(let i):
            let z = layout.zones[i]
            now = z.hit.insetBy(dx: -12, dy: -12).contains(p) ? z.button : []
        case .stick(let i):
            stickPoint[id] = p
            fingers[id] = (f.owner, [])
            return
        case .stylus, .none:
            return
        }
        fingers[id] = (f.owner, now)
    }

    mutating func ended(_ id: Int) {
        fingers[id] = nil
        stickPoint[id] = nil
        if stylusFinger == id { stylusFinger = nil }
    }

    func isStylus(_ id: Int) -> Bool { stylusFinger == id }

    private mutating func claim(_ id: Int, zoneIndex i: Int, at p: CGPoint) {
        let z = layout.zones[i]
        if z.shape == .stick { stickPoint[id] = p; fingers[id] = (.stick(i), []) }
        else if z.isDPad { fingers[id] = (.dpad(i), dpad(z, p, current: [])) }
        else if z.slideIn { fingers[id] = (.buttons, slideButtons(at: p).union(z.button)) }
        else { fingers[id] = (.locked(i), z.button) }
    }

    private func dpad(_ z: PadZone, _ p: CGPoint, current: DSButton) -> DSButton {
        DPadMath.directions(dx: p.x - z.rect.midX, dy: p.y - z.rect.midY,
                            deadZone: max(z.rect.width * 0.11, 7), current: current)
    }

    /// Every slide-in button under the finger: in the overlap between A and B both are pressed.
    private func slideButtons(at p: CGPoint) -> DSButton {
        layout.zones.filter { $0.slideIn && $0.contains(p) }.reduce(into: DSButton()) { $0.formUnion($1.button) }
    }

    private static func stickValue(_ z: PadZone, _ p: CGPoint) -> (Float, Float) {
        let dx = Float((p.x - z.rect.midX) / max(z.rect.width / 2, 1))
        let dy = Float((z.rect.midY - p.y) / max(z.rect.height / 2, 1))
        let len = hypot(dx, dy)
        let dead: Float = 0.15
        if len <= dead { return (0, 0) }
        let s = min((len - dead) / (1 - dead), 1)
        return (dx / len * s, dy / len * s)
    }

    private func nearest(_ p: CGPoint, in idx: [Int]) -> Int? {
        idx.min { a, b in
            let za = layout.zones[a].rect, zb = layout.zones[b].rect
            return hypot(p.x - za.midX, p.y - za.midY) < hypot(p.x - zb.midX, p.y - zb.midY)
        }
    }
}
