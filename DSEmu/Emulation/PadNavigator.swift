// Copyright (c) 2026 Charlie Rodriguez Garcia. All rights reserved.
// Controller navigation for the app's menus (library, sheets, pause menu). It polls every
// connected extended gamepad (MFi, Xbox, PlayStation, Switch Pro, Backbone...) once per frame,
// so it never replaces the value handlers the emulator uses while a game runs.
import Combine
import GameController
import SwiftUI
import UIKit

enum PadNav: Equatable { case up, down, left, right, a, b, x, y, l, r, menu }

final class PadNavigator: ObservableObject {
    static let shared = PadNavigator()

    @Published private(set) var connected = false
    /// Button glyph style for hints: "xbox", "playstation", "nintendo" or "generic".
    @Published private(set) var family = "generic"
    /// Navigation events, already filtered to the screen that currently owns the controller.
    let events = PassthroughSubject<(scope: String, event: PadNav), Never>()

    private var scopes: [String] = []
    private var link: CADisplayLink?
    private var held: [PadNav: (since: CFTimeInterval, last: CFTimeInterval)] = [:]
    private let repeatDelay: CFTimeInterval = 0.38, repeatRate: CFTimeInterval = 0.085

    private init() {
        let nc = NotificationCenter.default
        nc.addObserver(forName: .GCControllerDidConnect, object: nil, queue: .main) { [weak self] _ in self?.refresh() }
        nc.addObserver(forName: .GCControllerDidDisconnect, object: nil, queue: .main) { [weak self] _ in self?.refresh() }
        refresh()
    }

    /// The screen on top claims the controller; pop when it goes away.
    func push(_ scope: String) { scopes.removeAll { $0 == scope }; scopes.append(scope) }
    func pop(_ scope: String) { scopes.removeAll { $0 == scope } }
    var top: String? { scopes.last }

    private func refresh() {
        let pads = GCController.controllers().filter { $0.extendedGamepad != nil }
        connected = !pads.isEmpty
        if let c = pads.first {
            let s = ((c.vendorName ?? "") + " " + c.productCategory).lowercased()
            if s.contains("xbox") { family = "xbox" }
            else if s.contains("dualsense") || s.contains("dualshock") || s.contains("playstation") { family = "playstation" }
            else if s.contains("switch") || s.contains("joy-con") || s.contains("nintendo") { family = "nintendo" }
            else { family = "generic" }
        }
        if connected, link == nil {
            let l = CADisplayLink(target: self, selector: #selector(tick)); l.add(to: .main, forMode: .common); link = l
        } else if !connected { link?.invalidate(); link = nil; held = [:] }
    }

    @objc private func tick(_ l: CADisplayLink) {
        var now = Set<PadNav>()
        scrollY = 0
        for c in GCController.controllers() {
            guard let p = c.extendedGamepad else { continue }
            // Menus: the left stick always moves the focus (calibrated); the right stick's
            // horizontal axis does too, and its vertical axis scrolls the page smoothly.
            let cal = StickCalibrationStore.shared.calibration(for: c)
            var st = Set(cal.directions(x: p.leftThumbstick.xAxis.value, y: p.leftThumbstick.yAxis.value, right: false))
            let r = cal.apply(x: p.rightThumbstick.xAxis.value, y: p.rightThumbstick.yAxis.value, right: true)
            if r.x < -cal.dpadThreshold { st.insert("left") }
            if r.x > cal.dpadThreshold { st.insert("right") }
            if abs(r.y) > abs(scrollY) { scrollY = r.y }
            if p.dpad.left.isPressed || st.contains("left") { now.insert(.left) }
            if p.dpad.right.isPressed || st.contains("right") { now.insert(.right) }
            if p.dpad.up.isPressed || st.contains("up") { now.insert(.up) }
            if p.dpad.down.isPressed || st.contains("down") { now.insert(.down) }
            if p.buttonA.isPressed { now.insert(.a) }
            if p.buttonB.isPressed { now.insert(.b) }
            if p.buttonX.isPressed { now.insert(.x) }
            if p.buttonY.isPressed { now.insert(.y) }
            if p.leftShoulder.isPressed || p.leftTrigger.isPressed { now.insert(.l) }
            if p.rightShoulder.isPressed || p.rightTrigger.isPressed { now.insert(.r) }
            if p.buttonMenu.isPressed { now.insert(.menu) }
        }
        let t = l.timestamp
        if scrollY != 0 && !suspended { smoothScroll(by: CGFloat(-scrollY) * 1400 * CGFloat(max(l.targetTimestamp - l.timestamp, 1.0 / 120))) }
        for k in held.keys where !now.contains(k) { held[k] = nil }
        for k in now {
            if let h = held[k] {
                // Only directions repeat while held.
                guard [.up, .down, .left, .right].contains(k), t - h.since >= repeatDelay, t - h.last >= repeatRate else { continue }
                held[k] = (h.since, t); fire(k)
            } else { held[k] = (t, t); fire(k) }
        }
    }

    private var scrollY: Float = 0
    private weak var cachedScroll: UIScrollView?
    private var cachedAt: CFTimeInterval = 0

    /// Scrolls the frontmost scrollable page (pause menu, settings, About, sheets...).
    private func smoothScroll(by dy: CGFloat) {
        let now = CACurrentMediaTime()
        if cachedScroll?.window == nil || now - cachedAt > 0.5 { cachedScroll = Self.frontScrollView(); cachedAt = now }
        guard let sv = cachedScroll else { return }
        let maxY = max(-sv.adjustedContentInset.top, sv.contentSize.height - sv.bounds.height + sv.adjustedContentInset.bottom)
        let y = min(max(sv.contentOffset.y + dy, -sv.adjustedContentInset.top), maxY)
        sv.setContentOffset(CGPoint(x: sv.contentOffset.x, y: y), animated: false)
    }

    private static func frontScrollView() -> UIScrollView? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard let window = scenes.flatMap(\.windows).first(where: \.isKeyWindow), var vc = window.rootViewController else { return nil }
        while let p = vc.presentedViewController, !p.isBeingDismissed { vc = p }
        var best: UIScrollView?, bestArea: CGFloat = 0
        var queue: [UIView] = [vc.view]
        while !queue.isEmpty {
            let v = queue.removeFirst()
            if v.isHidden || v.alpha < 0.05 { continue }
            if let sv = v as? UIScrollView, sv.isScrollEnabled, sv.contentSize.height > sv.bounds.height + 1 {
                let area = sv.bounds.width * sv.bounds.height
                if area > bestArea { best = sv; bestArea = area }
            }
            queue.append(contentsOf: v.subviews)
        }
        return best
    }

