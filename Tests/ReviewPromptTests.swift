// Copyright (c) 2026 Charlie Rodriguez Garcia. All rights reserved.
import XCTest
@testable import TwinPlay

final class ReviewPromptTests: XCTestCase {
    private func defaults() -> UserDefaults {
        let name = "twinplay.review.tests.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    func testUnderFiveMinutesDoesNotAsk() {
        let d = defaults()
        XCTAssertFalse(ReviewPrompt.noteSession(seconds: 2 * 60, version: "1.2", defaults: d))
        XCTAssertFalse(ReviewPrompt.noteSession(seconds: 2 * 60, version: "1.2", defaults: d))
        XCTAssertEqual(d.double(forKey: ReviewPrompt.playedSecondsKey), 4 * 60, accuracy: 0.001)
        XCTAssertNil(d.string(forKey: ReviewPrompt.askedVersionKey))
    }

    func testFiveMinutesAsksOncePerVersion() {
        let d = defaults()
        XCTAssertFalse(ReviewPrompt.noteSession(seconds: 3 * 60, version: "1.2", defaults: d))
        XCTAssertTrue(ReviewPrompt.noteSession(seconds: 2 * 60, version: "1.2", defaults: d))
        XCTAssertEqual(d.double(forKey: ReviewPrompt.playedSecondsKey), 5 * 60, accuracy: 0.001)
        ReviewPrompt.markAsked(version: "1.2", defaults: d)
        // A later return in the same version does not ask again, even after more play.
        XCTAssertFalse(ReviewPrompt.noteSession(seconds: 30 * 60, version: "1.2", defaults: d))
        // The next version may ask once the five minutes are already on record.
        XCTAssertTrue(ReviewPrompt.noteSession(seconds: 1, version: "1.3", defaults: d))
        ReviewPrompt.markAsked(version: "1.3", defaults: d)
        XCTAssertFalse(ReviewPrompt.noteSession(seconds: 20 * 60, version: "1.3", defaults: d))
    }

    func testOneVisitOfFiveMinutesAsks() {
        let d = defaults()
        XCTAssertTrue(ReviewPrompt.noteSession(seconds: 5 * 60, version: "1.2", defaults: d))
    }

    func testZeroSecondsDoesNotAccumulate() {
        let d = defaults()
        XCTAssertFalse(ReviewPrompt.noteSession(seconds: 0, version: "1.2", defaults: d))
        XCTAssertEqual(d.double(forKey: ReviewPrompt.playedSecondsKey), 0)
    }

    func testPauseAndBackgroundAreNotCounted() {
        let clock = ReviewPlayClock()
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        clock.begin()
        clock.sync(running: true, now: t0)
        clock.sync(running: false, now: t0.addingTimeInterval(4 * 60))          // pause
        clock.sync(running: true, now: t0.addingTimeInterval(20 * 60))          // resume, gap ignored
        clock.sync(running: false, now: t0.addingTimeInterval(20 * 60 + 3 * 60)) // background
        clock.sync(running: true, now: t0.addingTimeInterval(40 * 60))
        let seconds = clock.finish(now: t0.addingTimeInterval(40 * 60 + 3 * 60))
        XCTAssertEqual(seconds, 10 * 60, accuracy: 0.001)
        let d = defaults()
        XCTAssertTrue(ReviewPrompt.noteSession(seconds: seconds, version: "1.2", defaults: d))
        XCTAssertEqual(d.double(forKey: ReviewPrompt.playedSecondsKey), 10 * 60, accuracy: 0.001)
    }

    func testKeysUseTheReviewPrefix() {
        XCTAssertEqual(ReviewPrompt.playedSecondsKey, "twinplay.review.playedSeconds")
        XCTAssertEqual(ReviewPrompt.askedVersionKey, "twinplay.review.askedVersion")
        XCTAssertFalse(ReviewPrompt.playedSecondsKey.contains("nduo"))
        XCTAssertFalse(ReviewPrompt.askedVersionKey.contains("nduo"))
    }
}
