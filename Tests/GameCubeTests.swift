// Copyright (c) 2026 Charlie Rodriguez Garcia. All rights reserved.
import XCTest
@testable import TwinPlay

final class GameCubeTests: XCTestCase {
    func testExtensionsAreGameCube() {
        for ext in ["iso", "gcm", "rvz", "ciso", "gcz", "zip", "ISO", "RVZ"] {
            XCTAssertEqual(ROMLibrary.classify(ext: ext, headerSystem: nil, headerIsGBA: nil), .gamecube, ext)
        }
        XCTAssertEqual(ROMLibrary.classify(ext: "nds", headerSystem: nil, headerIsGBA: nil), .ds)
        XCTAssertEqual(ROMLibrary.classify(ext: "n64", headerSystem: nil, headerIsGBA: nil), .n64)
    }

    func testDiscMagic() {
        var gc = Data(count: 0x20)
        gc[0x1C] = 0xC2; gc[0x1D] = 0x33; gc[0x1E] = 0x9F; gc[0x1F] = 0x3D
        XCTAssertEqual(GameCubeDisc.kind(header: gc), .gamecube)

        var wii = Data(count: 0x20)
        wii[0x18] = 0x5D; wii[0x19] = 0x1C; wii[0x1A] = 0x9E; wii[0x1B] = 0xA3
        XCTAssertEqual(GameCubeDisc.kind(header: wii), .wii)

        XCTAssertEqual(GameCubeDisc.kind(header: Data(count: 4)), .unknown)
        XCTAssertEqual(GameCubeDisc.kind(header: Data(count: 0x20)), .unknown)
    }

    func testSystemShape() {
        XCTAssertEqual(GameSystem.gamecube.label, "GameCube")
        XCTAssertEqual(GameSystem.gamecube.longName, "GameCube")
        XCTAssertTrue(GameSystem.gamecube.isSingleScreen)
        XCTAssertEqual(GameSystem.gamecube.screenAspect, 4.0 / 3.0, accuracy: 0.001)
        XCTAssertEqual(GameSystem.gamecube.skinSystem, .n64)
        XCTAssertEqual(GameSystem.gamecube.defaultSkin, .n64Original)
        XCTAssertEqual(RetroAchievementsRules.console(for: .gamecube), 16)
        XCTAssertFalse(GameCubeDisc.englishNotice.localizedCaseInsensitiveContains("duo"))
        XCTAssertTrue(GameCubeDisc.englishNotice.contains("iPhone 15 Pro"))
        XCTAssertTrue(GameCubeDisc.englishNotice.contains("M-series"))
        #if os(iOS)
        XCTAssertTrue(GameCubeDisc.showsOnThisPlatform)
        #else
        XCTAssertFalse(GameCubeDisc.showsOnThisPlatform)
        #endif
    }

    func testClassicFolder() {
        let game = ROMLibrary.Entry(url: URL(fileURLWithPath: "/roms/kart.iso"), name: "kart.iso",
                                    dateAdded: Date(), system: .gamecube)
        let folder = ClassicDSMenuView.Folder.gamecube
        XCTAssertEqual(folder.system, .gamecube)
        XCTAssertEqual(folder.filter([game]).map(\.name), ["kart.iso"])
        XCTAssertEqual(folder.englishTitle, "GameCube")
    }
}
