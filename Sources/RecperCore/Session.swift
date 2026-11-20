import CoreGraphics
import Foundation

// Session data. All times are on the session clock (seconds, 0 = session start). PLAN.md §4.

public struct Word: Codable, Equatable, Sendable {
    public var w: String
    public var t0: Double
    public var t1: Double
    public init(w: String, t0: Double, t1: Double) { self.w = w; self.t0 = t0; self.t1 = t1 }
}

/// One sentence (dictation output split on punctuation).
public struct Segment: Codable, Equatable, Sendable {
    public var id: String
    public var t0: Double
    public var t1: Double
    public var text: String
    public var words: [Word]
    public init(id: String, t0: Double, t1: Double, text: String, words: [Word] = []) {
        self.id = id; self.t0 = t0; self.t1 = t1; self.text = text; self.words = words
    }
}

public enum Tool: String, Codable, CaseIterable, Sendable {
    case pen, box, ellipse, arrow
    /// Sensitive info: the region is permanently pixelated in screenshots; persists for the whole session.
    case blur
}

/// Ink color. Red is the default; black stays readable on dark backgrounds thanks to its shadow.
public enum InkColor: String, Codable, CaseIterable, Sendable {
    case red, black, blue, yellow, green, white

    public var rgb: (r: CGFloat, g: CGFloat, b: CGFloat) {
        switch self {
        case .red: (1, 0.18, 0.2)
        case .black: (0.08, 0.08, 0.09)
        case .blue: (0.1, 0.45, 1)
        case .yellow: (1, 0.8, 0.05)
        case .green: (0.15, 0.75, 0.3)
        case .white: (1, 1, 1)
        }
    }

    public var name: String {
        switch self {
        case .red: "red"
        case .black: "black"
        case .blue: "blue"
        case .yellow: "yellow"
        case .green: "green"
        case .white: "white"
        }
    }
}

/// A mark on a screenshot; points are in the image's **pixel** coordinates (top-left origin).
public struct Mark: Codable, Equatable, Sendable {
    public var tool: Tool
    public var t: Double
    /// When drawing ended (for a merged mark, the end of the last stroke).
    public var t1: Double?
    public var points: [[Int]]
    public var color: InkColor?
    /// Mark number, increasing over the session (badge on screen and in the image; referred to in speech as "the one at 1…").
    public var n: Int?
    /// UI element under the mark (from the accessibility tree), e.g. `AXButton "Save"`.
    public var element: String?
    public init(tool: Tool, t: Double, t1: Double? = nil, points: [[Int]], color: InkColor? = nil, n: Int? = nil, element: String? = nil) {
        self.tool = tool; self.t = t; self.t1 = t1; self.points = points; self.color = color; self.n = n; self.element = element
    }

    /// Short description for humans and agents.
    public var summary: String {
        var s = shape
        if let n { s = "#\(n) " + s }
        if let color, color != .red, tool != .blur { s += " (\(color.name))" }
        if let element, !element.isEmpty { s += " → \(element)" }
        return s
    }

    private var shape: String {
        func p(_ a: [Int]) -> String { "(\(a[0]),\(a[1]))" }
        guard let first = points.first, let last = points.last else { return tool.rawValue }
        switch tool {
        case .blur:
            return "blurred area \(p([min(first[0], last[0]), min(first[1], last[1])]))–\(p([max(first[0], last[0]), max(first[1], last[1])]))"
        case .ellipse:
            return "ellipse \(p([min(first[0], last[0]), min(first[1], last[1])]))–\(p([max(first[0], last[0]), max(first[1], last[1])]))"
        case .box:   // independent of the drag corner: top-left – bottom-right
            return "box \(p([min(first[0], last[0]), min(first[1], last[1])]))–\(p([max(first[0], last[0]), max(first[1], last[1])]))"
        case .arrow: return "arrow \(p(first))→\(p(last))"
        case .pen:
            let xs = points.map { $0[0] }, ys = points.map { $0[1] }
            return "drawing \(p([xs.min()!, ys.min()!]))–\(p([xs.max()!, ys.max()!]))"
        }
    }
}

