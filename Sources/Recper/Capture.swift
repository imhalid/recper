import AppKit
import CoreImage
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers
import RecperCore

/// A stroke on screen (global Cocoa coordinates).
struct LiveStroke {
    var tool: Tool
    var t: Double
    var points: [CGPoint]
    /// For the pen, each point's time (s): speed → brush width.
    var times: [Double] = []
    var color: InkColor = .red
    /// Mark number (none for blur).
    var n: Int?
}

extension InkColor {
    var cg: CGColor { CGColor(srgbRed: rgb.r, green: rgb.g, blue: rgb.b, alpha: 1) }
    var ns: NSColor { NSColor(srgbRed: rgb.r, green: rgb.g, blue: rgb.b, alpha: 1) }
    /// Slightly darker shadow for light colors so white/yellow lines stay visible on light backgrounds.
    var shadowAlpha: CGFloat { self == .white || self == .yellow ? 0.55 : 0.32 }
}

/// Screenshot of the target (ScreenCaptureKit) + rendering strokes into the pixels. Our own windows are never captured.
enum Capture {
    /// Subtle dark shadow so ink reads on any background.
    static let shadowColor = CGColor(gray: 0, alpha: 0.35)
    static let lineWidth: CGFloat = 3.4   // average brush width (points)

    /// The target screen's scale factor (Retina: 2).
    @MainActor static func scale(for target: CaptureTarget) -> CGFloat {
        let mid = CGPoint(x: target.frame.midX, y: target.frame.midY)
        return Screens.under(mid)?.backingScaleFactor ?? 2
    }

    /// Capture plan: screen info is read on the main thread; the ScreenCaptureKit call runs separately with a timeout.
    struct Plan: Sendable {
        var windowID: UInt32?
        var displayID: UInt32
        var sourceRect: CGRect      // in the display's own points, top-left origin (unused for windows)
        var width: Int, height: Int
        var ownPID: Int32
    }

    @MainActor static func plan(for target: CaptureTarget) -> Plan? {
        let scale = scale(for: target)
        let f = target.frame
        guard let ns = Screens.under(CGPoint(x: f.midX, y: f.midY)) else { return nil }
        let local = f.intersection(ns.frame).offsetBy(dx: -ns.frame.minX, dy: -ns.frame.minY)
        var id: UInt32?
        if case .window(let w, _, _, _) = target { id = w }
        let size = id != nil ? f.size : local.size
        return Plan(windowID: id, displayID: Screens.displayID(ns),
                    sourceRect: CGRect(x: local.minX, y: ns.frame.height - local.maxY, width: local.width, height: local.height),
                    width: Int(size.width * scale), height: Int(size.height * scale), ownPID: WindowList.ownPID)
    }

    static func image(_ plan: Plan) async throws -> CGImage {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let config = SCStreamConfiguration()
        config.showsCursor = false
        config.capturesAudio = false
        config.width = plan.width
        config.height = plan.height
        let filter: SCContentFilter
        if let id = plan.windowID {
            guard let w = content.windows.first(where: { $0.windowID == id }) else { throw err("Window not found") }
            filter = SCContentFilter(desktopIndependentWindow: w)
        } else {
            guard let display = content.displays.first(where: { $0.displayID == plan.displayID }) else { throw err("Display not found") }
            // Our own windows (overlay, strip) are excluded; sharingType = .none guards this too.
            let own = content.windows.filter { $0.owningApplication?.processID == plan.ownPID }
            filter = SCContentFilter(display: display, excludingWindows: own)
            config.sourceRect = plan.sourceRect
        }
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }

