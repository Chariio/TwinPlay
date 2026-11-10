// Copyright (c) 2026 Charlie Rodriguez Garcia. All rights reserved.
// Per-game settings, chosen once when a game opens. The table is original data
// (product codes and board families only — no ROM bytes). Nothing here runs per frame.
import Foundation

struct GameIdentity: Equatable {
    /// Stable id for the per-game toggle (`twinplay.recommended.<primary>`).
    var primary: String
    /// Lookup order: exact id, then family keys, then the system.
    var keys: [String]
}

struct GameRecommendation: Equatable {
    var scale: Int
    var filter: String
    var frameSkip: String
    /// A table hit. Unknown DS games stay unlocked so the one-shot 3D probe can adjust.
    var locked: Bool
    var is3D: Bool
}

struct GameProfileEntry: Equatable {
    var scale: Int
    var filter: String
    var frameSkip: String
    var is3D: Bool
}

enum GameProfiles {
    static let togglePrefix = "twinplay.recommended."

    static func toggleKey(_ id: String) -> String { togglePrefix + id }

    /// Missing key means on.
    static func isEnabled(_ id: String, defaults: UserDefaults = .standard) -> Bool {
        let key = toggleKey(id)
        if defaults.object(forKey: key) == nil { return true }
        return defaults.bool(forKey: key)
    }

    static func setEnabled(_ id: String, _ on: Bool, defaults: UserDefaults = .standard) {
        defaults.set(on, forKey: toggleKey(id))
    }

