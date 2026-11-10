// Copyright (c) 2026 Charlie Rodriguez Garcia. All rights reserved.
import AVFoundation

/// Plays the core's 48 kHz stereo Int16 stream through AVAudioEngine.
///
/// The output node runs at the device's real hardware rate (48 kHz or 44.1 kHz, queried from
/// AVAudioSession), and this class resamples the core stream to it with linear interpolation.
/// Emulation is paced by wall time, so the two clocks drift slightly; a tiny rate correction
/// (at most ±0.5 %, inaudible) keeps about 60 ms of sound queued. Pitch and tempo stay correct.
final class AudioOutput {
    static let coreRate = 48_000.0
    private let engine = AVAudioEngine()
    private var source: AVAudioSourceNode?
    private let core: DSCoreBridge
    private let state: ResamplerState

    init(core: DSCoreBridge) {
        self.core = core
        state = ResamplerState()
    }

    deinit { engine.stop() }

    func start() {
        if engine.isRunning { return }
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
        try? session.setPreferredSampleRate(Self.coreRate)
        try? session.setPreferredIOBufferDuration(1024.0 / Self.coreRate)
        try? session.setActive(true)

        // The rate the hardware actually runs at (the preference above is only a request).
        var hwRate = engine.outputNode.outputFormat(forBus: 0).sampleRate
        if hwRate <= 0 { hwRate = session.sampleRate }
        if hwRate <= 0 { hwRate = Self.coreRate }
        guard let format = AVAudioFormat(standardFormatWithSampleRate: hwRate, channels: 2) else { return }
        state.reset(step: Self.coreRate / hwRate)

        let core = self.core, st = self.state
        let node = AVAudioSourceNode(format: format) { _, _, frameCount, audioBufferList -> OSStatus in
            let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
            guard buffers.count >= 2,
                  let left = buffers[0].mData?.assumingMemoryBound(to: Float.self),
                  let right = buffers[1].mData?.assumingMemoryBound(to: Float.self) else { return noErr }
            st.render(core: core, left: left, right: right, frames: Int(frameCount))
            return noErr
        }
        source = node
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        do { try engine.start() } catch { print("Audio unavailable: \(error)") }
    }

    func stop() {
        engine.stop()
        if let node = source { engine.detach(node) }
        source = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// Emulation thread stalled: output silence instead of whatever is left in the buffers.
    func setStalled(_ on: Bool) { if state.stalled != on { state.stalled = on } }

    /// Fast-forward: either mute (default) or play the sped-up stream at a raised pitch.
    /// Unlimited speed (0) is always muted.
    func setFastForward(speed: Int, muteWhenFast: Bool) {
        let fast = speed != 1
        state.muted = fast && (muteWhenFast || speed == 0)
        state.speedFactor = fast && !state.muted ? Double(speed) : 1
    }
}

/// Realtime-thread resampler state (touched only by the audio callback after reset).
final class ResamplerState {
    private let capacity = 8192
    private let input: UnsafeMutablePointer<Int16>        // queued core frames (stereo)
    private var count = 0                                   // frames in `input`
    private var pos = 0.0                                   // read position in `input`
    private var baseStep = 1.0
    private var primed = false
    private var underran = false                            // re-prime with a smaller cushion
    private var lastL: Float = 0, lastR: Float = 0          // for click-free fades
    private let target = 0.090 * AudioOutput.coreRate       // ~90 ms queued (core + local)
    // Written by the main thread, read by the audio thread. Single aligned word-sized values;
    // a stale read only delays the change by one buffer.
    var muted = false
    var stalled = false
    var speedFactor = 1.0

    init() {
        input = UnsafeMutablePointer<Int16>.allocate(capacity: capacity * 2)
        input.initialize(repeating: 0, count: capacity * 2)
    }

    deinit { input.deallocate() }

    func reset(step: Double) { baseStep = step; count = 0; pos = 0; primed = false; underran = false; lastL = 0; lastR = 0 }

    func render(core: DSCoreBridge, left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, frames: Int) {
        if muted || stalled {                                // fast-forward or stalled emulation: silence
            for i in 0..<frames { left[i] = 0; right[i] = 0 }
            count = 0; pos = 0; primed = false
            while core.readAudio(input, maxFrames: capacity) > 0 {}
            return
        }
        let queued = Double(core.audioBufferedFrames + count)
        if !primed {                                         // wait for a cushion before starting
            // After a frame spike only wait for half the cushion, and fade instead of cutting to 0.
            let need = (underran ? target * 0.5 : target) * speedFactor
            if queued < need { fadeOut(left: left, right: right, frames: frames); refill(core: core); return }
            primed = true; underran = false
        }
        // Drift correction: proportional, clamped to ±0.5 %.
        let err = (queued - target) / target
        let step = baseStep * speedFactor * (1 + max(-0.005, min(0.005, err * 0.01)))
        let needed = Int(Double(frames) * step + pos) + 2
        if count < needed { refill(core: core) }
        for i in 0..<frames {
            let i0 = Int(pos)
            if i0 + 1 >= count {                                 // underrun (emulation hiccup): fade, re-prime
                lastL *= 0.995; lastR *= 0.995; left[i] = lastL; right[i] = lastR
                primed = false; underran = true; continue
            }
            let f = Float(pos - Double(i0))
            let l0 = Float(input[i0 * 2]), l1 = Float(input[(i0 + 1) * 2])
            let r0 = Float(input[i0 * 2 + 1]), r1 = Float(input[(i0 + 1) * 2 + 1])
            left[i] = (l0 + (l1 - l0) * f) / 32768
            right[i] = (r0 + (r1 - r0) * f) / 32768
            lastL = left[i]; lastR = right[i]
            pos += step
        }
        // Discard consumed frames, keeping the one still needed for interpolation.
        let used = min(Int(pos), count)
        if used > 0 {
            let remain = count - used
            if remain > 0 { memmove(input, input + used * 2, remain * 2 * MemoryLayout<Int16>.size) }
            count = remain
            pos -= Double(used)
        }
    }

    private func fadeOut(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, frames: Int) {
        for i in 0..<frames { lastL *= 0.995; lastR *= 0.995; left[i] = lastL; right[i] = lastR }
    }

    private func refill(core: DSCoreBridge) {
        let room = capacity - count
        if room <= 0 { return }
        let got = core.readAudio(input + count * 2, maxFrames: room)
        count += got
    }
}
