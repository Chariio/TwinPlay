// Copyright (c) 2026 Charlie Rodriguez Garcia. All rights reserved.
import XCTest
@testable import TwinPlay

/// #12 Delta-style Hold Buttons.
final class HoldButtonsTests: XCTestCase {
    func testPickConfirmAndHold() {
        var h = HoldButtons()
        h.beginSelecting()
        XCTAssertEqual(h.touch(from: [], to: .a), [], "picking does not press in the game")
        _ = h.touch(from: .a, to: [])
        _ = h.touch(from: [], to: .r); _ = h.touch(from: .r, to: [])
        XCTAssertEqual(h.shown, [.a, .r])
        h.confirm()
        XCTAssertEqual(h.held, [.a, .r])
        XCTAssertFalse(h.selecting)
        // Other buttons still work on top of the held ones.
        XCTAssertEqual(h.touch(from: [], to: .b), [.a, .r, .b])
        XCTAssertEqual(h.touch(from: .b, to: []), [.a, .r])
    }

    func testTapAgainUnpicksWhileSelecting() {
        var h = HoldButtons()
        h.beginSelecting()
        _ = h.touch(from: [], to: .a); _ = h.touch(from: .a, to: [])
        _ = h.touch(from: [], to: .a); _ = h.touch(from: .a, to: [])
        XCTAssertEqual(h.shown, [])
    }

    func testTappingHeldButtonReleasesIt() {
        var h = HoldButtons()
        h.beginSelecting(); _ = h.touch(from: [], to: [.a, .up]); h.confirm()
        XCTAssertEqual(h.touch(from: [], to: .a), [.a, .up], "down while the finger is on it")
        XCTAssertEqual(h.touch(from: .a, to: []), [.up], "then released")
        XCTAssertEqual(h.held, .up)
    }

    func testCancelKeepsPreviousAndReleaseAll() {
        var h = HoldButtons()
        h.beginSelecting(); _ = h.touch(from: [], to: .start); h.confirm()
        h.beginSelecting(); XCTAssertEqual(h.shown, .start)
        _ = h.touch(from: .start, to: .b)
        h.cancel()
        XCTAssertEqual(h.held, .start)
        h.releaseAll()
        XCTAssertEqual(h.held, [])
    }

    func testNames() {
        XCTAssertEqual(DSButton([.a, .r]).names, "A + R")
        XCTAssertEqual(DSButton([]).names, "")
    }
}
