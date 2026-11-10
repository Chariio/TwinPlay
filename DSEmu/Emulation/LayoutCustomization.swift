// Copyright (c) 2026 Charlie Rodriguez Garcia. All rights reserved.
// User layout: where each screen and each on-screen control sits, saved per device model,
// console and orientation (the layout key). Pure logic (no UIKit), so it is unit-tested.
import CoreGraphics
import Foundation

/// A moved / resized item. Screens: `size` is the width as a fraction of the display width.
/// Controls: `size` is a scale factor (1 = the default size). cx, cy: centre as a fraction of the display.
struct ItemPlacement: Codable, Equatable {
    var cx: Double
    var cy: Double
    var size: Double
}

/// The movable control groups. Menu, touch/swap and fast-forward are the in-game buttons.
enum LayoutControl: String, CaseIterable, Codable {
    case dpad, stick, face, cButtons, l, r, select, start, menu, touch, ff

    var label: String {
        switch self {
        case .dpad: return String(localized: "D-pad")
        case .stick: return String(localized: "Stick")
        case .face: return String(localized: "Buttons")
        case .cButtons: return String(localized: "C buttons")
        case .l: return "L"
        case .r: return "R"
        case .select: return "Select"
        case .start: return "Start"
        case .menu: return String(localized: "Menu")
        case .touch: return String(localized: "Touch")
        case .ff: return String(localized: "Fast-forward")
        }
    }
    /// Allowed scale. The in-game buttons never go below their 44pt size.
    var scaleRange: ClosedRange<Double> {
        switch self { case .menu, .touch, .ff: return 1.0...1.6; default: return 0.6...1.8 }
    }
    var isChrome: Bool { self == .menu || self == .touch || self == .ff }
}

struct CustomLayout: Codable, Equatable {
    var screens: [String: ItemPlacement] = [:]            // "top", "bottom"
    var controls: [String: ItemPlacement] = [:]           // LayoutControl.rawValue
    var isEmpty: Bool { screens.isEmpty && controls.isEmpty }
    func control(_ c: LayoutControl) -> ItemPlacement? { controls[c.rawValue] }
}

enum LayoutStore {
    static let minScreenWidthFraction = 0.2

    /// Marketing identifier of this device, e.g. "iPhone18,2". Layouts are saved per model.
    static var deviceModel: String {
        var u = utsname(); uname(&u)
        let m = withUnsafePointer(to: &u.machine) { $0.withMemoryRebound(to: CChar.self, capacity: 1) { String(cString: $0) } }
        return (m == "arm64" || m == "x86_64") ? (ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] ?? m) : m
    }

    static func key(device: String = deviceModel, layoutKey: String) -> String { "layout.v1.\(device).\(layoutKey)" }

    private static var cache: [String: CustomLayout] = [:]
    private static let lock = NSLock()

    static func load(_ key: String, defaults: UserDefaults = .standard) -> CustomLayout {
        lock.lock(); defer { lock.unlock() }
        if defaults === UserDefaults.standard, let c = cache[key] { return c }
        var out = CustomLayout()
        if let d = defaults.data(forKey: key), let l = try? JSONDecoder().decode(CustomLayout.self, from: d) { out = l }
        if defaults === UserDefaults.standard { cache[key] = out }
        return out
    }

    static func save(_ l: CustomLayout, for key: String, defaults: UserDefaults = .standard) {
        lock.lock(); defer { lock.unlock() }
        if l.isEmpty { defaults.removeObject(forKey: key) }
        else if let d = try? JSONEncoder().encode(l) { defaults.set(d, forKey: key) }
        if defaults === UserDefaults.standard { cache[key] = l }
    }

    static func reset(_ key: String, defaults: UserDefaults = .standard) { save(CustomLayout(), for: key, defaults: defaults) }

    // MENU pill: its spot is saved per skin as well as per layout (posture / orientation /
    // console), next to the rest of the layout.
    static func menuKey(_ layoutStoreKey: String, skin: String) -> String { "\(layoutStoreKey).menu.\(skin)" }

    /// The layout with this skin's MENU placement (none saved for the skin: the default spot).
    static func merged(_ base: CustomLayout, menu: CustomLayout) -> CustomLayout {
        var c = base
        c.controls[LayoutControl.menu.rawValue] = menu.control(.menu)
        return c
    }

    /// Splits an edited layout into the part shared by every skin and the skin's MENU placement.
    static func split(_ c: CustomLayout) -> (base: CustomLayout, menu: CustomLayout) {
        var base = c, menu = CustomLayout()
        base.controls[LayoutControl.menu.rawValue] = nil
        menu.controls[LayoutControl.menu.rawValue] = c.control(.menu)
        return (base, menu)
    }

    static func load(_ key: String, skin: String, defaults: UserDefaults = .standard) -> CustomLayout {
        merged(load(key, defaults: defaults), menu: load(menuKey(key, skin: skin), defaults: defaults))
    }

    /// Saves both parts; an empty layout (Reset to Default) clears both.
    static func save(_ c: CustomLayout, for key: String, skin: String, defaults: UserDefaults = .standard) {
        let (base, menu) = split(c)
        save(base, for: key, defaults: defaults)
        save(menu, for: menuKey(key, skin: skin), defaults: defaults)
    }
}

