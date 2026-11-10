// Copyright (c) 2026 Charlie Rodriguez Garcia. All rights reserved.
import XCTest
@testable import TwinPlay

/// #7 Classic DS Menu colour themes: every theme readable, distinct, and the setting falls back
/// to the default.
final class ClassicMenuThemeTests: XCTestCase {
    func testEveryThemeReadable() {
        for t in ClassicMenuTheme.allCases {
            for bg in [t.screenTop, t.screenBottom] {
                XCTAssertGreaterThanOrEqual(RGB.contrast(t.text, bg), 4.5, "\(t) text")
                XCTAssertGreaterThanOrEqual(RGB.contrast(t.dim, bg), 3.0, "\(t) dim")
                XCTAssertGreaterThanOrEqual(RGB.contrast(t.accent, bg), 2.2, "\(t) accent")
            }
        }
    }

    func testThemesDistinct() {
        let screens = ClassicMenuTheme.allCases.map { [$0.screenTop.r, $0.screenTop.g, $0.screenTop.b] }
        XCTAssertEqual(Set(screens.map { $0.map { Int($0 * 255) } }).count, ClassicMenuTheme.allCases.count)
    }

    func testDefaultAndUnknownValue() {
        let d = UserDefaults.standard, old = d.string(forKey: ClassicMenuTheme.key)
        defer { d.set(old, forKey: ClassicMenuTheme.key) }
        d.removeObject(forKey: ClassicMenuTheme.key)
        XCTAssertEqual(ClassicMenuTheme.current, .twinplay)
        d.set("bogus", forKey: ClassicMenuTheme.key)
        XCTAssertEqual(ClassicMenuTheme.current, ClassicMenuTheme.defaultTheme)
        d.set("crimson", forKey: ClassicMenuTheme.key)
        XCTAssertEqual(ClassicMenuTheme.current, .crimson)
    }
}
