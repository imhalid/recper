import Testing
import CoreGraphics
import Foundation
@testable import RecperCore

private let segs = [
    Segment(id: "s1", t0: 3.0, t1: 6.8, text: "The padding on this button is too large."),
    Segment(id: "s2", t0: 8.0, t1: 11.0, text: "The logo shifted left."),
    Segment(id: "s3", t0: 20.0, t1: 23.0, text: "The sidebar stutters."),
]

@Test func bindInsideSentence() {
    #expect(Binder.segmentIndex(for: 5.0, in: segs) == 0)
    #expect(Binder.segmentIndex(for: 6.9, in: segs) == 0)      // within tolerance
}

@Test func bindShortSilenceGoesToPrevious() {
    #expect(Binder.segmentIndex(for: 7.5, in: segs) == 0)
    #expect(Binder.segmentIndex(for: 13.0, in: segs) == 1)     // 2 s silence
}

@Test func bindLongSilenceGoesToNext() {
    #expect(Binder.segmentIndex(for: 15.0, in: segs) == 2)     // 4 s silence → next
    #expect(Binder.segmentIndex(for: 1.0, in: segs) == 0)      // before the first sentence
    #expect(Binder.segmentIndex(for: 40.0, in: segs) == 2)     // after the last sentence
    #expect(Binder.segmentIndex(for: 5, in: []) == nil)
}

@Test func splitsOnSentencePunctuation() {
    let ws = [Word(w: "Logo", t0: 1, t1: 1.3), Word(w: "shifted.", t0: 1.3, t1: 1.8),
              Word(w: "Center", t0: 2.5, t1: 2.9), Word(w: "it", t0: 2.9, t1: 3.1), Word(w: "please", t0: 5.0, t1: 5.4)]
    let out = Sentences.split(ws, startID: 4)
    #expect(out.map(\.text) == ["Logo shifted.", "Center it", "please"])
    #expect(out.map(\.id) == ["s4", "s5", "s6"])
    #expect(out[1].t0 == 2.5 && out[1].t1 == 3.1)
}

@Test func markdownOrdersSentencesAndShots() throws {
    let shots = Binder.bind([
        Shot(id: "01", t: 5, file: "shots/01.png", size: [800, 600], marks: [Mark(tool: .box, t: 5, points: [[10, 20], [110, 60]])]),
        Shot(id: "02", t: 1, file: "shots/02.png", size: [800, 600], marks: []),
    ], to: Array(segs.prefix(1)))
    let doc = SessionDoc(startedAt: Date(timeIntervalSince1970: 0), duration: 72,
                         target: TargetInfo(kind: "window", app: "Chrome", label: "Window · Chrome", size: [800, 600]),
                         locale: "en-US", segments: Array(segs.prefix(1)), shots: shots)
    let md = Writer.markdown(doc)
    #expect(md.contains("- [ ] 1. The padding on this button is too large. [00:03]\n      ![1](shots/01.png) — box (10,20)–(110,60)\n      ![2](shots/02.png)\n"))
    #expect(md.contains("# Feedback — 1970-01-01"))
    #expect(md.contains("Target: Window · Chrome (800×600) · duration 01:12 · 2 screenshots"))
    let back = try JSONDecoder.iso.decode(SessionDoc.self, from: Writer.json(doc))
    #expect(back.shots[0].segment == "s1")
}

@Test func markPixelsAreTopLeft() {
    let target = CGRect(x: 100, y: 200, width: 400, height: 300)       // Cocoa
    #expect(MarkMapper.pixel(CGPoint(x: 100, y: 500), target: target, scale: 2) == [0, 0])
    #expect(MarkMapper.pixel(CGPoint(x: 150, y: 450), target: target, scale: 2) == [100, 100])
}

extension JSONDecoder {
    static var iso: JSONDecoder { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }
}

