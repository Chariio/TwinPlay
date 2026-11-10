// Copyright (c) 2026 Charlie Rodriguez Garcia. All rights reserved.
import XCTest
@testable import TwinPlay

/// Edit Layout: persistence per device / console / orientation, placement maths, snap guides.
final class LayoutCustomizationTests: XCTestCase {
    private let full = CGSize(width: 440, height: 956)
    private var defaults: UserDefaults!

    override func setUp() {
        defaults = UserDefaults(suiteName: "twinplay.layout.tests")!
        defaults.removePersistentDomain(forName: "twinplay.layout.tests")
    }

    private func dsLayout() -> (DualScreenLayout, TouchPadLayout) {
        let frame = CGSize(width: full.width, height: full.height - 59 - 34)
        let l = DualScreenLayout.make(size: frame, arrangement: .automatic, showsControls: true).offsetBy(dx: 0, dy: 59)
        return (l, TouchPadLayout.make(layout: l, system: .ds, showsButtons: true, stylus: l.bottom))
    }

    func testSaveLoadResetRoundTrip() {
        var c = CustomLayout()
        c.screens["top"] = ItemPlacement(cx: 0.5, cy: 0.2, size: 0.8)
        c.controls["menu"] = ItemPlacement(cx: 0.3, cy: 0.9, size: 1.2)
        let k = LayoutStore.key(device: "iPhone18,2", layoutKey: "flat.portrait.both.automatic")
        LayoutStore.save(c, for: k, defaults: defaults)
        XCTAssertEqual(LayoutStore.load(k, defaults: defaults), c)
        LayoutStore.reset(k, defaults: defaults)
        XCTAssertTrue(LayoutStore.load(k, defaults: defaults).isEmpty)
        XCTAssertNil(defaults.data(forKey: k))
    }

    func testLayoutsAreSavedPerDeviceConsoleAndOrientation() {
        var a = CustomLayout(); a.screens["top"] = ItemPlacement(cx: 0.5, cy: 0.3, size: 0.7)
        let kPortrait = LayoutStore.key(device: "iPhone18,2", layoutKey: "flat.portrait.both.automatic")
        let kLandscape = LayoutStore.key(device: "iPhone18,2", layoutKey: "flat.landscape.both.automatic")
        let kGBA = LayoutStore.key(device: "iPhone18,2", layoutKey: "flat.portrait.gba.automatic")
        let kOther = LayoutStore.key(device: "iPhone17,1", layoutKey: "flat.portrait.both.automatic")
        LayoutStore.save(a, for: kPortrait, defaults: defaults)
        for k in [kLandscape, kGBA, kOther] { XCTAssertTrue(LayoutStore.load(k, defaults: defaults).isEmpty, k) }
        XCTAssertEqual(LayoutStore.load(kPortrait, defaults: defaults), a)
    }

    func testScreenPlacementKeepsAspectAndStaysOnScreen() {
        let (l, _) = dsLayout()
        var c = CustomLayout()
        c.screens["top"] = ItemPlacement(cx: 1.4, cy: -0.5, size: 0.5)    // far outside: clamped
        let out = l.applying(c, in: full)
        XCTAssertEqual(out.top.width, full.width * 0.5, accuracy: 0.5)
        XCTAssertEqual(out.top.width / out.top.height, l.top.width / l.top.height, accuracy: 0.001)
        XCTAssertGreaterThanOrEqual(out.top.minX, 0); XCTAssertLessThanOrEqual(out.top.maxX, full.width)
        XCTAssertGreaterThanOrEqual(out.top.minY, 0)
        XCTAssertEqual(out.bottom, l.bottom)                               // untouched
    }

    func testControlPlacementMovesScalesAndKeepsTouchTargets() {
        let (_, p) = dsLayout()
        var c = CustomLayout()
        c.controls["face"] = ItemPlacement(cx: 0.5, cy: 0.5, size: 0.6)
        c.controls["start"] = ItemPlacement(cx: 0.1, cy: 0.95, size: 0.6)
        let out = p.applying(c, in: full)
        let faces = out.zones.filter { TouchPadLayout.group(of: $0) == .face }
        let center = CGPoint(x: faces.map(\.rect.midX).reduce(0, +) / 4, y: faces.map(\.rect.midY).reduce(0, +) / 4)
        XCTAssertEqual(center.x, full.width * 0.5, accuracy: 6)
        XCTAssertEqual(center.y, full.height * 0.5, accuracy: 6)
        for z in out.zones {
            XCTAssertGreaterThanOrEqual(min(z.hit.width, z.hit.height), 43.9, "\(z.label) hit area under 44pt")
            XCTAssertTrue(CGRect(origin: .zero, size: full).contains(z.rect), "\(z.label) off screen")
        }
        // Groups without a placement are unchanged.
        XCTAssertEqual(out.zones.first { TouchPadLayout.group(of: $0) == .dpad }?.rect, p.zones.first { $0.isDPad }?.rect)
    }

    func testEmptyLayoutIsANoOp() {
        let (l, p) = dsLayout()
        XCTAssertEqual(l.applying(CustomLayout(), in: full), l)
        XCTAssertEqual(p.applying(CustomLayout(), in: full), p)
    }

    func testSnapGuidesPullToCentreAndEdges() {
        let r = CGRect(x: 100, y: 300, width: 236, height: 100)          // midX 218
        let s = LayoutMath.snap(r, xs: [220], ys: [500], threshold: 7)
        XCTAssertEqual(s.dx, 2); XCTAssertEqual(s.vGuides, [220])
        XCTAssertEqual(s.dy, 0); XCTAssertTrue(s.hGuides.isEmpty)        // 500 is 100pt away
        XCTAssertEqual(LayoutMath.clamp(CGRect(x: -20, y: 900, width: 100, height: 100), in: CGRect(origin: .zero, size: full)),
                       CGRect(x: 0, y: 856, width: 100, height: 100))
    }

    func testMenuNeverLeavesTheScreenRange() {
        XCTAssertEqual(LayoutControl.menu.scaleRange.lowerBound, 1.0)    // never below its 44pt size
        XCTAssertTrue(LayoutControl.allCases.contains(.menu))
    }
}
