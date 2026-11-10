// Copyright (c) 2026 Charlie Rodriguez Garcia. All rights reserved.
import XCTest
@testable import TwinPlay

/// Games-folder import: recursive scan, duplicate detection by content, name clashes.
final class ROMFolderTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("twinplay-folder-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("GBA/Deep/Er"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".hidden"), withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    @discardableResult private func write(_ path: String, _ bytes: String) throws -> URL {
        let u = root.appendingPathComponent(path)
        try Data(bytes.utf8).write(to: u)
        return u
    }

    func testFindsGamesInSubfoldersOnly() throws {
        try write("a.nds", "A"); try write("GBA/b.GBA", "B"); try write("GBA/Deep/Er/c.gb", "C"); try write("GBA/Deep/d.gbc", "D")
        try write("notes.txt", "x"); try write("GBA/save.sav", "x"); try write(".hidden/e.nds", "E")
        let names = ROMFolder.findROMs(in: root).map(\.lastPathComponent)
        XCTAssertEqual(Set(names), ["a.nds", "b.GBA", "c.gb", "d.gbc"])
    }

    func testSkipsDuplicatesByContentAndRenamesClashes() throws {
        let lib = root.appendingPathComponent("lib"); try FileManager.default.createDirectory(at: lib, withIntermediateDirectories: true)
        let have = lib.appendingPathComponent("Game.gba"); try Data("GAME-1".utf8).write(to: have)
        let same = try write("GBA/Renamed copy.gba", "GAME-1")          // same content, other name: skip
        let clash = try write("Game.gba", "GAME-2")                      // other game, taken name: rename
        let twice1 = try write("x.nds", "DS"), twice2 = try write("GBA/Deep/x.nds", "DS")   // same game twice in the folder
        let plan = ROMFolder.plan(found: [same, clash, twice1, twice2], existing: [have])
        XCTAssertEqual(plan.duplicates, 2)
        XCTAssertEqual(plan.imports.map(\.name), ["Game (2).gba", "x.nds"])
    }

    func testFingerprintIgnoresNameAndSeesSize() throws {
        let a = try write("one.gb", "SAME"), b = try write("two.gb", "SAME"), c = try write("three.gb", "SAME!")
        XCTAssertEqual(ROMFolder.fingerprint(a), ROMFolder.fingerprint(b))
        XCTAssertNotEqual(ROMFolder.fingerprint(a), ROMFolder.fingerprint(c))
    }

    func testRealisticSkinsCoverEverySystem() {
        let ds = Skin.skins(for: .ds).filter { $0.shellStyle != .plain }
        let single = Skin.skins(for: .gba).filter { $0.shellStyle != .plain }
        XCTAssertEqual(Set(ds.map(\.shellStyle)), [.twin])   // #9: every DS colour uses the DS reference shell
        XCTAssertEqual(Set(single.map(\.shellStyle)), [.gba, .clamshell, .brick, .color, .phone])
        XCTAssertEqual(Skin.skins(for: .gb), Skin.skins(for: .gba))      // Game Boy games use the single-screen shells
    }
}