@Test func splitsOnFinalResultBreaks() {
    let ws = [Word(w: "padding", t0: 1, t1: 1.3), Word(w: "large", t0: 1.4, t1: 1.8),
              Word(w: "logo", t0: 2.0, t1: 2.3), Word(w: "shifted", t0: 2.4, t1: 2.8)]
    #expect(Sentences.split(ws, startID: 1, breaks: [1]).map(\.text) == ["padding large", "logo shifted"])
}

@Test func boxSummaryIsNormalized() {
    #expect(Mark(tool: .box, t: 0, points: [[1694, 1207], [1304, 1064]]).summary == "box (1304,1064)–(1694,1207)")
}

@Test func longSpeechSplitsAtShotMoments() {
    // Continuous speech (one final result), screenshot taken at 2.6 s.
    let ws = [Word(w: "button", t0: 1.0, t1: 1.3), Word(w: "large", t0: 1.4, t1: 1.8),
              Word(w: "logo", t0: 2.0, t1: 2.3), Word(w: "shifted", t0: 2.4, t1: 2.8),
              Word(w: "menu", t0: 2.9, t1: 3.2), Word(w: "stutters", t0: 3.3, t1: 3.8)]
    let segs = Sentences.split(ws, startID: 1, cuts: [2.6])
    #expect(segs.map(\.text) == ["button large logo shifted", "menu stutters"])
    let shot = Shot(id: "01", t: 1.9, file: "shots/01.png", size: [1, 1], marks: [], taken: 2.6)
    #expect(Binder.bind([shot], to: segs)[0].segment == "s1")
}

@Test func markSummaryNamesNonDefaultColor() {
    #expect(Mark(tool: .ellipse, t: 0, points: [[10, 20], [5, 2]], color: .black).summary == "ellipse (5,2)–(10,20) (black)")
    #expect(Mark(tool: .arrow, t: 0, points: [[0, 0], [9, 9]], color: .red).summary == "arrow (0,0)→(9,9)")
}

@Test func checklistMarksItems() {
    let md = "x\n- [ ] 1. logo shifted [00:01]\n      ![1](shots/01.png)\n- [ ] 2. padding too large [00:05]\n"
    #expect(Checklist.items(md).map(\.n) == [1, 2])
    let done = Checklist.mark(md, item: 2)!
    #expect(done.contains("- [x] 2. padding too large"))
    #expect(Checklist.items(done).map(\.done) == [false, true])
    #expect(Checklist.mark(md, item: 9) == nil)
}

@Test func voiceCommandsOnlyWhenAlone() {
    #expect(VoiceCommand.parse("Görüntü al.") == .snapshot)
    #expect(VoiceCommand.parse("tamam bitir") == .finish)
    #expect(VoiceCommand.parse("Geri al") == .undo)
    #expect(VoiceCommand.parse("bu işi bitir") == nil)
    #expect(VoiceCommand.parse("şu butonun rengini geri al ve büyüt") == nil)
}

@Test func englishVoiceCommands() {
    #expect(VoiceCommand.parse("Take screenshot.") == .snapshot)
    #expect(VoiceCommand.parse("Okay, undo") == .undo)
    #expect(VoiceCommand.parse("Stop recording!") == .finish)
    #expect(VoiceCommand.parse("I am done") == nil)
    #expect(VoiceCommand.parse("finish the login form") == nil)
}

@Test func markSummaryHasNumberAndElement() {
    let m = Mark(tool: .box, t: 0, points: [[0, 0], [10, 10]], n: 3, element: "AXButton \"Save\"")
    #expect(m.summary == "#3 box (0,0)–(10,10) → AXButton \"Save\"")
}

