// Copyright (c) 2026 Charlie Rodriguez Garcia. All rights reserved.
import Foundation
import UIKit

/// Save-state slots for one game: slot 0 is the automatic slot (written when you leave the
/// game or the app goes to the background), slots 1...5 are manual. Each slot is a state file
/// plus a PNG thumbnail of both screens, stored in Documents/States.
struct SaveSlotStore {
    static let manualSlots = 1...5
    static let autoSlot = 0
    static var allSlots: [Int] { [autoSlot] + Array(manualSlots) }

    let directory: URL
    let baseName: String

    init(directory: URL, gameFileName: String) {
        self.directory = directory
        baseName = gameFileName
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func stateURL(_ slot: Int) -> URL { directory.appendingPathComponent("\(baseName).slot\(slot).state") }
    func thumbnailURL(_ slot: Int) -> URL { directory.appendingPathComponent("\(baseName).slot\(slot).png") }

    struct Info: Identifiable {
        let slot: Int
        var id: Int { slot }
        let date: Date?
        let thumbnail: UIImage?
        var isEmpty: Bool { date == nil }
        var title: String { slot == SaveSlotStore.autoSlot ? String(localized: "Auto") : String(localized: "Slot \(slot)") }
    }

    func info(_ slot: Int) -> Info {
        let url = stateURL(slot)
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let date = attrs?[.modificationDate] as? Date
        let thumb = date == nil ? nil : UIImage(contentsOfFile: thumbnailURL(slot).path)
        return Info(slot: slot, date: date, thumbnail: thumb)
    }

    func allInfo() -> [Info] { Self.allSlots.map(info) }

    func write(slot: Int, state: Data, thumbnail: Data?) -> Bool {
        do {
            try state.write(to: stateURL(slot), options: .atomic)
            if let thumbnail { try? thumbnail.write(to: thumbnailURL(slot), options: .atomic) }
            return true
        } catch { return false }
    }

    func read(slot: Int) -> Data? { try? Data(contentsOf: stateURL(slot)) }

    func delete(slot: Int) {
        try? FileManager.default.removeItem(at: stateURL(slot))
        try? FileManager.default.removeItem(at: thumbnailURL(slot))
    }
}
