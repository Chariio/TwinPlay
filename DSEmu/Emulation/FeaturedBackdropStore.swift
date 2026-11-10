// Copyright (c) 2026 Charlie Rodriguez Garcia. All rights reserved.
// Lazy, non-blocking artwork for the library's top featured card: prefer the
// user's last-played frame, then a libretro gameplay snap, then a title
// screen, then the existing box art.
import Combine
import SwiftUI
import UIKit

@MainActor
final class FeaturedBackdropStore: ObservableObject {
    static let shared = FeaturedBackdropStore()

    /// Downloaded libretro snaps/titles, keyed by ROM path.
    @Published private(set) var remote: [String: UIImage] = [:]
    private var inflight: [String: Task<Void, Never>] = [:]
    /// Bumped when a local play-snapshot is saved so cards refresh.
    @Published private(set) var localGeneration = 0

    private init() {}

    func key(for url: URL) -> String { url.path }

    func invalidate(rom: URL) {
        localGeneration += 1
    }

    /// Immediate picture for the card: local play-snap first, else a cached download.
    func current(for entry: ROMLibrary.Entry, library: ROMLibrary?) -> UIImage? {
        if let local = library?.playSnapshot(for: entry) { return local }
        return remote[key(for: entry.url)]
    }

    /// Kicks off a download if needed. Safe to call from `body` / `onAppear`.
    func prefetch(for entry: ROMLibrary.Entry, library: ROMLibrary?) {
        if library?.playSnapshot(for: entry) != nil { return }
        let k = key(for: entry.url)
        if remote[k] != nil || inflight[k] != nil { return }
        let query = library?.boxArtQuery(for: entry) ?? BoxArtFinder.Query(names: [entry.name, entry.fileName], headerTitle: entry.headerTitle, gameCode: entry.gameCode, system: entry.system)
        inflight[k] = Task { [weak self] in
            let img = await BoxArtFinder.shared.featuredImage(for: query)
            await MainActor.run {
                guard let self else { return }
                self.inflight[k] = nil
                if let img { self.remote[k] = img }
            }
        }
    }
}
