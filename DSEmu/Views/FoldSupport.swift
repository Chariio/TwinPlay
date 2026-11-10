// Copyright (c) 2026 Charlie Rodriguez Garcia. All rights reserved.
import SwiftUI

// Foldable support uses the iOS 27.1 SDK APIs `View.onHingeChange`, `DeviceHinge`, and
// `GeometryProxy.reservedRegions(kind: .division)`. They are compiled only when the SDK has
// them (SwiftUICore 8.0.85+, i.e. Xcode 27.1); with older SDKs everything below is a no-op.

/// Observes the device hinge and reports a `FoldPosture`.
struct HingePostureObserver: ViewModifier {
    @Binding var posture: FoldPosture
    /// Hinge angle in degrees (180 = flat open, 0 = closed); nil when the device has no hinge.
    var angle: Binding<Double?>? = nil

    func body(content: Content) -> some View {
        #if canImport(SwiftUICore, _version: 8.0.85)
        if #available(iOS 27.1, *) {
            content.onHingeChange { _, ctx in
                posture = Self.posture(for: ctx)
                angle?.wrappedValue = ctx.hinge.map { $0.angle.degrees }
            }
        } else {
            content
        }
        #else
        content
        #endif
    }

    #if canImport(SwiftUICore, _version: 8.0.85)
    @available(iOS 27.1, *)
    static func posture(for ctx: DeviceHingeContext) -> FoldPosture {
        guard let h = ctx.hinge else { return .flat }
        if h.status == .closed { return .closed }
        if h.status == .partiallyOpen { return .book }
        if h.status == .fullyOpen { return .open }
        // A status this build does not know: the device does have a hinge, so go by its angle
        // instead of falling back to the plain-phone layout.
        return FoldPosture.from(angle: h.angle.degrees)
    }
    #endif
}

enum FoldGeometry {
    /// The hinge (division region) in the proxy's own coordinate space, if the system reports one
    /// that fits the window as it is now (see `validated`). Callers fall back to `defaultHinge`.
    static func hinge(in geo: GeometryProxy) -> CGRect? {
        validated(reportedHinge(in: geo), full: geo.size)
    }

    /// The division region exactly as the system reports it (may be stale or unusable).
    static func reportedHinge(in geo: GeometryProxy) -> CGRect? {
        #if canImport(SwiftUICore, _version: 8.0.85)
        if #available(iOS 27.1, *) {
            let regions = geo.reservedRegions(kind: .division)
            if let r = regions.first(where: \.isActive) ?? regions.first { return r.frame }
        }
        #endif
        return nil
    }

    /// Only trusts a reported hinge that matches the window it is laid out in: a thin band across
    /// the middle of the long side (horizontal in portrait, vertical in landscape), spanning the
    /// display. While the device rotates, or when it goes fully flat (the division region can be
    /// inactive then), the system can hand back a region that is stale (still in the previous
    /// orientation), empty, or much wider than the crease; laying the screens out around such a
    /// region shrank, swapped or overlapped them. Those are rejected (nil -> `defaultHinge`).
    /// The iPhone Duo folds across its long side, so that is the only orientation accepted.
    static func validated(_ reported: CGRect?, full: CGSize) -> CGRect? {
        guard let raw = reported, full.width > 1, full.height > 1 else { return nil }
        let r = raw.standardized
        guard r.minX.isFinite, r.minY.isFinite, r.width.isFinite, r.height.isFinite else { return nil }
        let portrait = full.height >= full.width
        let long = portrait ? full.height : full.width          // the axis the fold divides
        let cross = portrait ? full.width : full.height         // the axis the fold runs along
        let thickness = portrait ? r.height : r.width
        let span = portrait ? r.width : r.height
        let mid = portrait ? r.midY : r.midX
        guard thickness <= min(80, long * 0.1),                 // a crease, not a whole panel
              span >= cross * 0.8,                              // runs across the display
              abs(mid - long / 2) <= long * 0.15                // near the middle
        else { return nil }
        let bounds = CGRect(origin: .zero, size: full)
        guard bounds.intersects(r) || thickness == 0 else { return nil }
        return r
    }

    /// Fallback when a posture is known but no region is reported: a thin band across the
    /// middle of the longer side.
    static func defaultHinge(full: CGSize) -> CGRect {
        if full.height >= full.width {
            return CGRect(x: 0, y: full.height / 2 - 12, width: full.width, height: 24)
        }
        return CGRect(x: full.width / 2 - 12, y: 0, width: 24, height: full.height)
    }
}

