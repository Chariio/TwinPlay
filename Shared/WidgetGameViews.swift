// Copyright (c) 2026 Charlie Rodriguez Garcia. All rights reserved.
// The TwinPlay Games widget's views. Shared with the app only so DEBUG builds can render previews of
// every size and mode (the size and the tinted look are parameters, not read from the widget
// environment, for that reason).
import SwiftUI
import UIKit
import WidgetKit

enum WidgetSize { case small, medium, large, accessoryRectangular, accessoryInline
    var count: Int { switch self { case .small, .accessoryRectangular, .accessoryInline: 1; case .medium: 3; case .large: 5 } }
}

struct WidgetGamesContent: View {
    let games: [WidgetGame]
    let mode: WidgetMode
    let size: WidgetSize
    let hasLibrary: Bool          // false: no games at all (vs. an empty Favorites list)
    var accented = false          // tinted / clear home screen
    var now = Date()
    var image: (WidgetGame) -> UIImage? = { _ in nil }

    var body: some View {
        if games.isEmpty {
            WidgetEmptyState(size: size, favorites: hasLibrary && mode == .favorites)
        } else {
            switch size {
            case .small: small(games[0])
            case .medium: medium
            case .large: large
            case .accessoryRectangular: rectangular(games[0])
            case .accessoryInline: Text("\(games[0].name) · \(games[0].systemLabel)")
            }
        }
    }

    // MARK: Sizes

    private func small(_ g: WidgetGame) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            WidgetArt(game: g, image: image(g), accented: accented, showsName: false)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            VStack(alignment: .leading, spacing: 1) {
                Text(g.name).font(.caption.weight(.semibold)).lineLimit(1)
                Text(detail(g)).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }

    private var medium: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            HStack(alignment: .top, spacing: 10) {
                ForEach(games.prefix(3)) { g in
                    Link(destination: WidgetShared.openURL(for: g.id)) {
                        VStack(alignment: .leading, spacing: 3) {
                            WidgetArt(game: g, image: image(g), accented: accented, showsName: false)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                            Text(g.name).font(.caption2.weight(.semibold)).lineLimit(1)
                        }
                        .foregroundStyle(.primary)
                    }
                    .tint(.primary)
                }
                ForEach(0..<max(0, 3 - games.count), id: \.self) { _ in Color.clear }
            }
        }
    }

    private var large: some View {
        VStack(alignment: .leading, spacing: 0) {
            header.padding(.bottom, 8)
            ForEach(Array(games.prefix(5).enumerated()), id: \.element.id) { i, g in
                if i > 0 { Divider().padding(.leading, 54) }
                Link(destination: WidgetShared.openURL(for: g.id)) {
                    HStack(spacing: 10) {
                        WidgetArt(game: g, image: image(g), accented: accented, showsName: false)
                            .frame(width: 44, height: 44)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(g.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                            Text("\(g.systemLabel) · \(detail(g))").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer(minLength: 0)
                        if g.favorite {
                            Image(systemName: "star.fill").font(.caption).foregroundStyle(accented ? Color.primary : .yellow)
                                .accessibilityLabel(Text("Favorite"))
                        }
                    }
                    .padding(.vertical, 5)
                    .foregroundStyle(.primary)
                }
                .tint(.primary)
            }
            Spacer(minLength: 0)
        }
    }

    private func rectangular(_ g: WidgetGame) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Label { Text(mode.title).font(.caption2.weight(.semibold)) } icon: { Image(systemName: "gamecontroller.fill") }
            Text(g.name).font(.headline).lineLimit(1).widgetAccentable()
            Text("\(g.systemLabel) · \(detail(g))").font(.caption2).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var header: some View {
        HStack(spacing: 5) {
            Image(systemName: mode.symbol).font(.caption.weight(.bold)).foregroundStyle(accented ? Color.primary : .accentColor)
            Text(mode.title).font(.caption.weight(.bold))
            Spacer(minLength: 0)
            Text(verbatim: "TwinPlay").font(.caption2.weight(.heavy)).foregroundStyle(.secondary)
        }
        .widgetAccentable()
    }

    /// "Played 2 hr ago" (Recent, Favorites) or "3 h 12 min" (Most Played); "Not played yet" otherwise.
    private func detail(_ g: WidgetGame) -> String {
        if mode == .mostPlayed, g.playSeconds >= 60 { return Self.duration(g.playSeconds) }
        if let d = g.lastPlayed {
            let f = RelativeDateTimeFormatter(); f.unitsStyle = .abbreviated
            return String(localized: "Played \(f.localizedString(for: d, relativeTo: now))")
        }
        if g.playSeconds >= 60 { return Self.duration(g.playSeconds) }
        return String(localized: "Not played yet")
    }

    static func duration(_ s: Double) -> String {
        let f = DateComponentsFormatter()
        f.allowedUnits = s >= 3600 ? [.hour, .minute] : [.minute]; f.unitsStyle = .abbreviated
        return f.string(from: s) ?? ""
    }
}

