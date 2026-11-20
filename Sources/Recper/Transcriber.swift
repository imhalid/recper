@preconcurrency import AVFoundation
import Foundation
import Speech
import RecperCore

/// Microphone → SpeechAnalyzer + DictationTranscriber (on-device, tr-TR supported). PLAN.md §5.
/// Times are converted to the session clock: the audio clock starts at 0 on the first buffer, then `audioOffset` is added.
final class Transcriber: @unchecked Sendable {
    /// Live text (finalized + volatile) — called on the main thread.
    var onText: (@MainActor (String) -> Void)?
    /// A sentence (result) was finalized.
    var onFinal: (@MainActor () -> Void)?
    /// A sentence that is only a voice command (capture, undo, finish): not added to the text, delivered as a command.
    var onCommand: (@MainActor (VoiceCommand) -> Void)?
    var onError: (@MainActor (String) -> Void)?
    /// Microphone level (0…1), a few samples per buffer: the waveform in the strip.
    var onLevel: (@MainActor ([Float]) -> Void)?

    private(set) var localeID = "tr-TR"
    private var engine = AVAudioEngine()
    /// When the last mic buffer arrived: if buffers stop, the watchdog rebuilds the engine.
    private var lastBuffer = Date()
    private var natural: AVAudioFormat?
    private var watchdog: DispatchSourceTimer?
    private var configObserver: NSObjectProtocol?
    /// Microphone status: notice on reconnect.
    var onStatus: (@MainActor (String) -> Void)?
    private var analyzer: SpeechAnalyzer?
    private var resultsTask: Task<Void, Never>?
    private var continuation: AsyncStream<AnalyzerInput>.Continuation?
    private var converter: AVAudioConverter?
    private var format: AVAudioFormat?

    private let lock = NSLock()
    private var words: [Word] = []        // finalized words
    private var finalText = ""
    private var volatileText = ""
    private var sessionStart = Date()
    private var audioOffset: Double?
    private var micOn = false
    /// Index of each final result's last word: the sentence ends there even without punctuation.
    private var breaks: Set<Int> = []

    /// UI words: hints for English terms used within non-English speech (PLAN.md §5).
    static let vocabulary = ["padding", "margin", "header", "footer", "sidebar", "navbar", "button", "modal", "dropdown",
                             "logo", "icon", "font", "layout", "scroll", "hover", "tooltip", "toggle", "input", "placeholder",
                             "border", "radius", "shadow", "gap", "grid", "flex", "card", "tab", "toast", "badge", "spinner"]

    static func chooseLocale() async -> Locale {
        let supported = Set(await DictationTranscriber.supportedLocales.map { $0.identifier(.bcp47) })
        // Manual override: `defaults write dev.halid.recper dictationLocale tr-TR`
        if let forced = UserDefaults.standard.string(forKey: "dictationLocale"), supported.contains(forced) { return Locale(identifier: forced) }
        // Exact match first (e.g. en-TR isn't supported, but tr-TR is if it's in the list), then language prefix.
        if let exact = Locale.preferredLanguages.first(where: supported.contains) { return Locale(identifier: exact) }
        for id in Locale.preferredLanguages {
            if let match = supported.first(where: { $0.hasPrefix(id.prefix(2) + "-") }) { return Locale(identifier: match) }
        }
        return Locale(identifier: supported.contains("tr-TR") ? "tr-TR" : "en-US")
    }

    /// If `file` is given, it is fed instead of the microphone (testing: `Recper --transcribe <file>`).
    func start(sessionStart: Date, file: URL? = nil) async throws {
        self.sessionStart = sessionStart
        let micOK = file != nil ? true : await AVCaptureDevice.requestAccess(for: .audio)
        guard micOK else {
            throw NSError(domain: "recper", code: 1, userInfo: [NSLocalizedDescriptionKey: "No microphone permission"])
        }
        let locale = await Self.chooseLocale()
        localeID = locale.identifier(.bcp47)
        let transcriber = DictationTranscriber(locale: locale, contentHints: [], transcriptionOptions: [.punctuation],
                                               reportingOptions: [.volatileResults], attributeOptions: [.audioTimeRange])
        if let req = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await req.downloadAndInstall()
        }
        let ctx = AnalysisContext()
        ctx.contextualStrings[.general] = Self.vocabulary + extraTerms
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        try await analyzer.setContext(ctx)
        self.analyzer = analyzer

