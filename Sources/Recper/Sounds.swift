import AVFoundation
import Foundation

// MARK: UI sounds
//
// Short synthesized feedback sounds: no audio files, every sound is a few sine/FM tones and filtered-noise clicks rendered
// into a buffer when it plays. The design follows the sound set of chuanqisun/spaceship (MIT License, © 2026 Sun):
// the hand clicks (filtered-noise transients), the app answers in tones, a settled state ends on a plain sine, and every
// pitch comes from one E-major pentatonic scale. Each play is nudged by up to ±8 cents and ±1 dB so repeats don't ring identical.

/// One voice: a tone (FM when `index` > 0), or filtered white noise when `filter` is set.
/// Times in seconds. The level rises linearly over `attack`, holds for `hold`, then falls exponentially to silence over `decay`.
struct Voice {
    enum Wave { case sine, triangle, square }
    enum Filter { case bandpass, highpass, lowpass }
    var f: Double
    var to: Double? = nil
    var wave: Wave = .sine
    var filter: Filter? = nil
    var q: Double = 2
    var ratio: Double = 3.01
    var index: Double = 0
    var delay: Double = 0
    var attack: Double? = nil
    var hold: Double = 0
    var decay: Double
    var gain: Double
    var pan: Double = 0
}

final class Sounds: @unchecked Sendable {
    static let shared = Sounds()

    static let volumeKey = "soundVolume"

