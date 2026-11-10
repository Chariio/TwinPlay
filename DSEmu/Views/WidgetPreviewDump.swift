// Copyright (c) 2026 Charlie Rodriguez Garcia. All rights reserved.
#if DEBUG
// Testing aid: -TwinPlayWidgetPreviews /dir renders the TwinPlay Games widget views (same code as the
// widget extension) for every size, mode and appearance from the snapshot the app wrote to the
// App Group, as PNGs. Lets the simulator check the widget without placing it on a home screen.
import SwiftUI
import UIKit

enum WidgetPreviewDump {
    @MainActor static func run(to dir: URL) async {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // Let the debounced snapshot land (banner loading refreshes the library a few times first).
        var snap = WidgetSnapshot.load()
        for _ in 0..<20 {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            snap = WidgetSnapshot.load()
            if !snap.games.isEmpty { try? await Task.sleep(nanoseconds: 2_000_000_000); snap = WidgetSnapshot.load(); break }
        }
        let thumbs = WidgetShared.thumbsURL
        func image(_ g: WidgetGame) -> UIImage? {
            guard let t = g.thumb, let d = thumbs else { return nil }
            return UIImage(contentsOfFile: d.appendingPathComponent(t).path)
        }
        let sizes: [(WidgetSize, CGSize, String)] = [
            (.small, CGSize(width: 170, height: 170), "small"), (.medium, CGSize(width: 364, height: 170), "medium"),
            (.large, CGSize(width: 364, height: 382), "large"), (.accessoryRectangular, CGSize(width: 172, height: 76), "rect"),
            (.accessoryInline, CGSize(width: 260, height: 22), "inline"),
        ]
        var log = "games in snapshot: \(snap.games.count), container: \(WidgetShared.containerURL?.path ?? "nil")\n"
        for mode in WidgetMode.allCases {
            log += "\(mode.rawValue): " + snap.top(mode, limit: 5).map(\.name).joined(separator: " | ") + "\n"
            for (size, pt, name) in sizes {
                for look in ["light", "dark", "tinted"] {
                    if size == .accessoryRectangular || size == .accessoryInline, look != "tinted" { continue }
                    let games = snap.top(mode, limit: size.count)
                    let view = card(WidgetGamesContent(games: games, mode: mode, size: size, hasLibrary: !snap.games.isEmpty,
                                                       accented: look == "tinted", image: image), size: size, pt: pt, look: look)
                    save(view, to: dir.appendingPathComponent("\(mode.rawValue)-\(name)-\(look).png"))
                }
            }
        }
        // Empty library state.
        for (size, pt, name) in sizes where size != .accessoryInline {
            save(card(WidgetGamesContent(games: [], mode: .recent, size: size, hasLibrary: false), size: size, pt: pt, look: "light"),
                 to: dir.appendingPathComponent("empty-\(name)-light.png"))
        }
        try? log.write(to: dir.appendingPathComponent("order.txt"), atomically: true, encoding: .utf8)
    }

    /// Approximates the system chrome around a widget: wallpaper, rounded container, content margins.
    @MainActor private static func card<V: View>(_ content: V, size: WidgetSize, pt: CGSize, look: String) -> some View {
        let accessory = size == .accessoryRectangular || size == .accessoryInline
        let dark = look != "light"
        return ZStack {
            LinearGradient(colors: dark ? [Color(white: 0.12), Color(red: 0.1, green: 0.12, blue: 0.22)]
                                        : [Color(red: 0.62, green: 0.75, blue: 0.95), Color(red: 0.95, green: 0.8, blue: 0.85)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            Group {
                if accessory {
                    content.padding(4).frame(width: pt.width, height: pt.height).foregroundStyle(.white)
                } else {
                    content.padding(16).frame(width: pt.width, height: pt.height)
                        .background(look == "tinted" ? AnyShapeStyle(Color.white.opacity(0.12)) : AnyShapeStyle(.regularMaterial))
                        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                }
            }
            .modifier(Tint(on: look == "tinted"))
        }
        .frame(width: pt.width + 40, height: pt.height + 40)
        .environment(\.colorScheme, dark ? .dark : .light)
    }

    /// Rough stand-in for the tinted home screen: monochrome content multiplied by an accent tint.
    private struct Tint: ViewModifier {
        let on: Bool
        func body(content: Content) -> some View {
            if on { content.grayscale(1).colorMultiply(Color(red: 1, green: 0.85, blue: 0.6)) } else { content }
        }
    }

    @MainActor private static func save<V: View>(_ v: V, to url: URL) {
        let r = ImageRenderer(content: v); r.scale = 3
        if let data = r.uiImage?.pngData() { try? data.write(to: url) }
    }
}
#endif
