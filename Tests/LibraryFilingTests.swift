// Copyright (c) 2026 Charlie Rodriguez Garcia. All rights reserved.
import XCTest
@testable import TwinPlay

/// Which folder each game lands in, and that saved grid layouts survive the fixes.
final class LibraryFilingTests: XCTestCase {

    // MARK: System detection

    func testExtensionsDecideForDSAndGBA() {
        XCTAssertEqual(ROMLibrary.classify(ext: "nds", headerSystem: 0, headerIsGBA: false), .ds)
        XCTAssertEqual(ROMLibrary.classify(ext: "gba", headerSystem: 1, headerIsGBA: true), .gba)
        // A .gba is never filed as Game Boy, whatever a stale header cache says.
        XCTAssertEqual(ROMLibrary.classify(ext: "gba", headerSystem: 2, headerIsGBA: false), .gba)
        XCTAssertEqual(ROMLibrary.classify(ext: "GBA", headerSystem: nil, headerIsGBA: nil), .gba)
        XCTAssertEqual(ROMLibrary.classify(ext: "nds", headerSystem: 3, headerIsGBA: nil), .ds)
    }

    func testGameBoyUsesTheCGBFlag() {
        XCTAssertEqual(ROMLibrary.classify(ext: "gb", headerSystem: 2, headerIsGBA: false), .gb)
        XCTAssertEqual(ROMLibrary.classify(ext: "gb", headerSystem: 3, headerIsGBA: false), .gbc)   // CGB-compatible .gb
        XCTAssertEqual(ROMLibrary.classify(ext: "gbc", headerSystem: 3, headerIsGBA: false), .gbc)
        XCTAssertEqual(ROMLibrary.classify(ext: "gbc", headerSystem: 2, headerIsGBA: false), .gb)   // DMG-only game renamed .gbc
        XCTAssertEqual(ROMLibrary.classify(ext: "gb", headerSystem: nil, headerIsGBA: nil), .gb)    // header not read yet
        XCTAssertEqual(ROMLibrary.classify(ext: "gbc", headerSystem: nil, headerIsGBA: nil), .gbc)
        XCTAssertEqual(ROMLibrary.classify(ext: "sgb", headerSystem: 2, headerIsGBA: nil), .gb)
    }

    func testNESAndSNESExtensions() {
        XCTAssertEqual(ROMLibrary.classify(ext: "nes", headerSystem: nil, headerIsGBA: nil), .nes)
        XCTAssertEqual(ROMLibrary.classify(ext: "NES", headerSystem: 1, headerIsGBA: true), .nes)
        XCTAssertEqual(ROMLibrary.classify(ext: "sfc", headerSystem: nil, headerIsGBA: nil), .snes)
        XCTAssertEqual(ROMLibrary.classify(ext: "smc", headerSystem: 0, headerIsGBA: false), .snes)
        XCTAssertEqual(ROMLibrary.classify(ext: "bin", headerSystem: 4, headerIsGBA: false), .nes)
        XCTAssertEqual(ROMLibrary.classify(ext: "bin", headerSystem: 5, headerIsGBA: true), .snes)
        XCTAssertEqual(GameSystem.nes.screenAspect, 256.0 / 240.0, accuracy: 0.001)
        XCTAssertEqual(GameSystem.snes.screenAspect, 256.0 / 224.0, accuracy: 0.001)
        XCTAssertEqual(Skin.current(for: .nes, raw: nil), .nesFog)
        XCTAssertEqual(Skin.current(for: .snes, raw: nil), .snesFog)
        XCTAssertFalse(Skin.skins(for: .nes).contains(.gbaIndigo))
        XCTAssertFalse(Skin.skins(for: .gba).contains(.nesFog))
    }

    func testUnknownExtensionFallsBackToHeader() {
        XCTAssertEqual(ROMLibrary.classify(ext: "bin", headerSystem: 1, headerIsGBA: true), .gba)
        XCTAssertEqual(ROMLibrary.classify(ext: "bin", headerSystem: 3, headerIsGBA: false), .gbc)
        XCTAssertEqual(ROMLibrary.classify(ext: "bin", headerSystem: 0, headerIsGBA: false), .ds)
    }

    // MARK: Classic folders

    private func entry(_ file: String, _ sys: GameSystem, fav: Bool = false) -> ROMLibrary.Entry {
        ROMLibrary.Entry(url: URL(fileURLWithPath: "/roms/" + file), name: file, dateAdded: Date(),
                         favorite: fav, system: sys)
    }

    func testAllHoldsEveryGameAndFoldersHoldTheirSystem() {
        let games = [entry("a.nds", .ds), entry("b.gba", .gba, fav: true), entry("c.gb", .gb), entry("d.gbc", .gbc), entry("e.gba", .gba)]
        typealias F = ClassicDSMenuView.Folder
        XCTAssertEqual(F.all.filter(games).count, games.count)
        XCTAssertEqual(F.ds.filter(games).map(\.name), ["a.nds"])
        XCTAssertEqual(F.gba.filter(games).map(\.name), ["b.gba", "e.gba"])
        XCTAssertEqual(F.gb.filter(games).map(\.name), ["c.gb"])
        XCTAssertEqual(F.gbc.filter(games).map(\.name), ["d.gbc"])
        XCTAssertEqual(F.favorites.filter(games).map(\.name), ["b.gba"])
        // Every game is in exactly one system folder.
        let perSystem = [F.ds, .gba, .gb, .gbc].map { $0.filter(games).count }.reduce(0, +)
        XCTAssertEqual(perSystem, games.count)
        XCTAssertEqual(F.allCases.first, .all)
    }

