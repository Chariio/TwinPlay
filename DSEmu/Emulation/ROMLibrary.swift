// Copyright (c) 2026 Charlie Rodriguez Garcia. All rights reserved.
import Foundation
import UIKit
import UniformTypeIdentifiers

/// How a game is drawn in the library.
enum TileStyle: String, CaseIterable, Identifiable, Codable {
    case boxArt, cartridge, titleScreen
    var id: String { rawValue }
    var label: String { englishLabel.loc }
    /// English source text (the String Catalog key).
    var englishLabel: String {
        switch self {
        case .boxArt: return "Box art"
        case .cartridge: return "Cartridge"
        case .titleScreen: return "Title screen"
        }
    }
}

/// Manages the user's own game files (DS .nds and Game Boy Advance .gba), copied into the app's
/// Documents/ROMs folder. The app never ships any game, BIOS, firmware or cover art. Artwork is
/// the icon inside the user's own ROM, an image the user picked, or one the user chose with
/// "Find Box Art" (downloaded on request from the public libretro-thumbnails collection),
/// kept in Documents/Covers.
final class ROMLibrary: ObservableObject {
    struct Entry: Identifiable, Hashable {
        let url: URL
        var id: URL { url }
        var fileName: String { url.deletingPathExtension().lastPathComponent }
        /// Name shown in the library: the user's rename, else the ROM's banner title, else the file name.
        var name: String
        var bannerTitle: String?
        var icon: UIImage?
        var cover: UIImage?
        var dateAdded: Date
        var lastPlayed: Date?
        /// Play statistics (Classic DS Menu card): launches and total seconds in the game.
        var playCount: Int = 0
        var playSeconds: Double = 0
        var favorite: Bool = false
        var system: GameSystem = .ds
        /// Cartridge header title and game code (used to find box art).
        var headerTitle: String?
        var gameCode: String?
        /// Title-screen image (libretro Named_Titles / Named_Snaps), if the user picked one.
        var titleImage: UIImage?
        /// Title screen captured automatically by running the game for a few seconds (TitleScreenGenerator).
        var autoTitleImage: UIImage?
        /// What the "Title screen" style shows: the one the user picked, else the captured one.
        var titleScreen: UIImage? { titleImage ?? autoTitleImage }
        /// Per-game display style (nil = the library's global style).
        var styleOverride: TileStyle?
        /// Cartridge shell color (user choice, else known color for the game, else gray).
        var cartColorOverride: CartColor?
        var cartColor: CartColor { cartColorOverride ?? CartColor.known(gameCode: gameCode, system: system) }

        static func == (a: Entry, b: Entry) -> Bool {
            a.url == b.url && a.name == b.name && a.cover === b.cover && a.icon === b.icon && a.lastPlayed == b.lastPlayed && a.styleOverride == b.styleOverride && a.cartColorOverride == b.cartColorOverride && a.titleImage === b.titleImage && a.autoTitleImage === b.autoTitleImage
                && a.titleImage === b.titleImage && a.styleOverride == b.styleOverride && a.gameCode == b.gameCode
                && a.playCount == b.playCount && a.playSeconds == b.playSeconds && a.favorite == b.favorite && a.system == b.system
        }
        func hash(into h: inout Hasher) { h.combine(url) }
    }

    enum SortOrder: String, CaseIterable, Identifiable {
        case name, recentlyAdded, recentlyPlayed
        var id: String { rawValue }
        var label: String { englishLabel.loc }
        /// English source text (the String Catalog key).
        var englishLabel: String {
            switch self {
            case .name: return "Name"
            case .recentlyAdded: return "Recently added"
            case .recentlyPlayed: return "Recently played"
            }
        }
    }

    /// Per-game metadata kept in Documents/Library.json.
    private struct Meta: Codable {
        var displayName: String?
        var added: Date?
        var lastPlayed: Date?
        var playCount: Int?
        var playSeconds: Double?
        var favorite: Bool?
        var style: TileStyle?
        var cartColor: CartColor?
    }

    static let gbaType = UTType(importedAs: "com.charlie.dsemu.gba-rom", conformingTo: .data)
    static let gbType = UTType(importedAs: "com.charlie.dsemu.gb-rom", conformingTo: .data)
    static let gbcType = UTType(importedAs: "com.charlie.dsemu.gbc-rom", conformingTo: .data)
    static let nesType = UTType(importedAs: "com.charlie.dsemu.nes-rom", conformingTo: .data)
    static let snesType = UTType(importedAs: "com.charlie.dsemu.snes-rom", conformingTo: .data)
    static let n64Type = UTType(importedAs: "com.charlie.dsemu.n64-rom", conformingTo: .data)
    static let n3dsType = UTType(importedAs: "com.charlie.dsemu.3ds-rom", conformingTo: .data)
    static let romExtensions: Set<String> = ["nds", "gba", "gb", "gbc", "nes", "sfc", "smc", "n64", "z64", "v64", "3ds", "cci", "cxi"]
    static let ndsType = UTType(importedAs: "com.charlie.dsemu.nds-rom", conformingTo: .data)