public struct Shot: Codable, Equatable, Sendable {
    public var id: String
    /// Moment used for binding: when the group's first drawing started (or when taken, if no drawings).
    public var t: Double
    public var file: String
    public var size: [Int]
    public var marks: [Mark]
    public var segment: String?
    /// When the screenshot was taken (used to split speech).
    public var taken: Double?
    public init(id: String, t: Double, file: String, size: [Int], marks: [Mark], segment: String? = nil, taken: Double? = nil) {
        self.id = id; self.t = t; self.file = file; self.size = size; self.marks = marks; self.segment = segment; self.taken = taken
    }
}

public struct TargetInfo: Codable, Equatable, Sendable {
    public var kind: String
    public var app: String?
    public var label: String
    public var size: [Int]
    public init(kind: String, app: String?, label: String, size: [Int]) {
        self.kind = kind; self.app = app; self.label = label; self.size = size
    }
}

public struct SessionDoc: Codable, Equatable, Sendable {
    public var version = 1
    public var startedAt: Date
    public var duration: Double
    public var target: TargetInfo
    public var locale: String
    public var segments: [Segment]
    public var shots: [Shot]
    public init(startedAt: Date, duration: Double, target: TargetInfo, locale: String, segments: [Segment], shots: [Shot]) {
        self.startedAt = startedAt; self.duration = duration; self.target = target; self.locale = locale
        self.segments = segments; self.shots = shots
    }
}

// MARK: Binding

public enum Binder {
    /// If the silence is longer than this, the screenshot goes to the next sentence (user pointed first, then spoke).
    public static let longGap: Double = 3
    /// Tolerance for small drifts at sentence boundaries.
    public static let slack: Double = 0.25

    /// Index of the sentence a screenshot binds to. nil if there are no sentences.
    public static func segmentIndex(for t: Double, in segs: [Segment]) -> Int? {
        guard !segs.isEmpty else { return nil }
        if let i = segs.firstIndex(where: { t >= $0.t0 - slack && t <= $0.t1 + slack }) { return i }
        let prev = segs.lastIndex { $0.t1 <= t }
        let next = segs.firstIndex { $0.t0 >= t }
        switch (prev, next) {
        case let (p?, n?): return t - segs[p].t1 > longGap ? n : p
        case let (p?, nil): return p
        case let (nil, n?): return n
        default: return nil
        }
    }

    /// Index of the sentence a mark belongs to. Speech is cut where each mark starts, so a mark usually sits
    /// between two sentences: it belongs to the one that follows (the user draws, then explains),
    /// unless that one starts more than `longGap` later — then to the previous one (explained first, then drew).
    public static func anchorIndex(for t: Double, in segs: [Segment]) -> Int? {
        guard !segs.isEmpty else { return nil }
        if let i = segs.firstIndex(where: { t >= $0.t0 && t <= $0.t1 }) { return i }
        let next = segs.firstIndex { $0.t0 >= t }
        if let n = next, segs[n].t0 - t <= longGap { return n }
        return segs.lastIndex { $0.t1 <= t } ?? next
    }

    /// Start times of numbered marks (one per number): speech is also cut there, so each mark gets its own item.
    public static func markCuts(_ shots: [Shot]) -> [Double] {
        var first: [Int: Double] = [:]
        for s in shots { for m in s.marks { if let n = m.n { first[n] = min(first[n] ?? m.t, m.t) } } }
        return first.values.sorted()
    }

    public static func bind(_ shots: [Shot], to segs: [Segment]) -> [Shot] {
        shots.map { s in
            var s = s
            // A screenshot with marks belongs where its first mark belongs; a plain one to what was just said.
            let i = s.marks.contains { $0.n != nil } ? anchorIndex(for: s.t, in: segs) : segmentIndex(for: s.t, in: segs)
            s.segment = i.map { segs[$0].id }
            return s
        }
    }
}

// MARK: Sentence splitting

