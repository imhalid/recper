import AppKit
import RecperCore

/// A session's data: dictation, strokes, screenshots; writes feedback.md + session.json on finish.
@MainActor
final class Recorder {
    let startedAt = Date()
    private(set) var target: CaptureTarget
    let dir: URL
    let transcriber = Transcriber()

    /// Strokes on screen not yet captured.
    private(set) var pending: [LiveStroke] = []
    private(set) var shots: [Shot] = []
    /// Thumbnails for the screenshot strip (72 px tall; full size is not kept in memory).
    private(set) var thumbs: [Thumb] = []
    private var shotSeq = 0
    /// Blurred regions: not cleared on capture; applied to every screenshot for the whole session.
    private(set) var blurs: [LiveStroke] = []
    var blurRects: [CGRect] { blurs.compactMap(Self.rect) }

    static func rect(_ s: LiveStroke) -> CGRect? {
        guard let a = s.points.first, let b = s.points.last else { return nil }
        return CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
    }
    private var capturing = false
    /// Auto-capture: when a sentence ends or after a short pause (so drawing isn't interrupted).
    private var ticker: Timer?
    private var lastInk: Double = 0
    private var lastSpeech: Double = -10
    private var stroking = false
    /// Last assigned mark number.
    private var markSeq = 0
    /// Last pen stroke: a stroke starting soon after, nearby, in the same color gets the same number (handwriting/scribbles are one mark).
    private var lastPen: (n: Int, color: InkColor, box: CGRect, end: Double)?
    static let groupGap: Double = 2
    static let groupReach: CGFloat = 90
    /// UI element under each stroke, keyed by the stroke's `t`.
    private var elements: [Double: String] = [:]

    var onChange: (() -> Void)?
    var onError: ((String) -> Void)?
    /// Captured strokes (fade out on screen).
    var onCaptured: (([LiveStroke]) -> Void)?

    /// Even without a sentence end: capture after this long since the last stroke and this long a pause in speech.
    static let idleInk: Double = 2.5
    static let idleSpeech: Double = 1.5
    /// For a sentence-end trigger, the stroke must have ended at least this long ago (so a late end of the previous sentence doesn't capture a new stroke).
    static let settle: Double = 0.8

    static var root: URL { rootURL }

