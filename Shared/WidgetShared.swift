// Copyright (c) 2026 Charlie Rodriguez Garcia. All rights reserved.
// Shared by the app and the TwinPlay Games widget: the small library snapshot the app writes into the
// App Group, the ordering of the widget's three modes, and the deep links. No ROM data, no network.
import Foundation

enum WidgetShared {
    static let appGroup = "group.com.charlierodriguez.nduo"
    static let widgetKind = "NDUOGames"
    static let urlScheme = "nduo"
    static let snapshotFile = "widget-snapshot.json"
    static let thumbsFolder = "WidgetThumbs"

    /// The App Group folder, or nil when the group is not provisioned (then the widget shows its
    /// empty state and the app simply skips writing; nothing else depends on it).
    static var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)
    }
    static var snapshotURL: URL? { containerURL?.appendingPathComponent(snapshotFile) }
    static var thumbsURL: URL? { containerURL?.appendingPathComponent(thumbsFolder, isDirectory: true) }

    /// nduo://open?id=<rom file name> starts that game; nduo://library opens the library.
    static func openURL(for id: String) -> URL {
        var c = URLComponents()
        c.scheme = urlScheme; c.host = "open"; c.queryItems = [URLQueryItem(name: "id", value: id)]
        return c.url!
    }
    static let libraryURL = URL(string: "\(urlScheme)://library")!

    /// The game id (ROM file name) a deep link asks for, nil for the library or a foreign URL.
    static func gameID(from url: URL) -> String? {
        guard url.scheme == urlScheme, url.host == "open" else { return nil }
        return URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "id" }?.value
    }
}

/// What the widget shows ("Show" option on the widget).
enum WidgetMode: String, Codable, CaseIterable {
    case recent, favorites, mostPlayed
}

/// One game as the widget sees it.
struct WidgetGame: Codable, Hashable, Identifiable {
    var id: String              // ROM file name (stable key, also used in the deep link)
    var name: String
    var system: String          // "ds", "gba", "gb", "gbc"
    var playCount: Int
    var lastPlayed: Date?
    var playSeconds: Double
    var favorite: Bool
    var added: Date
    var thumb: String?          // file name in the App Group's WidgetThumbs folder

    /// Short console label.
    var systemLabel: String {
        switch system {
        case "gba": return "GBA"
        case "gb": return "GB"
        case "gbc": return "GBC"
        case "nes": return "NES"
        case "snes": return "SNES"
        default: return "DS"
        }
    }
}

struct WidgetSnapshot: Codable, Equatable {
    var games: [WidgetGame]

    static let empty = WidgetSnapshot(games: [])

    /// The games a mode shows, best first.
    /// - Recent: last played first; games never played follow, newest added first.
    /// - Favorites: starred games only, last played first, then by name.
    /// - Most Played: most play time first, then most launches, then name.
    func top(_ mode: WidgetMode, limit: Int) -> [WidgetGame] {
        let byName: (WidgetGame, WidgetGame) -> Bool = { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        let sorted: [WidgetGame]
        switch mode {
        case .recent:
            sorted = games.sorted { a, b in
                switch (a.lastPlayed, b.lastPlayed) {
                case let (x?, y?): return x != y ? x > y : byName(a, b)
                case (.some, nil): return true
                case (nil, .some): return false
                case (nil, nil): return a.added != b.added ? a.added > b.added : byName(a, b)
                }
            }
        case .favorites:
            sorted = games.filter(\.favorite).sorted { a, b in
                let x = a.lastPlayed ?? .distantPast, y = b.lastPlayed ?? .distantPast
                return x != y ? x > y : byName(a, b)
            }
        case .mostPlayed:
            sorted = games.sorted { a, b in
                if a.playSeconds != b.playSeconds { return a.playSeconds > b.playSeconds }
                if a.playCount != b.playCount { return a.playCount > b.playCount }
                return byName(a, b)
            }
        }
        return Array(sorted.prefix(limit))
    }

    static func load() -> WidgetSnapshot {
        guard let url = WidgetShared.snapshotURL, let data = try? Data(contentsOf: url),
              let s = try? JSONDecoder.widget.decode(WidgetSnapshot.self, from: data) else { return .empty }
        return s
    }
}

extension JSONEncoder {
    static var widget: JSONEncoder {
        let e = JSONEncoder(); e.dateEncodingStrategy = .secondsSince1970; e.outputFormatting = [.sortedKeys]; return e
    }
}
extension JSONDecoder {
    static var widget: JSONDecoder { let d = JSONDecoder(); d.dateDecodingStrategy = .secondsSince1970; return d }
}
