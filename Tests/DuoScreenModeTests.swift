// Copyright (c) 2026 Charlie Rodriguez Garcia. All rights reserved.
import XCTest
@testable import TwinPlay

/// An open iPhone Duo always shows both DS screens (a remembered single-screen mode is ignored).
final class DuoScreenModeTests: XCTestCase {
    func testOpenDuoShowsBoth() {
        XCTAssertTrue(ScreenMode.duoShowsBoth(isGBA: false, isDuo: true, onOuter: false))
    }
    func testSingleScreenStillAllowedElsewhere() {
        XCTAssertFalse(ScreenMode.duoShowsBoth(isGBA: false, isDuo: false, onOuter: false))   // regular iPhone / iPad
        XCTAssertFalse(ScreenMode.duoShowsBoth(isGBA: false, isDuo: true, onOuter: true))     // folded shut
        XCTAssertFalse(ScreenMode.duoShowsBoth(isGBA: true, isDuo: true, onOuter: false))     // GBA: one screen anyway
    }
}
