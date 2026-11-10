// Copyright (c) 2026 Charlie Rodriguez Garcia. All rights reserved.
import XCTest
@testable import TwinPlay

/// #14 iPad: the DS reference layout in large windows of the right proportions, the regular
/// layout otherwise (phones, narrow Split View / Stage Manager windows).
final class IPadLayoutTests: XCTestCase {
    private func check(_ size: CGSize, file: StaticString = #filePath, line: UInt = #line) {
        let frame = CGRect(x: 0, y: 24, width: size.width, height: size.height - 44)
        guard let l = DualScreenLayout.makeReference(frame: frame) else { return XCTFail("no layout for \(size)", file: file, line: line) }
        XCTAssertTrue(l.twin, file: file, line: line)
        let bar = DualScreenLayout.twinBar(hinge: l.hinge)
        XCTAssertFalse(l.top.intersects(bar), file: file, line: line); XCTAssertFalse(l.bottom.intersects(bar), file: file, line: line)
        XCTAssertTrue(frame.contains(l.top) && frame.contains(l.bottom), "\(l.top) \(l.bottom)", file: file, line: line)
        XCTAssertGreaterThan(l.top.minY, frame.minY + 44, "below the corner buttons", file: file, line: line)
        XCTAssertGreaterThan(l.top.width, 340, file: file, line: line)   // iPad mini landscape is the tightest (~361)
        XCTAssertEqual(l.top.width / l.top.height, 4.0 / 3.0, accuracy: 0.01, file: file, line: line)
        let pad = TouchPadLayout.make(layout: l, system: .ds, showsButtons: true, stylus: l.bottom)
        for z in pad.zones {
            XCTAssertFalse(z.rect.intersects(l.top) || z.rect.intersects(l.bottom), "\(z.label) \(size)", file: file, line: line)
            XCTAssertTrue(frame.insetBy(dx: -1, dy: -1).contains(z.rect), "\(z.label) \(size)", file: file, line: line)
        }
    }

    func testIPadPortraitAndLandscape() {
        for s in [CGSize(width: 820, height: 1180), CGSize(width: 1180, height: 820),        // iPad Air 11"
                  CGSize(width: 834, height: 1210), CGSize(width: 1210, height: 834),        // iPad Pro 11" (M4)
                  CGSize(width: 1032, height: 1376), CGSize(width: 1376, height: 1032),      // iPad Pro 13"
                  CGSize(width: 744, height: 1133), CGSize(width: 1133, height: 744)] {      // iPad mini
            check(s)
        }
    }

    func testFallsBackOnPhonesAndNarrowWindows() {
        XCTAssertNil(DualScreenLayout.makeReference(frame: CGRect(x: 0, y: 0, width: 440, height: 956)))   // iPhone portrait
        XCTAssertNil(DualScreenLayout.makeReference(frame: CGRect(x: 0, y: 0, width: 956, height: 440)))   // iPhone landscape
        XCTAssertNil(DualScreenLayout.makeReference(frame: CGRect(x: 0, y: 0, width: 507, height: 1180)))  // Split View half
        XCTAssertNil(DualScreenLayout.makeReference(frame: CGRect(x: 0, y: 0, width: 1180, height: 600)))  // short Stage Manager window
    }

    func testStageManagerResizeKeepsWorking() {
        // Any window in range gives a valid layout as it is resized.
        var w: CGFloat = 700
        while w <= 1300 { if let _ = DualScreenLayout.makeReference(frame: CGRect(x: 0, y: 0, width: w, height: 900)) { check(CGSize(width: w, height: 944)) }; w += 50 }
    }

    /// NES and Super NES on every iPad size, plus a narrow Split View and a short Stage Manager window.
    /// The screen keeps its aspect, the shell's controls stay on screen and off the picture, and each
    /// console has its own buttons. Resizing just passes a new size into the same layout.
    func testNESAndSNESOnIPadAndSplitView() {
        let ipads: [CGSize] = [
            CGSize(width: 820, height: 1180), CGSize(width: 1180, height: 820),
            CGSize(width: 834, height: 1210), CGSize(width: 1210, height: 834),
            CGSize(width: 1032, height: 1376), CGSize(width: 1376, height: 1032),
            CGSize(width: 744, height: 1133), CGSize(width: 1133, height: 744),
            CGSize(width: 507, height: 1180),   // Split View half, portrait
            CGSize(width: 1180, height: 507),   // Split View half, landscape
            CGSize(width: 700, height: 600),    // short Stage Manager window
            CGSize(width: 900, height: 700),
        ]
        let systems: [(PadSystem, CGFloat, Set<String>, Set<String>)] = [
            (.nes, 256.0 / 240.0, ["D-pad", "B", "A", "SELECT", "START"], ["L", "R", "X", "Y"]),
            (.snes, 256.0 / 224.0, ["D-pad", "Y", "X", "B", "A", "L", "R", "SELECT", "START"], []),
        ]
        for size in ipads {
            let frame = CGRect(x: 0, y: 24, width: size.width, height: max(1, size.height - 44))
            for (sys, aspect, need, absent) in systems {
                let raw = DualScreenLayout.makeSingle(size: frame.size, showsControls: true, aspect: aspect, portraitMargin: 12)
                let l = raw.offsetBy(dx: frame.minX, dy: frame.minY)
                XCTAssertTrue(l.isSingle, "\(sys) \(size)")
                XCTAssertEqual(l.top.width / l.top.height, aspect, accuracy: 0.02, "\(sys) \(size)")
                XCTAssertTrue(frame.insetBy(dx: -1, dy: -1).contains(l.top), "\(sys) screen \(size)")
                let pad = TouchPadLayout.make(layout: l, system: sys, showsButtons: true, stylus: nil)
                let labels = Set(pad.zones.map(\.label))
                XCTAssertTrue(need.isSubset(of: labels), "\(sys) \(size) has \(labels)")
                XCTAssertTrue(absent.isDisjoint(with: labels), "\(sys) \(size) has \(labels)")
                for z in pad.zones {
                    XCTAssertFalse(z.rect.intersects(l.top), "\(sys) \(z.label) covers the screen at \(size)")
                    XCTAssertTrue(CGRect(origin: .zero, size: size).insetBy(dx: -1, dy: -1).contains(z.rect),
                                  "\(sys) \(z.label) leaves the window at \(size)")
                }
                // The two consoles do not share a skin.
                if sys == .nes { XCTAssertEqual(Skin.skins(for: .nes), [.nesFog, .nesGraphite]) }
                if sys == .snes { XCTAssertEqual(Skin.skins(for: .snes), [.snesFog, .snesLilac]) }
            }
        }
        // A live resize (Stage Manager drag) keeps producing a layout at every width.
        var w: CGFloat = 500
        while w <= 1376 {
            let size = CGSize(width: w, height: 900)
            let l = DualScreenLayout.makeSingle(size: size, showsControls: true, aspect: 256.0 / 240.0)
            let pad = TouchPadLayout.make(layout: l, system: .snes, showsButtons: true, stylus: nil)
            XCTAssertGreaterThan(l.top.width, 40, "width \(w)")
            XCTAssertEqual(Set(pad.zones.map(\.label)), Set(["D-pad", "Y", "X", "B", "A", "L", "R", "SELECT", "START"]))
            for z in pad.zones {
                XCTAssertFalse(z.rect.intersects(l.top), "resize \(w) \(z.label)")
                XCTAssertTrue(CGRect(origin: .zero, size: size).insetBy(dx: -1, dy: -1).contains(z.rect), "resize \(w) \(z.label)")
            }
            w += 40
        }
    }
}
