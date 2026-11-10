// Copyright (c) 2026 Charlie Rodriguez Garcia. All rights reserved.
import Foundation

/// One user-entered cheat. Codes are typed by the user; no cheat database is included.
struct CheatEntry: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var code: String
    var enabled: Bool = true
}

/// Per-game cheat list, stored in UserDefaults under "cheats.<system>.<game code or title>".
enum CheatStore {
    static func coreSystem(_ s: GameSystem) -> String {
        switch s {
        case .ds: return "ds"
        case .gba: return "gba"
        case .nes: return "nes"
        case .snes: return "snes"
        case .n64: return "n64"
        case .n3ds: return "n3ds"
        case .gb, .gbc: return "gb"
        }
    }

    static func key(system: GameSystem, gameCode: String, title: String) -> String {
        let id = gameCode.trimmingCharacters(in: .whitespaces).isEmpty ? title : gameCode
        return "cheats.\(system.rawValue).\(id)"
    }
    static func load(_ key: String, defaults: UserDefaults = .standard) -> [CheatEntry] {
        guard let d = defaults.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([CheatEntry].self, from: d)) ?? []
    }
    static func save(_ list: [CheatEntry], key: String, defaults: UserDefaults = .standard) {
        if list.isEmpty { defaults.removeObject(forKey: key); return }
        if let d = try? JSONEncoder().encode(list) { defaults.set(d, forKey: key) }
    }
    /// Which formats this system accepts (shown in the editor).
    static func formatHint(_ s: GameSystem) -> String {
        switch s {
        case .ds: return String(localized: "Action Replay DS: lines of XXXXXXXX YYYYYYYY.")
        case .gba: return String(localized: "GameShark v1/v2 raw (XXXXXXXX YYYYYYYY) or CodeBreaker raw (XXXXXXXX YYYY). Encrypted codes aren't supported.")
        case .gb, .gbc: return String(localized: "GameShark (01VVAAAA) or Game Genie (ABC-DEF or ABC-DEF-GHI).")
        case .nes, .snes, .n64, .n3ds: return String(localized: "Cheats aren't available for this system yet.")
        }
    }
}