    static var enabled: Bool {
        get { UserDefaults.standard.object(forKey: "sounds") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "sounds") }
    }

    /// Master output volume (0…1, default 0.7). Applied live to the audio engine's main mixer.
    static var volume: Float {
        get {
            guard let n = UserDefaults.standard.object(forKey: volumeKey) as? NSNumber else { return 0.7 }
            return min(max(n.floatValue, 0), 1)
        }
        set {
            let clamped = min(max(newValue, 0), 1)
            UserDefaults.standard.set(clamped, forKey: volumeKey)
            shared.applyVolume(clamped)
        }
    }

    private let rate = 48_000.0
    private let queue = DispatchQueue(label: "recper.sounds", qos: .userInteractive)
    private let engine = AVAudioEngine()
    private var players: [AVAudioPlayerNode] = []
    private var next = 0
    private var started = false
    /// Stops the engine shortly after the last sound: a running output engine keeps CoreAudio's I/O thread busy
    /// (and the audio hardware awake) even in silence.
    private var idleStop: DispatchWorkItem?
    private var lastPlayed: [String: Date] = [:]
    private lazy var format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!

    private init() {
        NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { [weak self] _ in
            self?.queue.async { self?.started = false }     // output device changed: restart on the next sound
        }
    }

    // MARK: Playing

    /// Plays the voices (whole), unless `key` played less than `gap` seconds ago.
    func play(_ voices: [Voice], key: String? = nil, gap: Double = 0) {
        let vol = Self.volume
        guard Self.enabled, vol > 0.001 else { return }
        queue.async { [self] in
            if let key {
                let now = Date()
                if let last = lastPlayed[key], now.timeIntervalSince(last) < gap { return }
                lastPlayed[key] = now
            }
            guard startIfNeeded(), let buf = render(voices) else { return }
            engine.mainMixerNode.outputVolume = vol
            let p = players[next]
            next = (next + 1) % players.count
            p.stop()
            p.scheduleBuffer(buf, at: nil, options: [], completionHandler: nil)
            p.play()
            idleStop?.cancel()
            let stop = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.engine.stop()
                self.started = false
            }
            idleStop = stop
            queue.asyncAfter(deadline: .now() + 3, execute: stop)
        }
    }

    private func applyVolume(_ v: Float) {
        queue.async { [self] in
            if !players.isEmpty { engine.mainMixerNode.outputVolume = v }
        }
    }

    private func startIfNeeded() -> Bool {
        if started, engine.isRunning { return true }
        if players.isEmpty {
            for _ in 0..<8 {
                let p = AVAudioPlayerNode()
                engine.attach(p)
                engine.connect(p, to: engine.mainMixerNode, format: format)
                players.append(p)
            }
        }
        engine.mainMixerNode.outputVolume = Self.volume
        do {
            engine.prepare()
            try engine.start()
            started = true
        } catch {
            started = false
        }
        return started
    }

    // MARK: Rendering

    func render(_ voices: [Voice]) -> AVAudioPCMBuffer? {
        let detune = pow(2, Double.random(in: -8...8) / 1200)
        let length = (voices.map { $0.delay + ($0.attack ?? ($0.filter != nil ? 0.001 : 0.002)) + $0.hold + $0.decay }.max() ?? 0) + 0.03
        let n = AVAudioFrameCount(length * rate)
        guard n > 0, let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: n),
              let l = buf.floatChannelData?[0], let r = buf.floatChannelData?[1] else { return nil }
        buf.frameLength = n
        for i in 0..<Int(n) { l[i] = 0; r[i] = 0 }

        for v in voices {
            let gain = v.gain * pow(10, Double.random(in: -1...1) / 20)
            let attack = v.attack ?? (v.filter != nil ? 0.001 : 0.002)
            let dur = attack + v.hold + v.decay
            let start = Int(v.delay * rate), count = Int(dur * rate)
            let p = max(-1, min(1, v.pan)) * 0.85
            let gl = cos((p + 1) * .pi / 4), gr = sin((p + 1) * .pi / 4)
            let f0 = v.f * detune, f1 = (v.to ?? v.f) * detune

            var phase = 0.0, modPhase = 0.0
            var bq = v.filter.map { Biquad($0, f: f0, q: v.q, rate: rate) }
            for k in 0..<count where start + k < Int(n) {
                let t = Double(k) / rate
                // Envelope.
                let env: Double
                if t < attack { env = gain * t / attack }
                else if t < attack + v.hold { env = gain }
                else { env = gain * pow(1e-4 / gain, (t - attack - v.hold) / v.decay) }
                // Source.
                var s: Double
                if var b = bq {
                    s = b.run(Double.random(in: -1...1))
                    bq = b
                } else {
                    let f = f0 * pow(f1 / f0, t / dur)
                    var inst = f
                    if v.index > 0 {
                        let dev = v.index * f * v.ratio * pow(0.1, t / dur)
                        modPhase += 2 * .pi * f * v.ratio / rate
                        inst += dev * sin(modPhase)
                    }
                    phase += 2 * .pi * inst / rate
                    switch v.wave {
                    case .sine: s = sin(phase)
                    case .square: s = sin(phase) >= 0 ? 1 : -1
                    case .triangle: s = 2 / .pi * asin(sin(phase))
                    }
                }
                let out = s * env
                l[start + k] += Float(out * gl)
                r[start + k] += Float(out * gr)
            }
        }
        // Soft limiter.
        for i in 0..<Int(n) { l[i] = tanhf(l[i] * 1.2) / 1.2; r[i] = tanhf(r[i] * 1.2) / 1.2 }
        return buf
    }

    /// RBJ biquad (bandpass with 0 dB peak gain).
    private struct Biquad {
        var b0 = 0.0, b1 = 0.0, b2 = 0.0, a1 = 0.0, a2 = 0.0
        var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0
        init(_ type: Voice.Filter, f: Double, q: Double, rate: Double) {
            let w = 2 * .pi * min(f, rate * 0.45) / rate, alpha = sin(w) / (2 * q), c = cos(w)
            let a0: Double
            switch type {
            case .bandpass: b0 = alpha; b1 = 0; b2 = -alpha
            case .highpass: b0 = (1 + c) / 2; b1 = -(1 + c); b2 = (1 + c) / 2
            case .lowpass: b0 = (1 - c) / 2; b1 = 1 - c; b2 = (1 - c) / 2
            }
            a0 = 1 + alpha; a1 = -2 * c; a2 = 1 - alpha
            b0 /= a0; b1 /= a0; b2 /= a0; a1 /= a0; a2 /= a0
        }
        mutating func run(_ x: Double) -> Double {
            let y = b0 * x + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
            x2 = x1; x1 = x; y2 = y1; y1 = y
            return y
        }
    }
}

