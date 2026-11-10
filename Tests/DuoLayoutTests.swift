// Copyright (c) 2026 Charlie Rodriguez Garcia. All rights reserved.
import XCTest
import SwiftUI
@testable import TwinPlay

/// iPhone Duo layout fixes: the reported hinge is only trusted when it fits the window, saved
/// screen placements that would swap / stack the screens are ignored on the Duo, landscape keeps
/// the DS screens stacked, and the library always fills the display in the portrait arrangement.
final class DuoLayoutTests: XCTestCase {
    private let inner = CGSize(width: 669, height: 951)
    private let innerLand = CGSize(width: 951, height: 669)
    private let outer = CGSize(width: 466, height: 678)
    private let outerLand = CGSize(width: 678, height: 466)
    private let proMax = CGSize(width: 440, height: 956)

    // MARK: hinge

    func testHingeAcceptedWhenItFitsTheWindow() {
        let band = CGRect(x: 0, y: 463, width: 669, height: 24)
        XCTAssertEqual(FoldGeometry.validated(band, full: inner), band)
        let vertical = CGRect(x: 463, y: 0, width: 24, height: 669)
        XCTAssertEqual(FoldGeometry.validated(vertical, full: innerLand), vertical)
        XCTAssertNotNil(FoldGeometry.validated(CGRect(x: 0, y: 475, width: 669, height: 0), full: inner))  // zero-thickness crease
    }

    func testStaleOrBogusHingeRejected() {
        // Portrait band still reported after rotating to landscape.
        XCTAssertNil(FoldGeometry.validated(CGRect(x: 0, y: 463, width: 669, height: 24), full: innerLand))
        // Landscape band reported while the window is portrait.
        XCTAssertNil(FoldGeometry.validated(CGRect(x: 463, y: 0, width: 24, height: 669), full: inner))
        // A whole panel / wide inactive region instead of the crease.
        XCTAssertNil(FoldGeometry.validated(CGRect(x: 0, y: 300, width: 669, height: 350), full: inner))
        // Far from the middle, empty, or nothing.
        XCTAssertNil(FoldGeometry.validated(CGRect(x: 0, y: 120, width: 669, height: 24), full: inner))
        XCTAssertNil(FoldGeometry.validated(.zero, full: inner))
        XCTAssertNil(FoldGeometry.validated(nil, full: inner))
    }

    func testPostureFromAngle() {
        XCTAssertEqual(FoldPosture.from(angle: 180), .open)
        XCTAssertEqual(FoldPosture.from(angle: 172), .open)
        XCTAssertEqual(FoldPosture.from(angle: 120), .book)
        XCTAssertEqual(FoldPosture.from(angle: 0), .closed)
    }

    func testDuoDetection() {
        for s in [inner, innerLand, outer, outerLand] { XCTAssertTrue(OuterDisplay.isDuo(hingeKnown: false, posture: .flat, windowSize: s), "\(s)") }
        for s in [proMax, CGSize(width: 956, height: 440), CGSize(width: 402, height: 874), CGSize(width: 375, height: 812)] {
            XCTAssertFalse(OuterDisplay.isDuo(hingeKnown: false, posture: .flat, windowSize: s), "\(s)")
        }
        XCTAssertTrue(OuterDisplay.isDuo(hingeKnown: true, posture: .flat, windowSize: proMax))
    }

    // MARK: emulator layout

    private func flatOpen(hinge: CGRect? = nil, full: CGSize? = nil) -> DualScreenLayout {
        let f = full ?? inner
        let safe = CGRect(x: 0, y: 24, width: f.width, height: f.height - 24 - 20)
        let h = FoldGeometry.validated(hinge, full: f) ?? FoldGeometry.defaultHinge(full: f)
        return DualScreenLayout.makeFolded(safe: safe, hinge: h, posture: .open, isGBA: false, showsControls: true)
    }

    private func assertStackedAndLarge(_ l: DualScreenLayout, minWidth: CGFloat, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertLessThan(l.top.maxY, l.bottom.minY + 0.5, "top screen above the touch screen", file: file, line: line)
        XCTAssertFalse(l.top.insetBy(dx: 1, dy: 1).intersects(l.bottom), file: file, line: line)
        XCTAssertGreaterThan(l.top.width, minWidth, file: file, line: line)
        XCTAssertGreaterThan(l.bottom.width, minWidth, file: file, line: line)
    }

