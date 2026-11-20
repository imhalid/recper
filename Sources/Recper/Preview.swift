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

        let demoBlur = LiveStroke(tool: .blur, t: 0.5, points: [CGPoint(x: 560, y: 440), CGPoint(x: 860, y: 500)])
        let cases: [(String, OverlayModel.Phase, ((CGRect, String))?, (CGPoint, CGRect, CGRect)?)] = [
            ("1-area-idle", .choosing(.area), nil, nil),
            ("1b-area-last", .choosing(.area), nil, nil),
            ("2-area-drag", .choosing(.area), nil, (CGPoint(x: 400, y: 300), screen, CGRect(x: 400, y: 300, width: 520, height: 320))),
            ("3-window-hover", .choosing(.window), (win, "Google Chrome"), nil),
            ("4-screen-hover", .choosing(.screen), (screen, "Built-in Retina Display"), nil),
            ("5-session-window", .session(.window(id: 1, pid: 1, app: "Google Chrome", frame: win)), nil, nil),
            ("5b-session-selected-blur", .session(.window(id: 1, pid: 1, app: "Google Chrome", frame: win)), nil, nil),
            ("5c-session-selected-box", .session(.window(id: 1, pid: 1, app: "Google Chrome", frame: win)), nil, nil),
            ("5d-session-selected-arrow", .session(.window(id: 1, pid: 1, app: "Google Chrome", frame: win)), nil, nil),
        ]
        for (name, phase, hover, drag) in cases {
            let m = OverlayModel()
            m.phase = phase
            if name == "1b-area-last" { m.lastArea = CGRect(x: 300, y: 250, width: 640, height: 400) }
            m.hover = hover.map { ($0.0, $0.1) }
            m.drag = drag.map { ($0.0, $0.1, $0.2) }
            if name.hasPrefix("5") {
                m.strokes = { demoStrokes }
                m.blurs = { [demoBlur] }
                if name == "5b-session-selected-blur" { m.selectedMarkID = demoBlur.id }
                if name == "5c-session-selected-box" { m.selectedMarkID = demoStrokes[0].id; m.hoveredMarkID = demoStrokes[2].id }
                if name == "5d-session-selected-arrow" { m.selectedMarkID = demoStrokes[1].id }
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
        let gs = GlowState(); gs.on = true
        let edge = ZStack { Color(red: 0.12, green: 0.13, blue: 0.16); EdgeGlow(state: gs, radius: 12) }.frame(width: 1440, height: 900)
        writeSwiftUI(edge, to: url.appendingPathComponent("6b-edge-glow.png"))
        let radialItems = [("cursorarrow", "Cursor"), ("pencil.tip", "Pen"), ("rectangle", "Box"), ("arrow.up.right", "Arrow"),
                           ("checkmark", "Finish"), ("arrow.uturn.backward", "Undo"), ("eye.slash", "Blur")]
        let rm = RadialModel(); rm.shown = true; rm.selected = 1
        writeSwiftUI(RadialView(model: rm, items: radialItems), to: url.appendingPathComponent("6c-radial.png"))
        let rmCenter = RadialModel(); rmCenter.shown = true; rmCenter.selected = RadialMenu.center
        writeSwiftUI(RadialView(model: rmCenter, items: radialItems), to: url.appendingPathComponent("6d-radial-center.png"))
        let rmCancel = RadialModel(); rmCancel.shown = true; rmCancel.selected = RadialMenu.cancelled
        rmCancel.pointer = RadialModel.Pointer(offset: CGPoint(x: 165, y: -115), distance: 201, angle: 55, hasAngle: true)
        writeSwiftUI(RadialView(model: rmCancel, items: radialItems), to: url.appendingPathComponent("6e-radial-cancel.png"))
        let rmLight = RadialModel(); rmLight.shown = true; rmLight.selected = 0
        writeSwiftUI(RadialView(model: rmLight, items: radialItems).padding(20).background(Color(white: 0.96)),
                     to: url.appendingPathComponent("6f-radial-light.png"), backdrop: false)
        let rmDark = RadialModel(); rmDark.shown = true; rmDark.selected = 3
        writeSwiftUI(RadialView(model: rmDark, items: radialItems).padding(20).background(Color(white: 0.06)),
                     to: url.appendingPathComponent("6g-radial-dark.png"), backdrop: false)
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
        // Cursors: crisp 2x Retina showcase across white, dark, and gradient surfaces (every tool + ink colors + zoomed hotspot check).
        writeSwiftUI(CursorPreviewSheet(), to: url.appendingPathComponent("9-cursors.png"), backdrop: false)
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

        // Settings window sections (static dark-glass fallbacks, zero personal data).
        for (i, sec) in SettingsSection.allCases.enumerated() {
            let tag = String(format: "11-%02d-settings-%@.png", i + 1, sec.rawValue)
            writeSwiftUI(SettingsView(model: .preview(section: sec)), to: url.appendingPathComponent(tag))
        }
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

    private static func writeSwiftUI<V: View>(_ view: V, to url: URL, backdrop: Bool = true) {
        let r = ImageRenderer(content: backdrop
            ? AnyView(view.padding(20).background(Color(red: 0.35, green: 0.55, blue: 0.75)))
            : AnyView(view))
        r.scale = 2
        if let img = r.nsImage, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) {
            try? rep.representation(using: .png, properties: [:])?.write(to: url)
        }
    }
}