// MARK: The sound set

/// recper's sounds. The hand (grabbing, dropping, picking) clicks; the app answers in pentatonic tones.
enum Sfx {
    private static let pentatonic = [1, 9.0 / 8, 5.0 / 4, 3.0 / 2, 5.0 / 3]
    /// note(0) = E4, note(5) = E5, note(10) = E6, note(15) = E7.
    static func note(_ d: Int) -> Double {
        329.63 * pow(2, Double(Int((Double(d) / 5).rounded(.down)))) * pentatonic[((d % 5) + 5) % 5]
    }
    private static func click(_ f: Double, _ gain: Double, delay: Double = 0, decay: Double = 0.005) -> Voice {
        Voice(f: f, filter: .bandpass, q: 3, delay: delay, decay: decay, gain: gain)
    }
    private static func tone(_ d: Int, _ gain: Double, decay: Double, delay: Double = 0, index: Double = 0) -> Voice {
        Voice(f: note(d), index: index, delay: delay, decay: decay, gain: gain)
    }
    /// Low sine plus its 2nd–4th harmonics, so small speakers still suggest the body.
    private static func body(_ f: Double, _ gain: Double, _ decay: Double, to: Double? = nil, delay: Double = 0) -> [Voice] {
        [Voice(f: f, to: to, delay: delay, attack: 0.003, decay: decay, gain: gain)] + [(2.0, 0.55, 0.6), (3, 0.35, 0.45), (4, 0.2, 0.35)].map { n, g, d in
            Voice(f: f * n, to: to.map { $0 * n }, delay: delay, attack: 0.003, decay: decay * d, gain: gain * g)
        }
    }
    private static func play(_ v: [Voice], key: String? = nil, gap: Double = 0) { Sounds.shared.play(v, key: key, gap: gap) }

