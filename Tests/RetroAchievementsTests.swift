// Copyright (c) 2026 Charlie Rodriguez Garcia. All rights reserved.
import XCTest
@testable import TwinPlay

/// #13 RetroAchievements: console ids, hardcore rules, sign-in form; softcore by default.
final class RetroAchievementsTests: XCTestCase {
    func testConsoleIDs() {
        XCTAssertEqual(RetroAchievementsRules.console(for: .gb), 4)
        XCTAssertEqual(RetroAchievementsRules.console(for: .gbc), 6)
        XCTAssertEqual(RetroAchievementsRules.console(for: .gba), 5)
        XCTAssertEqual(RetroAchievementsRules.console(for: .ds), 18)
    }

    func testSoftcoreByDefaultAndHardcoreRules() {
        let d = UserDefaults.standard, old = d.object(forKey: RetroAchievementsRules.hardcoreKey)
        defer { d.set(old, forKey: RetroAchievementsRules.hardcoreKey) }
        d.removeObject(forKey: RetroAchievementsRules.hardcoreKey)
        XCTAssertFalse(RetroAchievementsRules.hardcore)
        XCTAssertTrue(RetroAchievementsRules.allowsCheats(hardcore: false))
        XCTAssertTrue(RetroAchievementsRules.allowsLoadingStates(hardcore: false))
        XCTAssertFalse(RetroAchievementsRules.allowsCheats(hardcore: true))
        XCTAssertFalse(RetroAchievementsRules.allowsLoadingStates(hardcore: true))
    }

    func testSignInForm() {
        XCTAssertTrue(RetroAchievementsRules.canSignIn(username: "Charlie", password: "x"))
        XCTAssertTrue(RetroAchievementsRules.canSignIn(username: " Player2 ", password: "x"))
        XCTAssertFalse(RetroAchievementsRules.canSignIn(username: "Charlie", password: ""))
        XCTAssertFalse(RetroAchievementsRules.canSignIn(username: "a", password: "x"))
        XCTAssertFalse(RetroAchievementsRules.canSignIn(username: "bad name", password: "x"))
    }
}
