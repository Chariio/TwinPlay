// Copyright (c) 2026 Charlie Rodriguez Garcia. All rights reserved.
import XCTest
#if canImport(SwiftUI)
import SwiftUI
#endif
@testable import TwinPlay

#if canImport(SwiftUI) && os(iOS)
/// #23 quick menu colours: every theme listed once, the picker renders.
final class MenuColorsPickerTests: XCTestCase {
    func testThemesAndGrid() {
        XCTAssertEqual(ClassicMenuTheme.allCases.count, 16)
        XCTAssertEqual(ClassicMenuTheme.allCases.count % MenuColorsPicker.cols, 0)   // two full rows
    }

    /// Set TWINPLAY_RENDER_DIR to write menu-colors-<theme>.png (the popover content on its theme).
    @MainActor func testRenderPicker() throws {
        guard let dir = ProcessInfo.processInfo.environment["TWINPLAY_RENDER_DIR"] else { throw XCTSkip("no render dir") }
        let old = UserDefaults.standard.string(forKey: ClassicMenuTheme.key)
        defer { UserDefaults.standard.set(old, forKey: ClassicMenuTheme.key) }
        for t in [ClassicMenuTheme.twinplay, .grape] {
            UserDefaults.standard.set(t.rawValue, forKey: ClassicMenuTheme.key)
            let v = MenuColorsPicker().background(RoundedRectangle(cornerRadius: 16).fill(Color(white: 0.16))).padding(20)
                .background(ClassicPalette.body).environment(\.colorScheme, .dark)
            let r = ImageRenderer(content: v); r.scale = 2
            try XCTUnwrap(r.uiImage?.pngData()).write(to: URL(fileURLWithPath: dir).appendingPathComponent("menu-colors-\(t.rawValue).png"))
        }
    }
}
#endif
