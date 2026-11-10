// Copyright (c) 2026 Charlie Rodriguez Garcia. All rights reserved.
import XCTest
@testable import TwinPlay

final class GameProfileTests: XCTestCase {
    func testBundledTableParses() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("DSEmu/Resources/GameProfiles.json")
        let data = try Data(contentsOf: url)
        let table = GameProfiles.parse(data)
        XCTAssertGreaterThan(table.count, 8)
        XCTAssertEqual(table["ds:AMCE"]?.is3D, true)
        XCTAssertEqual(table["ds:AMCE"]?.scale, 2)
        XCTAssertEqual(table["gba:BPEE"]?.scale, 1)
        XCTAssertEqual(table["gba:BPEE"]?.filter, "nearest")
        XCTAssertEqual(table["snes:family:1"]?.frameSkip, "off")
        XCTAssertEqual(table["nes:mapper:5"]?.frameSkip, "off")
        XCTAssertNil(table.values.first { $0.frameSkip != "off" })
    }

    func testUnknownDSIsUnlockedAnd2DSystemsAreCrisp() {
        let empty: [String: GameProfileEntry] = [:]
        let ds = GameProfiles.recommend(GameIdentity(primary: "ds:ZZZZ", keys: ["ds:ZZZZ", "ds"]), system: .ds, table: empty)
        XCTAssertFalse(ds.locked)
        XCTAssertEqual(ds.scale, 2)
        XCTAssertEqual(ds.filter, "sharpBilinear")
        XCTAssertEqual(ds.frameSkip, "off")
        let gba = GameProfiles.recommend(GameIdentity(primary: "gba:ZZZZ", keys: ["gba:ZZZZ", "gba"]), system: .gba, table: empty)
        XCTAssertTrue(gba.locked)
        XCTAssertEqual(gba.scale, 1)
        XCTAssertEqual(gba.filter, "nearest")
        let snes = GameProfiles.recommend(GameIdentity(primary: "snes", keys: ["snes:chip:13", "snes:family:1", "snes"]), system: .snes, table: GameProfiles.parse(Data(
            #"{"games":{"snes:family:1":{"scale":1,"filter":"nearest","frameskip":"off","threeD":false}}}"#.utf8)))
        XCTAssertTrue(snes.locked)
        XCTAssertEqual(snes.frameSkip, "off")
    }

    func testRecommendedToggleDefaultsOn() {
        let d = UserDefaults(suiteName: "twinplay.profile.test")!
        let key = GameProfiles.toggleKey("ds:AMCE")
        d.removeObject(forKey: key)
        XCTAssertTrue(GameProfiles.isEnabled("ds:AMCE", defaults: d))
        GameProfiles.setEnabled("ds:AMCE", false, defaults: d)
        XCTAssertFalse(GameProfiles.isEnabled("ds:AMCE", defaults: d))
        XCTAssertTrue(key.hasPrefix("twinplay."))
        XCTAssertFalse(key.contains("nduo"))
    }
}