    static func parse(_ data: Data) -> [String: GameProfileEntry] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let games = root["games"] as? [String: [String: Any]] else { return [:] }
        var out: [String: GameProfileEntry] = [:]
        for (id, row) in games {
            let scale = (row["scale"] as? Int) ?? (row["scale"] as? NSNumber)?.intValue ?? 1
            let filter = row["filter"] as? String ?? "nearest"
            let skip = row["frameskip"] as? String ?? "off"
            let three = row["threeD"] as? Bool ?? false
            out[id] = GameProfileEntry(scale: min(4, max(1, scale)), filter: filter, frameSkip: skip, is3D: three)
        }
        return out
    }

    private static let bundled: [String: GameProfileEntry] = {
        if let url = Bundle.main.url(forResource: "GameProfiles", withExtension: "json"),
           let data = try? Data(contentsOf: url) {
            let parsed = parse(data)
            if !parsed.isEmpty { return parsed }
        }
        return [:]
    }()

    static func identify(url: URL?, system: GameSystem, gameCode: String) -> GameIdentity {
        let code = gameCode.trimmingCharacters(in: .whitespaces)
        switch system {
        case .ds:
            let id = code.count == 4 ? "ds:\(code)" : "ds:unknown"
            return GameIdentity(primary: id, keys: [id, "ds"])
        case .gba:
            let sum = headerByte(url, 0xBD).map { String(format: "%02X", $0) }
            let id = code.isEmpty ? "gba:unknown" : "gba:\(code)"
            var keys = [id]
            if let sum, !code.isEmpty { keys.insert("gba:\(code):\(sum)", at: 0) }
            keys.append("gba")
            let primary = keys[0]
            return GameIdentity(primary: primary, keys: keys)
        case .gb, .gbc:
            let sum = headerByte(url, 0x14D).map { String(format: "%02X", $0) }
            let prefix = system.rawValue
            let id = code.isEmpty ? "\(prefix):unknown" : "\(prefix):\(code)"
            var keys = [id]
            if let sum { keys.insert("\(prefix):\(sum)", at: 0) }
            keys.append(prefix)
            return GameIdentity(primary: keys[0], keys: keys)
        case .nes:
            let mapper = nesMapper(url)
            let crc = crc32(url: url, skip: 16)
            var keys: [String] = []
            if let crc { keys.append(String(format: "nes:%08X", crc)) }
            if let mapper { keys.append(String(format: "nes:mapper:%d", mapper)) }
            keys.append("nes")
            return GameIdentity(primary: keys[0], keys: keys)
        case .snes:
            let hdr = snesHeader(url)
            let crc = crc32(url: url, skip: snesSkip(url))
            var keys: [String] = []
            if let crc { keys.append(String(format: "snes:%08X", crc)) }
            if let chip = hdr?.chip { keys.append(String(format: "snes:chip:%02X", chip)) }
            if let family = hdr?.family { keys.append("snes:family:\(family)") }
            if let hi = hdr?.hi { keys.append(hi ? "snes:map:hi" : "snes:map:lo") }
            keys.append("snes")
            return GameIdentity(primary: keys[0], keys: keys)
        case .n64, .n3ds:
            let prefix = system.rawValue
            return GameIdentity(primary: prefix, keys: [prefix])
        }
    }

    static func recommend(_ id: GameIdentity, system: GameSystem, table: [String: GameProfileEntry]? = nil) -> GameRecommendation {
        let rows = table ?? bundled
        for key in id.keys {
            if let row = rows[key] {
                return GameRecommendation(scale: row.scale, filter: row.filter, frameSkip: row.frameSkip, locked: true, is3D: row.is3D)
            }
        }
        // Unknown game. 2D systems stay at 1x with a crisp filter and no frameskip.
        // Unknown DS starts at 2x; a one-shot probe drops it if the GPU is never used.
        if system == .ds {
            return GameRecommendation(scale: 2, filter: "sharpBilinear", frameSkip: "off", locked: false, is3D: false)
        }
        return GameRecommendation(scale: 1, filter: "nearest", frameSkip: "off", locked: true, is3D: false)
    }

    // MARK: Headers (a few dozen bytes, once)

    private static func headerByte(_ url: URL?, _ offset: Int) -> UInt8? {
        guard let url, let data = read(url, offset: offset, count: 1), data.count == 1 else { return nil }
        return data[0]
    }

    private static func read(_ url: URL, offset: Int, count: Int) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        try? handle.seek(toOffset: UInt64(offset))
        return try? handle.read(upToCount: count)
    }

    private static func nesMapper(_ url: URL?) -> Int? {
        guard let url, let h = read(url, offset: 0, count: 16), h.count == 16,
              h[0] == 0x4E, h[1] == 0x45, h[2] == 0x53, h[3] == 0x1A else { return nil }
        var mapper = Int(h[6] >> 4) | Int(h[7] & 0xF0)
        if (h[7] & 0x0C) == 0x08 { mapper |= Int(h[8] & 0x0F) << 8 }
        return mapper
    }

    private struct SnesBits { var chip: Int; var family: Int; var hi: Bool }

    private static func snesSkip(_ url: URL?) -> Int {
        guard let url else { return 0 }
        let n = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        return n % 1024 == 512 ? 512 : 0
    }

    /// Same idea as the core's header score, only enough to name the chip. Not used while running.
    private static func snesHeader(_ url: URL?) -> SnesBits? {
        guard let url else { return nil }
        let skip = snesSkip(url)
        guard let file = try? Data(contentsOf: url), file.count > skip + 0x8000 else { return nil }
        let rom = file.dropFirst(skip)
        func score(_ hdr: Int, hi: Bool) -> Int {
            guard hdr + 0x20 < rom.count else { return -100 }
            let base = rom.startIndex
            let map = rom[base + hdr + 0x15]
            let nibble = map & 0x0F
            let speed = map & 0xF0
            var s = 0
            if speed == 0x20 || speed == 0x30 {
                if hi ? (nibble == 1 || nibble == 5) : (nibble == 0 || nibble == 2 || nibble == 3) { s += 6 }
            }
            let a = Int(rom[base + hdr + 0x1C]) | Int(rom[base + hdr + 0x1D]) << 8
            let b = Int(rom[base + hdr + 0x1E]) | Int(rom[base + hdr + 0x1F]) << 8
            if a ^ b == 0xFFFF && !((a == 0 && b == 0) || (a == 0xFFFF && b == 0xFFFF)) { s += 8 }
            return s
        }
        let lo = score(0x7FC0, hi: false)
        let hi = rom.count > 0xFFC0 ? score(0xFFC0, hi: true) : -100
        let hdr = hi > lo ? 0xFFC0 : 0x7FC0
        guard hdr + 0x16 < rom.count else { return nil }
        let chip = Int(rom[rom.startIndex + hdr + 0x16])
        return SnesBits(chip: chip, family: chip >> 4, hi: hi > lo)
    }

    static func crc32(url: URL?, skip: Int) -> UInt32? {
        guard let url, let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        if skip > 0 { try? handle.seek(toOffset: UInt64(skip)) }
        var crc: UInt32 = 0xFFFF_FFFF
        while let chunk = try? handle.read(upToCount: 64 * 1024), !chunk.isEmpty {
            for b in chunk {
                let idx = Int((crc ^ UInt32(b)) & 0xFF)
                crc = (crc >> 8) ^ crcTable[idx]
            }
        }
        return crc ^ 0xFFFF_FFFF
    }

    private static let crcTable: [UInt32] = {
        (0..<256).map { i -> UInt32 in
            var c = UInt32(i)
            for _ in 0..<8 { c = (c & 1) != 0 ? (0xEDB88320 ^ (c >> 1)) : (c >> 1) }
            return c
        }
    }()
}
