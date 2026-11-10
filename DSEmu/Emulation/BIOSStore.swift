// Copyright (c) 2026 Charlie Rodriguez Garcia. All rights reserved.
// The user's own BIOS / firmware dumps (optional). Nothing is bundled: files are imported by
// the user, checked by size (and CRC32 against known good dumps) and kept in the app sandbox.
import Foundation

final class BIOSStore: ObservableObject {
    static let shared = BIOSStore()

    enum Kind: String, CaseIterable, Identifiable {
        case ds9 = "bios9.bin", ds7 = "bios7.bin", dsFirmware = "firmware.bin", gba = "gba_bios.bin"
        case gbBoot = "dmg_boot.bin", gbcBoot = "cgb_boot.bin"
        var id: String { rawValue }
        var title: String { englishTitle.loc }
        /// English source text (the String Catalog key).
        var englishTitle: String {
            switch self {
            case .ds9: return "DS ARM9 BIOS"
            case .ds7: return "DS ARM7 BIOS"
            case .dsFirmware: return "DS firmware"
            case .gba: return "GBA BIOS"
            case .gbBoot: return "Game Boy boot ROM"
            case .gbcBoot: return "Game Boy Color boot ROM"
            }
        }
        var sizes: [Int] {
            switch self {
            case .ds9: return [4096]
            case .ds7, .gba: return [16384]
            case .dsFirmware: return [262144, 524288]
            case .gbBoot: return [256]
            case .gbcBoot: return [2304]
            }
        }
        var sizeText: String { self == .dsFirmware ? "256 or 512 KB" : self == .gbBoot ? "256 bytes" : self == .gbcBoot ? "2304 bytes" : (self == .ds9 ? "4 KB" : "16 KB") }
        /// CRC32 of known good dumps (firmware differs per console, so it is size-checked only).
        var knownCRCs: Set<UInt32> {
            switch self {
            case .ds9: return [0x2AB23573]
            case .ds7: return [0x1280F0D5]
            case .gba: return [0x81977335]
            case .gbBoot: return [0x59C8598E]
            case .gbcBoot: return [0x41884E46]
            case .dsFirmware: return []
            }
        }
    }

    struct Info { let size: Int; let crc: UInt32; let verified: Bool }

    @Published private(set) var info: [Kind: Info] = [:]
    /// Master switch ("Use my own BIOS/firmware"). Off = built-in HLE BIOS (default).
    @Published var enabled: Bool { didSet { UserDefaults.standard.set(enabled, forKey: "useOwnBIOS") } }
    /// DS only: start through the firmware boot screen when a firmware file is present.
    @Published var bootFirmware: Bool { didSet { UserDefaults.standard.set(bootFirmware, forKey: "bootFirmware2") } }

    let directory: URL

    private init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        directory = support.appendingPathComponent("SystemFiles", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var dir = directory
        var rv = URLResourceValues(); rv.isExcludedFromBackup = true; try? dir.setResourceValues(rv)
        enabled = UserDefaults.standard.bool(forKey: "useOwnBIOS")
        // Off by default: booting through the firmware menu is experimental (white screen with some dumps).
        bootFirmware = UserDefaults.standard.object(forKey: "bootFirmware2") as? Bool ?? false
        refresh()
    }

    func url(_ k: Kind) -> URL { directory.appendingPathComponent(k.rawValue) }

    func refresh() {
        var m: [Kind: Info] = [:]
        for k in Kind.allCases { if let d = try? Data(contentsOf: url(k)) { m[k] = Self.check(d, as: k) } }
        info = m
    }

    static func crc32(_ d: Data) -> UInt32 {
        var table = [UInt32](repeating: 0, count: 256)
        for i in 0..<256 { var c = UInt32(i); for _ in 0..<8 { c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1 }; table[i] = c }
        var crc: UInt32 = 0xFFFFFFFF
        for b in d { crc = table[Int((crc ^ UInt32(b)) & 0xFF)] ^ (crc >> 8) }
        return crc ^ 0xFFFFFFFF
    }
    static func check(_ d: Data, as k: Kind) -> Info {
        let c = crc32(d)
        return Info(size: d.count, crc: c, verified: k.knownCRCs.contains(c))
    }