@Test func tidyMergesFragmentsButNotAcrossShots() {
    let segs = [
        Segment(id: "s1", t0: 0, t1: 1, text: "Siri can you"),
        Segment(id: "s2", t0: 3, t1: 4, text: "hear me"),
        Segment(id: "s3", t0: 7, t1: 20, text: "I am painting this part green here what does this green mean"),
        Segment(id: "s4", t0: 21, t1: 22, text: "mine"),
        Segment(id: "s5", t0: 30, t1: 31, text: "October"),
    ]
    let out = Sentences.tidy(segs, cuts: [25])
    #expect(out.map(\.text) == ["Siri can you hear me", "I am painting this part green here what does this green mean mine", "October"])
    #expect(out.map(\.id) == ["s1", "s2", "s3"])
}

@Test func markdownListsMarksDrawnDuringSentence() {
    let segs = [Segment(id: "s1", t0: 0, t1: 5, text: "what is this green"), Segment(id: "s2", t0: 6, t1: 10, text: "and what are these")]
    let shot = Shot(id: "01", t: 1, file: "shots/01.png", size: [10, 10],
                    marks: [Mark(tool: .pen, t: 1, t1: 2, points: [[0, 0]], n: 1), Mark(tool: .pen, t: 7, t1: 9, points: [[0, 0]], n: 2)],
                    segment: "s1")
    let doc = SessionDoc(startedAt: Date(), duration: 10, target: TargetInfo(kind: "area", app: nil, label: "x", size: [10, 10]),
                         locale: "en-US", segments: segs, shots: [shot])
    let md = Writer.markdown(doc)
    #expect(md.contains("- [ ] 1. what is this green [00:00]\n      ↳ drawn while speaking: #1 (screenshot 1)\n"))
    #expect(md.contains("- [ ] 2. and what are these [00:06]\n      ↳ drawn while speaking: #2 (screenshot 1)\n"))
}

/// Real timings from a session: the user names the color, pauses, then draws. Each mark must get its own item,
/// starting where its explanation starts (not where the pen touched down).
@Test func marksSplitSpeechAtTheirExplanation() {
    let raw: [(String, Double, Double)] = [
        ("with", 4.76, 5.03), ("red", 7.94, 8.63), ("I", 9.20, 10.88), ("paint", 10.88, 11.54), ("a", 11.54, 11.75),
        ("problem", 11.87, 12.74), ("then", 13.94, 14.21), ("next", 14.21, 14.78), ("blue", 15.65, 16.46),
        ("this", 16.46, 17.21), ("needs", 17.21, 18.95), ("adding", 19.73, 21.83), ("look", 22.58, 22.97),
        ("yellow", 23.18, 24.83), ("another", 26.42, 26.69), ("problem", 26.75, 27.65),
    ]
    let words = raw.map { Word(w: $0.0, t0: $0.1, t1: $0.2) }
    let shot = Shot(id: "01", t: 9.2, file: "shots/01.png", size: [10, 10], marks: [
        Mark(tool: .pen, t: 9.2, t1: 11.7, points: [[0, 0]], n: 1),
        Mark(tool: .pen, t: 16.3, t1: 18.9, points: [[0, 0]], color: .blue, n: 2),
        Mark(tool: .pen, t: 24.1, t1: 27.1, points: [[0, 0]], color: .yellow, n: 3),
    ], taken: 30)
    let markCuts = Sentences.alignCuts(Binder.markCuts([shot]), words: words)
    #expect(markCuts == [7.94, 13.94, 22.58])          // moved back to the pause before each explanation
    let cuts = (markCuts + [30]).sorted()
    let segs = Sentences.tidy(Sentences.split(words, startID: 1, breaks: [Set(words.indices)].first!, cuts: cuts),
                              cuts: cuts, markCuts: markCuts)
    #expect(segs.map(\.text) == ["with", "red I paint a problem", "then next blue this needs adding", "look yellow another problem"])
    #expect(Binder.anchorIndex(for: 9.2, in: segs) == 1)
    #expect(Binder.anchorIndex(for: 16.3, in: segs) == 2)
    #expect(Binder.anchorIndex(for: 24.1, in: segs) == 3)
}