    /// Fully flat in portrait: large screens either side of the hinge, in order, whatever region
    /// the system hands back.
    func testFlatPortraitScreensStayLargeAndInOrder() {
        for reported in [nil, CGRect(x: 0, y: 463, width: 669, height: 24), CGRect(x: 0, y: 300, width: 669, height: 350),
                         CGRect(x: 463, y: 0, width: 24, height: 951), .zero] as [CGRect?] {
            let l = flatOpen(hinge: reported)
            assertStackedAndLarge(l, minWidth: 400)
            XCTAssertLessThan(l.top.maxY, inner.height / 2); XCTAssertGreaterThan(l.bottom.minY, inner.height / 2)
        }
    }

    /// Saved placements that swap / shrink the screens (saved under the wrong key) are ignored
    /// on the Duo; sensible ones are kept; a regular iPhone keeps whatever the user saved.
    func testSwappedSavedScreensIgnoredOnDuo() {
        let base = flatOpen()
        var bad = CustomLayout()
        bad.screens["top"] = ItemPlacement(cx: 0.5, cy: 0.68, size: 0.40)
        bad.screens["bottom"] = ItemPlacement(cx: 0.5, cy: 0.30, size: 0.33)
        let r = base.applyingChecked(bad, in: inner, foldable: true)
        XCTAssertTrue(r.rejectedScreens)
        XCTAssertEqual(r.layout, base)
        XCTAssertFalse(base.applyingChecked(bad, in: inner, foldable: false).rejectedScreens)

        var overlap = CustomLayout()
        overlap.screens["top"] = ItemPlacement(cx: 0.45, cy: 0.45, size: 0.5)
        overlap.screens["bottom"] = ItemPlacement(cx: 0.55, cy: 0.55, size: 0.5)
        XCTAssertTrue(base.applyingChecked(overlap, in: inner, foldable: true).rejectedScreens)

        var ok = CustomLayout()
        ok.screens["top"] = ItemPlacement(cx: 0.5, cy: 0.25, size: 0.7)
        ok.screens["bottom"] = ItemPlacement(cx: 0.5, cy: 0.72, size: 0.7)
        let kept = base.applyingChecked(ok, in: inner, foldable: true)
        XCTAssertFalse(kept.rejectedScreens)
        XCTAssertEqual(kept.layout.top.width, 0.7 * inner.width, accuracy: 0.5)

        // Controls-only layouts are never touched.
        var controls = CustomLayout(); controls.controls["l"] = ItemPlacement(cx: 0.1, cy: 0.5, size: 1)
        XCTAssertFalse(base.applyingChecked(controls, in: inner, foldable: true).rejectedScreens)
    }

    /// Landscape on the Duo: the regular landscape layout with the screens stacked (Automatic
    /// means stacked there), controls at the sides and off the screens.
    func testLandscapeDuoStacked() {
        let safe = CGRect(x: 0, y: 0, width: innerLand.width - 0, height: innerLand.height)
        let l = DualScreenLayout.make(size: safe.size, arrangement: .stacked, showsControls: true)
        XCTAssertFalse(l.isSideBySide)
        assertStackedAndLarge(l, minWidth: 380)
        XCTAssertEqual(l.top.midX, innerLand.width / 2, accuracy: 1)
        let p = TouchPadLayout.make(layout: l, system: .ds, showsButtons: true, stylus: l.bottom)
        for z in p.zones {
            XCTAssertFalse(z.rect.intersects(l.top) || z.rect.intersects(l.bottom), z.label)
            XCTAssertTrue(CGRect(origin: .zero, size: innerLand).contains(z.rect), z.label)
        }
    }

    // MARK: library

    func testLibraryArrangement() {
        typealias A = ClassicDSMenuView.Arrangement
        XCTAssertEqual(ClassicDSMenuView.arrangement(posture: .open, duo: true, size: inner), A.hingeSplit)
        XCTAssertEqual(ClassicDSMenuView.arrangement(posture: .book, duo: true, size: inner), A.hingeSplit)
        // Duo landscape (open, book, unknown) and closed: stacked, never side by side.
        for p in [FoldPosture.open, .book, .flat, .closed] {
            XCTAssertEqual(ClassicDSMenuView.arrangement(posture: p, duo: true, size: innerLand), A.stacked, "\(p)")
            XCTAssertEqual(ClassicDSMenuView.arrangement(posture: p, duo: true, size: outerLand), A.stacked, "\(p)")
        }
        XCTAssertEqual(ClassicDSMenuView.arrangement(posture: .closed, duo: true, size: outer), A.stacked)
        // Regular iPhone unchanged.
        XCTAssertEqual(ClassicDSMenuView.arrangement(posture: .flat, duo: false, size: proMax), A.compact)
        XCTAssertEqual(ClassicDSMenuView.arrangement(posture: .flat, duo: false, size: CGSize(width: 956, height: 440)), A.sideBySide)
    }
}