        let audioFile = try file.map { try AVAudioFile(forReading: $0) }
        let natural = audioFile?.processingFormat ?? engine.inputNode.outputFormat(forBus: 0)
        guard let fmt = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber], considering: natural) else {
            throw NSError(domain: "recper", code: 2, userInfo: [NSLocalizedDescriptionKey: "No audio format"])
        }
        format = fmt
        converter = natural == fmt ? nil : AVAudioConverter(from: natural, to: fmt)
        self.natural = natural

        let (stream, cont) = AsyncStream<AnalyzerInput>.makeStream()
        continuation = cont

        resultsTask = Task { [weak self] in
            do {
                for try await r in transcriber.results { self?.handle(r) }
            } catch {
                await self?.report(error.localizedDescription)
            }
        }
        try await analyzer.start(inputSequence: stream)

        if let audioFile {
            while audioFile.framePosition < audioFile.length,
                  let buf = AVAudioPCMBuffer(pcmFormat: natural, frameCapacity: 4096) {
                try audioFile.read(into: buf)
                feed(buf)
            }
            return
        }
        try startMic()
        micOn = true
        startWatchdog()
    }

    // MARK: Microphone (resilient to disconnects)
    //
    // When the audio device changes (AirPods switch to call mode, headphones plug in, display wakes) AVAudioEngine
    // silently stops. On a change notification, or if no buffer arrives for 1.5 s, the engine is rebuilt; dictation continues.

    private func startMic() throws {
        let input = engine.inputNode
        let fmt = input.outputFormat(forBus: 0)
        guard fmt.sampleRate > 0, fmt.channelCount > 0 else {
            throw NSError(domain: "recper", code: 4, userInfo: [NSLocalizedDescriptionKey: "No microphone found"])
        }
        if natural != fmt, let target = format {
            natural = fmt
            converter = fmt == target ? nil : AVAudioConverter(from: fmt, to: target)
        }
        input.installTap(onBus: 0, bufferSize: 4096, format: fmt) { [weak self] buf, _ in self?.feed(buf) }
        engine.prepare()
        try engine.start()
        lastBuffer = Date()
        if let o = configObserver { NotificationCenter.default.removeObserver(o) }
        configObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { [weak self] _ in
            self?.restartMic(reason: "audio device changed")
        }
    }

    private let micQueue = DispatchQueue(label: "recper.mic")

    private func restartMic(reason: String) {
        micQueue.async { [weak self] in
            guard let self, self.micOn else { return }
            self.engine.inputNode.removeTap(onBus: 0)
            self.engine.stop()
            self.engine = AVAudioEngine()           // the old engine may not attach to the new device
            // Pad silence for the gap: keeps the dictation timeline aligned with the session clock (screenshot–sentence links stay correct).
            self.padSilence(Date().timeIntervalSince(self.lock.withLock { self.lastBuffer }))
            do {
                try self.startMic()
                Task { @MainActor [weak self] in self?.onStatus?("Microphone reconnected (\(reason))") }
            } catch {
                self.lastBuffer = Date()            // the watchdog retries after 1.5 s
                Task { @MainActor [weak self] in self?.onError?("Microphone: \(error.localizedDescription)") }
            }
        }
    }

    private func padSilence(_ seconds: Double) {
        guard seconds > 0.1, seconds < 600, let fmt = format else { return }
        var left = AVAudioFrameCount(seconds * fmt.sampleRate)
        while left > 0 {
            let n = min(left, AVAudioFrameCount(fmt.sampleRate))          // chunks of at most 1 s
            guard let b = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: n) else { return }
            b.frameLength = n
            let abl = UnsafeMutableAudioBufferListPointer(b.mutableAudioBufferList)
            for buf in abl { if let p = buf.mData { memset(p, 0, Int(buf.mDataByteSize)) } }
            continuation?.yield(AnalyzerInput(buffer: b))
            left -= n
        }
    }

    private func startWatchdog() {
        let t = DispatchSource.makeTimerSource(queue: micQueue)
        t.schedule(deadline: .now() + 1, repeating: 1)
        t.setEventHandler { [weak self] in
            guard let self, self.micOn else { return }
            if Date().timeIntervalSince(self.lock.withLock { self.lastBuffer }) > 1.5 { self.restartMic(reason: "no audio was arriving") }
        }
        t.resume()
        watchdog = t
    }

    /// Adds on-screen terms (AX) to the dictation hints. If they arrive before dictation starts, they are applied at start.
    private var extraTerms: [String] = []
    func addVocabulary(_ extra: [String]) async {
        guard !extra.isEmpty else { return }
        extraTerms = extra
        guard let analyzer else { return }
        let ctx = AnalysisContext()
        ctx.contextualStrings[.general] = Self.vocabulary + extra
        try? await analyzer.setContext(ctx)
    }

    /// Sentences finalized so far (fallback if stopping hangs).
    /// Finalized words and the indices where a final result ended (for splitting with custom cuts).
    func wordsAndBreaks() -> ([Word], Set<Int>) { lock.withLock { (words, breaks) } }

    func segmentsSoFar(cuts: [Double] = []) -> [Segment] { lock.withLock { Sentences.split(words, startID: 1, breaks: breaks, cuts: cuts) } }

    /// Stops recording, waits for the final results, returns the sentences.
    func stop(cuts: [Double] = []) async -> [Segment] {
        watchdog?.cancel(); watchdog = nil
        if let o = configObserver { NotificationCenter.default.removeObserver(o); configObserver = nil }
        micQueue.sync {
            if micOn { engine.inputNode.removeTap(onBus: 0); engine.stop(); micOn = false }
        }
        continuation?.finish()
        try? await analyzer?.finalizeAndFinishThroughEndOfInput()
        _ = await resultsTask?.value
        return segmentsSoFar(cuts: cuts)
    }

    // MARK: Audio

    /// Splits the buffer into 4 parts and maps each part's RMS from dB to a 0…1 scale.
    private func meter(_ buf: AVAudioPCMBuffer) {
        guard onLevel != nil, let ch = buf.floatChannelData?[0] else { return }
        let n = Int(buf.frameLength), parts = 4, step = max(1, n / parts)
        var out: [Float] = []
        for p in 0..<parts {
            var sum: Float = 0
            let a = p * step, b = min(n, a + step)
            guard b > a else { continue }
            for i in a..<b { sum += ch[i] * ch[i] }
            let db = 20 * log10(max(sqrt(sum / Float(b - a)), 1e-6))
            out.append(min(1, max(0, (db + 55) / 45)))
        }
        Task { @MainActor [weak self] in self?.onLevel?(out) }
    }

    private func feed(_ buf: AVAudioPCMBuffer) {
        meter(buf)
        lock.lock()
        lastBuffer = Date()
        if audioOffset == nil { audioOffset = Date().timeIntervalSince(sessionStart) - Double(buf.frameLength) / buf.format.sampleRate }
        lock.unlock()
        guard let fmt = format else { return }
        guard let converter else { continuation?.yield(AnalyzerInput(buffer: buf)); return }
        let cap = AVAudioFrameCount(Double(buf.frameLength) * fmt.sampleRate / buf.format.sampleRate) + 32
        guard let out = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: cap) else { return }
        nonisolated(unsafe) var given = false
        var err: NSError?
        converter.convert(to: out, error: &err) { _, status in
            if given { status.pointee = .noDataNow; return nil }
            given = true; status.pointee = .haveData; return buf
        }
        if err == nil, out.frameLength > 0 { continuation?.yield(AnalyzerInput(buffer: out)) }
    }

    // MARK: Results

    private func handle(_ r: DictationTranscriber.Result) {
        let text = String(r.text.characters)
        lock.lock()
        let offset = audioOffset ?? 0
        if r.isFinal, let cmd = VoiceCommand.parse(text) {
            volatileText = ""
            let live = finalText
            lock.unlock()
            Task { @MainActor [weak self] in
                self?.onText?(live)
                self?.onCommand?(cmd)
            }
            return
        }
        if r.isFinal {
            for run in r.text.runs {
                let w = String(r.text[run.range].characters).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !w.isEmpty else { continue }
                // A punctuation-only piece attaches to the previous word (avoids " .").
                if w.allSatisfy({ $0.isPunctuation }), let last = words.popLast() {
                    words.append(Word(w: last.w + w, t0: last.t0, t1: last.t1)); continue
                }
                if let tr = run.audioTimeRange {
                    words.append(Word(w: w, t0: tr.start.seconds + offset, t1: tr.end.seconds + offset))
                } else if let last = words.last {
                    words.append(Word(w: w, t0: last.t1, t1: last.t1))     // untimed piece: attaches to the previous one
                } else {
                    words.append(Word(w: w, t0: offset, t1: offset))
                }
            }
            if !words.isEmpty { breaks.insert(words.count - 1) }
            finalText += (finalText.isEmpty ? "" : " ") + text.trimmingCharacters(in: .whitespaces)
            volatileText = ""
        } else {
            volatileText = text
        }
        let live = [finalText, volatileText].filter { !$0.isEmpty }.joined(separator: " ")
        lock.unlock()
        let final = r.isFinal
        Task { @MainActor [weak self] in
            self?.onText?(live)
            if final { self?.onFinal?() }
        }
    }

    private func report(_ msg: String) async {
        await MainActor.run { [weak self] in self?.onError?(msg) }
    }
}