// MARK: - Applying a layout

extension DualScreenLayout {
    /// Screens at the user's positions and sizes (aspect ratio kept, always inside the display).
    func applying(_ c: CustomLayout, in full: CGSize) -> DualScreenLayout {
        guard !c.screens.isEmpty else { return self }
        var l = self
        func place(_ r: CGRect, _ p: ItemPlacement?) -> CGRect {
            guard let p, r.width > 1, r.height > 1 else { return r }
            return LayoutMath.screenRect(aspect: r.width / r.height, placement: p, in: full)
        }
        l.top = place(top, c.screens["top"])
        if !isSingle { l.bottom = place(bottom, c.screens["bottom"]) }
        return l
    }

    /// iPhone Duo: `applying`, unless the saved screen placements would break the DS layout
    /// (top screen below the touch screen, or the two screens on top of each other). Such a
    /// placement was saved for a different window (another posture or orientation, see
    /// `EmulatorView.startEditingLayout`) and is ignored: the default screens are used, the
    /// user's control placements still apply (they live in the pad layout).
    func applyingChecked(_ c: CustomLayout, in full: CGSize, foldable: Bool) -> (layout: DualScreenLayout, rejectedScreens: Bool) {
        let placed = applying(c, in: full)
        guard foldable, !isSingle, !c.screens.isEmpty, !Self.screensInOrder(placed, sideBySide: isSideBySide) else {
            return (placed, false)
        }
        return (self, true)
    }

    /// Both DS screens in reading order (top above / left of the touch screen) and not covering
    /// each other (a sliver of overlap from rounding is fine).
    static func screensInOrder(_ l: DualScreenLayout, sideBySide: Bool) -> Bool {
        let a = l.top, b = l.bottom
        guard a.width > 1, b.width > 1 else { return true }
        let ordered = sideBySide ? a.midX < b.midX : a.midY < b.midY
        let o = a.intersection(b)
        let overlap = o.isNull ? 0 : o.width * o.height
        let smaller = min(a.width * a.height, b.width * b.height)
        return ordered && overlap <= smaller * 0.03
    }
}

extension TouchPadLayout {
    static func group(of z: PadZone) -> LayoutControl? {
        if z.shape == .stick { return .stick }
        if z.isDPad { return .dpad }
        let b = z.button
        if b == .a || b == .b || b == .x || b == .y { return .face }
        if b == .cUp || b == .cDown || b == .cLeft || b == .cRight { return .cButtons }
        if b == .l { return .l }
        if b == .r { return .r }
        if b == .select { return .select }
        if b == .start { return .start }
        return nil
    }

    /// Bounding box of every control group as drawn now.
    var groupRects: [LayoutControl: CGRect] {
        var out: [LayoutControl: CGRect] = [:]
        for z in zones {
            guard let g = Self.group(of: z) else { continue }
            out[g] = out[g].map { $0.union(z.rect) } ?? z.rect
        }
        return out
    }

    /// Controls moved / scaled to the user's placement. Touch targets stay at least 44pt.
    func applying(_ c: CustomLayout, in full: CGSize) -> TouchPadLayout {
        guard !c.controls.isEmpty else { return self }
        let boxes = groupRects
        var out = self
        out.zones = zones.map { z in
            guard let g = Self.group(of: z), let p = c.control(g), let box = boxes[g] else { return z }
            let (center, k) = LayoutMath.controlTransform(box: box, placement: p, range: g.scaleRange, in: full)
            func map(_ r: CGRect) -> CGRect {
                CGRect(x: center.x + (r.minX - box.midX) * k, y: center.y + (r.minY - box.midY) * k, width: r.width * k, height: r.height * k)
            }
            var n = z
            n.rect = map(z.rect)
            if let hr = z.hitRadius {
                let r = max(hr * k, TouchSettings.minTarget / 2)
                n.hitRadius = r
                n.hit = CGRect(x: n.rect.midX - r, y: n.rect.midY - r, width: r * 2, height: r * 2)
            } else {
                n.hit = TouchPadLayout.minTarget(map(z.hit))
            }
            return n
        }
        if let st = out.stylus {
            out.zones = out.zones.map { z in var z = z; z.hit = Self.trim(z.hit, keeping: z.rect, avoiding: st); return z }
        }
        return out
    }