public enum Sentences {
    /// Splits timestamped words at sentence-ending punctuation. `startID`: number of the first sentence.
    /// A pause this long ends the sentence even without punctuation.
    public static let pause: Double = 1.2

    /// `breaks`: a sentence ends after the word at these indices (the dictation engine's final-result boundaries).
    /// `cuts`: session moments (when screenshots were taken); the sentence is split there even during
    /// continuous speech, so each screenshot binds to its own narration.
    public static func split(_ words: [Word], startID: Int, breaks: Set<Int> = [], cuts: [Double] = []) -> [Segment] {
        let cuts = cuts.sorted()
        var ci = 0
        var out: [Segment] = []
        var cur: [Word] = []
        func flush() {
            guard let a = cur.first, let b = cur.last else { return }
            let text = cur.map(\.w).joined(separator: " ")
            out.append(Segment(id: "s\(startID + out.count)", t0: a.t0, t1: b.t1, text: text, words: cur))
            cur = []
        }
        for (i, w) in words.enumerated() {
            while ci < cuts.count, let prev = cur.last, cuts[ci] <= prev.t0 { ci += 1 }
            if ci < cuts.count, let prev = cur.last, cuts[ci] > prev.t0, cuts[ci] <= w.t0 { flush(); ci += 1 }
            if let prev = cur.last, w.t0 - prev.t1 > pause { flush() }
            cur.append(w)
            if let c = w.w.last, ".?!…".contains(c) { flush() } else if breaks.contains(i) { flush() }
        }
        flush()
        return out
    }

    /// Moves each mark cut back to where its explanation starts: people name the thing ("with red…") just
    /// before drawing. Within `lookback` seconds before the mark, the cut goes to the longest pause (≥ `minPause`);
    /// with no pause it stays at the mark. Cuts never move before the previous cut.
    public static func alignCuts(_ cuts: [Double], words: [Word], lookback: Double = 4, minPause: Double = 0.4) -> [Double] {
        var out: [Double] = []
        for c in cuts.sorted() {
            let floor = max(c - lookback, (out.last ?? -.infinity) + 0.05)
            var best: (pause: Double, at: Double)?
            for i in words.indices.dropFirst() {
                let w = words[i], prev = words[i - 1]
                guard w.t0 > floor, w.t0 <= c else { continue }
                let pause = w.t0 - prev.t1
                if pause >= minPause, pause > (best?.pause ?? 0) { best = (pause, w.t0) }
            }
            out.append(best?.at ?? c)
        }
        return out
    }

    /// Merges short fragments into their neighbor ("Siri can you" + "hear me", one-word crumbs):
    /// two sentences merge if either has at most `short` words and the silence between is under `maxGap` s.
    /// Never merges across a screenshot moment (`cuts`); a merged sentence never exceeds `maxWords`. IDs are renumbered.
    ///
    /// `markCuts` (subset of `cuts`): an item that starts at a mark keeps the speech that follows until the next cut,
    /// as long as pauses stay under `Binder.longGap` — the whole explanation of one mark is one item.
    public static func tidy(_ segs: [Segment], cuts: [Double] = [], markCuts: [Double] = [], short: Int = 3, maxGap: Double = 4, maxWords: Int = 45) -> [Segment] {
        var out: [Segment] = []
        var lastLed = false                       // does the last item start at a mark?
        var prevEnd = -Double.infinity
        for s in segs {
            let led = markCuts.contains { $0 > prevEnd - 0.01 && $0 <= s.t0 + 0.01 }
            prevEnd = s.t1
            if var last = out.last {
                let cut = cuts.contains { $0 > last.t1 - 0.01 && $0 <= s.t0 + 0.01 }
                let n1 = last.text.split(separator: " ").count, n2 = s.text.split(separator: " ").count
                let fragment = s.t0 - last.t1 < maxGap && min(n1, n2) <= short
                let sameMark = lastLed && s.t0 - last.t1 < Binder.longGap
                if !cut, fragment || sameMark, n1 + n2 <= maxWords {
                    last.text += " " + s.text
                    last.t1 = s.t1
                    last.words += s.words
                    out[out.count - 1] = last
                    continue
                }
            }
            out.append(s)
            lastLed = led
        }
        let first = segs.first.flatMap { Int($0.id.dropFirst()) } ?? 1
        for i in out.indices { out[i].id = "s\(first + i)" }
        return out
    }
}