    /// The chooser opens: soft pips climbing into place.
    static func open() {
        play([10, 12, 14].enumerated().map { i, d in tone(d, 0.045 + Double(i) * 0.012, decay: 0.05, delay: Double(i) * 0.04) }
             + [Voice(f: 5000, filter: .highpass, decay: 0.006, gain: 0.12)])
    }
    /// A capture mode is chosen; each mode has its own pitch.
    static func mode(_ i: Int) { play([click(2400, 0.12, decay: 0.003), tone(5 + i * 2, 0.06, decay: 0.03)]) }
    /// The window under the pointer changes (window mode).
    static func hover() { play([Voice(f: 6500, filter: .highpass, q: 0.7, decay: 0.008, gain: 0.08)], key: "hover", gap: 0.06) }
    /// A target is taken: the session starts.
    static func take() {
        play([click(1800, 0.3), click(3000, 0.2, delay: 0.01), tone(10, 0.08, decay: 0.05, delay: 0.015), tone(14, 0.07, decay: 0.1, delay: 0.05)])
    }
    /// A drawing tool is selected; each tool has its own pitch.
    static func tool(_ i: Int) { play([click(1800, 0.22), tone(5 + i * 3, 0.06, decay: 0.04)]) }
    static func color(_ i: Int) { play([click(2400, 0.12, decay: 0.003), tone(8 + i * 2, 0.05, decay: 0.03)]) }
    /// Pen down / pen up: a latch (two clicks).
    static func grab() { play([click(2200, 0.16), click(3200, 0.11, delay: 0.012)]) }
    static func drop() { play([click(3200, 0.11), click(2200, 0.14, delay: 0.012)]) }
    /// Shutter: a bright snap, the mirror clacks, a short low thump.
    static func shutter() {
        play([Voice(f: 5000, filter: .highpass, decay: 0.006, gain: 0.22), click(1800, 0.28, delay: 0.035), click(3000, 0.16, delay: 0.045)]
             + body(140, 0.16, 0.05, to: 80, delay: 0.035))
    }
    static func undo() {
        play([Voice(f: 5000, filter: .highpass, decay: 0.006, gain: 0.16), Voice(f: 3500, filter: .highpass, delay: 0.04, decay: 0.006, gain: 0.11)])
    }
    static func palette() {
        play([Voice(f: 5000, filter: .highpass, decay: 0.006, gain: 0.14), Voice(f: 5000, filter: .highpass, delay: 0.045, decay: 0.006, gain: 0.14),
              tone(12, 0.045, decay: 0.03, delay: 0.045)])
    }
    /// Choosing is cancelled: the opening pips, falling.
    static func cancel() { play([12, 9, 5].enumerated().map { i, d in tone(d, 0.06, decay: 0.03, delay: Double(i) * 0.035) }) }
    /// Finish pressed: the hand lets go.
    static func finish() { play([click(3000, 0.2), click(2000, 0.25, delay: 0.012), tone(10, 0.06, decay: 0.04, delay: 0.04, index: 1.2)]) }
    /// Saved and copied: two notes resolving upward.
    static func done() { play([tone(13, 0.06, decay: 0.1), Voice(f: note(15), delay: 0.07, attack: 0.003, decay: 0.3, gain: 0.07)]) }
    /// The radial menu opens around the pointer: airy iris unfurl + soft climbing harmonics.
    static func radialOpen() {
        play([Voice(f: 5800, filter: .highpass, decay: 0.007, gain: 0.1),
              click(3200, 0.07, delay: 0.008, decay: 0.004),
              tone(10, 0.032, decay: 0.045, delay: 0.014, index: 0.35),
              tone(14, 0.026, decay: 0.065, delay: 0.036)])
    }
    /// The pointer moves onto another radial item (center = -1, cancel = -2); each item has its own pitch and stereo pan.
    static func radialTick(_ i: Int, pan: Double = 0) {
        if i == -1 {
            play([click(2400, 0.09, decay: 0.003), Voice(f: note(5), decay: 0.024, gain: 0.026)], key: "radial", gap: 0.03)
            return
        }
        if i < -1 {
            play([Voice(f: 1800, filter: .lowpass, q: 1.4, decay: 0.008, gain: 0.08),
                  Voice(f: note(6), to: note(4), decay: 0.038, gain: 0.03, pan: pan)], key: "radial", gap: 0.03)
            return
        }
        play([Voice(f: 2600 + Double(i) * 140, filter: .bandpass, q: 3.2, decay: 0.003, gain: 0.1, pan: pan),
              Voice(f: note(7 + i), index: 0.25, decay: 0.032, gain: 0.04, pan: pan)], key: "radial", gap: 0.028)
    }
    /// An item is confirmed on release from the visible radial menu: a crisp crystalline latch.
    static func radialConfirm(_ i: Int, pan: Double = 0) {
        let d = 12 + max(0, min(i, 5))
        play([Voice(f: 4200, filter: .highpass, decay: 0.005, gain: 0.08, pan: pan),
              Voice(f: note(d), index: 0.3, delay: 0.008, decay: 0.05, gain: 0.032, pan: pan)])
    }
    /// Circle gesture detected in cursor mode: soft rising airy chime.
    static func circleGesture() {
        play([Voice(f: 4600, filter: .highpass, decay: 0.006, gain: 0.09),
              tone(10, 0.048, decay: 0.055, delay: 0.006, index: 0.25),
              tone(14, 0.042, decay: 0.11, delay: 0.042)])
    }
    static func error() {
        play([Voice(f: 196, wave: .square, decay: 0.05, gain: 0.025), Voice(f: 196, wave: .square, delay: 0.08, decay: 0.05, gain: 0.025)])
    }
}
