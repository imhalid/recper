import AppKit
import SwiftUI
import RecperCore

/// Renders overlay and bar states to PNG without screen capture or permissions (for visual inspection).
@MainActor
enum Preview {
    static func render(to dir: String) {
        let url = URL(fileURLWithPath: dir)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let win = CGRect(x: 260, y: 160, width: 900, height: 600)

        let cases: [(String, OverlayModel.Phase, ((CGRect, String))?, (CGPoint, CGRect, CGRect)?)] = [
            ("1-area-idle", .choosing(.area), nil, nil),
            ("1b-area-last", .choosing(.area), nil, nil),
            ("2-area-drag", .choosing(.area), nil, (CGPoint(x: 400, y: 300), screen, CGRect(x: 400, y: 300, width: 520, height: 320))),
            ("3-window-hover", .choosing(.window), (win, "Google Chrome"), nil),
            ("4-screen-hover", .choosing(.screen), (screen, "Built-in Retina Display"), nil),
            ("5-session-window", .session(.window(id: 1, pid: 1, app: "Google Chrome", frame: win)), nil, nil),
        ]
        for (name, phase, hover, drag) in cases {
            let m = OverlayModel()
            m.phase = phase
            if name == "1b-area-last" { m.lastArea = CGRect(x: 300, y: 250, width: 640, height: 400) }
            m.hover = hover.map { ($0.0, $0.1) }
            m.drag = drag.map { ($0.0, $0.1, $0.2) }
            if name.hasPrefix("5") {
                m.strokes = { demoStrokes }
            }
            let v = OverlayView(model: m, screenFrame: screen)
            v.refresh()
            writeLayered(Backdrop(frame: v.frame), v, to: url.appendingPathComponent("\(name).png"))
        }

        BarView.flatBackground = true
        let b = BarModel()
        b.meter.samples = (0..<Meter.count).map { i in Float(abs(sin(Double(i) * 0.9)) * (0.25 + Double(i) / 30)) }
        b.mode = .area
        writeSwiftUI(BarView(model: b), to: url.appendingPathComponent("6-bar-choosing.png"))
        b.target = .window(id: 1, pid: 1, app: "Google Chrome", frame: win)
        b.startedAt = Date().addingTimeInterval(-72)
        b.tool = .pen
        b.color = .black
        b.shotCount = 3
        b.pendingCount = 1
        b.thumbs = (1...3).map { i in Thumb(id: String(format: "%02d", i), image: NSImage(size: NSSize(width: 56, height: 36), flipped: false) { r in NSColor(calibratedHue: CGFloat(i) / 5, saturation: 0.4, brightness: 0.9, alpha: 1).setFill(); r.fill(); return true }) }
        b.liveText = "This button's padding is too large, shrink it a bit. Also the logo in the header is shifted to the left"
        writeSwiftUI(BarView(model: b), to: url.appendingPathComponent("7-bar-session.png"))
        b.paletteOpen = true
        b.liveText = ""
        writeSwiftUI(BarView(model: b), to: url.appendingPathComponent("7b-bar-palette.png"))
        b.paletteOpen = false
        // Burn-in onto the screenshot: 2x white image + the same strokes (target = window).
        if let ctx = CGContext(data: nil, width: Int(win.width * 2), height: Int(win.height * 2), bitsPerComponent: 8, bytesPerRow: 0,
                               space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
            ctx.setFillColor(.white); ctx.fill(CGRect(x: 0, y: 0, width: ctx.width, height: ctx.height))
            // Fake secret line; the blur region sits on top of it.
            let ns = NSGraphicsContext(cgContext: ctx, flipped: false)
            NSGraphicsContext.current = ns
            NSAttributedString(string: "api_key = demo-0000-not-a-real-key", attributes: [.font: NSFont.monospacedSystemFont(ofSize: 44, weight: .medium)])
                .draw(at: CGPoint(x: 120, y: 120))
            NSGraphicsContext.current = nil
            let out = Capture.compose(ctx.makeImage()!, strokes: demoStrokes, blurs: [CGRect(x: 300, y: 205, width: 460, height: 50)], target: win)
            try? Capture.writePNG(out, to: url.appendingPathComponent("8-compose.png"))
        }
        // Cursors: each tool once (pen in black and yellow).
        let cur = NSImage(size: NSSize(width: 7 * 48, height: 48), flipped: false) { _ in
            NSColor(white: 0.85, alpha: 1).setFill(); CGRect(x: 0, y: 0, width: 7 * 48, height: 48).fill()
            let list: [(Tool, InkColor)] = [(.pen, .black), (.pen, .yellow), (.pen, .red), (.box, .red), (.ellipse, .blue), (.arrow, .green), (.blur, .red)]
            for (i, (t, c)) in list.enumerated() { Cursors.cursor(t, c).image.draw(at: CGPoint(x: i * 48 + 4, y: 4), from: .zero, operation: .sourceOver, fraction: 1) }
            return true
        }
        if let tiff = cur.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) { try? rep.representation(using: .png, properties: [:])?.write(to: url.appendingPathComponent("9-cursors.png")) }
        // Review screen.
        let shotImg = NSImage(size: NSSize(width: 96, height: 60), flipped: false) { r in NSColor(calibratedHue: 0.58, saturation: 0.3, brightness: 0.9, alpha: 1).setFill(); r.fill(); return true }
        let segs = [Segment(id: "s1", t0: 1, t1: 4, text: "This button's padding is too large, shrink it a bit"),
                    Segment(id: "s2", t0: 6, t1: 9, text: "The logo in the header is shifted left, center it"),
                    Segment(id: "s3", t0: 11, t1: 13, text: "Also the arrow at 2 is unnecessary")]
        let shots = [Shot(id: "01", t: 2, file: "shots/01.png", size: [1800, 1200], marks: [Mark(tool: .box, t: 2, points: [[10, 10], [200, 90]], n: 1, element: "AXButton \"Save\"")], segment: "s1"),
                     Shot(id: "02", t: 7, file: "shots/02.png", size: [1800, 1200], marks: [], segment: "s2"),
                     Shot(id: "03", t: 7.5, file: "shots/03.png", size: [1800, 1200], marks: [], segment: "s2")]
        let rd = SessionDoc(startedAt: Date(), duration: 14, target: TargetInfo(kind: "window", app: "Chrome", label: "Chrome", size: [1800, 1200]), locale: "en-US", segments: segs, shots: shots)
        writeSwiftUI(ReviewView(model: ReviewModel(doc: rd, images: ["01": shotImg, "02": shotImg, "03": shotImg])), to: url.appendingPathComponent("10-review.png"))
        print("ok \(dir)")
    }

    // A wave that starts slow and speeds up, and a hand-drawn loop (speed changes show up as width).
    static func wave() -> LiveStroke {
        var pts: [CGPoint] = [], ts: [Double] = []
        for i in 0..<60 {
            let d = Double(i)
            // Small deterministic jitter like a real mouse, so the smoothing effect is visible.
            pts.append(CGPoint(x: 480 + d * 6 + sin(d * 7.3) * 1.2, y: 420 + sin(d / 4) * 16 + cos(d * 5.1) * 1.2))
            ts.append(d * d * 0.0009 + d * 0.004)
        }
        return LiveStroke(tool: .pen, t: 3, points: pts, times: ts, color: .black, n: 4)
    }

    static func loop() -> LiveStroke {
        var pts: [CGPoint] = [], ts: [Double] = [], t = 0.0
        for i in 0..<70 {
            let d = Double(i), a: Double = d / 64 * 2 * .pi
            pts.append(CGPoint(x: 1000 + cos(a) * (110 + d * 0.4) + sin(d * 3.7) * 1.5, y: 560 + sin(a) * 60 + cos(d * 4.3) * 1.5))
            t += i < 20 ? 0.03 : 0.006
            ts.append(t)
        }
        return LiveStroke(tool: .pen, t: 4, points: pts, times: ts, n: 5)
    }

    static let demoStrokes: [LiveStroke] = [
        LiveStroke(tool: .box, t: 1, points: [CGPoint(x: 900, y: 300), CGPoint(x: 1080, y: 360)], n: 1),
        LiveStroke(tool: .arrow, t: 2, points: [CGPoint(x: 600, y: 520), CGPoint(x: 330, y: 650)], n: 2),
        LiveStroke(tool: .ellipse, t: 2.5, points: [CGPoint(x: 340, y: 230), CGPoint(x: 560, y: 300)], color: .blue, n: 3),
        wave(), loop(),
    ]

    /// A fake desktop under the overlay, so the dimming and the cut-out are visible.
    final class Backdrop: NSView {
        override func draw(_ r: NSRect) {
            NSColor(calibratedRed: 0.35, green: 0.55, blue: 0.75, alpha: 1).setFill(); bounds.fill()
            NSColor.white.setFill()
            NSBezierPath(roundedRect: CGRect(x: 260, y: 160, width: 900, height: 600), xRadius: 10, yRadius: 10).fill()
            NSColor(white: 0.92, alpha: 1).setFill()
            CGRect(x: 260, y: 728, width: 900, height: 32).fill()
            let t = NSAttributedString(string: "App window", attributes: [.font: NSFont.systemFont(ofSize: 28, weight: .bold)])
            t.draw(at: CGPoint(x: 300, y: 640))
        }
    }

    /// The overlay draws with layers: first the fake desktop, then the overlay's layer tree on top.
    private static func writeLayered(_ bg: NSView, _ v: OverlayView, to url: URL) {
        guard let rep = bg.bitmapImageRepForCachingDisplay(in: bg.bounds) else { return }
        bg.cacheDisplay(in: bg.bounds, to: rep)
        guard let ctx = NSGraphicsContext(bitmapImageRep: rep)?.cgContext, let layer = v.layer else { return }
        layer.render(in: ctx)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }

    private static func write(_ v: NSView, to url: URL) {
        guard let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
        v.cacheDisplay(in: v.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }

    private static func writeSwiftUI<V: View>(_ view: V, to url: URL) {
        let r = ImageRenderer(content: view.padding(20).background(Color(red: 0.35, green: 0.55, blue: 0.75)))
        r.scale = 2
        if let img = r.nsImage, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) {
            try? rep.representation(using: .png, properties: [:])?.write(to: url)
        }
    }
}