    @Published private(set) var entries: [Entry] = []
    @Published var lastError: String?

    let romsDirectory: URL
    let statesDirectory: URL
    let savesDirectory: URL
    let coversDirectory: URL
    /// Optional user-provided BIOS files (never bundled), e.g. biosnds7.bin.
    let biosDirectory: URL
    private let metaURL: URL
    private var meta: [String: Meta] = [:]
    private var bannerCache: [String: DSROMBanner] = [:]
    private var headerCache: [String: DSROMHeaderInfo] = [:]

    init() {
        var docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        #if DEBUG
        // -TwinPlayLibraryRoot <folder>: DEBUG screenshot aid, uses Documents/<folder> as a separate demo library
        // so store shots never show the device owner's own games. Never set in Release.
        if let alt = UserDefaults.standard.string(forKey: "TwinPlayLibraryRoot"), !alt.isEmpty { docs = docs.appendingPathComponent(alt, isDirectory: true) }
        #endif
        romsDirectory = docs.appendingPathComponent("ROMs", isDirectory: true)
        statesDirectory = docs.appendingPathComponent("States", isDirectory: true)
        savesDirectory = docs.appendingPathComponent("Saves", isDirectory: true)
        biosDirectory = docs.appendingPathComponent("BIOS", isDirectory: true)
        coversDirectory = docs.appendingPathComponent("Covers", isDirectory: true)
        metaURL = docs.appendingPathComponent("Library.json")
        for dir in [romsDirectory, statesDirectory, savesDirectory, biosDirectory, coversDirectory] {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        if let data = try? Data(contentsOf: metaURL), let m = try? JSONDecoder().decode([String: Meta].self, from: data) {
            meta = m
        }
        refresh()
    }

    private func saveMeta() {
        if let data = try? JSONEncoder().encode(meta) { try? data.write(to: metaURL, options: .atomic) }
    }

    func refresh() {
        let files = (try? FileManager.default.contentsOfDirectory(at: romsDirectory, includingPropertiesForKeys: [.creationDateKey])) ?? []
        let roms = files.filter { Self.romExtensions.contains($0.pathExtension.lowercased()) }
        var changed = false
        entries = roms.map { url in
            let key = url.lastPathComponent
            var m = meta[key] ?? Meta()
            if m.added == nil {
                m.added = (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date()
                meta[key] = m; changed = true
            }
            let banner = bannerCache[key]
            let title = banner.map { Self.shortTitle($0.title) }
            let fileName = url.deletingPathExtension().lastPathComponent
            let header = headerCache[key]
            let ext = url.pathExtension.lowercased()
            let system = Self.classify(ext: ext, headerSystem: header.map { Int($0.system) }, headerIsGBA: header?.isGBA)
            let isGBA = system != .ds
            // GBA/GB header titles are short codes ("GBAZELDA MC"); the file name reads better.
            let shown = m.displayName ?? (isGBA ? fileName : (title ?? fileName))
            return Entry(url: url, name: shown, bannerTitle: banner?.title,
                         icon: banner?.icon, cover: loadCover(for: url), dateAdded: m.added ?? Date(), lastPlayed: m.lastPlayed,
                         playCount: m.playCount ?? 0, playSeconds: m.playSeconds ?? 0, favorite: m.favorite ?? false,
                         system: system, headerTitle: header?.title, gameCode: header?.gameCode,
                         titleImage: UIImage(contentsOfFile: titleImageURL(for: url).path),
                         autoTitleImage: UIImage(contentsOfFile: autoTitleURL(for: url).path),
                         styleOverride: m.style, cartColorOverride: m.cartColor)
        }
        if changed { saveMeta() }
        loadMissingBanners(roms)
        publishWidgetSnapshot()
    }

    /// Which system a ROM belongs to (and so which library folder it is filed in).
    /// The extension decides first for .nds, .gba, .nes, .sfc and .smc; .gb/.gbc/.sgb files are
    /// Game Boy Color when the cartridge header's CGB flag (0x143 bit 7) is set, else Game Boy
    /// (with no header yet: by extension). Other extensions fall back to the header.
    /// headerSystem: 0 DS, 1 GBA, 2 GB, 3 GBC, 4 NES, 5 Super NES.
    static func classify(ext rawExt: String, headerSystem: Int?, headerIsGBA: Bool?) -> GameSystem {
        let ext = rawExt.lowercased()
        switch ext {
        case "nds": return .ds
        case "gba": return .gba
        case "nes": return .nes
        case "sfc", "smc": return .snes
        case "n64", "z64", "v64": return .n64
        case "3ds", "cci", "cxi": return .n3ds
        case "gb", "gbc", "sgb":
            switch headerSystem {
            case 3: return .gbc
            case 2: return .gb
            default: return ext == "gbc" ? .gbc : .gb
            }
        default:
            switch headerSystem {
            case 7: return .n3ds
            case 6: return .n64
            case 5: return .snes
            case 4: return .nes
            case 3: return .gbc
            case 2: return .gb
            case 1: return .gba
            default: return (headerIsGBA ?? false) ? .gba : .ds
            }
        }
    }

    /// First line of a banner title ("MARIO KART DS\nNintendo" -> "MARIO KART DS").
    static func shortTitle(_ t: String) -> String {
        t.split(separator: "\n").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? t
    }

    private func loadMissingBanners(_ roms: [URL]) {
        let missing = roms.filter { !bannerTried.contains($0.lastPathComponent) }
        guard !missing.isEmpty, !loadingBanners else { return }
        loadingBanners = true
        for url in missing { bannerTried.insert(url.lastPathComponent) }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var found: [String: DSROMBanner] = [:]
            var headers: [String: DSROMHeaderInfo] = [:]
            for url in missing {
                if let b = DSCoreBridge.banner(forROMAt: url) { found[url.lastPathComponent] = b }
                if let h = DSCoreBridge.headerInfo(forROMAt: url) { headers[url.lastPathComponent] = h }
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.loadingBanners = false
                guard !found.isEmpty || !headers.isEmpty else { return }
                self.bannerCache.merge(found) { a, _ in a }
                self.headerCache.merge(headers) { a, _ in a }
                self.refresh()
            }
        }
    }

    private var loadingBanners = false
    private var bannerTried: Set<String> = []

    /// Games of one system (nil = all), filtered by the search text and sorted.
    func sorted(_ order: SortOrder, search: String, system: GameSystem? = nil) -> [Entry] {
        let q = search.trimmingCharacters(in: .whitespaces)
        let pool = system.map { s in entries.filter { $0.system == s } } ?? entries
        let list = q.isEmpty ? pool : pool.filter {
            $0.name.localizedCaseInsensitiveContains(q) || $0.fileName.localizedCaseInsensitiveContains(q)
                || ($0.bannerTitle?.localizedCaseInsensitiveContains(q) ?? false)
        }
        switch order {
        case .name: return list.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        case .recentlyAdded: return list.sorted { $0.dateAdded > $1.dateAdded }
        case .recentlyPlayed: return list.sorted { ($0.lastPlayed ?? .distantPast) > ($1.lastPlayed ?? .distantPast) }
        }
    }

    /// Copies files picked in the Files app into the library.
    func importFiles(_ urls: [URL]) {
        for source in urls {
            let scoped = source.startAccessingSecurityScopedResource()
            defer { if scoped { source.stopAccessingSecurityScopedResource() } }
            guard Self.romExtensions.contains(source.pathExtension.lowercased()) else {
                lastError = String(localized: "\(source.lastPathComponent) is not a .nds, .gba, .gb or .gbc file")
                continue
            }
            let destination = romsDirectory.appendingPathComponent(source.lastPathComponent)
            do {
                if FileManager.default.fileExists(atPath: destination.path) {
                    try FileManager.default.removeItem(at: destination)
                }
                try FileManager.default.copyItem(at: source, to: destination)
                meta[destination.lastPathComponent, default: Meta()].added = Date()
                bannerCache[destination.lastPathComponent] = nil
                headerCache[destination.lastPathComponent] = nil
                bannerTried.remove(destination.lastPathComponent)
            } catch {
                lastError = String(localized: "Could not import \(source.lastPathComponent): \(error.localizedDescription)")
            }
        }
        saveMeta()
        refresh()
    }

    func delete(_ entry: Entry) {
        try? FileManager.default.removeItem(at: entry.url)
        try? FileManager.default.removeItem(at: coverURL(for: entry.url))
        try? FileManager.default.removeItem(at: titleImageURL(for: entry.url))
        try? FileManager.default.removeItem(at: playSnapshotURL(for: entry.url))
        try? FileManager.default.removeItem(at: autoTitleURL(for: entry.url))
        meta[entry.url.lastPathComponent] = nil
        saveMeta()
        refresh()
    }

    /// Renames the game in the library (display name only; files, saves and states keep their names).
    func rename(_ entry: Entry, to newName: String) {
        let n = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        meta[entry.url.lastPathComponent, default: Meta()].displayName = n.isEmpty ? nil : n
        saveMeta()
        refresh()
    }

    func markPlayed(_ url: URL) {
        meta[url.lastPathComponent, default: Meta()].lastPlayed = Date()
        meta[url.lastPathComponent, default: Meta()].playCount = (meta[url.lastPathComponent]?.playCount ?? 0) + 1
        saveMeta()
        refresh()
    }

    /// Adds time spent in a game (from launch until the emulator closes).
    func addPlayTime(_ url: URL, seconds: Double) {
        guard seconds > 1 else { return }
        meta[url.lastPathComponent, default: Meta()].playSeconds = (meta[url.lastPathComponent]?.playSeconds ?? 0) + seconds
        saveMeta()
        refresh()
    }

    func toggleFavorite(_ entry: Entry) {
        meta[entry.url.lastPathComponent, default: Meta()].favorite = !entry.favorite
        saveMeta()
        refresh()
    }

    // MARK: Covers (user-chosen images only)

    func coverURL(for rom: URL) -> URL {
        coversDirectory.appendingPathComponent(rom.deletingPathExtension().lastPathComponent + ".png")
    }

    /// Title-screen / gameplay picture shown by the "Title screen" style.
    func titleImageURL(for rom: URL) -> URL {
        coversDirectory.appendingPathComponent(rom.deletingPathExtension().lastPathComponent + ".title.png")
    }

    /// Last-played gameplay frame, shown on the library featured card when present.
    func playSnapshotURL(for rom: URL) -> URL {
        coversDirectory.appendingPathComponent(rom.deletingPathExtension().lastPathComponent + ".playsnap.png")
    }

    func playSnapshot(for entry: Entry) -> UIImage? {
        guard let img = UIImage(contentsOfFile: playSnapshotURL(for: entry.url).path),
              PlaySnapshotQuality.isUsable(img) else { return nil }
        return img
    }

    func savePlaySnapshot(_ image: UIImage, for rom: URL) {
        // A blank 3DS Vulkan read of the software FB used to overwrite the card
        // with a black still and hide the real screenshot / box art.
        guard PlaySnapshotQuality.isUsable(image) else { return }
        let maxSide: CGFloat = 1280
        let size = image.size
        let scale = min(1, maxSide / max(size.width, size.height, 1))
        let target = CGSize(width: max(1, size.width * scale), height: max(1, size.height * scale))
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let resized = UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
        if let png = resized.pngData() {
            try? png.write(to: playSnapshotURL(for: rom), options: .atomic)
            Task { @MainActor in FeaturedBackdropStore.shared.invalidate(rom: rom) }
        }
    }

    /// Automatically captured title screen (cache; regenerated by "Refresh title screens").
    func autoTitleURL(for rom: URL) -> URL {
        coversDirectory.appendingPathComponent(rom.deletingPathExtension().lastPathComponent + ".autotitle.png")
    }

    func setAutoTitle(_ image: UIImage, for rom: URL) {
        guard let png = image.pngData() else { return }
        try? png.write(to: autoTitleURL(for: rom), options: .atomic)
        refresh()
    }

    /// Drops the user's chosen title image so the captured one is shown again.
    func clearTitleImage(for entry: Entry) {
        try? FileManager.default.removeItem(at: titleImageURL(for: entry.url))
        refresh()
    }

    private func loadCover(for rom: URL) -> UIImage? { UIImage(contentsOfFile: coverURL(for: rom).path) }

    func setTitleImage(_ image: UIImage, for entry: Entry) {
        guard let png = image.pngData() else { return }
        try? png.write(to: titleImageURL(for: entry.url), options: .atomic)
        refresh()
    }

    /// Per-game display style (nil = follow the global setting).
    func setCartColor(_ c: CartColor?, for entry: Entry) {
        meta[entry.url.lastPathComponent, default: Meta()].cartColor = c
        saveMeta()
        refresh()
    }

    func setStyle(_ style: TileStyle?, for entry: Entry) {
        meta[entry.url.lastPathComponent, default: Meta()].style = style
        saveMeta()
        refresh()
    }

    /// Everything the box-art finder knows about a game.
    func boxArtQuery(for entry: Entry) -> BoxArtFinder.Query {
        var names = [entry.name, entry.fileName]
        if let b = entry.bannerTitle { names.append(Self.shortTitle(b)); names.append(b.replacingOccurrences(of: "\n", with: " ")) }
        return BoxArtFinder.Query(names: names, headerTitle: entry.headerTitle, gameCode: entry.gameCode, system: entry.system)
    }

    /// Stores a user-chosen cover, scaled down to at most 1024 px on the long side.
    func setCover(_ image: UIImage, for entry: Entry) {
        let maxSide: CGFloat = 1024
        let size = image.size
        let scale = min(1, maxSide / max(size.width, size.height, 1))
        let target = CGSize(width: max(1, size.width * scale), height: max(1, size.height * scale))
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let resized = UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
        guard let png = resized.pngData() else { lastError = "Could not read that image"; return }
        do { try png.write(to: coverURL(for: entry.url), options: .atomic) } catch {
            lastError = String(localized: "Could not save the cover: \(error.localizedDescription)")
        }
        refresh()
    }

    func resetCover(for entry: Entry) {
        try? FileManager.default.removeItem(at: coverURL(for: entry.url))
        refresh()
    }

    /// Image search in the browser for the user to pick a cover themselves (never auto-downloaded).
    static func coverSearchURL(for entry: Entry) -> URL? {
        var c = URLComponents(string: "https://www.google.com/search")
        c?.queryItems = [URLQueryItem(name: "tbm", value: "isch"),
                         URLQueryItem(name: "q", value: "\(entry.name) \(entry.system.longName) box art")]
        return c?.url
    }

    // MARK: Other files

    /// Cartridge save (".sav") for a game, in Documents/Saves.
    func saveURL(for rom: URL) -> URL {
        savesDirectory.appendingPathComponent(rom.deletingPathExtension().lastPathComponent + ".sav")
    }

    /// The user's own ARM7 BIOS, if they copied one to Documents/BIOS.
    var arm7BIOSURL: URL? {
        let url = biosDirectory.appendingPathComponent("biosnds7.bin")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
}

// MARK: - Folder import

extension ROMLibrary {
    struct FolderScanResult { var added = 0; var duplicates = 0; var failed = 0; var folderMissing = false }

    /// Scans `folder` (and its subfolders) off the main thread and imports games not in the
    /// library yet. `quiet`: report only when something new was found (launch auto-find).
    func importFolder(_ folder: URL, quiet: Bool = false, completion: ((FolderScanResult) -> Void)? = nil) {
        let romsDir = romsDirectory
        let existing = entries.map(\.url)
        DispatchQueue.global(qos: .userInitiated).async {
            var result = FolderScanResult()
            let scoped = folder.startAccessingSecurityScopedResource()
            defer { if scoped { folder.stopAccessingSecurityScopedResource() } }
            guard FileManager.default.fileExists(atPath: folder.path) else {
                result.folderMissing = true
                DispatchQueue.main.async { self.finishFolderImport(result, [], quiet: quiet, completion) }
                return
            }
            let plan = ROMFolder.plan(found: ROMFolder.findROMs(in: folder), existing: existing)
            result.duplicates = plan.duplicates
            var added: [String] = []
            for item in plan.imports {
                do {
                    try FileManager.default.copyItem(at: item.source, to: romsDir.appendingPathComponent(item.name))
                    added.append(item.name)
                } catch { result.failed += 1 }
            }
            result.added = added.count
            DispatchQueue.main.async { self.finishFolderImport(result, added, quiet: quiet, completion) }
        }
    }

    private func finishFolderImport(_ r: FolderScanResult, _ names: [String], quiet: Bool, _ completion: ((FolderScanResult) -> Void)?) {
        for n in names { meta[n, default: Meta()].added = Date() }
        if !names.isEmpty { saveMeta(); refresh() }
        if r.folderMissing {
            if !quiet { lastError = "The games folder is no longer available. Choose it again in Settings." }
        } else if !quiet || r.added > 0 {
            var msg = r.added == 0 ? String(localized: "No new games found") : r.added == 1 ? String(localized: "Imported 1 new game") : String(localized: "Imported \(r.added) new games")
            if r.duplicates > 0 { msg += " · " + String(localized: "\(r.duplicates) already in the library") }
            if r.failed > 0 { msg += " · " + String(localized: "\(r.failed) could not be copied") }
            lastError = msg + "."
        }
        completion?(r)
    }
}