// MARK: Output

public enum Writer {
    public static func clock(_ s: Double) -> String {
        let n = max(0, Int(s.rounded(.down))); return String(format: "%02d:%02d", n / 60, n % 60)
    }

    /// The main file the agent reads. Images are referenced by relative path.
    public static func markdown(_ doc: SessionDoc, now: Date = Date()) -> String {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "yyyy-MM-dd HH:mm"
        var md = "# Feedback — \(df.string(from: doc.startedAt))\n\n"
        let shots = doc.shots.count == 1 ? "1 screenshot" : "\(doc.shots.count) screenshots"
        md += "Target: \(doc.target.label) (\(doc.target.size[0])×\(doc.target.size[1])) · duration \(clock(doc.duration)) · \(shots)\n\n"
        md += "> The user's spoken feedback on the app, in the order it was said; each item is one task. "
        md += "The marks in the images were drawn by the user; `#n` numbers are the badges in the images (the user may say \"number 1\"). "
        md += "Coordinates are image pixels (top-left origin); `→` is the UI element under the mark. "
        md += "As you complete an item, change `- [ ]` to `- [x]`.\n\n"

        var n = 0
        var shotNo: [String: Int] = [:]
        for (i, s) in doc.shots.enumerated() { shotNo[s.id] = i + 1 }

        func shotLines(_ s: Shot) -> String {
            let marks = s.marks.map(\.summary).joined(separator: "; ")
            return "      ![\(shotNo[s.id]!)](\(s.file))" + (marks.isEmpty ? "" : " — \(marks)") + "\n"
        }

        /// Marks bind to sentences like screenshots do (within a sentence; after a short silence to the previous one, after a long one to the next);
        /// each mark is listed under exactly one sentence, whichever screenshot it is in, so the agent can match words to marks.
        var marksBySeg: [String: [(shot: Int, n: Int)]] = [:]
        var seenN = Set<Int>()
        for s in doc.shots {
            for m in s.marks {
                guard let n = m.n, seenN.insert(n).inserted, let i = Binder.anchorIndex(for: m.t, in: doc.segments) else { continue }
                marksBySeg[doc.segments[i].id, default: []].append((shotNo[s.id]!, n))
            }
        }
        func drawnDuring(_ seg: Segment) -> String {
            guard let list = marksBySeg[seg.id], !list.isEmpty else { return "" }
            var parts: [String] = []
            for shot in Array(Set(list.map(\.shot))).sorted() {
                parts.append(list.filter { $0.shot == shot }.map { "#\($0.n)" }.joined(separator: ", ") + " (screenshot \(shot))")
            }
            return "      ↳ drawn while speaking: " + parts.joined(separator: "; ") + "\n"
        }

        // Sentences with their bound images; images without a sentence are interleaved in time order.
        enum Item { case seg(Segment), loose(Shot) }
        var items: [(Double, Item)] = doc.segments.map { ($0.t0, .seg($0)) }
        items += doc.shots.filter { $0.segment == nil }.map { ($0.t, .loose($0)) }
        items.sort { $0.0 < $1.0 }

        for (_, item) in items {
            n += 1
            switch item {
            case .seg(let seg):
                md += "- [ ] \(n). \(seg.text) [\(clock(seg.t0))]\n"
                md += drawnDuring(seg)
                for s in doc.shots where s.segment == seg.id { md += shotLines(s) }
            case .loose(let s):
                md += "- [ ] \(n). (no speech) [\(clock(s.t))]\n" + shotLines(s)
            }
            md += "\n"
        }
        if items.isEmpty { md += "_(No speech or screenshots.)_\n" }
        return md
    }

    public static func json(_ doc: SessionDoc) throws -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        e.dateEncodingStrategy = .iso8601
        return try e.encode(doc)
    }
}

