// Copyright (c) 2026 Charlie Rodriguez Garcia. All rights reserved.
// Joystick calibration, saved per controller model (vendor/product name): centre offset,
// range per axis and direction, inner/outer deadzone, response curve, sensitivity,
// stick-to-D-pad threshold, invert Y and which stick drives the D-pad.
import Foundation
import GameController

struct StickCalibration: Codable, Equatable {
    struct Axis: Codable, Equatable {
        var center: Float = 0
        var minV: Float = -1      // most negative value seen
        var maxV: Float = 1       // most positive value seen
    }
    enum Curve: String, Codable, CaseIterable { case linear, smooth, aggressive
        var label: String { englishLabel.loc }
        /// English source text (the String Catalog key).
        var englishLabel: String { switch self { case .linear: return "Linear"; case .smooth: return "Smooth (fine control)"; case .aggressive: return "Aggressive (fast)" } }
        var exponent: Float { switch self { case .linear: return 1; case .smooth: return 1.7; case .aggressive: return 0.6 } }
    }
    enum StickUse: String, Codable, CaseIterable { case left, right, both
        var label: String { englishLabel.loc }
        /// English source text (the String Catalog key).
        var englishLabel: String { switch self { case .left: return "Left stick"; case .right: return "Right stick"; case .both: return "Both sticks" } }
    }

    var leftX = Axis(), leftY = Axis(), rightX = Axis(), rightY = Axis()
    var deadzone: Float = 0.15
    var outerDeadzone: Float = 0.05
    var sensitivity: Float = 1.0
    var curve: Curve = .linear
    var dpadThreshold: Float = 0.5
    var invertY = false
    var stickForDpad: StickUse = .left

    static let standard = StickCalibration()

    private static func norm(_ v: Float, _ a: Axis) -> Float {
        let d = v - a.center
        let span = d >= 0 ? max(a.maxV - a.center, 0.2) : max(a.center - a.minV, 0.2)
        return max(-1, min(1, d / span))
    }

    /// Raw stick values to calibrated values (unit circle, deadzones and curve applied).
    func apply(x: Float, y: Float, right: Bool) -> (x: Float, y: Float) {
        var nx = Self.norm(x, right ? rightX : leftX)
        var ny = Self.norm(y, right ? rightY : leftY)
        if invertY { ny = -ny }
        let mag = min(1, (nx * nx + ny * ny).squareRoot())
        guard mag > deadzone, mag > 0 else { return (0, 0) }
        let live = max(0.01, 1 - deadzone - outerDeadzone)
        var m = min(1, (mag - deadzone) / live)
        m = min(1, powf(m, curve.exponent) * sensitivity)
        nx = nx / mag * m; ny = ny / mag * m
        return (nx, ny)
    }

    /// Calibrated direction set ("up", "down", "left", "right") for D-pad emulation.
    func directions(x: Float, y: Float, right: Bool) -> [String] {
        let v = apply(x: x, y: y, right: right)
        var d: [String] = []
        if v.y > dpadThreshold { d.append("up") }
        if v.y < -dpadThreshold { d.append("down") }
        if v.x < -dpadThreshold { d.append("left") }
        if v.x > dpadThreshold { d.append("right") }
        return d
    }

    /// Directions from whichever stick(s) drive the D-pad, for a gamepad.
    func stickDirections(_ p: GCExtendedGamepad) -> Set<String> {
        var s = Set<String>()
        if stickForDpad != .right { s.formUnion(directions(x: p.leftThumbstick.xAxis.value, y: p.leftThumbstick.yAxis.value, right: false)) }
        if stickForDpad != .left { s.formUnion(directions(x: p.rightThumbstick.xAxis.value, y: p.rightThumbstick.yAxis.value, right: true)) }
        return s
    }
}

final class StickCalibrationStore {
    static let shared = StickCalibrationStore()
    private let key = "stickCalibrations"
    private var cache: [String: StickCalibration] = [:]
    private init() {
        if let d = UserDefaults.standard.data(forKey: key), let m = try? JSONDecoder().decode([String: StickCalibration].self, from: d) { cache = m }
    }
    func calibration(for id: String) -> StickCalibration { Store.allows(.stickCalibration) ? (cache[id] ?? .standard) : .standard }
    func calibration(for c: GCController) -> StickCalibration { calibration(for: GameControllerManager.profileID(c)) }
    func set(_ c: StickCalibration?, for id: String) {
        cache[id] = c
        if let d = try? JSONEncoder().encode(cache) { UserDefaults.standard.set(d, forKey: key) }
    }
}
