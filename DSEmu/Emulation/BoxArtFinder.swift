// Copyright (c) 2026 Charlie Rodriguez Garcia. All rights reserved.
import Foundation
import UIKit

/// Finds box art, title screens and in-game snaps for the user's games in the free, public
/// libretro-thumbnails collection (thumbnails.libretro.com, mirrored on GitHub). Nothing is
/// bundled with the app: indexes and images are downloaded on request and cached locally.
/// Games are matched by name (No-Intro naming) with fuzzy matching on the file name, the
/// ROM's built-in title and the cartridge header (title + game code region).
final class BoxArtFinder {
    enum Kind: String, CaseIterable, Identifiable {
        case boxart = "Named_Boxarts", title = "Named_Titles", snap = "Named_Snaps"
        var id: String { rawValue }
        var label: String { englishLabel.loc }
        /// English source text (the String Catalog key).
        var englishLabel: String {
            switch self {
            case .boxart: return "Box art"
            case .title: return "Title screen"
            case .snap: return "Gameplay"
            }
        }
    }

    struct Candidate: Identifiable, Hashable {
        let name: String          // No-Intro style name, without ".png"
        let score: Double
        let url: URL              // primary server
        let mirrorURL: URL        // GitHub mirror
        var id: String { url.absoluteString }
    }

    /// What we know about one game.
    struct Query {
        var names: [String]       // display name, file name, banner title...
        var headerTitle: String?
        var gameCode: String?
        var system: GameSystem
    }

    /// Feature flag. OFF for 1.0: no cover / title-screen downloads and no UI for them. The code
    /// stays so it can come back later by flipping this one constant.
    static let isEnabled = true   // 1.1: free for everyone; fetches only when the user taps

    static let shared = BoxArtFinder()

    private let cacheDir: URL
    private let session: URLSession
    private var indexes: [String: [String]] = [:]
    private let lock = NSLock()

    init() {
        cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BoxArt", isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        let config = URLSessionConfiguration.default
        config.urlCache = URLCache(memoryCapacity: 16 << 20, diskCapacity: 200 << 20,
                                   directory: cacheDir.appendingPathComponent("http", isDirectory: true))
        config.requestCachePolicy = .returnCacheDataElseLoad
        config.timeoutIntervalForRequest = 30
        session = URLSession(configuration: config)
    }

    // MARK: Sources

