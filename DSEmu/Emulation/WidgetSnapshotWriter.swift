// Copyright (c) 2026 Charlie Rodriguez Garcia. All rights reserved.
// Keeps the TwinPlay Games widget current: after every library refresh (import, delete, rename,
// favorite, play, play time, cover change) it writes a small JSON snapshot plus downscaled
// thumbnails into the App Group and asks WidgetKit to reload, but only when something changed.
// No ROM data leaves the app's Documents folder. Without the App Group it does nothing.
import Foundation
import UIKit
import WidgetKit

final class WidgetSnapshotWriter {
    static let shared = WidgetSnapshotWriter()
    private let queue = DispatchQueue(label: "twinplay.widget-snapshot", qos: .utility)
    private var pending: DispatchWorkItem?
    private var lastWritten: Data?

    struct Source { let game: WidgetGame; let art: URL? }

    /// Debounced: refresh() can run several times in a row while banners load.
    func schedule(_ sources: [Source]) {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.write(sources) }
        pending = work
        queue.asyncAfter(deadline: .now() + 0.6, execute: work)
    }

    private func write(_ sources: [Source]) {
        guard let dir = WidgetShared.containerURL, let thumbs = WidgetShared.thumbsURL,
              let snapURL = WidgetShared.snapshotURL else { return }
        let fm = FileManager.default
        try? fm.createDirectory(at: thumbs, withIntermediateDirectories: true)
        var games: [WidgetGame] = []
        var keep: Set<String> = []
        for s in sources {
            var g = s.game
            if let art = s.art, let stamp = Self.stamp(art) {
                // Name carries the source's modification time, so a new cover gets a new file and
                // the snapshot (and therefore the widget) changes with it.
                let name = "\(Self.fnv(g.id))-\(stamp).jpg"
                let url = thumbs.appendingPathComponent(name)
                if !fm.fileExists(atPath: url.path) {
                    if let img = UIImage(contentsOfFile: art.path), let data = Self.thumbnail(img)?.jpegData(compressionQuality: 0.85) {
                        try? data.write(to: url, options: .atomic)
                    }
                }
                if fm.fileExists(atPath: url.path) { g.thumb = name; keep.insert(name) }
            }
            games.append(g)
        }
        // Drop thumbnails of removed games / replaced covers.
        for f in (try? fm.contentsOfDirectory(atPath: thumbs.path)) ?? [] where !keep.contains(f) {
            try? fm.removeItem(at: thumbs.appendingPathComponent(f))
        }
        guard let data = try? JSONEncoder.widget.encode(WidgetSnapshot(games: games)) else { return }
        if data == lastWritten, fm.fileExists(atPath: snapURL.path) { return }
        _ = dir
        try? data.write(to: snapURL, options: .atomic)
        lastWritten = data
        WidgetCenter.shared.reloadAllTimelines()
    }

    /// Longest side 240 px: sharp in a large widget row and small enough for the widget's memory budget.
    static func thumbnail(_ img: UIImage, maxSide: CGFloat = 240) -> UIImage? {
        let s = img.size
        guard s.width > 0, s.height > 0 else { return nil }
        let k = min(1, maxSide / max(s.width, s.height))
        let size = CGSize(width: max(1, (s.width * k).rounded()), height: max(1, (s.height * k).rounded()))
        let f = UIGraphicsImageRendererFormat(); f.scale = 1; f.opaque = true
        return UIGraphicsImageRenderer(size: size, format: f).image { _ in img.draw(in: CGRect(origin: .zero, size: size)) }
    }

    private static func stamp(_ url: URL) -> Int? {
        guard let d = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date else { return nil }
        return Int(d.timeIntervalSince1970)
    }

    static func fnv(_ s: String) -> String {
        var h: UInt64 = 0xcbf29ce484222325
        for b in s.utf8 { h ^= UInt64(b); h = h &* 0x100000001b3 }
        return String(h, radix: 16)
    }
}

extension ROMLibrary {
    /// Snapshot of the current library for the widget (cover, else title screen, as the picture).
    func publishWidgetSnapshot() {
        let fm = FileManager.default
        let sources = entries.map { e -> WidgetSnapshotWriter.Source in
            let art = [coverURL(for: e.url), titleImageURL(for: e.url), autoTitleURL(for: e.url)]
                .first { fm.fileExists(atPath: $0.path) }
            let g = WidgetGame(id: e.url.lastPathComponent, name: e.name, system: e.system.rawValue, playCount: e.playCount,
                               lastPlayed: e.lastPlayed, playSeconds: e.playSeconds, favorite: e.favorite,
                               added: e.dateAdded, thumb: nil)
            return .init(game: g, art: art)
        }
        WidgetSnapshotWriter.shared.schedule(sources)
    }
}
