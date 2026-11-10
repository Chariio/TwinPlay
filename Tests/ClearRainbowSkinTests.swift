// Copyright (c) 2026 Charlie Rodriguez Garcia. All rights reserved.
import XCTest
@testable import TwinPlay

final class ClearRainbowSkinTests: XCTestCase {
    private let systems: [GameSystem] = [.ds, .n3ds, .gba, .n64]

    func testAtLeastEightClearColorsOnEachSystem() {
        for sys in systems {
            let hues = Set(Skin.skins(for: sys).compactMap(\.clearHue))
            XCTAssertGreaterThanOrEqual(hues.count, 8, "\(sys)")
            for needed in [ClearHue.red, .orange, .yellow, .lime, .green, .darkGreen, .teal, .blue, .purple, .pink] {
                XCTAssertTrue(hues.contains(needed), "\(sys) missing \(needed)")
            }
        }
    }

    func testClearSkinsAreTranslucentAndFree() {
        for sys in systems {
            let clears = Skin.skins(for: sys).filter(\.isClearRainbow)
            XCTAssertFalse(clears.isEmpty, "\(sys)")
            for s in clears {
                XCTAssertTrue(s.lid.translucent, "\(s)")
                XCTAssertTrue(s.isFree, "\(s)")
                XCTAssertGreaterThan(s.palette.portraitOpacity, 0)
                XCTAssertTrue(s.palette.drawsShell, "\(s)")
            }
        }
    }

    func testKeptSkinsStillPresent() {
        XCTAssertTrue(Skin.skins(for: .ds).contains(.classicGray))
        XCTAssertEqual(GameSystem.ds.defaultSkin, .classicGray)
        XCTAssertEqual(Set(Skin.skins(for: .n64)).isSuperset(of: [.n64Original, .n64Charcoal, .n64Forest]), true)
        XCTAssertEqual(GameSystem.n64.defaultSkin, .n64Original)
        XCTAssertTrue(Skin.skins(for: .n3ds).contains(.n3dsPearl))
    }

    func testRetiredOpaqueDSColorsAreHiddenButStillDecode() {
        for s in [Skin.polarWhite, .onyxBlack, .cobaltBlue, .crimsonRed, .pink, .iceBlue] {
            XCTAssertTrue(s.isRetiredOpaqueColor)
            XCTAssertFalse(Skin.skins(for: .ds).contains(s))
            XCTAssertEqual(Skin(rawValue: s.rawValue), s)
        }
    }

    func testClearShellStylesPerSystem() {
        XCTAssertEqual(Skin.dsClearRed.shellStyle, .twin)
        XCTAssertEqual(Skin.n3dsClearRed.shellStyle, .twin)
        XCTAssertEqual(Skin.gbClearRed.shellStyle, .color)
        XCTAssertEqual(Skin.n64ClearRed.shellStyle, .nes)
        XCTAssertEqual(Skin.dsClearRed.padModel, .standard)
        XCTAssertEqual(Skin.n3dsClearRed.padModel, .standard)
    }

    func testPickerPutsClearGroupFirst() {
        for sys in systems {
            let groups = SkinPickerView.groups(for: sys)
            XCTAssertEqual(groups.first?.title, "Clear · Translucent", "\(sys)")
            XCTAssertGreaterThanOrEqual(groups.first?.skins.count ?? 0, 8, "\(sys)")
            let listed = Set(groups.flatMap(\.skins))
            XCTAssertEqual(listed, Set(Skin.skins(for: sys)))
        }
    }

    func testExistingClearRawValuesKept() {
        XCTAssertEqual(Skin(rawValue: "dsClearIce"), .dsClearIce)
        XCTAssertEqual(Skin(rawValue: "dsClearGrape")?.clearHue, .purple)
        XCTAssertEqual(Skin.n64Original.rawValue, "n64Original")
        XCTAssertEqual(Skin.classicGray.rawValue, "classicGray")
        XCTAssertEqual(Skin.twinPearl.rawValue, "duoPearl")
    }
}
