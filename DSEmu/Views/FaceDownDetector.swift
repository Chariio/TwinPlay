// Copyright (c) 2026 Charlie Rodriguez Garcia. All rights reserved.
import SwiftUI
import CoreMotion
import UIKit

/// Detects the phone lying face-down: gravity pointing out of the screen (CoreMotion). The proximity
/// sensor is not used: enabling it blanks the display whenever a hand covers the top during play.
/// Debounced so a quick tilt doesn't trigger it.
final class FaceDownDetector: ObservableObject {
    @Published private(set) var isFaceDown = false
    private let motion = CMMotionManager()
    private var candidateSince: Date?
    private var observer: NSObjectProtocol?

    func start() {
        guard !motion.isDeviceMotionActive, motion.isDeviceMotionAvailable else { return }
        motion.deviceMotionUpdateInterval = 1.0 / 15
        motion.startDeviceMotionUpdates(to: .main) { [weak self] m, _ in
            guard let self, let g = m?.gravity else { return }
            // z ≈ +1 when the screen faces the floor.
            let down = g.z > (self.isFaceDown ? 0.75 : 0.88)
            if down {
                if self.candidateSince == nil { self.candidateSince = Date() }
                if !self.isFaceDown, Date().timeIntervalSince(self.candidateSince!) > 0.4 { self.isFaceDown = true }
            } else {
                self.candidateSince = nil
                if self.isFaceDown { self.isFaceDown = false }
            }
        }
    }

    func stop() {
        motion.stopDeviceMotionUpdates()
        candidateSince = nil
        isFaceDown = false
    }
}
