// Copyright (c) 2026 Charlie Rodriguez Garcia. All rights reserved.
import XCTest
@testable import TwinPlay

/// The TwinPlay Games widget: ordering of Recent / Favorites / Most Played, deep links, JSON round trip.
final class WidgetSnapshotTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func game(_ id: String, played: Double? = nil, count: Int = 0, seconds: Double = 0, fav: Bool = false, added: Double = 0, system: String = "ds") -> WidgetGame {
        WidgetGame(id: id, name: id, system: system, playCount: count, lastPlayed: played.map { t0.addingTimeInterval($0) },
                   playSeconds: seconds, favorite: fav, added: t0.addingTimeInterval(added), thumb: nil)
    }

    private var snap: WidgetSnapshot {
        WidgetSnapshot(games: [
            game("Alpha", played: 100, count: 2, seconds: 600),
            game("Bravo", played: 300, count: 1, seconds: 60, fav: true, system: "gba"),
            game("Charlie", count: 0, fav: true, added: 50, system: "gb"),
            game("Delta", played: 200, count: 9, seconds: 600, fav: true, system: "gbc"),
            game("Echo", count: 0, added: 80),
            game("Foxtrot", played: 50, count: 1, seconds: 7200),
        ])
    }

    func testRecentPutsLastPlayedFirstThenNewestUnplayed() {
        XCTAssertEqual(snap.top(.recent, limit: 10).map(\.id), ["Bravo", "Delta", "Alpha", "Foxtrot", "Echo", "Charlie"])
    }

    func testFavoritesOnlyStarredByLastPlayed() {
        XCTAssertEqual(snap.top(.favorites, limit: 10).map(\.id), ["Bravo", "Delta", "Charlie"])
    }

    func testMostPlayedByTimeThenLaunchesThenName() {
        // Alpha and Delta tie on time; Delta has more launches.
        XCTAssertEqual(snap.top(.mostPlayed, limit: 10).map(\.id), ["Foxtrot", "Delta", "Alpha", "Bravo", "Charlie", "Echo"])
    }

    func testLimitsMatchWidgetSizes() {
        XCTAssertEqual(snap.top(.recent, limit: WidgetSize.small.count).count, 1)
        XCTAssertEqual(snap.top(.recent, limit: WidgetSize.medium.count).count, 3)
        XCTAssertEqual(snap.top(.recent, limit: WidgetSize.large.count).count, 5)
        XCTAssertTrue(WidgetSnapshot.empty.top(.favorites, limit: 5).isEmpty)
    }

    func testSystemLabelsNeverSayNintendo() {
        XCTAssertEqual(snap.games.map(\.systemLabel), ["DS", "GBA", "GB", "GBC", "DS", "DS"])
    }

    func testDeepLinksRoundTrip() {
        let id = "Legend of Zelda, The - The Minish Cap (USA).gba"
        let url = WidgetShared.openURL(for: id)
        XCTAssertEqual(url.scheme, "nduo")
        XCTAssertEqual(WidgetShared.gameID(from: url), id)
        XCTAssertNil(WidgetShared.gameID(from: WidgetShared.libraryURL))
        XCTAssertNil(WidgetShared.gameID(from: URL(string: "https://example.com/open?id=x")!))
    }

    func testSnapshotJSONRoundTrip() throws {
        let data = try JSONEncoder.widget.encode(snap)
        XCTAssertEqual(try JSONDecoder.widget.decode(WidgetSnapshot.self, from: data), snap)
    }
}
