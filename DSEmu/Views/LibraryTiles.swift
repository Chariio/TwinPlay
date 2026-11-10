// Copyright (c) 2026 Charlie Rodriguez Garcia. All rights reserved.
// Library tiles: box art, an original drawn cartridge, or a title-screen picture,
// plus the box-art finder sheet. All shapes are original; no logos or trademarks.
import SwiftUI

/// Small "DS" / "GBA" label on a tile.
struct SystemBadge: View {
    let system: GameSystem
    var body: some View {
        Text(system.label)
            .font(.system(size: 10, weight: .heavy, design: .rounded))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .foregroundStyle(.white)
            .background(system == .ds ? Color(red: 0.25, green: 0.35, blue: 0.75) : Color(red: 0.45, green: 0.30, blue: 0.70),
                        in: Capsule())
            .overlay(Capsule().stroke(Color.white.opacity(0.7), lineWidth: 1))
            .accessibilityLabel((system == .ds ? "DS game" : "Game Boy Advance game").loc)
    }
}

/// The artwork of a game in a given style.
struct GameArtwork: View {
    let entry: ROMLibrary.Entry
    let style: TileStyle
    var depth3D = false

    var body: some View {
        switch style {
        case .cartridge:
            CartridgeView(system: entry.system, label: labelImage, title: entry.name, pixelated: entry.cover == nil,
                          color: entry.cartColor, depth3D: depth3D)
        case .titleScreen:
            TitleScreenTile(entry: entry)
        case .boxArt:
            boxArt
        }
    }

    private var labelImage: UIImage? { entry.cover ?? entry.titleImage ?? entry.icon }

    @ViewBuilder private var boxArt: some View {
        ZStack {
            Color(white: 0.9)
            if let cover = entry.cover {
                Image(uiImage: cover).resizable().scaledToFill()
            } else if let icon = entry.icon {
                Image(uiImage: icon).resizable().interpolation(.none).scaledToFit().padding(18)
            } else {
                VStack(spacing: 6) {
                    Image(systemName: "gamecontroller").font(.system(size: 34))
                    Text(entry.system.label).font(.caption.weight(.bold))
                }
                .foregroundStyle(.secondary)
            }
        }
    }
}

/// "Title screen" style: the game's title screen inside a small TV / monitor bezel, so it reads
/// clearly differently from box art. Shows a progress placeholder while it is being captured.
struct TitleScreenTile: View {
    let entry: ROMLibrary.Entry
    @ObservedObject private var gen = TitleScreenGenerator.shared

    var body: some View {
        GeometryReader { geo in
            let aspect: CGFloat = entry.system.screenAspect
            let bezel = max(5, geo.size.width * 0.06)
            let w = geo.size.width - bezel * 2
            let h = min(w / aspect, geo.size.height - bezel * 2 - 12)
            let sw = h * aspect
            VStack(spacing: 0) {
                ZStack {
                    RoundedRectangle(cornerRadius: bezel * 1.4, style: .continuous)
                        .fill(LinearGradient(colors: [Color(white: 0.24), Color(white: 0.09)], startPoint: .top, endPoint: .bottom))
                        .overlay(RoundedRectangle(cornerRadius: bezel * 1.4, style: .continuous).stroke(Color(white: 0.38), lineWidth: 1))
                    ZStack {
                        Color.black
                        if let t = entry.titleScreen {
                            Image(uiImage: t).resizable().interpolation(.none).scaledToFill()
                        } else if gen.isPending(entry.url) {
                            VStack(spacing: 6) {
                                ProgressView().tint(.white)
                                Text((gen.current == entry.url ? "Capturing title…" : "Waiting…").loc)
                                    .font(.caption2).foregroundStyle(.white.opacity(0.8))
                            }
                        } else {
                            VStack(spacing: 4) {
                                Image(systemName: "tv").font(.title2)
                                Text(entry.name).font(.caption2.weight(.semibold)).lineLimit(2).multilineTextAlignment(.center)
                            }
                            .foregroundStyle(.white.opacity(0.7)).padding(6)
                        }
                        // Glass reflection.
                        LinearGradient(colors: [.white.opacity(0.16), .clear], startPoint: .topLeading, endPoint: .center)
                    }
                    .frame(width: sw, height: h)
                    .clipShape(RoundedRectangle(cornerRadius: bezel * 0.6, style: .continuous))
                }
                .frame(width: sw + bezel * 2, height: h + bezel * 2)
                .overlay(alignment: .bottomTrailing) {
                    Circle().fill(Color.green).frame(width: 4, height: 4).padding(bezel * 0.4)
                }
                // Stand.
                Trapezoid().fill(Color(white: 0.16)).frame(width: sw * 0.34, height: 10)
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .shadow(color: .black.opacity(0.35), radius: 6, y: 4)
        }
    }
}

private struct Trapezoid: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX + r.width * 0.25, y: r.minY)); p.addLine(to: CGPoint(x: r.maxX - r.width * 0.25, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY)); p.addLine(to: CGPoint(x: r.minX, y: r.maxY)); p.closeSubpath()
        return p
    }
}

