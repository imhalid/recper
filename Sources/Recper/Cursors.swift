import AppKit
import RecperCore

/// Cursor per tool and color: thin crosshair (or brush tip for the pen) + a small badge of the selected tool.
@MainActor
enum Cursors {
    private static var cache: [String: NSCursor] = [:]

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

    private static func make(_ tool: Tool, _ color: InkColor) -> NSCursor {
        let size = NSSize(width: 40, height: 40)
        let hot = CGPoint(x: 12, y: 12)    // top-left origin
        let img = NSImage(size: size, flipped: true) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            if tool == .pen {
                // Brush tip: pen-colored dot with a white + dark ring so it shows on light and dark backgrounds.
                let r: CGFloat = 3.2
                let dot = CGRect(x: hot.x - r, y: hot.y - r, width: r * 2, height: r * 2)
                ctx.setFillColor(CGColor(gray: 0, alpha: 0.45))
                ctx.fillEllipse(in: dot.insetBy(dx: -2.6, dy: -2.6))
                ctx.setFillColor(.white)
                ctx.fillEllipse(in: dot.insetBy(dx: -1.6, dy: -1.6))
                ctx.setFillColor(color.cg)
                ctx.fillEllipse(in: dot)
            } else {
                // Thin crosshair: dark outline first, white line on top.
                let arm: CGFloat = 8, gap: CGFloat = 2.5
                let lines: [(CGPoint, CGPoint)] = [
                    (CGPoint(x: hot.x - arm, y: hot.y), CGPoint(x: hot.x - gap, y: hot.y)),
                    (CGPoint(x: hot.x + gap, y: hot.y), CGPoint(x: hot.x + arm, y: hot.y)),
                    (CGPoint(x: hot.x, y: hot.y - arm), CGPoint(x: hot.x, y: hot.y - gap)),
                    (CGPoint(x: hot.x, y: hot.y + gap), CGPoint(x: hot.x, y: hot.y + arm)),
                ]
                ctx.setLineCap(.round)
                for (w, c) in [(3.2, CGColor(gray: 0, alpha: 0.6)), (1.4, CGColor(gray: 1, alpha: 1))] {
                    ctx.setLineWidth(w); ctx.setStrokeColor(c)
                    for (a, b) in lines { ctx.move(to: a); ctx.addLine(to: b) }
                    ctx.strokePath()
                }
                ctx.setFillColor(.white)
                ctx.fillEllipse(in: CGRect(x: hot.x - 1, y: hot.y - 1, width: 2, height: 2))
            }
            // Badge: bottom-right, tool-colored disc + tool symbol.
            let badge = CGRect(x: 21, y: 21, width: 16, height: 16)
            let fill: CGColor = tool == .blur ? CGColor(gray: 0.2, alpha: 1) : color.cg
            ctx.setFillColor(CGColor(gray: 0, alpha: 0.35))
            ctx.fillEllipse(in: badge.insetBy(dx: -1.5, dy: -1.5))
            ctx.setFillColor(.white)
            ctx.fillEllipse(in: badge.insetBy(dx: -0.8, dy: -0.8))
            ctx.setFillColor(fill)
            ctx.fillEllipse(in: badge)
            let glyphColor: NSColor = (tool != .blur && (color == .white || color == .yellow)) ? .black : .white
            let conf = NSImage.SymbolConfiguration(pointSize: 8.5, weight: .bold)
                .applying(.init(paletteColors: [glyphColor]))
            if let g = NSImage(systemSymbolName: symbol(tool), accessibilityDescription: nil)?.withSymbolConfiguration(conf) {
                let s = g.size
                g.draw(in: CGRect(x: badge.midX - s.width / 2, y: badge.midY - s.height / 2, width: s.width, height: s.height))
            }
            return true
        }
        return NSCursor(image: img, hotSpot: hot)
    }
}