    /// Draws strokes over the image. `target`: the global frame the image corresponds to.
    /// Blurred regions are burned into the pixels first (the raw version never hits disk), then ink.
    static func compose(_ img0: CGImage, strokes: [LiveStroke], blurs: [CGRect] = [], target: CGRect) -> CGImage {
        let img = obscure(img0, blurs, target: target)
        let w = img.width, h = img.height
        guard !strokes.isEmpty,
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return img }
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        // Global Cocoa → image pixels (CG context has a bottom-left origin, same orientation as the image).
        let sx = CGFloat(w) / target.width, sy = CGFloat(h) / target.height
        ctx.translateBy(x: 0, y: 0)
        ctx.scaleBy(x: sx, y: sy)
        ctx.translateBy(x: -target.minX, y: -target.minY)
        draw(strokes, in: ctx, lineWidth: lineWidth, pixelScale: sx)
        drawBadges(strokes, in: ctx, pixelScale: sx)
        return ctx.makeImage() ?? img
    }

    /// Blurred regions: pixelate + Gaussian blur (blur alone can be reversed; pixel blocks destroy the information).
    static func obscure(_ img: CGImage, _ rects: [CGRect], target: CGRect) -> CGImage {
        guard !rects.isEmpty else { return img }
        let sx = CGFloat(img.width) / target.width, sy = CGFloat(img.height) / target.height
        var out = CIImage(cgImage: img)
        let extent = out.extent
        for r in rects {
            let local = r.intersection(target)
            guard !local.isNull, local.width > 0, local.height > 0 else { continue }
            // CI also uses a bottom-left origin, same as Cocoa.
            let px = CGRect(x: (local.minX - target.minX) * sx, y: (local.minY - target.minY) * sy,
                            width: local.width * sx, height: local.height * sy).integral.intersection(extent)
            let block = max(12, min(px.width, px.height) / 6)
            let hidden = out.cropped(to: px).clampedToExtent()
                .applyingFilter("CIPixellate", parameters: [kCIInputScaleKey: block, kCIInputCenterKey: CIVector(x: px.minX, y: px.minY)])
                .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: block * 0.6])
                .cropped(to: px)
            out = hidden.composited(over: out)
        }
        return CIContext(options: [.cacheIntermediates: false]).createCGImage(out, from: extent) ?? img
    }

    /// Same drawing code on screen and in the screenshot.
    /// Fill path of a stroke (global coordinates): brush for the pen, clean shapes for box/ellipse/arrow.
    static func path(for s: LiveStroke, lineWidth: CGFloat = lineWidth) -> CGPath {
        let out = CGMutablePath()
        guard let a = s.points.first, let b = s.points.last else { return out }
        // A stroke that hasn't moved beyond a click isn't shown (no blob the moment you press).
        if s.tool == .pen, Brush.length(s.points) < 3 { return out }
        if s.tool != .pen, hypot(b.x - a.x, b.y - a.y) < 6 { return out }
        switch s.tool {
        case .pen:
            let ts = s.times.count == s.points.count ? s.times : s.points.indices.map { Double($0) / 120 }
            out.addPath(Brush.outline(s.points, times: ts, base: lineWidth))
        case .box: out.addPath(Shapes.box(a, b))
        case .ellipse: out.addPath(Shapes.ellipse(a, b))
        case .arrow: out.addPath(Shapes.arrow(a, b))
        case .blur:
            break   // not ink: handled in a separate layer / in pixels
        }
        return out
    }

    /// `pixelScale`: shadows are measured in device pixels (unaffected by the CTM).
    static func draw(_ strokes: [LiveStroke], in ctx: CGContext, lineWidth: CGFloat, pixelScale: CGFloat = 2) {
        ctx.saveGState()
        for s in strokes where s.tool != .blur {
            ctx.setShadow(offset: CGSize(width: 0, height: -0.5 * pixelScale), blur: 1.4 * pixelScale,
                          color: CGColor(gray: 0, alpha: s.color.shadowAlpha))
            ctx.setFillColor(s.color.cg)
            ctx.addPath(path(for: s, lineWidth: lineWidth))
            ctx.fillPath(using: .winding)
        }
        ctx.restoreGState()
    }

    // MARK: Number badge

    static let badgeRadius: CGFloat = 8.5

    /// Badge center (global coordinates): top-left corner for box/ellipse, start point for arrow and pen.
    static func badgeCenter(_ s: LiveStroke) -> CGPoint? {
        guard s.n != nil, s.tool != .blur, let a = s.points.first, let b = s.points.last else { return nil }
        switch s.tool {
        case .box, .ellipse: return CGPoint(x: min(a.x, b.x), y: max(a.y, b.y))
        default: return a
        }
    }

    /// Badge text color: dark on light ink.
    static func badgeText(_ c: InkColor) -> CGColor { c == .white || c == .yellow ? CGColor(gray: 0.08, alpha: 1) : .white }

    static func drawBadges(_ strokes: [LiveStroke], in ctx: CGContext, pixelScale: CGFloat) {
        var seen = Set<Int>()            // only the first stroke with a given number gets a badge
        for s in strokes {
            guard let n = s.n, let c = badgeCenter(s), seen.insert(n).inserted else { continue }
            let r = badgeRadius
            let disc = CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: -0.5 * pixelScale), blur: 1.5 * pixelScale, color: CGColor(gray: 0, alpha: 0.35))
            ctx.setFillColor(.white)
            ctx.fillEllipse(in: disc.insetBy(dx: -1.5, dy: -1.5))
            ctx.restoreGState()
            ctx.setFillColor(s.color.cg)
            ctx.fillEllipse(in: disc)
            let attr = NSAttributedString(string: "\(n)", attributes: [.font: NSFont.systemFont(ofSize: n > 9 ? 9.5 : 11, weight: .bold), .foregroundColor: NSColor(cgColor: badgeText(s.color)) ?? .white])
            let line = CTLineCreateWithAttributedString(attr)
            // Position-independent metrics: center vertically using ascent/descent (ImageBounds included the previous textPosition).
            var ascent: CGFloat = 0, descent: CGFloat = 0
            let w = CTLineGetTypographicBounds(line, &ascent, &descent, nil)
            ctx.textMatrix = .identity
            ctx.textPosition = CGPoint(x: c.x - CGFloat(w) / 2, y: c.y - (ascent - descent) / 2)
            CTLineDraw(line, ctx)
        }
    }

    static func writePNG(_ img: CGImage, to url: URL) throws {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { throw err("Could not write PNG") }
        CGImageDestinationAddImage(dest, img, nil)
        guard CGImageDestinationFinalize(dest) else { throw err("Could not write PNG") }
    }

    static func err(_ m: String) -> NSError { NSError(domain: "recper", code: 3, userInfo: [NSLocalizedDescriptionKey: m]) }
}
