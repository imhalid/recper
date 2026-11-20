import AppKit
import RecperCore

/// Precision drawing cursors per tool and ink color, rendered at 1x + 2x Retina with double-contrast halos
/// so every cursor stays razor-sharp on white pages, dark UIs, and photos.
@MainActor
enum Cursors {
    private static var cache: [String: NSCursor] = [:]

    static let canvasSize = NSSize(width: 44, height: 44)

    static func cursor(_ tool: Tool, _ color: InkColor) -> NSCursor {
        let key = "\(tool.rawValue)-\(color.rawValue)"
        if let c = cache[key] { return c }
        let c = make(tool, color)
        cache[key] = c
        return c
    }

    static func symbol(_ tool: Tool) -> String {
        switch tool {
        case .pen: "pencil.tip"
        case .box: "rectangle"
        case .ellipse: "circle"
        case .arrow: "arrow.up.right"
        case .blur: "eye.slash"
        }
    }

    /// Exact hot spot (top-left origin, in points) for each tool.
    static func hotSpot(for tool: Tool) -> CGPoint {
        tool == .pen ? CGPoint(x: 11, y: 11) : CGPoint(x: 13, y: 13)
    }

    private static func make(_ tool: Tool, _ color: InkColor) -> NSCursor {
        let hot = hotSpot(for: tool)
        let img = NSImage(size: canvasSize)
        // Add 2x Retina and 1x bitmap representations so NSCursor renders crisp on every display.
        for scale in [2, 1] {
            if let rep = renderRep(tool: tool, color: color, hot: hot, scale: scale) {
                img.addRepresentation(rep)
            }
        }
        return NSCursor(image: img, hotSpot: hot)
    }

    private static func renderRep(tool: Tool, color: InkColor, hot: CGPoint, scale: Int) -> NSBitmapImageRep? {
        let s = CGFloat(scale)
        let pw = Int(canvasSize.width) * scale
        let ph = Int(canvasSize.height) * scale
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: pw, height: ph, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }

        ctx.setShouldAntialias(true)
        ctx.setAllowsAntialiasing(true)
        ctx.interpolationQuality = .high

        // Flip to top-left origin so drawing coordinates match NSCursor.hotSpot 1:1.
        ctx.translateBy(x: 0, y: canvasSize.height * s)
        ctx.scaleBy(x: s, y: -s)

        switch tool {
        case .pen:
            drawPen(in: ctx, hot: hot, color: color, scale: s)
        case .box:
            drawCrosshair(in: ctx, hot: hot, dotColor: color, scale: s)
            drawBoxBadge(in: ctx, color: color, scale: s)
        case .ellipse:
            drawCrosshair(in: ctx, hot: hot, dotColor: color, scale: s)
            drawEllipseBadge(in: ctx, color: color, scale: s)
        case .arrow:
            drawCrosshair(in: ctx, hot: hot, dotColor: color, scale: s)
            drawArrowBadge(in: ctx, color: color, scale: s)
        case .blur:
            drawCrosshair(in: ctx, hot: hot, dotColor: nil, scale: s)
            drawBlurBadge(in: ctx, scale: s)
        }