    /// Like `applying`, but any group whose drawn rect would sit on a screen keeps its default
    /// place (so a saved Duo layout cannot cover a 3DS LCD). The user can still move it in the editor.
    func applying(_ c: CustomLayout, in full: CGSize, avoiding screens: [CGRect]) -> TouchPadLayout {
        let applied = applying(c, in: full)
        let blocked: Set<LayoutControl> = Set(applied.groupRects.compactMap { g, r in
            screens.contains(where: { $0.intersects(r.insetBy(dx: 4, dy: 4)) }) ? g : nil
        })
        guard !blocked.isEmpty else { return applied }
        let kept = applied.zones.filter { z in
            guard let g = Self.group(of: z) else { return true }
            return !blocked.contains(g)
        }
        let fallback = zones.filter { z in
            guard let g = Self.group(of: z) else { return false }
            return blocked.contains(g)
        }
        var out = applied
        out.zones = kept + fallback
        if let st = out.stylus {
            out.zones = out.zones.map { z in var z = z; z.hit = Self.trim(z.hit, keeping: z.rect, avoiding: st); return z }
        }
        return out
    }
}

enum LayoutMath {
    /// A screen of `aspect` (w/h) at the placement, shrunk to fit and moved inside `full`.
    static func screenRect(aspect: CGFloat, placement p: ItemPlacement, in full: CGSize) -> CGRect {
        var w = min(max(CGFloat(p.size), CGFloat(LayoutStore.minScreenWidthFraction)), 1) * full.width
        var h = w / aspect
        if h > full.height { h = full.height; w = h * aspect }
        let x = min(max(CGFloat(p.cx) * full.width - w / 2, 0), full.width - w)
        let y = min(max(CGFloat(p.cy) * full.height - h / 2, 0), full.height - h)
        return CGRect(x: x, y: y, width: w, height: h)
    }

    /// Centre and scale for a control group: scale clamped to `range`, whole group kept on screen.
    static func controlTransform(box: CGRect, placement p: ItemPlacement, range: ClosedRange<Double>, in full: CGSize) -> (CGPoint, CGFloat) {
        var k = CGFloat(min(max(p.size, range.lowerBound), range.upperBound))
        k = min(k, full.width / max(box.width, 1), full.height / max(box.height, 1))
        let hw = box.width * k / 2, hh = box.height * k / 2
        let cx = min(max(CGFloat(p.cx) * full.width, hw), full.width - hw)
        let cy = min(max(CGFloat(p.cy) * full.height, hh), full.height - hh)
        return (CGPoint(x: cx, y: cy), k)
    }

    /// Keeps `r` inside `bounds`.
    static func clamp(_ r: CGRect, in bounds: CGRect) -> CGRect {
        var o = r
        o.origin.x = min(max(o.minX, bounds.minX), bounds.maxX - o.width)
        o.origin.y = min(max(o.minY, bounds.minY), bounds.maxY - o.height)
        return o
    }

    struct Snap: Equatable {
        var dx: CGFloat = 0, dy: CGFloat = 0
        var vGuides: [CGFloat] = []      // x positions of vertical guide lines
        var hGuides: [CGFloat] = []      // y positions of horizontal guide lines
    }

    /// Nudges `r` so an edge or its centre lands on a target line within `threshold`.
    static func snap(_ r: CGRect, xs: [CGFloat], ys: [CGFloat], threshold: CGFloat = 7) -> Snap {
        func best(_ edges: [CGFloat], _ targets: [CGFloat]) -> (CGFloat, CGFloat)? {
            var out: (CGFloat, CGFloat)?, bd = threshold + 0.001
            for e in edges { for t in targets where abs(t - e) < bd { bd = abs(t - e); out = (t - e, t) } }
            return out
        }
        var s = Snap()
        if let (d, t) = best([r.minX, r.midX, r.maxX], xs) { s.dx = d; s.vGuides = [t] }
        if let (d, t) = best([r.minY, r.midY, r.maxY], ys) { s.dy = d; s.hGuides = [t] }
        return s
    }
}