/// Cartridge tile: a cached Core Graphics render (CartridgeRenderer) at true
/// proportions with the game's art on the label. No logos or trademarks.
struct CartridgeView: View {
    let system: GameSystem
    let label: UIImage?
    let title: String
    var pixelated = false
    var color: CartColor? = nil
    var depth3D = false

    var body: some View {
        GeometryReader { geo in
            let gba = system == .gba
            let gbc = system == .gbc
            let gb = system.isGameBoy
            let nes = system == .nes
            let snes = system == .snes
            let mm = CartridgeRenderer.canvasMM(gba: gba, gb: gb, gbc: gbc, nes: nes, snes: snes)
            let fit = min(geo.size.width / mm.width, geo.size.height / mm.height)
            let cartColor = color ?? CartColor.known(gameCode: nil, system: system)
            ZStack {
                if let img = CartridgeImageCache.shared.image(gba: gba, gb: gb, gbc: gbc, nes: nes, snes: snes, color: cartColor, label: label, pixelated: pixelated,
                                                              title: title, pointsPerMM: fit) {
                    Image(uiImage: img).resizable().interpolation(.high)
                        .frame(width: mm.width * fit, height: mm.height * fit)
                        .shadow(color: .black.opacity(depth3D ? 0.35 : 0), radius: depth3D ? 8 : 0, x: 0, y: depth3D ? 6 : 0)
                }
                if label == nil {
                    Text(title).font(.system(size: max(9, mm.width * fit * 0.07), weight: .bold, design: .rounded))
                        .multilineTextAlignment(.center).foregroundStyle(.white).lineLimit(3)
                        .frame(width: CartridgeRenderer.labelRect(gba: gba, gb: gb, gbc: gbc, nes: nes, snes: snes).width * fit * 0.9)
                        .offset(y: (CartridgeRenderer.labelRect(gba: gba, gb: gb, gbc: gbc, nes: nes, snes: snes).midY + CartridgeRenderer.marginMM - mm.height / 2) * fit)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }
}

/// Renders each cartridge once per (system, color, label, size bucket) and keeps it in memory.
final class CartridgeImageCache {
    static let shared = CartridgeImageCache()
    private let cache = NSCache<NSString, UIImage>()
    init() { cache.countLimit = 120 }

    func image(gba: Bool, gb: Bool = false, gbc: Bool = false, nes: Bool = false, snes: Bool = false, color: CartColor, label: UIImage?, pixelated: Bool, title: String, pointsPerMM: CGFloat) -> UIImage? {
        let screen = UIScreen.main.scale
        let bucket = max(2, (pointsPerMM * screen / 2).rounded(.up) * 2)          // px per mm, bucketed
        let labelKey = label.map { String(UInt(bitPattern: ObjectIdentifier($0).hashValue)) } ?? title
        let key = "\(gba)-\(gb)-\(gbc)-\(nes)-\(snes)-\(color.rawValue)-\(labelKey)-\(pixelated)-\(Int(bucket))" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        guard let cg = CartridgeRenderer.render(gba: gba, gb: gb, gbc: gbc, nes: nes, snes: snes, color: color, label: label?.cgImage, pixelatedLabel: pixelated,
                                                title: title, scale: bucket) else { return nil }
        let img = UIImage(cgImage: cg, scale: screen, orientation: .up)
        cache.setObject(img, forKey: key)
        return img
    }
}

/// Grid of box-art candidates from libretro-thumbnails; tap one to use it.
/// Only reachable while `BoxArtFinder.isEnabled` (off for 1.0); every way in is hidden behind that flag.
struct BoxArtPickerView: View {
    let entry: ROMLibrary.Entry
    @EnvironmentObject private var library: ROMLibrary
    @Environment(\.dismiss) private var dismiss
    @State private var kind: BoxArtFinder.Kind
    @ObservedObject private var gen = TitleScreenGenerator.shared
    @State private var results: [BoxArtFinder.Candidate] = []
    @State private var loading = false
    @State private var error: String?
    @State private var applying: String?
    let onGoogle: () -> Void
    let onPhotos: () -> Void

    init(entry: ROMLibrary.Entry, kind: BoxArtFinder.Kind = .boxart, onGoogle: @escaping () -> Void, onPhotos: @escaping () -> Void) {
        self.entry = entry; self.onGoogle = onGoogle; self.onPhotos = onPhotos
        _kind = State(initialValue: kind)
    }

    private var live: ROMLibrary.Entry { library.entries.first { $0.id == entry.id } ?? entry }

    private let columns = [GridItem(.adaptive(minimum: 120), spacing: 12)]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Picker("Kind", selection: $kind) {
                        ForEach(BoxArtFinder.Kind.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    if kind == .title { autoCapturedRow }
                    if loading { ProgressView("Searching…").frame(maxWidth: .infinity).padding() }
                    if let error { Text(error.loc).foregroundStyle(.secondary) }
                    if !loading && results.isEmpty && error == nil {
                        Text("No matches found. Try renaming the game to its full name, or use the options below.")
                            .foregroundStyle(.secondary)
                    }
                    LazyVGrid(columns: columns, spacing: 14) {
                        ForEach(results) { c in
                            Button { apply(c) } label: {
                                VStack(spacing: 4) {
                                    AsyncImage(url: c.url) { phase in
                                        switch phase {
                                        case .success(let img): img.resizable().scaledToFit()
                                        case .failure: AsyncImage(url: c.mirrorURL) { $0.resizable().scaledToFit() } placeholder: { Color(white: 0.9) }
                                        default: ZStack { Color(white: 0.92); ProgressView() }
                                        }
                                    }
                                    .frame(height: 130)
                                    .overlay { if applying == c.id { ProgressView().padding(8).glassSurface(Circle()) } }
                                    Text(c.name).font(.caption2).lineLimit(2).multilineTextAlignment(.center).foregroundStyle(.primary)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    Divider()
                    Button { dismiss(); onPhotos() } label: { Label("Choose from Photos instead", systemImage: "photo") }
                    Button { dismiss(); onGoogle() } label: { Label("Search Google Images", systemImage: "magnifyingglass") }
                    Text("Images come from the free libretro-thumbnails collection and are downloaded only when you ask.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                .padding()
            }
            .navigationTitle(entry.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
            .task(id: kind) { await search() }
        }
    }

    /// The title screen TwinPlay captured itself, offered next to the online results.
    private var autoCapturedRow: some View {
        HStack(spacing: 12) {
            ZStack {
                Color.black
                if let a = live.autoTitleImage { Image(uiImage: a).resizable().interpolation(.none).scaledToFit() }
                else if gen.isPending(entry.url) { ProgressView().tint(.white) }
                else { Image(systemName: "tv").foregroundStyle(.white.opacity(0.6)) }
            }
            .frame(width: 128, height: 96).clipShape(RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 6) {
                Text("Captured by TwinPlay").font(.subheadline.weight(.semibold))
                if live.autoTitleImage != nil {
                    Button((live.titleImage == nil ? "In use ✓" : "Use this").loc) { library.clearTitleImage(for: live); dismiss() }
                        .glassButton(prominent: true).disabled(live.titleImage == nil)
                }
                Button((gen.isPending(entry.url) ? "Capturing…" : "Capture again").loc) { gen.regenerate([live], library: library) }
                    .glassButton().disabled(gen.isPending(entry.url))
            }
            Spacer()
        }
        .padding(10)
        .glassSurface(RoundedRectangle(cornerRadius: 12))
    }

    private func search() async {
        loading = true; error = nil
        do { results = try await BoxArtFinder.shared.candidates(for: library.boxArtQuery(for: entry), kind: kind) }
        catch { results = []; self.error = "Could not reach the art server. Check the internet connection." }
        loading = false
    }

    private func apply(_ c: BoxArtFinder.Candidate) {
        applying = c.id
        Task {
            do {
                let img = try await BoxArtFinder.shared.image(for: c)
                await MainActor.run {
                    if kind == .boxart { library.setCover(img, for: entry) } else { library.setTitleImage(img, for: entry) }
                    applying = nil
                    dismiss()
                }
            } catch {
                await MainActor.run { applying = nil; self.error = "That image could not be downloaded." }
            }
        }
    }
}