        guard let cg = ctx.makeImage() else { return nil }
        let rep = NSBitmapImageRep(cgImage: cg)
        rep.size = canvasSize
        return rep
    }

    // MARK: Pen — Exact ink tip bead + sculpted precision fountain nib

    private static func drawPen(in ctx: CGContext, hot: CGPoint, color: InkColor, scale: CGFloat) {
        let light = color == .white || color == .yellow

        // 1. Exact ink bead centered directly on the hot spot.
        let r: CGFloat = 2.6
        let dot = CGRect(x: hot.x - r, y: hot.y - r, width: r * 2, height: r * 2)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -0.9 * scale), blur: 1.8 * scale, color: CGColor(gray: 0, alpha: 0.46))
        if light {
            ctx.setFillColor(CGColor(gray: 1, alpha: 0.55))
            ctx.fillEllipse(in: dot.insetBy(dx: -2.0, dy: -2.0))
        } else {
            ctx.setFillColor(CGColor(gray: 0.04, alpha: 0.72))
            ctx.fillEllipse(in: dot.insetBy(dx: -2.1, dy: -2.1))
        }
        ctx.restoreGState()

        if light {
            ctx.setFillColor(CGColor(gray: 0.08, alpha: 0.94))
            ctx.fillEllipse(in: dot.insetBy(dx: -1.25, dy: -1.25))
        } else {
            ctx.setFillColor(.white)
            ctx.fillEllipse(in: dot.insetBy(dx: -1.15, dy: -1.15))
        }
        ctx.setFillColor(color.cg)
        ctx.fillEllipse(in: dot)

        // Subtle specular glint on non-white ink beads.
        if color != .white {
            ctx.setFillColor(CGColor(gray: 1, alpha: 0.42))
            ctx.fillEllipse(in: CGRect(x: hot.x - 1.4, y: hot.y - 1.5, width: 1.5, height: 1.2))
        }

        // 2. Sculpted technical stylus / fountain nib pointing directly into the ink bead.
        ctx.saveGState()
        ctx.translateBy(x: hot.x + 3.8, y: hot.y + 3.8)
        ctx.rotate(by: .pi / 4)

        // Full pen silhouette (front nib + collar + machined graphite barrel).
        let body = CGMutablePath()
        body.move(to: CGPoint(x: 0, y: 0))
        body.addQuadCurve(to: CGPoint(x: 9.8, y: -4.8), control: CGPoint(x: 4.5, y: -4.2))
        body.addLine(to: CGPoint(x: 13.0, y: -3.8))
        body.addLine(to: CGPoint(x: 21.8, y: -3.2))
        body.addQuadCurve(to: CGPoint(x: 23.8, y: 0), control: CGPoint(x: 23.8, y: -2.4))
        body.addQuadCurve(to: CGPoint(x: 21.8, y: 3.2), control: CGPoint(x: 23.8, y: 2.4))
        body.addLine(to: CGPoint(x: 13.0, y: 3.8))
        body.addLine(to: CGPoint(x: 9.8, y: 4.8))
        body.addQuadCurve(to: CGPoint(x: 0, y: 0), control: CGPoint(x: 4.5, y: 4.2))
        body.closeSubpath()

        // Double-contrast halo around the whole pen silhouette.
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -1.2 * scale), blur: 2.2 * scale, color: CGColor(gray: 0, alpha: 0.45))
        ctx.setLineJoin(.round)
        ctx.setLineCap(.round)
        if light {
            ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.52))
            ctx.setLineWidth(3.4)
            ctx.addPath(body)
            ctx.strokePath()
        } else {
            ctx.setStrokeColor(CGColor(gray: 0.04, alpha: 0.68))
            ctx.setLineWidth(3.5)
            ctx.addPath(body)
            ctx.strokePath()
        }
        ctx.restoreGState()

        ctx.setLineJoin(.round)
        ctx.setLineCap(.round)
        ctx.setStrokeColor(light ? CGColor(gray: 0.08, alpha: 0.94) : CGColor(gray: 1, alpha: 0.98))
        ctx.setLineWidth(1.9)
        ctx.addPath(body)
        ctx.strokePath()

        // Clip interior fills cleanly to the silhouette.
        ctx.saveGState()
        ctx.addPath(body)
        ctx.clip()

        let space = CGColorSpace(name: CGColorSpace.sRGB)!

        // 2a. Front nib filled with vibrant ink color + subtle 3D directional lighting.
        let rgb = color.rgb
        let topTint = CGColor(srgbRed: min(1, rgb.r + 0.16), green: min(1, rgb.g + 0.16), blue: min(1, rgb.b + 0.16), alpha: 1)
        let botTint = CGColor(srgbRed: max(0, rgb.r * 0.78), green: max(0, rgb.g * 0.78), blue: max(0, rgb.b * 0.78), alpha: 1)
        if let grad = CGGradient(colorsSpace: space, colors: [topTint, color.cg, botTint] as CFArray, locations: [0, 0.48, 1]) {
            ctx.drawLinearGradient(grad, start: CGPoint(x: 6, y: -5), end: CGPoint(x: 6, y: 5), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        }

        // 2b. Machined platinum collar band (x = 12.6…14.9).
        let collarRect = CGRect(x: 12.6, y: -6, width: 2.3, height: 12)
        ctx.saveGState()
        ctx.clip(to: collarRect)
        if let grad = CGGradient(colorsSpace: space,
                                 colors: [CGColor(gray: 0.95, alpha: 1), CGColor(gray: 0.62, alpha: 1), CGColor(gray: 0.35, alpha: 1)] as CFArray,
                                 locations: [0, 0.55, 1]) {
            ctx.drawLinearGradient(grad, start: CGPoint(x: 13.7, y: -4.5), end: CGPoint(x: 13.7, y: 4.5), options: [])
        }
        ctx.restoreGState()

        // 2c. Rear obsidian graphite barrel (Recper signature material, x = 14.9…24).
        let barrelRect = CGRect(x: 14.9, y: -6, width: 10, height: 12)
        ctx.saveGState()
        ctx.clip(to: barrelRect)
        if let grad = CGGradient(colorsSpace: space,
                                 colors: [CGColor(gray: 0.34, alpha: 1), CGColor(gray: 0.15, alpha: 1), CGColor(gray: 0.08, alpha: 1)] as CFArray,
                                 locations: [0, 0.52, 1]) {
            ctx.drawLinearGradient(grad, start: CGPoint(x: 19, y: -4), end: CGPoint(x: 19, y: 4), options: [])
        }
        // Subtle specular ridge along the upper barrel.
        ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.28))
        ctx.setLineWidth(0.9)
        ctx.move(to: CGPoint(x: 15.2, y: -2.0))
        ctx.addLine(to: CGPoint(x: 21.8, y: -1.7))
        ctx.strokePath()
        ctx.restoreGState()

        // 2d. Fine collar seam hairlines.
        ctx.setStrokeColor(CGColor(gray: 0, alpha: 0.45))
        ctx.setLineWidth(0.6)
        ctx.move(to: CGPoint(x: 12.6, y: -5)); ctx.addLine(to: CGPoint(x: 12.6, y: 5))
        ctx.move(to: CGPoint(x: 14.9, y: -5)); ctx.addLine(to: CGPoint(x: 14.9, y: 5))
        ctx.strokePath()

        // 2e. Classic fountain-nib slit + breather hole on the front nib.
        let detailColor: CGColor = light ? CGColor(gray: 0.08, alpha: 0.72) : CGColor(gray: 1, alpha: 0.90)
        ctx.setStrokeColor(detailColor)
        ctx.setLineWidth(0.95)
        ctx.setLineCap(.round)
        ctx.move(to: CGPoint(x: 0.9, y: 0))
        ctx.addLine(to: CGPoint(x: 6.8, y: 0))
        ctx.strokePath()
        ctx.setFillColor(detailColor)
        ctx.fillEllipse(in: CGRect(x: 6.4, y: -1.25, width: 2.5, height: 2.5))

        ctx.restoreGState() // end silhouette clip
        ctx.restoreGState() // end pen transform
    }

    // MARK: Precision Optical Crosshair (Box, Ellipse, Arrow, Blur)

    private static func drawCrosshair(in ctx: CGContext, hot: CGPoint, dotColor: InkColor?, scale: CGFloat) {
        let arm: CGFloat = 9.5
        let gap: CGFloat = 3.2
        let arms: [(CGPoint, CGPoint)] = [
            (CGPoint(x: hot.x - arm, y: hot.y), CGPoint(x: hot.x - gap, y: hot.y)),
            (CGPoint(x: hot.x + gap, y: hot.y), CGPoint(x: hot.x + arm, y: hot.y)),
            (CGPoint(x: hot.x, y: hot.y - arm), CGPoint(x: hot.x, y: hot.y - gap)),
            (CGPoint(x: hot.x, y: hot.y + gap), CGPoint(x: hot.x, y: hot.y + arm)),
        ]

        // Outer dark casing with soft drop shadow.
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -0.7 * scale), blur: 1.4 * scale, color: CGColor(gray: 0, alpha: 0.42))
        ctx.setLineCap(.round)
        ctx.setLineWidth(3.2)
        ctx.setStrokeColor(CGColor(gray: 0.04, alpha: 0.80))
        for (a, b) in arms { ctx.move(to: a); ctx.addLine(to: b) }
        ctx.strokePath()
        ctx.restoreGState()

        // Crisp pure-white optical hairlines.
        ctx.setLineCap(.round)
        ctx.setLineWidth(1.3)
        ctx.setStrokeColor(.white)
        for (a, b) in arms { ctx.move(to: a); ctx.addLine(to: b) }
        ctx.strokePath()

        // Exact center pinpoint at the hot spot pixel.
        if let c = dotColor {
            let light = c == .white || c == .yellow
            let r: CGFloat = 1.25
            let dot = CGRect(x: hot.x - r, y: hot.y - r, width: r * 2, height: r * 2)
            if light {
                ctx.setFillColor(CGColor(gray: 0.06, alpha: 0.88))
                ctx.fillEllipse(in: dot.insetBy(dx: -0.95, dy: -0.95))
            } else {
                ctx.setFillColor(CGColor(gray: 0.04, alpha: 0.65))
                ctx.fillEllipse(in: dot.insetBy(dx: -1.4, dy: -1.4))
                ctx.setFillColor(.white)
                ctx.fillEllipse(in: dot.insetBy(dx: -0.8, dy: -0.8))
            }
            ctx.setFillColor(c.cg)
            ctx.fillEllipse(in: dot)
        } else {
            let r: CGFloat = 1.1
            let dot = CGRect(x: hot.x - r, y: hot.y - r, width: r * 2, height: r * 2)
            ctx.setFillColor(CGColor(gray: 0.04, alpha: 0.78))
            ctx.fillEllipse(in: dot.insetBy(dx: -0.9, dy: -0.9))
            ctx.setFillColor(.white)
            ctx.fillEllipse(in: dot)
        }
    }

    // MARK: Tool Badges (Lower-right quadrant)

    private static func drawBoxBadge(in ctx: CGContext, color: InkColor, scale: CGFloat) {
        let rect = CGRect(x: 21.5, y: 23.5, width: 17.5, height: 13.5)
        let path = CGPath(roundedRect: rect, cornerWidth: 3.2, cornerHeight: 3.2, transform: nil)
        fillSubtleTint(in: ctx, path: path, color: color)
        strokeWithHalo(in: ctx, path: path, color: color, width: 2.35, scale: scale)
    }

    private static func drawEllipseBadge(in ctx: CGContext, color: InkColor, scale: CGFloat) {
        let rect = CGRect(x: 21.0, y: 23.5, width: 18.5, height: 13.5)
        let path = CGPath(ellipseIn: rect, transform: nil)
        fillSubtleTint(in: ctx, path: path, color: color)
        strokeWithHalo(in: ctx, path: path, color: color, width: 2.35, scale: scale)
    }

    private static func drawArrowBadge(in ctx: CGContext, color: InkColor, scale: CGFloat) {
        let start = CGPoint(x: 22.5, y: 37.0)
        let tip = CGPoint(x: 37.5, y: 22.0)
        let ang = atan2(tip.y - start.y, tip.x - start.x)
        let head: CGFloat = 7.2
        let spread: CGFloat = .pi / 5.4
        let path = CGMutablePath()
        path.move(to: start)
        path.addLine(to: tip)
        path.move(to: CGPoint(x: tip.x - head * cos(ang - spread), y: tip.y - head * sin(ang - spread)))
        path.addLine(to: tip)
        path.addLine(to: CGPoint(x: tip.x - head * cos(ang + spread), y: tip.y - head * sin(ang + spread)))
        strokeWithHalo(in: ctx, path: path, color: color, width: 2.45, scale: scale)
    }

    /// Redact / Hide badge: a frosted 3×2 pixelation mosaic card with dashed privacy border and crisp eye-slash glyph.
    private static func drawBlurBadge(in ctx: CGContext, scale: CGFloat) {
        let rect = CGRect(x: 19.5, y: 22.0, width: 21.0, height: 15.5)
        let corner: CGFloat = 3.8
        let card = CGPath(roundedRect: rect, cornerWidth: corner, cornerHeight: corner, transform: nil)

        // Outer shadow + dark casing.
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -1.1 * scale), blur: 2.2 * scale, color: CGColor(gray: 0, alpha: 0.48))
        ctx.setStrokeColor(CGColor(gray: 0.04, alpha: 0.88))
        ctx.setLineWidth(3.1)
        ctx.addPath(card)
        ctx.strokePath()
        ctx.restoreGState()

        // Clipped 3×2 frosted mosaic pixelation grid (larger cells read unmistakably as pixel-blur redaction at 1×).
        ctx.saveGState()
        ctx.addPath(card)
        ctx.clip()

        let cols = 3, rows = 2
        let cw = rect.width / CGFloat(cols)
        let ch = rect.height / CGFloat(rows)
        let palette: [[CGFloat]] = [
            [0.24, 0.56, 0.32],
            [0.52, 0.22, 0.60],
        ]
        for row in 0..<rows {
            for col in 0..<cols {
                let lum = palette[row][col]
                ctx.setFillColor(CGColor(srgbRed: lum * 0.92, green: lum * 0.96, blue: min(1, lum * 1.08), alpha: 1))
                let cell = CGRect(x: rect.minX + CGFloat(col) * cw, y: rect.minY + CGFloat(row) * ch, width: cw + 0.3, height: ch + 0.3)
                ctx.fill(cell)
            }
        }
        // Soft center vignette so the white eye-slash reads effortlessly at a glance.
        ctx.setFillColor(CGColor(gray: 0.04, alpha: 0.28))
        ctx.fill(rect)
        ctx.restoreGState()

        // Crisp white dashed outline (directly echoing OverlayView's blurred-region border).
        ctx.saveGState()
        ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.95))
        ctx.setLineWidth(1.25)
        ctx.setLineDash(phase: 0.5, lengths: [3.8, 2.5])
        ctx.addPath(card)
        ctx.strokePath()
        ctx.restoreGState()

        // Crisp custom-vector eye-slash centered over the mosaic so it unmistakably reads "hide / redact".
        let cx = rect.midX, cy = rect.midY
        let eye = CGMutablePath()
        eye.move(to: CGPoint(x: cx - 5.9, y: cy))
        eye.addQuadCurve(to: CGPoint(x: cx + 5.9, y: cy), control: CGPoint(x: cx, y: cy - 4.9))
        eye.addQuadCurve(to: CGPoint(x: cx - 5.9, y: cy), control: CGPoint(x: cx, y: cy + 4.9))
        eye.closeSubpath()

        let slash = CGMutablePath()
        slash.move(to: CGPoint(x: cx - 5.0, y: cy + 4.5))
        slash.addLine(to: CGPoint(x: cx + 5.0, y: cy - 4.5))

        // Dark halo behind eye + pupil.
        ctx.saveGState()
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.setStrokeColor(CGColor(gray: 0.04, alpha: 0.92))
        ctx.setLineWidth(3.1)
        ctx.addPath(eye)
        ctx.strokePath()
        ctx.setFillColor(CGColor(gray: 0.04, alpha: 0.90))
        ctx.fillEllipse(in: CGRect(x: cx - 2.4, y: cy - 2.4, width: 4.8, height: 4.8))

        // Crisp white eye outline + pupil.
        ctx.setStrokeColor(.white)
        ctx.setLineWidth(1.4)
        ctx.addPath(eye)
        ctx.strokePath()
        ctx.setFillColor(.white)
        ctx.fillEllipse(in: CGRect(x: cx - 1.4, y: cy - 1.4, width: 2.8, height: 2.8))

        // Diagonal redaction slash cuts cleanly across the eye with a dark separation gap + pure white stroke.
        ctx.setStrokeColor(CGColor(gray: 0.04, alpha: 0.94))
        ctx.setLineWidth(3.5)
        ctx.addPath(slash)
        ctx.strokePath()
        ctx.setStrokeColor(.white)
        ctx.setLineWidth(1.6)
        ctx.addPath(slash)
        ctx.strokePath()
        ctx.restoreGState()
    }

    // MARK: Contrast Helpers

    private static func fillSubtleTint(in ctx: CGContext, path: CGPath, color: InkColor) {
        ctx.saveGState()
        if color == .white {
            ctx.setFillColor(CGColor(gray: 0.08, alpha: 0.24))
            ctx.addPath(path); ctx.fillPath()
            ctx.setFillColor(CGColor(gray: 1, alpha: 0.22))
            ctx.addPath(path); ctx.fillPath()
        } else {
            let rgb = color.rgb
            ctx.setFillColor(CGColor(srgbRed: rgb.r, green: rgb.g, blue: rgb.b, alpha: 0.18))
            ctx.addPath(path); ctx.fillPath()
        }
        ctx.restoreGState()
    }

    /// Adaptive double-contrast stroke: stays crisp on pure white pages, pure dark IDEs, and busy photos.
    private static func strokeWithHalo(in ctx: CGContext, path: CGPath, color: InkColor, width: CGFloat, scale: CGFloat) {
        let light = color == .white || color == .yellow
        ctx.saveGState()
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)

        // Outer halo + drop shadow.
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -1.0 * scale), blur: 2.0 * scale, color: CGColor(gray: 0, alpha: 0.46))
        if light {
            ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.45))
            ctx.setLineWidth(width + 3.6)
        } else {
            ctx.setStrokeColor(CGColor(gray: 0.04, alpha: 0.70))
            ctx.setLineWidth(width + 3.6)
        }
        ctx.addPath(path)
        ctx.strokePath()
        ctx.restoreGState()

        // Inner contrasting halo.
        ctx.setStrokeColor(light ? CGColor(gray: 0.08, alpha: 0.94) : CGColor(gray: 1, alpha: 0.98))
        ctx.setLineWidth(width + 2.15)
        ctx.addPath(path)
        ctx.strokePath()

        // Vivid ink core.
        ctx.setStrokeColor(color.cg)
        ctx.setLineWidth(width)
        ctx.addPath(path)
        ctx.strokePath()

        ctx.restoreGState()
    }
}
