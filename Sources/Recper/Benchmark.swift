import AppKit
import RecperCore

/// `Recper --benchmark`: times recper's hot paths (median of repeated runs) and prints a Markdown table.
/// No permissions, no screen capture: synthetic inputs of realistic size.
@MainActor
enum Benchmark {
    static func run() {
        var rows: [(String, String, String)] = []
        /// Median wall time of `runs` runs in milliseconds (after one warm-up run).
        func median(_ runs: Int, _ body: () -> Void) -> Double {
            body()
            var times: [Double] = []
            for _ in 0..<runs {
                let t0 = DispatchTime.now().uptimeNanoseconds
                body()
                times.append(Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6)
            }
            return times.sorted()[runs / 2]
        }
        func measure(_ name: String, detail: String, runs: Int, _ body: () -> Void) {
            rows.append((name, detail, format(median(runs, body))))
        }

        // 1. Burning marks + a blur region into a Retina window screenshot (what every shutter press does).
        let win = CGRect(x: 260, y: 160, width: 900, height: 600)
        let base = whiteImage(width: Int(win.width * 2), height: Int(win.height * 2))
        let strokes = Preview.demoStrokes
        let blur = CGRect(x: 560, y: 440, width: 300, height: 60)
        var composed = base
        measure("Compose screenshot", detail: "1800×1200, 5 marks + 1 blur region", runs: 20) {
            composed = Capture.compose(base, strokes: strokes, blurs: [blur], target: win)
        }

        // 2. Writing it as PNG.
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("recper-bench.png")
        measure("Write PNG", detail: "1800×1200", runs: 10) { try? Capture.writePNG(composed, to: tmp) }
        try? FileManager.default.removeItem(at: tmp)

        // 3. feedback.md for a long session.
        let doc = longSession(sentences: 60, shots: 25)
        measure("Write feedback.md", detail: "60 sentences, 25 screenshots", runs: 50) { _ = Writer.markdown(doc) }

        // 4. Circle gesture detection: cost per mouse-move event (the monitor runs on every move in cursor mode).
        var det = CircleGestureDetector()
        let events = 20_000
        var hits = 0
        let total = median(5) {
            det.reset()
            for i in 0..<events {
                let t = Double(i) / 120
                let a = t * 2 * .pi / 1.1                // a loop every 1.1 s, like a real circling motion
                let p = CGPoint(x: 700 + cos(a) * 120, y: 450 + sin(a) * 90)
                if det.add(point: p, at: t) != nil { hits += 1 }
            }
        }
        rows.append(("Circle gesture detector", "per mouse-move event, circling", String(format: "%.0f ns", total * 1_000_000 / Double(events))))
        // Worst case: the pointer keeps wandering without closing a loop, so every event runs the full scan.
        let wander = median(5) {
            det.reset()
            for i in 0..<events {
                let t = Double(i) / 120
                let p = CGPoint(x: 200 + Double((i * 7) % 1000), y: 450 + sin(t * 3) * 140)     // 7 pt steps: no event is skipped
                if det.add(point: p, at: t) != nil { hits += 1 }
            }
        }
        rows.append(("Circle gesture detector", "per mouse-move event, wandering (worst case)", String(format: "%.0f ns", wander * 1_000_000 / Double(events))))
        _ = hits

        // 5. Drawing a tool cursor (first use of a tool/color; cached afterwards).
        measure("Draw a tool cursor", detail: "pen, 2× Retina, uncached", runs: 20) {
            _ = Cursors.renderUncached(.pen, .red)
        }

        // 6. Synthesizing a UI sound.
        let voices = [Voice(f: 5000, filter: .highpass, decay: 0.006, gain: 0.22), Voice(f: 1800, filter: .bandpass, q: 3, delay: 0.035, decay: 0.005, gain: 0.28),
                      Voice(f: 140, to: 80, delay: 0.035, attack: 0.003, decay: 0.05, gain: 0.16)]
        measure("Synthesize a sound", detail: "shutter: 3 voices, 48 kHz stereo", runs: 50) { _ = Sounds.shared.render(voices) }

        print("| Operation | Input | Median |")
        print("|---|---|---:|")
        for r in rows { print("| \(r.0) | \(r.1) | \(r.2) |") }
    }

    private static func format(_ ms: Double) -> String {
        return ms < 1 ? String(format: "%.2f ms", ms) : String(format: "%.1f ms", ms)
    }

    private static func whiteImage(width: Int, height: Int) -> CGImage {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(.white); ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()!
    }

    private static func longSession(sentences: Int, shots: Int) -> SessionDoc {
        let segs = (0..<sentences).map { i in
            Segment(id: "s\(i)", t0: Double(i) * 4, t1: Double(i) * 4 + 3, text: "Sentence \(i): the spacing in this card looks off, make it consistent")
        }
        let list = (0..<shots).map { i in
            Shot(id: String(format: "%02d", i + 1), t: Double(i) * 9 + 1, file: String(format: "shots/%02d.png", i + 1), size: [1800, 1200],
                 marks: [Mark(tool: .box, t: Double(i) * 9, points: [[10, 10], [200, 90]], n: i + 1, element: "AXButton \"Save\"")],
                 segment: "s\(min(sentences - 1, i * 2))")
        }
        return SessionDoc(startedAt: Date(timeIntervalSince1970: 0), duration: Double(sentences) * 4,
                          target: TargetInfo(kind: "window", app: "Browser", label: "Browser", size: [1800, 1200]),
                          locale: "en-US", segments: segs, shots: list)
    }
}
