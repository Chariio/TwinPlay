// Copyright (c) 2026 Charlie Rodriguez Garcia. All rights reserved.
// Captures a title-screen thumbnail for each game by running the core headless for a few
// seconds (no audio, no save file attached) and keeping the most colourful top-screen frame.
// Results are cached as Documents/Covers/<game>.autotitle.png.
import CoreGraphics
import Foundation
import UIKit

@MainActor
final class TitleScreenGenerator: ObservableObject {
    static let shared = TitleScreenGenerator()

    /// Games queued or being captured right now.
    @Published private(set) var pending: Set<URL> = []
    @Published private(set) var current: URL?
    private var queue: [URL] = []
    private var running = false
    private weak var library: ROMLibrary?
    private let worker = DispatchQueue(label: "twinplay.titlescreens", qos: .utility)

    func isPending(_ url: URL) -> Bool { pending.contains(url) }

    /// Queues every game that has no captured title screen yet.
    func ensure(_ entries: [ROMLibrary.Entry], library: ROMLibrary) {
        self.library = library
        for e in entries where e.autoTitleImage == nil && !pending.contains(e.url) {
            if FileManager.default.fileExists(atPath: library.autoTitleURL(for: e.url).path) { continue }
            enqueue(e.url)
        }
        pump()
    }

    /// Captures again (the "Refresh title screens" / "Capture again" actions).
    func regenerate(_ entries: [ROMLibrary.Entry], library: ROMLibrary) {
        self.library = library
        for e in entries where !pending.contains(e.url) {
            try? FileManager.default.removeItem(at: library.autoTitleURL(for: e.url))
            enqueue(e.url)
        }
        library.refresh()
        pump()
    }

    private func enqueue(_ url: URL) { queue.append(url); pending.insert(url) }

    /// Paused while a game is being played (the capture stops within a frame).
    var paused = false { didSet { Self.cancel = paused; if !paused { pump() } } }
    nonisolated(unsafe) static var cancel = false

    private func pump() {
        guard !running, !paused, !queue.isEmpty else { return }
        running = true
        let url = queue.removeFirst()
        current = url
        worker.async {
            let img = Self.capture(rom: url)
            DispatchQueue.main.async {
                if let img { self.library?.setAutoTitle(img, for: url); self.pending.remove(url) }
                else if self.paused { self.queue.insert(url, at: 0) }   // interrupted: try again later
                else { self.pending.remove(url) }
                self.current = nil
                self.running = false
                self.pump()
            }
        }
    }

    /// Runs the game for up to 10 s (GBA) / 18 s (DS) of emulated time and returns the best top-screen frame.
    nonisolated static func capture(rom: URL, seconds: Double? = nil) -> UIImage? {
        let gb = DSCoreBridge.gameBoySystem(ofROMAt: rom) != 0
        let nes = !gb && DSCoreBridge.isNESROM(at: rom)
        let snes = !gb && !nes && DSCoreBridge.isSNESROM(at: rom)
        let n64 = !gb && !nes && !snes && DSCoreBridge.isN64ROM(at: rom)
        let n3ds = !gb && !nes && !snes && !n64 && DSCoreBridge.is3DSROM(at: rom)
        let gba = !gb && !nes && !snes && !n64 && !n3ds && DSCoreBridge.isGBAROM(at: rom)
        // DS games show publisher logos longer before the title (e.g. Super Mario 64 DS).
        let seconds = seconds ?? (gba || gb || nes || snes ? 10 : 18)
        let core = DSCoreBridge(kind: gb ? .gb : n64 ? .n64 : n3ds ? .n3ds : nes ? .nes : snes ? .snes : gba ? .gba : .interpreter)
        if gb { EmulatorSession.applyGameBoyVideo(core) }
        core.renderScale = 1
        core.renderThreads = 0
        core.frameSkip = 0
        do { try core.loadROM(at: rom) } catch { return nil }
        let total = Int(seconds * 60)
        var best: CGImage?
        var bestScore = -1.0
        for f in 1...total {
            if cancel { return nil }
            autoreleasepool { core.runFrame() }
            // Sample twice a second after the first second (skips the blank boot frames).
            guard f >= 60, f % 30 == 0, let img = core.copyScreenImage(0) else { continue }
            let s = colourfulness(img)
            // Later frames win ties, so we land on the title rather than a logo fading in.
            if s >= bestScore * 0.98 { best = img; bestScore = max(s, bestScore) }
            // A rich, fully drawn picture: good enough, stop early.
            if s > 0.9 && f > 240 { break }
        }
        // Game Boy titles are often two-tone (black on white), so any drawn picture counts.
        guard let best, bestScore > (gb ? 0.005 : 0.05) else { return nil }
        return UIImage(cgImage: best)
    }

    /// 0...1: how many distinct colours a frame uses and how much of it is not near-black / near-white.
    nonisolated static func colourfulness(_ img: CGImage) -> Double {
        let w = 64, h = 48
        var px = [UInt32](repeating: 0, count: w * h)
        guard let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return 0 }
        ctx.interpolationQuality = .none
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        var colours = Set<UInt32>()
        var content = 0, white = 0
        for p in px {
            let r = Int(p & 0xFF), g = Int((p >> 8) & 0xFF), b = Int((p >> 16) & 0xFF)
            colours.insert(UInt32((r >> 4) << 8 | (g >> 4) << 4 | (b >> 4)))
            let mx = max(r, g, b), mn = min(r, g, b)
            if mx > 40 && mn < 225 { content += 1 }
            if mn > 200 { white += 1 }
        }
        let variety = min(1, Double(colours.count) / 120)
        let fill = Double(content) / Double(px.count)
        // Mostly-white frames are publisher logo screens ("Nintendo"), not the title.
        let logoPenalty = Double(white) / Double(px.count) > 0.5 ? 0.35 : 1.0
        return (variety * 0.6 + fill * 0.4) * logoPenalty
    }
}
