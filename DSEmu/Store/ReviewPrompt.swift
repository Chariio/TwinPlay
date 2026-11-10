// Copyright (c) 2026 Charlie Rodriguez Garcia. All rights reserved.
import Foundation

/// Counts real play time and decides when Apple's review prompt may be shown.
///
/// Time is cumulative across visits, and only while emulation is actually running
/// (not paused, not in the background). After about five minutes, the prompt may
/// be offered once per app version, and only from the library after the player
/// has left the game — never over the game itself.
enum ReviewPrompt {
    static let playedSecondsKey = "twinplay.review.playedSeconds"
    static let askedVersionKey = "twinplay.review.askedVersion"
    static let minimumSeconds: TimeInterval = 5 * 60

    static func currentVersion() -> String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    /// Adds this visit's running time. True when the total has reached five minutes
    /// and this version has not asked yet. Does not consume the ask.
    static func noteSession(seconds: TimeInterval,
                             version: String = currentVersion(),
                             defaults: UserDefaults = .standard) -> Bool {
        if seconds > 0 {
            let total = defaults.double(forKey: playedSecondsKey) + seconds
            defaults.set(total, forKey: playedSecondsKey)
        }
        guard defaults.double(forKey: playedSecondsKey) >= minimumSeconds else { return false }
        return defaults.string(forKey: askedVersionKey) != version
    }

    static func markAsked(version: String = currentVersion(), defaults: UserDefaults = .standard) {
        defaults.set(version, forKey: askedVersionKey)
    }

    private static var askScheduled = false

    /// Asks on the next turn of the main queue, after the game cover has finished
    /// leaving. If a game is open again by then, the ask stays unused.
    static func scheduleAsk(stillInLibrary: @escaping () -> Bool, request: @escaping () -> Void) {
        guard !askScheduled else { return }
        askScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            askScheduled = false
            guard stillInLibrary() else { return }
            markAsked()
            request()
        }
    }
}

/// Running-time clock for one play session. Paused and background stretches are omitted.
final class ReviewPlayClock {
    private var accumulated: TimeInterval = 0
    private var runningSince: Date?

    func begin() {
        accumulated = 0
        runningSince = nil
    }

    func sync(running: Bool, now: Date = Date()) {
        if running {
            if runningSince == nil { runningSince = now }
        } else if let start = runningSince {
            accumulated += max(0, now.timeIntervalSince(start))
            runningSince = nil
        }
    }

    /// Stops the clock and returns the running time for the session.
    func finish(now: Date = Date()) -> TimeInterval {
        sync(running: false, now: now)
        let seconds = accumulated
        accumulated = 0
        return seconds
    }
}