/// Comprehensive 2x Retina cursor inspection sheet: tests all tools & colors on white, dark, and photo-like backdrops,
/// plus a 2× zoomed row with exact hot-spot crosshairs.
private struct CursorPreviewSheet: View {
    private static let list: [(Tool, InkColor, String)] = [
        (.pen, .red, "Pen · Red"),
        (.pen, .black, "Pen · Black"),
        (.pen, .white, "Pen · White"),
        (.pen, .yellow, "Pen · Yellow"),
        (.box, .red, "Box · Red"),
        (.box, .white, "Box · White"),
        (.ellipse, .blue, "Ellipse · Blue"),
        (.arrow, .green, "Arrow · Green"),
        (.blur, .red, "Blur · Redact"),
    ]

    var body: some View {
        VStack(spacing: 0) {
            // Labels header
            HStack(spacing: 0) {
                Text("Surface").font(.system(size: 10, weight: .bold)).foregroundStyle(.white.opacity(0.6))
                    .frame(width: 72, alignment: .leading).padding(.leading, 10)
                ForEach(Array(Self.list.enumerated()), id: \.offset) { _, item in
                    Text(item.2).font(.system(size: 9.5, weight: .semibold)).foregroundStyle(.white.opacity(0.85))
                        .lineLimit(1)
                        .frame(width: 72)
                }
            }
            .frame(height: 26)
            .background(Color(white: 0.10))

            row(title: "White UI", darkLabel: true, bg: AnyView(Color.white))
            row(title: "Dark IDE", darkLabel: false, bg: AnyView(Color(red: 0.08, green: 0.09, blue: 0.11)))
            row(title: "Photo / Grad", darkLabel: false, bg: AnyView(
                LinearGradient(colors: [Color(red: 0.20, green: 0.45, blue: 0.72), Color(red: 0.78, green: 0.44, blue: 0.36), Color(red: 0.22, green: 0.56, blue: 0.40)],
                               startPoint: .leading, endPoint: .trailing)
            ))
            zoomedRow()
        }
        .fixedSize()
    }

    private func row(title: String, darkLabel: Bool, bg: AnyView) -> some View {
        HStack(spacing: 0) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(darkLabel ? Color.black.opacity(0.65) : Color.white.opacity(0.75))
                .frame(width: 72, alignment: .leading)
                .padding(.leading, 10)
            ForEach(Array(Self.list.enumerated()), id: \.offset) { _, item in
                let cur = Cursors.cursor(item.0, item.1)
                Image(nsImage: cur.image)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: Cursors.canvasSize.width, height: Cursors.canvasSize.height)
                    .frame(width: 72, height: 60)
            }
        }
        .background(bg)
    }

    private func zoomedRow() -> some View {
        let zoom: CGFloat = 1.65
        return HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text("1.65× HotSpot").font(.system(size: 9.5, weight: .semibold)).foregroundStyle(.white.opacity(0.8))
                Text("green = exact").font(.system(size: 8.5)).foregroundStyle(Color(red: 0.55, green: 1.0, blue: 0.5))
            }
            .frame(width: 72, alignment: .leading)
            .padding(.leading, 10)

            ForEach(Array(Self.list.enumerated()), id: \.offset) { _, item in
                let cur = Cursors.cursor(item.0, item.1)
                let hot = cur.hotSpot
                let w = Cursors.canvasSize.width * zoom
                let h = Cursors.canvasSize.height * zoom
                let hx = (hot.x - Cursors.canvasSize.width / 2) * zoom
                let hy = (hot.y - Cursors.canvasSize.height / 2) * zoom
                ZStack {
                    Rectangle().fill(Color(red: 0.55, green: 1.0, blue: 0.5).opacity(0.45)).frame(width: 1, height: 76).offset(x: hx)
                    Rectangle().fill(Color(red: 0.55, green: 1.0, blue: 0.5).opacity(0.45)).frame(width: 68, height: 1).offset(y: hy)
                    Image(nsImage: cur.image)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: w, height: h)
                }
                .frame(width: 72, height: 82)
            }
        }
        .background(Color(white: 0.16))
    }
}
