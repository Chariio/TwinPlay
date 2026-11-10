// Copyright (c) 2026 Charlie Rodriguez Garcia. All rights reserved.
import XCTest
@testable import TwinPlay

/// 1.1: the box-art / title-screen finder is on and free (not part of any paid tier).
/// Cover Flow stays Pro.
final class BoxArtFlagTests: XCTestCase {
    func testFinderIsFree() {
        XCTAssertTrue(BoxArtFinder.isEnabled)
        XCTAssertFalse(Feature.allCases.map(\.rawValue).contains("boxArtFinder"))
        XCTAssertEqual(Feature.coverFlow.tier, .pro)
    }
}
