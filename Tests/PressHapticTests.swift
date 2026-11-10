// Copyright (c) 2026 Charlie Rodriguez Garcia. All rights reserved.
import XCTest
@testable import TwinPlay

/// #8 A light haptic on every on-screen press, never on release; setting on by default.
final class PressHapticTests: XCTestCase {
    func testEveryPressBuzzes() {
        XCTAssertTrue(PressHaptic.shouldBuzz(from: [], to: .a))
        XCTAssertTrue(PressHaptic.shouldBuzz(from: .a, to: [.a, .b]))      // second finger
        XCTAssertTrue(PressHaptic.shouldBuzz(from: [], to: .up))           // D-pad
        XCTAssertTrue(PressHaptic.shouldBuzz(from: .up, to: .left))        // new direction
        XCTAssertTrue(PressHaptic.shouldBuzz(from: .up, to: [.up, .right]))// diagonal
        XCTAssertTrue(PressHaptic.shouldBuzz(from: [], to: .start))
    }

    func testReleaseAndHoldDoNotBuzz() {
        XCTAssertFalse(PressHaptic.shouldBuzz(from: .a, to: []))
        XCTAssertFalse(PressHaptic.shouldBuzz(from: [.a, .b], to: .a))
        XCTAssertFalse(PressHaptic.shouldBuzz(from: .up, to: .up))
        XCTAssertFalse(PressHaptic.shouldBuzz(from: [.up, .right], to: .up))
    }

    func testOnByDefault() {
        let d = UserDefaults.standard, old = d.object(forKey: TouchSettings.hapticsKey)
        defer { d.set(old, forKey: TouchSettings.hapticsKey) }
        d.removeObject(forKey: TouchSettings.hapticsKey)
        XCTAssertTrue(TouchSettings.haptics)
        d.set(false, forKey: TouchSettings.hapticsKey)
        XCTAssertFalse(TouchSettings.haptics)
    }
}