    nonisolated static var rootURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".recper/sessions", isDirectory: true)
    }

    init(target: CaptureTarget) {
        self.target = target
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd_HHmmss"
        dir = Self.root.appendingPathComponent(f.string(from: startedAt), isDirectory: true)
        try? FileManager.default.createDirectory(at: dir.appendingPathComponent("shots"), withIntermediateDirectories: true)
        ticker = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    var now: Double { Date().timeIntervalSince(startedAt) }

    func retarget(_ t: CaptureTarget) {
        if !pending.isEmpty { snapshot() }
        target = t
    }

    // MARK: Drawing

    func begin(_ tool: Tool, color: InkColor, at p: CGPoint) {
        stroking = true
        var n: Int?
        if tool == .pen, let lp = lastPen, lp.color == color, now - lp.end < Self.groupGap,
           lp.box.insetBy(dx: -Self.groupReach, dy: -Self.groupReach).contains(p) {
            n = lp.n                                   // continuation of the same mark
        } else if tool != .blur {
            markSeq += 1; n = markSeq
        }
        pending.append(LiveStroke(tool: tool, t: now, points: [p], times: [now], color: color, n: n))
        onChange?()
    }

    func extend(to p: CGPoint) {
        guard let i = pending.indices.last else { return }
        // Mutate in place so an early return never drops the stroke (old bug: only one point remained).
        if pending[i].tool == .pen {
            guard let last = pending[i].points.last, hypot(p.x - last.x, p.y - last.y) >= 0.5 else { return }
            pending[i].points.append(p); pending[i].times.append(now)
        } else {
            pending[i].points = [pending[i].points[0], p]
        }
        onChange?()
    }

    func end() {
        stroking = false
        lastInk = now
        guard let s = pending.last else { return }
        // A click (or mouse jitter while clicking) is not a stroke: discard pen paths under 6 points
        // and box/arrow/blur diagonals under 8 points.
        let tiny: Bool
        if s.tool == .pen {
            tiny = Brush.length(s.points) < 6
        } else if let a = s.points.first, let b = s.points.last {
            tiny = hypot(b.x - a.x, b.y - a.y) < 8
        } else { tiny = true }
        if tiny {
            release(pending.removeLast()); onChange?()
            return
        }
        if s.tool == .blur {
            blurs.append(pending.removeLast())
            onChange?()
        }
        if s.tool == .pen, let n = s.n {
            let xs = s.points.map(\.x), ys = s.points.map(\.y)
            var box = CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
            if let lp = lastPen, lp.n == n { box = box.union(lp.box) }
            lastPen = (n, s.color, box, now)
        } else if s.tool != .blur {
            lastPen = nil
        }
        lookUpElement(s)
    }

    func undo() {
        if !pending.isEmpty {
            release(pending.removeLast())
        } else if let b = blurs.last, b.t > (shots.last?.taken ?? -1) {
            blurs.removeLast()          // last action was a blur
        } else if let last = shots.last {
            deleteShot(last.id); return
        }
        onChange?()
    }

    /// If the discarded stroke had the latest number, release it (keeps numbering gapless).
    private func release(_ s: LiveStroke) {
        if let n = s.n, n == markSeq, !pending.contains(where: { $0.n == n }), !shots.contains(where: { $0.marks.contains { $0.n == n } }) { markSeq -= 1 }
        if let lp = lastPen, lp.n == s.n, !pending.contains(where: { $0.n == lp.n }) { lastPen = nil }
        elements[s.t] = nil
    }

    /// Finds the element under a mark via the accessibility tree (if permitted; doesn't block the main thread).
    private func lookUpElement(_ s: LiveStroke) {
        guard AXIsProcessTrusted(), s.tool != .blur, let a = s.points.first, let b = s.points.last else { return }
        let p: CGPoint
        switch s.tool {
        case .box, .ellipse: p = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
        case .arrow: p = b                                   // arrow tip
        default:
            let xs = s.points.map(\.x), ys = s.points.map(\.y)
            p = CGPoint(x: xs.reduce(0, +) / CGFloat(xs.count), y: ys.reduce(0, +) / CGFloat(ys.count))
        }
        let q = Screens.quartz(p)
        var pid: pid_t?
        if case .window(_, let wp, _, _) = target { pid = wp }
        else { pid = WindowPicker.window(at: q, in: WindowList.onScreen(), excludingPID: WindowList.ownPID)?.pid }
        guard let pid else { return }
        let t = s.t
        Task { [weak self] in
            let d = await Task.detached { AXElement.describe(at: q, pid: pid) }.value
            if let d { self?.elements[t] = d }
        }
    }

    // MARK: Auto-capture

    /// Whether ink is waiting to be captured (blur regions don't count).
    private var hasInk: Bool { pending.contains { $0.tool != .blur } }

    /// Speech is ongoing (live text updated).
    func heard() { lastSpeech = now }

    /// Auto-capture (sentence end / pause). Off by default: the user takes screenshots with the shutter.
    nonisolated static var autoCapture: Bool {
        get { UserDefaults.standard.bool(forKey: "autoCapture") }
        set { UserDefaults.standard.set(newValue, forKey: "autoCapture") }
    }

    /// Dictation finalized a sentence: if there is ink being described, quietly capture.
    func sentenceEnded() {
        lastSpeech = now
        guard Self.autoCapture else { return }
        guard hasInk, !stroking, now - lastInk >= Self.settle else { return }
        snapshot()
    }

    /// Even without a sentence end: drawing finished and speech paused → capture.
    private func tick() {
        guard Self.autoCapture else { return }
        guard hasInk, !stroking, !capturing else { return }
        let n = now
        if n - lastInk >= Self.idleInk, n - lastSpeech >= Self.idleSpeech { snapshot() }
    }

    // MARK: Screenshot

    /// Captures the target with any pending strokes.
    func snapshot() {
        lastPen = nil                // next stroke after a capture is a new mark
        guard !capturing else { return }
        // Without permission ScreenCaptureKit can hang: report without trying; strokes stay on screen.
        guard CGPreflightScreenCaptureAccess() else {
            onError?("No Screen Recording permission: enable recper in System Settings › Privacy & Security › Screen & System Audio Recording, then restart recper.")
            return
        }
        guard let plan = Capture.plan(for: target) else { onError?("Target is not on screen"); return }
        capturing = true
        let strokes = pending.filter { $0.tool != .blur }
        let blurList = blurs
        let tgt = target
        let t = strokes.map(\.t).min() ?? now
        let taken = now
        shotSeq += 1
        let n = shotSeq          // numbers of deleted screenshots are not reused (avoids file collisions)
        let id = String(format: "%02d", n)
        let file = "shots/\(id).png"
        let url = dir.appendingPathComponent(file)
        Task {
            defer { capturing = false }
            do {
                let raw = try await withTimeout(4, "Screenshot") { try await Capture.image(plan) }
                let img = Capture.compose(raw, strokes: strokes, blurs: blurList.compactMap(Self.rect), target: tgt.frame)
                try Capture.writePNG(img, to: url)
                let scale = CGFloat(img.width) / tgt.frame.width
                let marks = (blurList.filter { Self.rect($0)?.intersects(tgt.frame) == true } + strokes).map { s in
                    Mark(tool: s.tool, t: (s.t * 10).rounded() / 10, t1: ((s.times.last ?? s.t) * 10).rounded() / 10,
                         points: s.points.map { MarkMapper.pixel($0, target: tgt.frame, scale: scale) },
                         color: s.tool == .blur ? nil : s.color, n: s.n, element: elements[s.t])
                }
                    .reduce(into: [Mark]()) { acc, m in
                        // Strokes with the same number (handwriting/scribbles) are one mark: points merge, the bounding box covers all.
                        if let n = m.n, let i = acc.firstIndex(where: { $0.n == n }) {
                            acc[i].points += m.points
                            acc[i].t1 = max(acc[i].t1 ?? acc[i].t, m.t1 ?? m.t)
                            if acc[i].element == nil { acc[i].element = m.element }
                        } else { acc.append(m) }
                    }
                thumbs.append(Thumb(id: id, image: Self.thumbnail(img)))
                shots.append(Shot(id: id, t: (t * 100).rounded() / 100, file: file, size: [img.width, img.height], marks: marks, taken: (taken * 100).rounded() / 100))
                // Captured strokes leave the screen; strokes drawn in the meantime stay.
                onCaptured?(strokes)
                let done = Set(strokes.map(\.t))
                pending.removeAll { done.contains($0.t) }
            } catch {
                onError?("Screenshot failed: \(error.localizedDescription)")
            }
            onChange?()
        }
    }

    func deleteShot(_ id: String) {
        guard let i = shots.firstIndex(where: { $0.id == id }) else { return }
        try? FileManager.default.removeItem(at: dir.appendingPathComponent(shots[i].file))
        shots.remove(at: i)
        thumbs.removeAll { $0.id == id }
        onChange?()
    }

    func url(ofShot id: String) -> URL? {
        shots.first { $0.id == id }.map { dir.appendingPathComponent($0.file) }
    }

    static func thumbnail(_ img: CGImage) -> NSImage {
        let h = 72, w = max(1, img.width * h / max(img.height, 1))
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return NSImage() }
        ctx.interpolationQuality = .high
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let small = ctx.makeImage() else { return NSImage() }
        return NSImage(cgImage: small, size: NSSize(width: CGFloat(w) / 2, height: CGFloat(h) / 2))
    }

    // MARK: Finish

    /// Stops dictation, writes the files, returns the feedback.md path.
    func finish() async -> URL { write(await collect()) }

    /// Stops dictation and builds the session document (doesn't write yet: the review screen may edit it).
    func collect() async -> SessionDoc {
        ticker?.invalidate(); ticker = nil
        if !pending.isEmpty { snapshot() }
        for _ in 0..<100 where capturing { try? await Task.sleep(for: .milliseconds(50)) }   // at most 5 s
        let tr = transcriber
        _ = try? await withTimeout(5, "Dictation") { await tr.stop() }
        let (words, breaks) = tr.wordsAndBreaks()
        // Cut at screenshot moments and where each mark's explanation starts: every mark gets its own item.
        let markCuts = Sentences.alignCuts(Binder.markCuts(shots), words: words)
        let cuts = (shots.compactMap(\.taken) + markCuts).sorted()
        let segments = Sentences.tidy(Sentences.split(words, startID: 1, breaks: breaks, cuts: cuts), cuts: cuts, markCuts: markCuts)
        let duration = now
        let scale = Capture.scale(for: target)
        let size = [Int(target.frame.width * scale), Int(target.frame.height * scale)]
        let app: String? = if case .window(_, _, let a, _) = target { a } else { nil }
        let doc = SessionDoc(startedAt: startedAt, duration: (duration * 10).rounded() / 10,
                             target: TargetInfo(kind: target.mode.rawValue, app: app, label: target.label, size: size),
                             locale: transcriber.localeID, segments: segments, shots: Binder.bind(shots, to: segments))
        return doc
    }

    /// Writes md + json; deletes files of screenshots removed from the document. Returns the feedback.md path.
    @discardableResult
    func write(_ doc: SessionDoc) -> URL {
        let kept = Set(doc.shots.map(\.file))
        for s in shots where !kept.contains(s.file) { try? FileManager.default.removeItem(at: dir.appendingPathComponent(s.file)) }
        let md = dir.appendingPathComponent("feedback.md")
        try? Writer.markdown(doc).write(to: md, atomically: true, encoding: .utf8)
        try? Writer.json(doc).write(to: dir.appendingPathComponent("session.json"))
        return md
    }
}