/// #3b iPhone Duo: the app covers the whole display. The Duo keeps its clock / battery in a
/// column on the trailing edge, reported as a horizontal safe-area inset (about a fifth of the
/// width), so screens that honoured the safe area left that strip empty. On the Duo the status
/// bar is hidden (as in games: the system then shows only its small battery pill) and the
/// horizontal safe area is ignored. Regular iPhones and iPads are unchanged.
struct DuoFullScreen: ViewModifier {
    let active: Bool
    func body(content: Content) -> some View {
        content
            .ignoresSafeArea(.container, edges: active ? .horizontal : [])
            .statusBarHidden(active ? true : false)
    }
}

extension OuterDisplay {
    /// The current window belongs to an iPhone Duo (either display), whatever the safe area.
    static func duoWindow(hingeKnown: Bool, posture: FoldPosture) -> Bool {
        isPhone && isDuo(hingeKnown: hingeKnown, posture: posture, windowSize: EmulatorView.keyWindowSize)
    }
    /// Trailing room kept free at the top for the Duo's battery pill (the outer display shows it
    /// in the top-right corner once the status bar is hidden).
    static func pillClearance(duo: Bool) -> CGFloat {
        duo && looksLikeOuter(EmulatorView.keyWindowSize) ? 46 : 0
    }
}

extension View {
    /// See DuoFullScreen.
    func duoFullScreen(_ active: Bool) -> some View { modifier(DuoFullScreen(active: active)) }

    func observeHingePosture(_ posture: Binding<FoldPosture>, angle: Binding<Double?>? = nil) -> some View {
        modifier(HingePostureObserver(posture: posture, angle: angle))
    }
}


/// iPhone Duo outer display: when Game Boy family games use the full-bleed classic shell.
/// Pure logic (no UIKit), unit-tested.
enum OuterDisplay {
    /// The outer display is 466x678pt (either orientation); the inner one is 669x951pt, so the
    /// window size alone tells the two apart, whatever the hinge reports (tent / half-folded
    /// with the outer screen in use).
    static func looksLikeOuter(_ size: CGSize) -> Bool {
        let a = min(size.width, size.height), b = max(size.width, size.height)
        return (440...500).contains(a) && (640...720).contains(b)
    }

    /// The inner (unfolded) display: 669x951pt, either orientation.
    static func looksLikeInner(_ size: CGSize) -> Bool {
        let a = min(size.width, size.height), b = max(size.width, size.height)
        return (640...700).contains(a) && (920...990).contains(b)
    }

    /// Running on an iPhone Duo: the hinge is reported, or the window has one of its two display
    /// sizes (no other iPhone has them; 17 Pro Max is 440x956).
    static func isDuo(hingeKnown: Bool, posture: FoldPosture, windowSize: CGSize) -> Bool {
        hingeKnown || posture != .flat || looksLikeOuter(windowSize) || looksLikeInner(windowSize)
    }

    /// The app is on the outer display: hinge reports closed, or the device has a hinge and the
    /// window has the outer display's size (tent / folded-back postures).
    static func isActive(posture: FoldPosture, hingeKnown: Bool, windowSize: CGSize) -> Bool {
        posture == .closed || (hingeKnown && looksLikeOuter(windowSize))
    }

    /// Classic shell: GB / GBC / GBA on the outer display, landscape or portrait. The shell is
    /// used even with a controller connected (the on-screen buttons are then just not drawn).
    /// DS keeps its own behaviour (lid).
    static func usesClassicShell(system: GameSystem, outer: Bool, size: CGSize) -> Bool {
        system != .ds && outer && size.width > 0 && size.height > 0
    }
}