    /// Validates and stores an imported file. Returns a message for the user.
    func importFile(_ src: URL, as k: Kind) -> (ok: Bool, message: String) {
        let scoped = src.startAccessingSecurityScopedResource()
        defer { if scoped { src.stopAccessingSecurityScopedResource() } }
        guard let d = Self.readCoordinated(src) else { return (false, String(localized: "Couldn't read that file. If it's in iCloud Drive, open it once in Files so it downloads, then try again.")) }
        guard k.sizes.contains(d.count) else {
            return (false, String(localized: "\(k.title) must be \(k.sizeText.loc); this file is \(ByteCountFormatter.string(fromByteCount: Int64(d.count), countStyle: .binary))."))
        }
        if d.allSatisfy({ $0 == 0 }) || d.allSatisfy({ $0 == 0xFF }) { return (false, String(localized: "That file is empty (all zeros/FFs), not a BIOS dump.")) }
        do { try d.write(to: url(k), options: [.atomic, .completeFileProtection]) } catch { return (false, String(localized: "Couldn't save the file.")) }
        refresh()
        if !enabled { enabled = true }          // importing a file means the user wants to use it
        let i = Self.check(d, as: k)
        let crc = String(format: "%08X", i.crc)
        if k == .dsFirmware { return (true, String(localized: "Firmware saved (CRC32 \(crc)).")) }
        return (true, i.verified ? String(localized: "\(k.title) saved and verified (CRC32 \(crc)).")
                                 : String(localized: "\(k.title) saved, but its CRC32 \(crc) doesn't match a known good dump. It may not work."))
    }

    /// Reads through NSFileCoordinator so iCloud Drive files that aren't downloaded yet are fetched.
    static func readCoordinated(_ url: URL) -> Data? {
        var out: Data?; var err: NSError?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &err) { u in out = try? Data(contentsOf: u) }
        return out ?? (try? Data(contentsOf: url))
    }

    /// Which slot a dump belongs to, from its size, CRC32 and (for unknown 16 KB dumps) its name.
    static func detect(_ d: Data, name: String) -> Kind? {
        let crc = crc32(d), n = name.lowercased()
        if let k = Kind.allCases.first(where: { $0.knownCRCs.contains(crc) }) { return k }
        switch d.count {
        case 4096: return .ds9
        case 16384: return n.contains("gba") || n.contains("agb") ? .gba : (n.contains("7") ? .ds7 : nil)
        case 262144, 524288: return .dsFirmware
        case 256: return .gbBoot
        case 2304: return .gbcBoot
        default: return nil
        }
    }

    /// "Import files…": several files at once, each put in the right slot automatically.
    func importDetected(_ urls: [URL]) -> String {
        var lines: [String] = []
        for u in urls {
            let scoped = u.startAccessingSecurityScopedResource()
            defer { if scoped { u.stopAccessingSecurityScopedResource() } }
            guard let d = Self.readCoordinated(u) else { lines.append(String(localized: "\(u.lastPathComponent): couldn't read it.")); continue }
            guard let k = Self.detect(d, name: u.lastPathComponent) else {
                lines.append(String(localized: "\(u.lastPathComponent): not a BIOS/firmware file TwinPlay recognizes.")); continue
            }
            lines.append("\(u.lastPathComponent): " + importFile(u, as: k).message)
        }
        return lines.joined(separator: "\n")
    }

    func remove(_ k: Kind) { try? FileManager.default.removeItem(at: url(k)); refresh() }

    var dsReady: Bool { info[.ds9] != nil && info[.ds7] != nil }
    var gbaReady: Bool { info[.gba] != nil }

    /// Game Boy: the optional boot ROM (the logo screen) before the game. Without one the core
    /// starts the game directly with the post-boot register state.
    func applyGameBoy(to core: DSCoreBridge, color: Bool) {
        guard enabled, Store.allows(.customBIOS) else { return }
        let kind: Kind = color ? .gbcBoot : .gbBoot
        guard info[kind] != nil, let b = try? Data(contentsOf: url(kind)) else { return }
        _ = core.setLLEBIOS(bios9: b, bios7: nil, firmware: nil, bootFirmware: false)
    }

    /// Hands the files to a core before its game is loaded. HLE stays in place if disabled or incomplete.
    func apply(to core: DSCoreBridge, gba: Bool) {
        guard enabled, Store.allows(.customBIOS) else { return }
        if gba {
            guard gbaReady, let b = try? Data(contentsOf: url(.gba)) else { return }
            _ = core.setLLEBIOS(bios9: b, bios7: nil, firmware: nil, bootFirmware: false)
        } else {
            guard dsReady, let b9 = try? Data(contentsOf: url(.ds9)), let b7 = try? Data(contentsOf: url(.ds7)) else { return }
            let fw = try? Data(contentsOf: url(.dsFirmware))
            _ = core.setLLEBIOS(bios9: b9, bios7: b7, firmware: fw, bootFirmware: bootFirmware && fw != nil)
        }
    }
}
