// Copyright (c) 2026 Charlie Rodriguez Garcia. All rights reserved.
// Library / menu background music is no longer started. stopForGameplay()
// still releases any leftover engine and the ambient session so a game can
// take .playback alone. The unused loop generator remains for an easy revert.
import AVFoundation

final class MenuMusic {
    static let shared = MenuMusic()
    static let mutedKey = "twinplay.menuMusicMuted"

    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private var started = false

    private init() {}

    var isMuted: Bool { true }

    func setMuted(_ muted: Bool) {
        UserDefaults.standard.set(true, forKey: Self.mutedKey)
        stopForGameplay()
    }

    func startIfAllowed() {
        // Library / menu background music was removed. Call sites are
        // unchanged; this never starts the loop. In-game audio stays.
        if started { stopForGameplay() }
    }

    /// Full stop. Safe to call more than once, including when music never started.
    func stopForGameplay() {
        player?.stop()
        engine?.stop()
        engine?.reset()
        player = nil
        engine = nil
        started = false
        // Drop our ambient session so the game's .playback session is the only one.
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }

    /// Original C-major loop at 128 BPM. Soft sines, a light hat, no borrowed melody.
    private static func loop(format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let rate = format.sampleRate
        let bpm = 128.0
        let beat = 60.0 / bpm
        let beats = 16.0                                 // four bars, back to the first chord
        let frames = AVAudioFrameCount(rate * beats * beat)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
        buffer.frameLength = frames
        let left = buffer.floatChannelData![0]
        let right = buffer.floatChannelData![1]
        // I – V – vi – IV. Roots and a small original pentatonic line, one note per eighth.
        let roots: [Double] = [130.81, 196.00, 220.00, 174.61]          // C3 G3 A3 F3
        let melody: [Double] = [
            523.25, 659.25, 783.99, 659.25, 523.25, 587.33, 659.25, 523.25,
            493.88, 587.33, 659.25, 587.33, 523.25, 493.88, 440.00, 392.00,
            440.00, 523.25, 659.25, 523.25, 440.00, 523.25, 587.33, 659.25,
            698.46, 659.25, 587.33, 523.25, 587.33, 523.25, 493.88, 523.25,
        ]
        let eighth = beat / 2
        for i in 0..<Int(frames) {
            let t = Double(i) / rate
            let bar = min(3, Int(t / (beat * 4)))
            let step = min(31, Int(t / eighth))
            let into = t - Double(step) * eighth
            let noteEnv = exp(-into * 7.5) * (into < eighth ? 1.0 : 0)
            let bassEnv = exp(-into * 5.0)
            let hat = (into < 0.012) ? Float(1 - into / 0.012) : 0
            let kick = (step % 2 == 0 && into < 0.04) ? Float(exp(-into * 40)) : 0
            let bass = sin(2 * .pi * roots[bar] * t) * bassEnv * 0.22
            let lead = sin(2 * .pi * melody[step] * t) * noteEnv * 0.16
            let fifth = sin(2 * .pi * roots[bar] * 1.5 * t) * noteEnv * 0.05
            var s = Float(bass + lead + fifth) + hat * 0.045 + kick * 0.12
            // A few samples of fade so the loop point doesn't click.
            let edge = min(t, beats * beat - t)
            if edge < 0.01 { s *= Float(edge / 0.01) }
            left[i] = s
            right[i] = s * 0.96
        }
        return buffer
    }
}
