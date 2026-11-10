// Copyright (c) 2026 Charlie Rodriguez Garcia. All rights reserved.
import Foundation

/// #13 RetroAchievements rules that do not need the network (pure, unit-tested).
enum RetroAchievementsRules {
    static let usernameKey = "ra.username"
    static let hardcoreKey = "ra.hardcore"            // Bool, default off (softcore)
    static let enabledKey = "ra.enabled"              // Bool, default on once signed in

    /// rcheevos console id: GB/GBC/GBA first, DS through the DS core's memory hook.
    static func console(for system: GameSystem) -> Int {
        switch system {
        case .gb: return 4
        case .gbc: return 6
        case .gba: return 5
        case .nes: return 7
        case .snes: return 3
        case .n64: return 2
        case .n3ds: return 62
        case .ds: return 18
        }
    }

    /// Hardcore follows RetroAchievements' rules: no cheats, no loading save states (saving is
    /// fine), no slow motion. Softcore allows everything.
    static func allowsCheats(hardcore: Bool) -> Bool { !hardcore }
    static func allowsLoadingStates(hardcore: Bool) -> Bool { !hardcore }

    /// Usernames are 2-20 letters / digits; the password is never stored, only checked non-empty.
    static func canSignIn(username: String, password: String) -> Bool {
        let u = username.trimmingCharacters(in: .whitespaces)
        return (2...20).contains(u.count) && u.allSatisfy { $0.isLetter || $0.isNumber } && !password.isEmpty
    }

    static var hardcore: Bool { UserDefaults.standard.bool(forKey: hardcoreKey) }
}