extension WidgetMode {
    var title: String {
        switch self {
        case .recent: return String(localized: "Recent")
        case .favorites: return String(localized: "Favorites")
        case .mostPlayed: return String(localized: "Most Played")
        }
    }
    var symbol: String {
        switch self { case .recent: "clock.fill"; case .favorites: "star.fill"; case .mostPlayed: "chart.bar.fill" }
    }
}

/// Cover / title-screen image, else a clean tile in the console's colour with its label and the name.
struct WidgetArt: View {
    let game: WidgetGame
    let image: UIImage?
    var accented = false
    var showsName = true

    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            ZStack {
                if let image {
                    Image(uiImage: image).resizable().twinArtRendering().aspectRatio(contentMode: .fill)
                        .frame(width: geo.size.width, height: geo.size.height, alignment: .top).clipped()
                } else {
                    Rectangle().fill(accented ? AnyShapeStyle(Color.primary.opacity(0.14)) : AnyShapeStyle(Self.tint(game.system).gradient))
                    VStack(spacing: side > 70 ? 4 : 1) {
                        Text(verbatim: game.systemLabel)
                            .font(.system(size: max(11, side * 0.24), weight: .heavy, design: .rounded))
                        if showsName || side > 90 {
                            Text(game.name).font(.system(size: max(9, side * 0.11), weight: .semibold))
                                .multilineTextAlignment(.center).lineLimit(2).padding(.horizontal, 6)
                        }
                    }
                    .foregroundStyle(accented ? Color.primary : .white)
                    .widgetAccentable()
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: side > 70 ? 12 : 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: side > 70 ? 12 : 8, style: .continuous).strokeBorder(.primary.opacity(0.08)))
        }
        .accessibilityHidden(true)
    }

    static func tint(_ system: String) -> Color {
        switch system {
        case "gba": return Color(red: 0.36, green: 0.29, blue: 0.66)
        case "gbc": return Color(red: 0.05, green: 0.55, blue: 0.62)
        case "gb": return Color(red: 0.40, green: 0.50, blue: 0.24)
        case "nes": return Color(red: 0.55, green: 0.20, blue: 0.18)
        case "snes": return Color(red: 0.42, green: 0.40, blue: 0.58)
        default: return Color(red: 0.34, green: 0.38, blue: 0.46)
        }
    }
}

struct WidgetEmptyState: View {
    let size: WidgetSize
    let favorites: Bool
    var body: some View {
        let text = favorites ? String(localized: "Star a game in TwinPlay to see it here") : String(localized: "Add games in TwinPlay")
        if size == .accessoryInline {
            Text(text)
        } else {
            VStack(spacing: 6) {
                Image(systemName: favorites ? "star" : "gamecontroller")
                    .font(size == .accessoryRectangular ? .body : .title2).foregroundStyle(.secondary)
                    .widgetAccentable()
                Text(text).font(size == .large ? .headline : .caption.weight(.semibold))
                    .multilineTextAlignment(.center).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private extension Image {
    /// On a tinted home screen keep cover art recognisable (desaturated, not flat-tinted).
    func twinArtRendering() -> some View {
        Group {
            if #available(iOS 18.0, *) { self.widgetAccentedRenderingMode(.desaturated) } else { self }
        }
    }
}
