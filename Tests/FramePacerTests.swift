// Copyright (c) 2026 Charlie Rodriguez Garcia. All rights reserved.
import XCTest
@testable import TwinPlay

/// The emulation loop's frame pacing: a steady 60 fps on 60 Hz and ProMotion displays, also when
/// the main thread (which drives the display link) hitches.
final class FramePacerTests: XCTestCase {
    private let ds = 1.0 / 59.8261

    /// Runs `wakes` (dt per wake) and returns the frames run, like the loop (at most 3 per wake).
    private func run(_ wakes: [Double], woke: Bool = true) -> (frames: Int, perWake: [Int]) {
        var p = FramePacer(frameDuration: ds)
        var frames = 0, per: [Int] = []
        for dt in wakes {
            p.advance(dt: dt, woke: woke, speed: 1)
            var ran = 0
            while ran < 3 && p.credit >= 1 { p.credit -= 1; ran += 1 }
            frames += ran; per.append(ran)
        }
        return (frames, per)
    }

    func testSixtyHzOneFramePerRefresh() {
        var wakes: [Double] = []
        for i in 0..<600 { wakes.append(1.0 / 60 + (i % 2 == 0 ? 0.0012 : -0.0012)) }   // jittery vsync
        let r = run(wakes)
        XCTAssertEqual(r.frames, 600, accuracy: 1)
        XCTAssertTrue(r.perWake.dropFirst(20).allSatisfy { $0 == 1 }, "never 0 then 2 (repeated picture)")
    }

    /// Main-thread hitches merge refreshes: the frames are made up, the total stays at 60/s.
    func testHitchesDoNotLoseFrames() {
        var wakes: [Double] = []
        for i in 0..<600 { wakes.append(i % 30 == 29 ? 3.0 / 60 : 1.0 / 60) }      // a 50 ms gap every half second
        let seconds = wakes.reduce(0, +)
        let r = run(wakes)
        XCTAssertEqual(Double(r.frames), seconds * 60, accuracy: 2)
    }

    /// A slow frame: the queued vsync wakes the loop right away. Nothing runs twice.
    func testQueuedWakeDoesNotRunExtraFrames() {
        var wakes: [Double] = Array(repeating: 1.0 / 60, count: 100)
        for _ in 0..<50 { wakes += [0.025, 1.0 / 60 * 2 - 0.025] }                  // pairs = 2 refreshes
        let seconds = wakes.reduce(0, +)
        XCTAssertEqual(Double(run(wakes).frames), seconds * 60, accuracy: 2)
    }

    func testProMotion120HzRunsAtDSRate() {
        let wakes = Array(repeating: 1.0 / 120, count: 1200)                       // 10 s
        XCTAssertEqual(Double(run(wakes).frames), 10 * 59.8261, accuracy: 2)
    }

    func testTimerFallbackRunsAtDSRate() {
        let wakes = Array(repeating: ds, count: 600)
        XCTAssertEqual(run(wakes, woke: false).frames, 600, accuracy: 1)
    }
}
