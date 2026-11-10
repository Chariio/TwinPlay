// Copyright (c) 2026 Charlie Rodriguez Garcia. All rights reserved.
import SwiftUI
import UIKit

/// What the overlay draws as pressed (fed by the touch layer).
final class PadVisualState: ObservableObject {
    @Published var pressed: DSButton = []
    /// N64 stick / 3DS circle pad, each axis -1...1.
    @Published var stick: CGPoint = .zero
}

/// One UIKit view for every finger on the game: the D-pad, buttons and the DS touch screen.
/// Raw UITouch handling (no SwiftUI gestures): no recognizer delays, true multitouch, and
/// fingers can slide between controls.
struct TouchInputLayer: UIViewRepresentable {
    let session: EmulatorSession
    let pad: TouchPadLayout
    let state: PadVisualState
    var enabled = true

    func makeUIView(context: Context) -> TouchInputUIView {
        let v = TouchInputUIView()
        v.onButtons = { [weak state, weak session] b in session?.setTouchButtons(b); state?.pressed = b }
        v.onAnalog = { [weak state, weak session] x, y in session?.setStick(x: x, y: y); state?.stick = CGPoint(x: CGFloat(x), y: CGFloat(y)) }
        v.onStylus = { [weak session] down, x, y in session?.touch(down: down, x: x, y: y) }
        return v
    }

    func updateUIView(_ v: TouchInputUIView, context: Context) {
        v.apply(layout: pad, enabled: enabled)
    }

    static func dismantleUIView(_ v: TouchInputUIView, coordinator: ()) { v.releaseAll() }
}

/// A light tap for the on-screen chrome buttons (MENU, fast-forward, touch-only, swap), on the
/// same "Haptic feedback" setting as the game buttons.
@MainActor enum ButtonHaptics {
    private static let generator = UIImpactFeedbackGenerator(style: .light)
    static func tap() {
        guard TouchSettings.haptics else { return }
        generator.impactOccurred(intensity: 0.75)
        generator.prepare()
    }
}

final class TouchInputUIView: UIView {
    var onButtons: ((DSButton) -> Void)?
    var onAnalog: ((Float, Float) -> Void)?
    var onStylus: ((Bool, Int, Int) -> Void)?

    private var resolver = PadTouchResolver()
    private var ids: [ObjectIdentifier: Int] = [:]
    private var nextID = 1
    private var lastButtons: DSButton = []
    private var lastAnalog: (Float, Float) = (0, 0)
    private var stylusDown = false
    private var lastStylus: (Int, Int)?
    private var enabled = true
    private let impact = UIImpactFeedbackGenerator(style: .light)
    private let cursor = CAShapeLayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isMultipleTouchEnabled = true
        isExclusiveTouch = false
        backgroundColor = .clear
        cursor.fillColor = UIColor.clear.cgColor
        cursor.strokeColor = UIColor.white.cgColor
        cursor.lineWidth = 1.5
        cursor.shadowColor = UIColor.black.cgColor
        cursor.shadowOpacity = 0.8
        cursor.shadowRadius = 1
        cursor.shadowOffset = .zero
        cursor.isHidden = true
        cursor.actions = ["position": NSNull(), "hidden": NSNull(), "path": NSNull()]   // no animation lag
        layer.addSublayer(cursor)
        accessibilityLabel = String(localized: "Game controls")
    }

    required init?(coder: NSCoder) { fatalError() }

    func apply(layout: TouchPadLayout, enabled: Bool) {
        if !enabled { releaseAll() }
        self.enabled = enabled
        let hadStylus = resolver.stylusFinger != nil
        resolver.setLayout(layout)
        if hadStylus && resolver.stylusFinger == nil { liftStylus() }
        publish()
    }

    func releaseAll() {
        resolver.reset(); ids.removeAll()
        liftStylus()
        publish()
    }

    // Only claim touches we can use: elsewhere (empty background) they still reach us, which
    // is harmless, but the top bar sits above this view in SwiftUI and keeps its own taps.
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard enabled else { return }
        var newPress = false
        for t in touches {
            let id = nextID; nextID += 1
            ids[ObjectIdentifier(t)] = id
            let p = t.location(in: self)
            if resolver.began(id, at: p) { stylus(at: p) } else { newPress = true }
        }
        if newPress { impact.prepare() }
        publish()
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard enabled else { return }
        for t in touches {
            guard let id = ids[ObjectIdentifier(t)] else { continue }
            if resolver.isStylus(id) {
                // Every sample the screen took since the last frame, for smooth, exact strokes.
                let samples = event?.coalescedTouches(for: t) ?? [t]
                for s in samples { stylus(at: s.location(in: self)) }
            } else {
                resolver.moved(id, to: t.location(in: self))
            }
        }
        publish()
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { finish(touches) }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { finish(touches) }

    private func finish(_ touches: Set<UITouch>) {
        for t in touches {
            guard let id = ids.removeValue(forKey: ObjectIdentifier(t)) else { continue }
            if resolver.isStylus(id) { liftStylus() }
            resolver.ended(id)
        }
        publish()
    }

    private func stylus(at p: CGPoint) {
        guard let rect = resolver.layout.stylus else { return }
        let c = StylusMapper.map(p, in: rect, raise: TouchSettings.stylusOffset)
        if !stylusDown || lastStylus.map({ $0 != c }) ?? true { onStylus?(true, c.x, c.y) }
        stylusDown = true; lastStylus = c
        if TouchSettings.stylusCursor {
            let q = StylusMapper.point(x: c.x, y: c.y, in: rect)
            let path = UIBezierPath()
            path.append(UIBezierPath(ovalIn: CGRect(x: -5, y: -5, width: 10, height: 10)))
            path.move(to: CGPoint(x: -9, y: 0)); path.addLine(to: CGPoint(x: -6, y: 0))
            path.move(to: CGPoint(x: 6, y: 0)); path.addLine(to: CGPoint(x: 9, y: 0))
            path.move(to: CGPoint(x: 0, y: -9)); path.addLine(to: CGPoint(x: 0, y: -6))
            path.move(to: CGPoint(x: 0, y: 6)); path.addLine(to: CGPoint(x: 0, y: 9))
            cursor.path = path.cgPath
            cursor.position = q
            cursor.isHidden = false
        }
    }

    private func liftStylus() {
        if stylusDown { onStylus?(false, lastStylus?.0 ?? 0, lastStylus?.1 ?? 0) }
        stylusDown = false; lastStylus = nil
        cursor.isHidden = true
    }

    private func publish() {
        let b = resolver.pressed
        let a = resolver.analog
        if a != lastAnalog { lastAnalog = a; onAnalog?(a.0, a.1) }
        guard b != lastButtons else { return }
        if TouchSettings.haptics && PressHaptic.shouldBuzz(from: lastButtons, to: b) {
            impact.impactOccurred(intensity: 0.75)
            impact.prepare()
        }
        lastButtons = b
        onButtons?(b)
    }
}
