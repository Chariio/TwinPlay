// Copyright (c) 2026 Charlie Rodriguez Garcia. All rights reserved.
import XCTest
@testable import TwinPlay

/// MENU pill: saved per skin (and per layout key), Reset clears it, the outer shell has no
/// decorative dot under R any more.
final class MenuPillTests: XCTestCase {
    private func defaults() -> UserDefaults {
        let d = UserDefaults(suiteName: "MenuPillTests-\(UUID().uuidString)")!
        return d
    }

    func testMenuSavedPerSkin() {
        let d = defaults(), key = "layout.v1.test.outer.portrait.gba.automatic"
        var c = CustomLayout()
        c.controls["menu"] = ItemPlacement(cx: 0.8, cy: 0.1, size: 1)
        c.controls["dpad"] = ItemPlacement(cx: 0.2, cy: 0.7, size: 1.2)
        LayoutStore.save(c, for: key, skin: "gbaPurple", defaults: d)
        let same = LayoutStore.load(key, skin: "gbaPurple", defaults: d)
        XCTAssertEqual(same, c)
        let other = LayoutStore.load(key, skin: "gbaYellow", defaults: d)
        XCTAssertNil(other.control(.menu), "another skin keeps the default MENU spot")
        XCTAssertEqual(other.control(.dpad), c.control(.dpad), "the rest of the layout is shared")
        // Another orientation / posture key: default too.
        XCTAssertNil(LayoutStore.load(key.replacingOccurrences(of: "portrait", with: "landscape"), skin: "gbaPurple", defaults: d).control(.menu))
        // Reset to Default clears both parts.
        LayoutStore.save(CustomLayout(), for: key, skin: "gbaPurple", defaults: d)
        XCTAssertTrue(LayoutStore.load(key, skin: "gbaPurple", defaults: d).isEmpty)
    }

    func testSplitMerge() {
        var c = CustomLayout(); c.controls["menu"] = ItemPlacement(cx: 0.5, cy: 0.05, size: 1.2)
        let (base, menu) = LayoutStore.split(c)
        XCTAssertNil(base.control(.menu)); XCTAssertEqual(menu.control(.menu), c.control(.menu))
        XCTAssertEqual(LayoutStore.merged(base, menu: menu), c)
    }

    func testOuterShellSpotsInside() {
        for size in [CGSize(width: 466, height: 678), CGSize(width: 678, height: 466)] {
            for gba in [true, false] {
                let l = DualScreenLayout.makeOuter(size: size, aspect: gba ? 1.5 : 160.0 / 144.0, gba: gba)
                let m = l.outerSpots.menu
                XCTAssertTrue(CGRect(origin: .zero, size: size).insetBy(dx: 20, dy: 10).contains(m))
                XCTAssertFalse(l.top.contains(m), "MENU never on the game screen")
            }
        }
    }
}
