// Copyright (c) 2026 Charlie Rodriguez Garcia. All rights reserved.
import XCTest
@testable import TwinPlay

/// Menu measure for the sizes TwinPlay is held in. These do not touch orientation or windows.
final class MenuLayoutTests: XCTestCase {
    func testColorColumns() {
        XCTAssertEqual(MenuLayout.colorColumns(width: 320), 2)          // small iPhone
        XCTAssertEqual(MenuLayout.colorColumns(width: 390), 4)          // large iPhone portrait
        XCTAssertEqual(MenuLayout.colorColumns(width: 440), 4)
        XCTAssertEqual(MenuLayout.colorColumns(width: 669), 4)          // Duo inner, portrait
        XCTAssertEqual(MenuLayout.colorColumns(width: 956), 4)          // iPhone landscape
        XCTAssertEqual(MenuLayout.colorColumns(width: 1180), 4)         // iPad landscape
        XCTAssertEqual(ClassicMenuTheme.allCases.count % 2, 0)
        XCTAssertEqual(ClassicMenuTheme.allCases.count % 4, 0)
    }

    func testReadableWidth() {
        XCTAssertEqual(MenuLayout.readableWidth(320), 320)
        XCTAssertEqual(MenuLayout.readableWidth(430), 430)
        XCTAssertEqual(MenuLayout.readableWidth(820), 680)
        XCTAssertEqual(MenuLayout.readableWidth(1180), 680)
    }

    func testGameInfoStacking() {
        XCTAssertTrue(MenuLayout.stacksGameInfo(width: 320, height: 568))     // small iPhone portrait
        XCTAssertTrue(MenuLayout.stacksGameInfo(width: 402, height: 874))     // large iPhone portrait
        XCTAssertFalse(MenuLayout.stacksGameInfo(width: 874, height: 402))    // large iPhone landscape
        XCTAssertFalse(MenuLayout.stacksGameInfo(width: 820, height: 1180))   // iPad portrait
        XCTAssertFalse(MenuLayout.stacksGameInfo(width: 1180, height: 820))   // iPad landscape
        XCTAssertFalse(MenuLayout.stacksGameInfo(width: 669, height: 951))    // Duo open, portrait
        XCTAssertTrue(MenuLayout.stacksGameInfo(width: 360, height: 280))     // very short window
    }
}