    private static func systemFolder(_ s: GameSystem) -> String {
        switch s {
        case .ds: return "Nintendo - Nintendo DS"
        case .gba: return "Nintendo - Game Boy Advance"
        case .gb: return "Nintendo - Game Boy"
        case .gbc: return "Nintendo - Game Boy Color"
        case .nes: return "Nintendo - Nintendo Entertainment System"
        case .snes: return "Nintendo - Super Nintendo Entertainment System"
        case .n64: return "Nintendo - Nintendo 64"
        case .n3ds: return "Nintendo - Nintendo 3DS"
        }
    }
    private static func githubRepo(_ s: GameSystem) -> String {
        switch s {
        case .ds: return "Nintendo_-_Nintendo_DS"
        case .gba: return "Nintendo_-_Game_Boy_Advance"
        case .gb: return "Nintendo_-_Game_Boy"
        case .gbc: return "Nintendo_-_Game_Boy_Color"
        case .nes: return "Nintendo_-_Nintendo_Entertainment_System"
        case .snes: return "Nintendo_-_Super_Nintendo_Entertainment_System"
        case .n64: return "Nintendo_-_Nintendo_64"
        case .n3ds: return "Nintendo_-_Nintendo_3DS"
        }
    }
    /// libretro replaces these characters with "_" in file names.
    static func fileSafe(_ name: String) -> String {
        var out = name
        for ch in ["&", "*", "/", ":", "`", "<", ">", "?", "\\", "|", "\""] { out = out.replacingOccurrences(of: ch, with: "_") }
        return out
    }
    private static func pathEscape(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "&+#?"))) ?? s
    }
    static func imageURL(system: GameSystem, kind: Kind, name: String) -> URL {
        URL(string: "https://thumbnails.libretro.com/" + pathEscape(systemFolder(system)) + "/" + kind.rawValue + "/"
            + pathEscape(fileSafe(name)) + ".png")!
    }
    static func mirrorURL(system: GameSystem, kind: Kind, name: String) -> URL {
        URL(string: "https://raw.githubusercontent.com/libretro-thumbnails/" + githubRepo(system) + "/master/" + kind.rawValue + "/"
            + pathEscape(fileSafe(name)) + ".png")!
    }

    // MARK: Index (list of available names), cached for a week

    func index(system: GameSystem, kind: Kind) async throws -> [String] {
        guard Self.isEnabled else { throw URLError(.notConnectedToInternet) }   // disabled: never touch the network
        let key = "\(system.rawValue)-\(kind.rawValue)"
        lock.lock(); let cached = indexes[key]; lock.unlock()
        if let cached { return cached }
        let file = cacheDir.appendingPathComponent(key + ".txt")
        if let attrs = try? FileManager.default.attributesOfItem(atPath: file.path),
           let date = attrs[.modificationDate] as? Date, Date().timeIntervalSince(date) < 7 * 86400,
           let text = try? String(contentsOf: file, encoding: .utf8), !text.isEmpty {
            let list = text.split(separator: "\n").map(String.init)
            lock.lock(); indexes[key] = list; lock.unlock()
            return list
        }
        let url = URL(string: "https://thumbnails.libretro.com/" + Self.pathEscape(Self.systemFolder(system)) + "/" + kind.rawValue + "/")!
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        // NES and Super NES listings are large enough that the directory page sometimes
        // comes back empty. A short list is treated as a failure so the GitHub tree,
        // which has the same names, can answer instead. DS and GBA keep the listing
        // they already use whenever it actually contains the library.
        let listed: [String]
        if let (data, _) = try? await session.data(for: request) {
            listed = Self.parseIndex(String(decoding: data, as: UTF8.self))
        } else {
            listed = []
        }
        let list: [String]
        if listed.count >= 20 {
            list = listed
        } else {
            var treeRequest = URLRequest(url: Self.gitTreeURL(system))
            treeRequest.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            let (data, response) = try await session.data(for: treeRequest)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
            list = Self.parseGitTree(data, prefix: kind.rawValue)
            if list.isEmpty { throw URLError(.cannotParseResponse) }
        }
        try? list.joined(separator: "\n").write(to: file, atomically: true, encoding: .utf8)
        lock.lock(); indexes[key] = list; lock.unlock()
        return list
    }

    static func gitTreeURL(_ system: GameSystem) -> URL {
        URL(string: "https://api.github.com/repos/libretro-thumbnails/" + githubRepo(system) + "/git/trees/master?recursive=1")!
    }

    /// Names from a GitHub git tree (`Named_Boxarts/Game.png` → `Game`).
    static func parseGitTree(_ data: Data, prefix: String) -> [String] {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tree = obj["tree"] as? [[String: Any]] else { return [] }
        let folder = prefix.hasSuffix("/") ? prefix : prefix + "/"
        var out: [String] = []
        for node in tree {
            guard let path = node["path"] as? String, path.hasPrefix(folder), path.hasSuffix(".png") else { continue }
            let name = String(path.dropFirst(folder.count).dropLast(4))
            if !name.isEmpty, !name.contains("/") { out.append(name) }
        }
        return out
    }

    /// Extracts `href="Name.png"` entries from an Apache directory listing.
    static func parseIndex(_ html: String) -> [String] {
        var out: [String] = []
        var rest = html[...]
        while let r = rest.range(of: "href=\"") {
            rest = rest[r.upperBound...]
            guard let end = rest.firstIndex(of: "\"") else { break }
            let href = String(rest[..<end])
            rest = rest[end...]
            guard href.hasSuffix(".png"), !href.contains("/"), !href.hasPrefix("?") else { continue }
            let decoded = href.removingPercentEncoding ?? href
            out.append(String(decoded.dropLast(4)))
        }
        return out
    }

    // MARK: Fuzzy matching

    static func tokens(_ s: String) -> [String] {
        var t = s.lowercased()
        // Drop "(USA)", "[!]" and similar tags.
        while let open = t.firstIndex(where: { $0 == "(" || $0 == "[" }) {
            let close: Character = t[open] == "(" ? ")" : "]"
            if let end = t[open...].firstIndex(of: close) { t.removeSubrange(open...end) } else { t.removeSubrange(open...); break }
        }
        t = t.replacingOccurrences(of: "&", with: " and ").replacingOccurrences(of: "é", with: "e")
        let words = t.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        return words.filter { $0 != "the" }
    }

    static func regionTag(gameCode: String?) -> String? {
        guard let c = gameCode?.last else { return nil }
        switch c {
        case "E": return "(USA"
        case "P", "D", "F", "S", "I", "U": return "(Europe"
        case "J": return "(Japan"
        case "K": return "(Korea"
        default: return nil
        }
    }

    /// NES and Super NES have no regionful product code. "(USA)" / "(Rev 1)" live in the file name.
    static func regionFromNames(_ names: [String]) -> String? {
        let blob = names.joined(separator: " ").uppercased()
        if blob.contains("(USA") || blob.contains("(US)") || blob.contains("(U)") { return "(USA" }
        if blob.contains("(EUROPE") || blob.contains("(EU)") { return "(Europe" }
        if blob.contains("(JAPAN") || blob.contains("(JP)") { return "(Japan" }
        if blob.contains("(WORLD") { return "(World" }
        return nil
    }

    /// Internal cartridge titles that do not match the No-Intro name on their own.
    static func headerAliases(system: GameSystem, title: String) -> [String] {
        let key = tokens(title).joined()
        let table: [GameSystem: [String: String]] = [
            .snes: [
                "legendofzelda": "Legend of Zelda, The - A Link to the Past",
                "supermarioworld": "Super Mario World",
                "supermetroid": "Super Metroid",
            ],
            .nes: [
                "supermariobros": "Super Mario Bros.",
                "legendofzelda": "Legend of Zelda, The",
                "metroid": "Metroid",
            ],
        ]
        if let name = table[system]?[key] { return [name] }
        return []
    }

    static func score(query: String, candidate: String, region: String?, looseRegion: Bool = false, system: GameSystem = .ds) -> Double {
        let q = tokens(query), c = tokens(candidate)
        guard !q.isEmpty, !c.isEmpty else { return 0 }
        let qs = Set(q), cs = Set(c)
        var s = 2 * Double(qs.intersection(cs).count) / Double(qs.count + cs.count)
        let qc = q.joined(), cc = c.joined()
        if qc == cc { s += 0.5 }
        else if qc.count >= 5 && (cc.contains(qc) || qc.contains(cc)) { s = max(s, 0.6) + 0.1 }
        if let region, candidate.contains(region) {
            s += 0.05
        } else if looseRegion, let region {
            let aliases: [String]
            switch region {
            case "(USA": aliases = ["(US)", "(U)", "(JP-US)", "(World)"]
            case "(Europe": aliases = ["(EU)", "(E)"]
            case "(Japan": aliases = ["(JP)", "(JA)"]
            default: aliases = []
            }
            if aliases.contains(where: { candidate.contains($0) }) { s += 0.03 }
        }
        for bad in ["(Beta", "(Proto", "(Demo", "(Sample", "(Kiosk", "(Virtual Console", "(Pirate"] where candidate.contains(bad) { s -= 0.15 }
        if system == .nes || system == .snes {
            if candidate.contains("[") { s -= 0.35 }          // GoodTools hack / bad-dump tags
            if candidate.contains("(19") { s -= 0.12 }        // dated TOSEC-style duplicate
        }
        s -= Double(candidate.count) * 0.0005             // prefer the plain release on ties
        return s
    }

    /// Best matches for a game, highest score first.
    func candidates(for q: Query, kind: Kind, limit: Int = 24) async throws -> [Candidate] {
        let list = try await index(system: q.system, kind: kind)
        let codeRegion = Self.regionTag(gameCode: q.gameCode)
        let region = codeRegion ?? Self.regionFromNames(q.names + [q.headerTitle].compactMap { $0 })
        let loose = codeRegion == nil
        var queries = q.names.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        if let h = q.headerTitle, !h.isEmpty {
            queries.append(h)
            queries.append(contentsOf: Self.headerAliases(system: q.system, title: h))
        }
        var best: [(String, Double)] = []
        best.reserveCapacity(list.count)
        for name in list {
            var s = 0.0
            for query in queries {
                s = max(s, Self.score(query: query, candidate: name, region: region, looseRegion: loose, system: q.system))
            }
            if s > 0.25 { best.append((name, s)) }
        }
        best.sort { $0.1 > $1.1 }
        return best.prefix(limit).map {
            Candidate(name: $0.0, score: $0.1,
                      url: Self.imageURL(system: q.system, kind: kind, name: $0.0),
                      mirrorURL: Self.mirrorURL(system: q.system, kind: kind, name: $0.0))
        }
    }

    /// Downloads one image (primary server, then the GitHub mirror). Cached by URLCache.
    func image(for c: Candidate) async throws -> UIImage {
        guard Self.isEnabled else { throw URLError(.notConnectedToInternet) }
        for url in [c.url, c.mirrorURL] {
            if let (data, response) = try? await session.data(from: url),
               (response as? HTTPURLResponse)?.statusCode == 200, let img = UIImage(data: data) { return img }
        }
        throw URLError(.fileDoesNotExist)
    }

    /// A match good enough to apply without asking ("Find all missing").
    static let autoApplyScore = 1.0

    /// Loads a gameplay snap (then a title screen) for the featured library card.
    /// Tries the exact No-Intro file name first, then a fuzzy match. Cached on disk.
    /// Never throws into the UI; returns nil so the caller can fall back to box art.
    func featuredImage(for query: Query) async -> UIImage? {
        var names: [String] = []
        var seen = Set<String>()
        for raw in query.names {
            let n = Self.fileSafe(raw.trimmingCharacters(in: .whitespacesAndNewlines))
            if !n.isEmpty, seen.insert(n).inserted { names.append(n) }
        }
        for kind in [Kind.snap, Kind.title] {
            for name in names {
                if let img = await imageIfPresent(system: query.system, kind: kind, name: name) {
                    return img
                }
            }
        }
        for kind in [Kind.snap, Kind.title] {
            guard let best = try? await candidates(for: query, kind: kind, limit: 4).first, best.score >= 0.55 else { continue }
            if let img = try? await image(for: best) { return img }
        }
        return nil
    }

    /// Direct fetch of one named thumbnail, using the on-disk file cache first.
    private func imageIfPresent(system: GameSystem, kind: Kind, name: String) async -> UIImage? {
        let file = cacheDir.appendingPathComponent("featured-\(system.rawValue)-\(kind.rawValue)-\(name).png")
        if let img = UIImage(contentsOfFile: file.path) { return img }
        let primary = Self.imageURL(system: system, kind: kind, name: name)
        let mirror = Self.mirrorURL(system: system, kind: kind, name: name)
        for url in [primary, mirror] {
            var request = URLRequest(url: url)
            request.timeoutInterval = 20
            guard let (data, response) = try? await session.data(for: request),
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  let img = UIImage(data: data) else { continue }
            try? data.write(to: file, options: .atomic)
            return img
        }
        return nil
    }
}