    // MARK: Saved grid layouts

    func testReconcileKeepsArrangementAndDropsGamesFromOtherFolders() {
        // A "gb" layout that wrongly picked up GBA games (old bug) plus the user's own arrangement.
        var folder = ClassicSlot(kind: .folder, name: "Faves", items: ["c.gb", "mario.gba"])
        folder.id = "F"
        let saved: [ClassicSlot] = [.empty(), .game("x.gb"), .game("mario.gba"), folder, .game("c2.gb")]
        let out = ClassicGridStore.reconcile(saved, games: ["c.gb", "c2.gb", "x.gb", "new.gb"])
        XCTAssertEqual(out.first?.kind, .empty)                     // user's gap kept
        XCTAssertEqual(out[1].game, "x.gb")                         // order kept
        XCTAssertFalse(out.contains { $0.game == "mario.gba" })     // GBA game removed from GB layout
        XCTAssertEqual(out.first { $0.id == "F" }?.items, ["c.gb"]) // folder kept, cleaned
        XCTAssertEqual(out.last?.game, "new.gb")                    // new game appended
        XCTAssertEqual(out.compactMap(\.game).count + (out.first { $0.id == "F" }?.items?.count ?? 0), 4)
    }

    // MARK: Box art names (NES / Super NES)

    func testBoxArtRegionAndRevisionCleanup() {
        // DS/GBA product codes still decide the region. Mapper and map-mode strings do not.
        XCTAssertEqual(BoxArtFinder.regionTag(gameCode: "AZLE"), "(USA")
        XCTAssertEqual(BoxArtFinder.regionTag(gameCode: "AZLP"), "(Europe")
        XCTAssertNil(BoxArtFinder.regionTag(gameCode: "LoROM"))
        XCTAssertNil(BoxArtFinder.regionTag(gameCode: "HiROM"))
        XCTAssertNil(BoxArtFinder.regionTag(gameCode: "M000"))
        XCTAssertEqual(BoxArtFinder.regionFromNames(["Super Mario Bros. (USA) (Rev 0)"]), "(USA")
        XCTAssertEqual(BoxArtFinder.regionFromNames(["Legend of Zelda, The (Europe)"]), "(Europe")
        // "(Rev 0)" is a tag, not part of the title, so it still matches the plain release.
        let usa = BoxArtFinder.score(query: "Super Mario Bros. (USA) (Rev 0)",
                                     candidate: "Super Mario Bros. (World)",
                                     region: "(USA", looseRegion: true, system: .nes)
        let hack = BoxArtFinder.score(query: "Super Mario Bros. (USA) (Rev 0)",
                                      candidate: "Super Mario Bros. (1985-09-13)(Nintendo)(JP-US)[h Vimm][iNES title]",
                                      region: "(USA", looseRegion: true, system: .nes)
        XCTAssertGreaterThan(usa, 1.0)
        XCTAssertGreaterThan(usa, hack)
        // A GBA query is scored the same way it was: no GoodTools penalty, code region only.
        let gba = BoxArtFinder.score(query: "Zelda", candidate: "The Legend of Zelda (USA)", region: "(USA", system: .gba)
        XCTAssertGreaterThan(gba, 0.5)
    }

    func testSNESInternalTitleAliases() {
        XCTAssertEqual(BoxArtFinder.headerAliases(system: .snes, title: "THE LEGEND OF ZELDA"),
                       ["Legend of Zelda, The - A Link to the Past"])
        XCTAssertEqual(BoxArtFinder.headerAliases(system: .snes, title: "SUPER MARIOWORLD"),
                       ["Super Mario World"])
        XCTAssertEqual(BoxArtFinder.headerAliases(system: .nes, title: "THE LEGEND OF ZELDA"),
                       ["Legend of Zelda, The"])
        let aliased = BoxArtFinder.score(query: "Legend of Zelda, The - A Link to the Past",
                                         candidate: "Legend of Zelda, The - A Link to the Past (USA)",
                                         region: "(USA", looseRegion: true, system: .snes)
        XCTAssertGreaterThanOrEqual(aliased, BoxArtFinder.autoApplyScore)
    }

    func testGitTreeIndexParsesBoxArtNames() {
        let json = #"{"tree":[{"path":"Named_Boxarts/Super Mario Bros. (World).png","type":"blob"},{"path":"Named_Snaps/other.png","type":"blob"},{"path":"README.md","type":"blob"}]}"#
        let names = BoxArtFinder.parseGitTree(Data(json.utf8), prefix: "Named_Boxarts")
        XCTAssertEqual(names, ["Super Mario Bros. (World)"])
    }
}
