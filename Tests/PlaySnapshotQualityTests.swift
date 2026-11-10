// Copyright (c) 2026 Charlie Rodriguez Garcia. All rights reserved.
import XCTest
@testable import TwinPlay
import UIKit

final class PlaySnapshotQualityTests: XCTestCase {
    func testBlackFrameIsNotUsable() {
        let img = solid(UIColor.black, size: CGSize(width: 256, height: 384))
        XCTAssertFalse(PlaySnapshotQuality.isUsable(img))
    }

    func testGameplayLikeFrameIsUsable() {
        let img = UIGraphicsImageRenderer(size: CGSize(width: 128, height: 96)).image { ctx in
            UIColor.black.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 128, height: 96))
            UIColor(red: 0.2, green: 0.6, blue: 0.3, alpha: 1).setFill()
            ctx.fill(CGRect(x: 10, y: 10, width: 80, height: 60))
            UIColor.white.setFill()
            ctx.fill(CGRect(x: 20, y: 20, width: 20, height: 12))
        }
        XCTAssertTrue(PlaySnapshotQuality.isUsable(img))
    }

    private func solid(_ color: UIColor, size: CGSize) -> UIImage {
        UIGraphicsImageRenderer(size: size).image { ctx in
            color.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
        }
    }
}
