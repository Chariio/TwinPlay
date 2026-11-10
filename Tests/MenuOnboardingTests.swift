// Copyright (c) 2026 Charlie Rodriguez Garcia. All rights reserved.
import XCTest
@testable import TwinPlay

final class MenuOnboardingTests: XCTestCase {
    private func defaults() -> UserDefaults {
        let name = "twinplay.onboarding.tests.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    func testFreshInstallShowsOnce() {
        let d = defaults()
        XCTAssertTrue(MenuOnboarding.shouldPresent(defaults: d))
        MenuOnboarding.choose("standard", defaults: d)
        XCTAssertEqual(d.string(forKey: "libraryStyle"), "standard")
        XCTAssertTrue(d.bool(forKey: MenuOnboarding.chosenKey))
        XCTAssertFalse(MenuOnboarding.shouldPresent(defaults: d))
    }

    func testExistingStyleSkipsTheScreen() {
        let d = defaults()
        d.set("classicDS", forKey: "libraryStyle")
        XCTAssertFalse(MenuOnboarding.shouldPresent(defaults: d))
        XCTAssertFalse(d.bool(forKey: MenuOnboarding.chosenKey))
    }

    func testFlagIsNotAnNDUOKey() {
        XCTAssertEqual(MenuOnboarding.chosenKey, "twinplay.onboarding.menuChosen")
        XCTAssertFalse(MenuOnboarding.chosenKey.contains("nduo"))
        XCTAssertEqual(MenuOnboarding.styleKey, "libraryStyle")
    }
}
