// Copyright (c) 2026 Charlie Rodriguez Garcia. All rights reserved.
// "TwinPlay Games" home screen / lock screen widget. Reads the snapshot the app writes into the App
// Group; never touches ROM files or the network.
import AppIntents
import SwiftUI
import UIKit
import WidgetKit

enum ShowOption: String, AppEnum {
    case recent, favorites, mostPlayed
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Show"
    static var caseDisplayRepresentations: [ShowOption: DisplayRepresentation] = [
        .recent: "Recent", .favorites: "Favorites", .mostPlayed: "Most Played",
    ]
    var mode: WidgetMode { WidgetMode(rawValue: rawValue) ?? .recent }
}

struct NDUOGamesIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "TwinPlay Games"
    static var description = IntentDescription("Your recent, favorite or most played games.")
    @Parameter(title: "Show", default: .recent) var show: ShowOption
    init() {}
    init(show: ShowOption) { self.show = show }
}

struct GamesEntry: TimelineEntry {
    let date: Date
    let mode: WidgetMode
    let games: [WidgetGame]
    let hasLibrary: Bool
    let images: [String: UIImage]
}

struct GamesProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> GamesEntry {
        GamesEntry(date: Date(), mode: .recent, games: Self.sample, hasLibrary: true, images: [:])
    }
    func snapshot(for configuration: NDUOGamesIntent, in context: Context) async -> GamesEntry {
        let e = entry(configuration.show.mode, family: context.family)
        return context.isPreview && e.games.isEmpty && !e.hasLibrary
            ? GamesEntry(date: Date(), mode: e.mode, games: Self.sample, hasLibrary: true, images: [:]) : e
    }
    func timeline(for configuration: NDUOGamesIntent, in context: Context) async -> Timeline<GamesEntry> {
        // The app reloads the widget whenever the library or play stats change; the hourly refresh
        // only keeps "Played 2 hr ago" current.
        Timeline(entries: [entry(configuration.show.mode, family: context.family)],
                 policy: .after(Date().addingTimeInterval(3600)))
    }

    private func entry(_ mode: WidgetMode, family: WidgetFamily) -> GamesEntry {
        let snap = WidgetSnapshot.load()
        let games = snap.top(mode, limit: family.size.count)
        var images: [String: UIImage] = [:]
        if family.size != .accessoryInline && family.size != .accessoryRectangular, let dir = WidgetShared.thumbsURL {
            for g in games {
                if let t = g.thumb, let img = UIImage(contentsOfFile: dir.appendingPathComponent(t).path) { images[g.id] = img }
            }
        }
        return GamesEntry(date: Date(), mode: mode, games: games, hasLibrary: !snap.games.isEmpty, images: images)
    }

    static let sample: [WidgetGame] = [
        WidgetGame(id: "sample1", name: "TwinPlay Demo", system: "ds", playCount: 3, lastPlayed: Date(), playSeconds: 1800, favorite: true, added: Date(), thumb: nil),
        WidgetGame(id: "sample2", name: "Mode 7 Racer", system: "gba", playCount: 1, lastPlayed: nil, playSeconds: 0, favorite: false, added: Date(), thumb: nil),
        WidgetGame(id: "sample3", name: "Libbet", system: "gb", playCount: 0, lastPlayed: nil, playSeconds: 0, favorite: false, added: Date(), thumb: nil),
    ]
}

extension WidgetFamily {
    var size: WidgetSize {
        switch self {
        case .systemMedium: .medium
        case .systemLarge, .systemExtraLarge: .large
        case .accessoryRectangular: .accessoryRectangular
        case .accessoryInline: .accessoryInline
        default: .small
        }
    }
}

struct TwinPlayGamesView: View {
    @Environment(\.widgetFamily) private var family
    @Environment(\.widgetRenderingMode) private var renderingMode
    let entry: GamesEntry

    var body: some View {
        WidgetGamesContent(games: entry.games, mode: entry.mode, size: family.size, hasLibrary: entry.hasLibrary,
                           accented: renderingMode != .fullColor, now: entry.date, image: { entry.images[$0.id] })
            .containerBackground(.fill.tertiary, for: .widget)
            // Small and lock screen: the whole widget opens the game. Larger sizes link each game and
            // open the library from anywhere else.
            .widgetURL(family.size.count == 1 ? entry.games.first.map { WidgetShared.openURL(for: $0.id) } ?? WidgetShared.libraryURL
                                              : WidgetShared.libraryURL)
    }
}

struct TwinPlayGamesWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: WidgetShared.widgetKind, intent: NDUOGamesIntent.self, provider: GamesProvider()) { entry in
            TwinPlayGamesView(entry: entry)
        }
        .configurationDisplayName("TwinPlay Games")
        .description("Your recent, favorite or most played games.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge, .accessoryRectangular, .accessoryInline])
    }
}

@main
struct TwinPlayWidgetBundle: WidgetBundle {
    var body: some Widget { TwinPlayGamesWidget() }
}
