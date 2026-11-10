// Copyright (c) 2026 Charlie Rodriguez Garcia. All rights reserved.
import Foundation

/// Mirrors dscore::Button bit values (Core/include/dscore/Types.hpp).
struct DSButton: OptionSet, Hashable {
    let rawValue: UInt32
    static let a      = DSButton(rawValue: 1 << 0)
    static let b      = DSButton(rawValue: 1 << 1)
    static let select = DSButton(rawValue: 1 << 2)
    static let start  = DSButton(rawValue: 1 << 3)
    static let right  = DSButton(rawValue: 1 << 4)
    static let left   = DSButton(rawValue: 1 << 5)
    static let up     = DSButton(rawValue: 1 << 6)
    static let down   = DSButton(rawValue: 1 << 7)
    static let r      = DSButton(rawValue: 1 << 8)
    static let l      = DSButton(rawValue: 1 << 9)
    static let x      = DSButton(rawValue: 1 << 10)
    static let y      = DSButton(rawValue: 1 << 11)
    /// N64 Z and C buttons, and the 3DS ZL/ZR triggers. Other systems ignore them.
    static let z       = DSButton(rawValue: 1 << 12)
    static let cUp     = DSButton(rawValue: 1 << 13)
    static let cDown   = DSButton(rawValue: 1 << 14)
    static let cLeft   = DSButton(rawValue: 1 << 15)
    static let cRight  = DSButton(rawValue: 1 << 16)
    static let zl      = DSButton(rawValue: 1 << 17)
    static let zr      = DSButton(rawValue: 1 << 18)
}

extension DSButton {
    /// Every single button in a fixed order, with the label printed on the hardware.
    static let named: [(DSButton, String)] = [
        (.up, "↑"), (.down, "↓"), (.left, "←"), (.right, "→"),
        (.a, "A"), (.b, "B"), (.x, "X"), (.y, "Y"), (.l, "L"), (.r, "R"),
        (.z, "Z"), (.zl, "ZL"), (.zr, "ZR"),
        (.cUp, "C↑"), (.cDown, "C↓"), (.cLeft, "C←"), (.cRight, "C→"),
        (.start, "START"), (.select, "SELECT"),
    ]
    /// "A + B" style list of the buttons in the set ("" when empty).
    var names: String { DSButton.named.filter { contains($0.0) }.map(\.1).joined(separator: " + ") }
}

/// #12 Delta-style Hold Buttons. From the in-game menu the player enters selection, taps the
/// on-screen buttons to hold (tapping again un-picks), then confirms: those stay pressed until
/// the player taps one of them again, which releases just that button.
struct HoldButtons: Equatable {
    private(set) var held: DSButton = []
    private(set) var selecting = false
    private(set) var pending: DSButton = []

    /// Buttons shown as pressed on the overlay (the picks while selecting).
    var shown: DSButton { selecting ? pending : held }

    mutating func beginSelecting() { selecting = true; pending = held }
    mutating func confirm() { held = pending; selecting = false; pending = [] }
    mutating func cancel() { selecting = false; pending = [] }
    mutating func releaseAll() { held = []; if selecting { pending = [] } }

    /// Feeds the on-screen buttons going from `old` to `new`; returns what the game should see
    /// from the touch controls. While selecting nothing reaches the game except what is held.
    mutating func touch(from old: DSButton, to new: DSButton) -> DSButton {
        let added = new.subtracting(old)
        if selecting {
            pending.formSymmetricDifference(added)
            return held
        }
        // Tapping a held button lets go of it: it stays down only while the finger is on it.
        held.subtract(added)
        return held.union(new)
    }
}
