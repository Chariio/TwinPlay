// Copyright (c) 2026 Charlie Rodriguez Garcia. All rights reserved.
import XCTest
@testable import TwinPlay

/// #5 Sharp enlarged screens: the screens sit on whole device pixels, so the compositor never
/// resamples them on top of the shader's filter.
final class SharpScalingTests: XCTestCase {
    private func onGrid(_ v: CGFloat, _ scale: CGFloat) -> Bool { abs((v * scale).rounded() - v * scale) < 0.0001 }

    func testScreensOnWholePixels() {
        for scale in [2.0, 3.0] as [CGFloat] {
            for size in [CGSize(width: 440, height: 860), CGSize(width: 669, height: 951), CGSize(width: 1024, height: 1366), CGSize(width: 833.5, height: 700.25)] {
                let l = DualScreenLayout.make(size: size, arrangement: .automatic, showsControls: true)
                    .offsetBy(dx: 0.33, dy: 47.1).pixelAligned(scale: scale)
                for r in [l.top, l.bottom] {
                    XCTAssertTrue(onGrid(r.minX, scale) && onGrid(r.minY, scale) && onGrid(r.width, scale) && onGrid(r.height, scale), "\(r) @\(scale)x")
                }
                XCTAssertLessThanOrEqual(l.top.maxY, l.bottom.minY + 0.01)
            }
        }
    }

    func testAlignmentMovesLessThanAPixel() {
        let raw = DualScreenLayout.make(size: CGSize(width: 669, height: 951), arrangement: .stacked, showsControls: true).offsetBy(dx: 0.4, dy: 0.2)
        let a = raw.pixelAligned(scale: 3)
        XCTAssertEqual(a.top.minX, raw.top.minX, accuracy: 1.0 / 3)
        XCTAssertEqual(a.top.width, raw.top.width, accuracy: 2.0 / 3)
        XCTAssertEqual(raw.pixelAligned(scale: 0), raw)
    }
}
