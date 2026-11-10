// Copyright (c) 2026 Charlie Rodriguez Garcia. All rights reserved.
import Foundation
import GameController

/// Something a physical controller input can be mapped to.
enum PadAction: String, Codable, CaseIterable, Identifiable {
    case a, b, x, y, l, r, z, start, select, up, down, left, right
    case fastForward, quickSave, quickLoad, saveSlots, pauseMenu, screenMode, peekScreen
    var id: String { rawValue }

    /// Start/Select are hardware button names and stay in English ("Select" is also a verb key).
    var label: String { self == .start || self == .select ? englishLabel : englishLabel.loc }
    /// English source text (the String Catalog key).
    var englishLabel: String {
        switch self {
        case .a: return "A"
        case .b: return "B"
        case .x: return "X"
        case .y: return "Y"
        case .l: return "L"
        case .r: return "R"
        case .z: return "Z"
        case .start: return "Start"
        case .select: return "Select"
        case .up: return "Up"
        case .down: return "Down"
        case .left: return "Left"
        case .right: return "Right"
        case .fastForward: return "Fast-forward (hold)"
        case .quickSave: return "Quick save (slot 1)"
        case .quickLoad: return "Quick load (slot 1)"
        case .saveSlots: return "Open save slots"
        case .pauseMenu: return "Open pause menu"
        case .screenMode: return "Screen mode (both / top / bottom)"
        case .peekScreen: return "Show hidden screen (hold)"
        }
    }

    /// The DS button this action presses, if it is one.
    var dsButton: DSButton? {
        switch self {
        case .a: return .a
        case .b: return .b
        case .x: return .x
        case .y: return .y
        case .l: return .l
        case .r: return .r
        case .z: return .z
        case .start: return .start
        case .select: return .select
        case .up: return .up
        case .down: return .down
        case .left: return .left
        case .right: return .right
        default: return nil
        }
    }
}

/// Input element identifiers: GameController element names, with ".up/.down/.left/.right"
/// appended for directional pads and thumbsticks (e.g. "Direction Pad.up").
enum PadElement {
    static func dir(_ pad: String, _ d: String) -> String { "\(pad).\(d)" }
    /// Virtual element: two fingers on the DualSense / DualShock touchpad.
    static let touchpadTwoFinger = "Touchpad Two-Finger Tap"
    /// Elements that open the pause menu even in profiles saved before this option existed.
    static let pauseDefaults = [GCInputDualShockTouchpadButton, GCInputButtonShare, touchpadTwoFinger]

    /// Human-readable name for the remapping screen.
    static func displayName(_ id: String) -> String {
        let parts = id.split(separator: ".")
        if parts.count == 2 {
            let arrow: String
            switch parts[1] {
            case "up": arrow = "↑"
            case "down": arrow = "↓"
            case "left": arrow = "←"
            default: arrow = "→"
            }
            return "\(parts[0]) \(arrow)"
        }
        return id
    }
}

/// One controller's mapping (element id -> action). Many elements may share an action.
struct ControllerProfile: Codable, Equatable {
    var map: [String: PadAction]

    /// Default: DS face buttons by position (A right, B bottom, X top, Y left), shoulders and
    /// triggers to L/R, Menu = Start, Options = Select, D-pad and left stick = directions,
    /// right-stick click = fast-forward, left-stick click = screen mode.
    static var standard: ControllerProfile {
        var m: [String: PadAction] = [
            GCInputButtonB: .a, GCInputButtonA: .b, GCInputButtonY: .x, GCInputButtonX: .y,
            GCInputLeftShoulder: .l, GCInputLeftTrigger: .l, GCInputRightShoulder: .r, GCInputRightTrigger: .r,
            GCInputButtonMenu: .start, GCInputButtonOptions: .select,
            GCInputRightThumbstickButton: .fastForward,
            GCInputLeftThumbstickButton: .screenMode,
            GCInputDualShockTouchpadButton: .pauseMenu, GCInputButtonShare: .pauseMenu,
            PadElement.touchpadTwoFinger: .pauseMenu,
        ]
        for pad in [GCInputDirectionPad, GCInputLeftThumbstick] {
            m[PadElement.dir(pad, "up")] = .up; m[PadElement.dir(pad, "down")] = .down
            m[PadElement.dir(pad, "left")] = .left; m[PadElement.dir(pad, "right")] = .right
        }
        return ControllerProfile(map: m)
    }

    func elements(for action: PadAction) -> [String] {
        map.filter { $0.value == action }.map(\.key).sorted()
    }

    /// Assigns an element to an action (an element drives one action at a time).
    mutating func assign(_ element: String, to action: PadAction) { map[element] = action }
    mutating func clear(_ action: PadAction) { map = map.filter { $0.value != action } }

    /// Resolves pressed elements into DS buttons and shortcut actions.
    func resolve(_ pressed: Set<String>) -> (buttons: DSButton, actions: Set<PadAction>) {
        var b: DSButton = []
        var acts = Set<PadAction>()
        for e in pressed {
            guard let a = map[e] else { continue }
            if let d = a.dsButton { b.insert(d) } else { acts.insert(a) }
        }
        return (b, acts)
    }
}

/// Saves one profile per controller model (keyed by its vendor name / category).
final class ControllerProfileStore {
    static let shared = ControllerProfileStore()
    private let key = "controllerProfiles.v1"
    private var profiles: [String: ControllerProfile]

    init() {
        if let data = UserDefaults.standard.data(forKey: key),
           let p = try? JSONDecoder().decode([String: ControllerProfile].self, from: data) {
            profiles = p
        } else {
            profiles = [:]
        }
    }

    func profile(for id: String) -> ControllerProfile { profiles[id] ?? .standard }

    func set(_ profile: ControllerProfile, for id: String) {
        profiles[id] = profile
        if let data = try? JSONEncoder().encode(profiles) { UserDefaults.standard.set(data, forKey: key) }
    }

    func reset(_ id: String) { set(.standard, for: id) }
}