// MARK: Coordinates

public enum MarkMapper {
    /// Converts a global Cocoa point to the target image's pixel coordinates (top-left origin).
    public static func pixel(_ p: CGPoint, target: CGRect, scale: CGFloat) -> [Int] {
        [Int(((p.x - target.minX) * scale).rounded()), Int(((target.maxY - p.y) * scale).rounded())]
    }
}

// MARK: Checklist

/// The `- [ ] n.` items in feedback.md: list and tick them.
public enum Checklist {
    /// (item number, done, text)
    public static func items(_ md: String) -> [(n: Int, done: Bool, text: String)] {
        md.split(separator: "\n", omittingEmptySubsequences: false).compactMap { line in
            let l = String(line)
            let done: Bool
            if l.hasPrefix("- [ ] ") { done = false } else if l.hasPrefix("- [x] ") { done = true } else { return nil }
            let rest = l.dropFirst(6)
            guard let dot = rest.firstIndex(of: "."), let n = Int(rest[..<dot]) else { return nil }
            return (n, done, rest[rest.index(after: dot)...].trimmingCharacters(in: .whitespaces))
        }
    }

    /// Ticks (or unticks) item `n`. nil if there is no such item.
    public static func mark(_ md: String, item n: Int, done: Bool = true) -> String? {
        var found = false
        let lines = md.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            let l = String(line)
            for p in ["- [ ] \(n). ", "- [x] \(n). "] where l.hasPrefix(p) {
                found = true
                return (done ? "- [x] \(n). " : "- [ ] \(n). ") + l.dropFirst(p.count)
            }
            return l
        }
        return found ? lines.joined(separator: "\n") : nil
    }
}

// MARK: Voice commands

/// Only a short sentence consisting solely of a command counts ("take screenshot", "undo", "finish");
/// command words inside a longer sentence do not (e.g. "finish this task" is narration).
/// Turkish and English phrases are both accepted; dictation language follows the system.
public enum VoiceCommand: String, Sendable {
    case snapshot, undo, finish

    static let phrases: [VoiceCommand: [String]] = [
        .snapshot: ["görüntü al", "ekran görüntüsü al", "fotoğraf çek", "fotoğraf al", "çek", "screenshot", "ekranı al",
                    "take screenshot", "take a screenshot", "snapshot", "capture"],
        .undo: ["geri al", "sil", "sil onu", "onu sil", "son çizimi sil", "vazgeç",
                "undo", "delete that", "remove that"],
        .finish: ["bitir", "kaydı bitir", "tamam bitir", "bitti", "kaydı durdur", "gönder",
                  "finish", "done", "stop recording", "send"],
    ]

    /// Short filler words allowed before a command ("tamam görüntü al", "okay undo").
    static let fillers: Set<String> = ["tamam", "evet", "şimdi", "hadi", "lütfen", "şunu", "bunu",
                                       "ok", "okay", "now", "please"]

    public static func parse(_ text: String) -> VoiceCommand? {
        // Turkish lowercasing maps "I" to "ı", so English is also tried with a neutral locale.
        for locale in ["tr_TR", "en_US_POSIX"] {
            if let cmd = match(normalized(text, locale: locale)) { return cmd }
        }
        return nil
    }

    private static func normalized(_ text: String, locale: String) -> String {
        text.lowercased(with: Locale(identifier: locale))
            .filter { $0.isLetter || $0 == " " }
            .split(separator: " ").joined(separator: " ")
    }

    private static func match(_ t: String) -> VoiceCommand? {
        guard !t.isEmpty, t.split(separator: " ").count <= 4 else { return nil }
        for (cmd, list) in phrases where list.contains(t) { return cmd }
        // Short prefixes such as "tamam görüntü al", "evet bitir", "okay undo".
        for (cmd, list) in phrases {
            for p in list where p.split(separator: " ").count >= 1 && t.hasSuffix(" " + p) {
                let head = t.dropLast(p.count + 1)
                if fillers.contains(String(head)) { return cmd }
            }
        }
        return nil
    }
}
