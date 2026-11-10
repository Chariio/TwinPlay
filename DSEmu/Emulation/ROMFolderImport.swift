// Copyright (c) 2026 Charlie Rodriguez Garcia. All rights reserved.
import CryptoKit
import Foundation

/// A folder the user picked in Files (iOS only lets an app see folders the user chooses).
/// TwinPlay keeps a bookmark to it, scans it and every subfolder for games, imports the new ones
/// and skips the ones it already has. Rescans happen only when the user asks.
enum ROMFolder {
    static let bookmarkKey = "romFolderBookmark"
    static let promptedKey = "romFolderPrompted"
    static let nameKey = "romFolderName"

    static var folderName: String? { UserDefaults.standard.string(forKey: nameKey) }
    static var hasFolder: Bool { UserDefaults.standard.data(forKey: bookmarkKey) != nil }

    /// Remembers a folder URL returned by the document picker (call while its scope is open).
    static func remember(_ url: URL) throws {
        let data = try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        UserDefaults.standard.set(data, forKey: bookmarkKey)
        UserDefaults.standard.set(url.lastPathComponent, forKey: nameKey)
    }

    /// The remembered folder, refreshing a stale bookmark. nil if it is gone.
    static func resolve() -> URL? {
        guard let data = UserDefaults.standard.data(forKey: bookmarkKey) else { return nil }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &stale) else { return nil }
        if stale {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            try? remember(url)
        }
        return url
    }

    static func forget() {
        UserDefaults.standard.removeObject(forKey: bookmarkKey)
        UserDefaults.standard.removeObject(forKey: nameKey)
    }

    /// Every .nds/.gba/.gb/.gbc under `root`, in subfolders too (hidden files and packages skipped).
    static func findROMs(in root: URL) -> [URL] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey]
        guard let en = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys,
                                                      options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        var out: [URL] = []
        for case let url as URL in en {
            guard ROMLibrary.romExtensions.contains(url.pathExtension.lowercased()),
                  (try? url.resourceValues(forKeys: Set(keys)))?.isRegularFile == true else { continue }
            out.append(url)
        }
        return out.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    /// Identity of a game file: its size plus a SHA-256 of the first MiB (headers + code), so
    /// the same game under another name is still recognised. Reads at most 1 MiB.
    static func fingerprint(_ url: URL) -> String? {
        guard let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size > 0,
              let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        let head = (try? h.read(upToCount: 1 << 20)) ?? Data()
        let digest = SHA256.hash(data: head).map { String(format: "%02x", $0) }.joined()
        return "\(size)-\(digest)"
    }

    struct Plan: Equatable {
        /// Source file and the name it gets in the library.
        var imports: [Item] = []
        var duplicates = 0
        struct Item: Equatable { var source: URL; var name: String }
    }

    /// Decides what to copy. A file is skipped if the library (or an earlier file in this scan)
    /// already has the same content; a different game with a taken name gets "Name (2).ext".
    static func plan(found: [URL], existing: [URL], fingerprint fp: (URL) -> String? = fingerprint) -> Plan {
        var plan = Plan()
        var known = Set(existing.compactMap(fp))
        var names = Set(existing.map { $0.lastPathComponent.lowercased() })
        for url in found {
            guard let f = fp(url) else { continue }
            if known.contains(f) { plan.duplicates += 1; continue }
            known.insert(f)
            let base = url.deletingPathExtension().lastPathComponent, ext = url.pathExtension
            var name = url.lastPathComponent, n = 2
            while names.contains(name.lowercased()) { name = "\(base) (\(n)).\(ext)"; n += 1 }
            names.insert(name.lowercased())
            plan.imports.append(.init(source: url, name: name))
        }
        return plan
    }
}