    /// While true (e.g. while remapping a button), no navigation events are sent.
    var suspended = false

    /// Sends an event as if pressed on the controller (unit tests / debugging).
    func inject(_ e: PadNav) { fire(e) }

    private func fire(_ e: PadNav) {
        guard !suspended, let s = top else { return }
        events.send((s, e))
    }

    /// Hint glyph for a face button on the connected controller (positions follow the
    /// GameController framework: A = bottom, B = right, X = left, Y = top).
    func glyph(_ e: PadNav) -> String {
        switch (family, e) {
        case ("playstation", .a): return "xmark.circle"
        case ("playstation", .b): return "circle.circle"
        case ("playstation", .x): return "square.circle"
        case ("playstation", .y): return "triangle.circle"
        case ("nintendo", .a): return "b.circle"      // bottom button is labeled B on Nintendo pads
        case ("nintendo", .b): return "a.circle"
        case ("nintendo", .x): return "y.circle"
        case ("nintendo", .y): return "x.circle"
        case (_, .a): return "a.circle"
        case (_, .b): return "b.circle"
        case (_, .x): return "x.circle"
        case (_, .y): return "y.circle"
        case (_, .l): return "l1.rectangle.roundedbottom"
        case (_, .r): return "r1.rectangle.roundedbottom"
        case (_, .menu): return "line.3.horizontal.circle"
        default: return "dpad"
        }
    }
}

/// Lets a view own the controller while it is on screen and receive its events.
struct PadScope: ViewModifier {
    let scope: String
    let handle: (PadNav) -> Void
    @ObservedObject private var pad = PadNavigator.shared
    func body(content: Content) -> some View {
        content
            .onAppear { pad.push(scope) }
            .onDisappear { pad.pop(scope) }
            .onReceive(pad.events) { ev in if ev.scope == scope { handle(ev.event) } }
    }
}
extension View {
    func padScope(_ scope: String, _ handle: @escaping (PadNav) -> Void) -> some View { modifier(PadScope(scope: scope, handle: handle)) }
}

/// Small bar of button hints, shown only while a controller is connected.
struct ControllerHintBar: View {
    let items: [(PadNav, String)]
    @ObservedObject private var pad = PadNavigator.shared
    var body: some View {
        if pad.connected {
            // Never wraps a label ("Chang e"): falls back to fewer hints, then glyphs only, on narrow screens.
            ViewThatFits(in: .horizontal) {
                row(items, labels: true)
                row(Array(items.prefix(2)) + Array(items.suffix(1)), labels: true)
                row(items, labels: false)
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
            .glassSurface(Capsule())
            .foregroundStyle(.primary)
            .padding(.bottom, 6)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .accessibilityElement(children: .combine)
        }
    }
    private func row(_ list: [(PadNav, String)], labels: Bool) -> some View {
        HStack(spacing: labels ? 14 : 18) {
            ForEach(Array(list.enumerated()), id: \.offset) { _, it in
                HStack(spacing: 4) {
                    Image(systemName: pad.glyph(it.0)).font(.system(size: 15, weight: .semibold))
                    if labels { Text(it.1.loc).font(.caption.weight(.semibold)).lineLimit(1).fixedSize() }
                }
                .accessibilityLabel(Text(it.1.loc))
            }
        }
        .fixedSize()
    }
}

/// Focus ring for controller navigation: scales up and glows.
struct PadFocus: ViewModifier {
    let focused: Bool
    func body(content: Content) -> some View {
        content
            .scaleEffect(focused ? 1.08 : 1)
            .shadow(color: Color.accentColor.opacity(focused ? 0.85 : 0), radius: focused ? 14 : 0)
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.accentColor, lineWidth: focused ? 3 : 0).padding(-4))
            .zIndex(focused ? 1 : 0)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: focused)
    }
}
extension View { func padFocus(_ focused: Bool) -> some View { modifier(PadFocus(focused: focused)) } }
