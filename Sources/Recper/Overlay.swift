import AppKit
import RecperCore

/// Shared state of the overlays on all screens. Every overlay redraws when it changes.
@MainActor
final class OverlayModel {
    enum Phase: Equatable {
        case choosing(CaptureMode)
        case session(CaptureTarget)
    }

    var phase: Phase = .choosing(.area) { didSet { changed() } }
    /// Candidate highlighted during selection (global Cocoa coordinates) and its label.
    var hover: (rect: CGRect, label: String)? { didSet { changed() } }
    /// Area drag: start point and its screen (global coordinates).
    var drag: (start: CGPoint, screen: CGRect, current: CGRect)? { didSet { changed() } }
    /// Last selected area: shown ready when returning to Area mode; ⏎ or a click inside reuses it.
    var lastArea: CGRect? { didSet { changed() } }
    /// Drawing tool selected in the session; nil = pointer (clicks go to the app underneath).
    var tool: Tool? { didSet { changed() } }
    /// Color for new strokes.
    var color: InkColor = .red
    /// Strokes to show on screen.
    var strokes: () -> [LiveStroke] = { [] }
    /// Blurred regions (global coordinates).
    var blurs: () -> [CGRect] = { [] }

    var onChange: (() -> Void)?
    func changed() { onChange?() }
}

/// One per screen: borderless, transparent, above everything.
final class OverlayWindow: NSPanel {
    init(screen: NSScreen) {
        super.init(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .screenSaver
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isReleasedWhenClosed = false
        acceptsMouseMovedEvents = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        // Keep out of screen captures; ScreenCaptureKit also excludes our app.
        sharingType = .none
        setFrame(screen.frame, display: false)
    }
    /// Takes keyboard focus only while choosing; during a session it doesn't steal typing from the user's app.
    var keyable = true
    override var canBecomeKey: Bool { keyable }
}

final class OverlayView: NSView {
    let model: OverlayModel
    /// Global frame of the screen this view covers.
    var screenFrame: CGRect
    var onPick: ((CaptureTarget) -> Void)?
    var onKey: ((NSEvent) -> Void)?
    var onHover: ((CGPoint) -> Void)?
    /// Drawing in a session: begin / move / end (global coordinates, clamped to the target).
    var onStroke: ((StrokePhase, CGPoint) -> Void)?
    var screenName = ""
    var displayID: UInt32 = 0
    /// In Window mode, the window under the mouse (set by the controller).
    var pickedWindow: WindowInfo?

    enum StrokePhase { case begin, move, end }

    init(model: OverlayModel, screenFrame: CGRect) {
        self.model = model
        self.screenFrame = screenFrame
        super.init(frame: CGRect(origin: .zero, size: screenFrame.size))
        setUpLayers()
        refresh()
    }
    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var isFlipped: Bool { false }

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeAlways, .inVisibleRect, .cursorUpdate], owner: self))
    }

    override func cursorUpdate(with event: NSEvent) {
        switch model.phase {
        case .choosing(.area): NSCursor.crosshair.set()
        case .session where model.tool != nil: Cursors.cursor(model.tool!, model.color).set()
        default: NSCursor.arrow.set()
        }
    }

    private func global(_ e: NSEvent) -> CGPoint {
        let p = convert(e.locationInWindow, from: nil)
        return CGPoint(x: p.x + screenFrame.minX, y: p.y + screenFrame.minY)
    }

    private func clamped(_ p: CGPoint, to r: CGRect) -> CGPoint {
        CGPoint(x: min(max(p.x, r.minX), r.maxX), y: min(max(p.y, r.minY), r.maxY))
    }

    // MARK: Mouse

    override func mouseMoved(with e: NSEvent) { onHover?(global(e)) }

    private var drawing = false

    override func mouseDown(with e: NSEvent) {
        let p = global(e)
        switch model.phase {
        case .session(let t):
            guard model.tool != nil, t.frame.contains(p) else { return }
            drawing = true
            onStroke?(.begin, p)
        case .choosing(.area):
            model.drag = (p, screenFrame, CGRect(origin: p, size: .zero))
        case .choosing(.window):
            onHover?(p)
            if let h = model.hover, let w = pickedWindow { onPick?(.window(id: w.id, pid: w.pid, app: w.app, frame: h.rect)) }
        case .choosing(.screen):
            onPick?(.screen(displayID: displayID, name: screenName, frame: screenFrame))
        }
    }

    override func mouseDragged(with e: NSEvent) {
        if drawing, case .session(let t) = model.phase { onStroke?(.move, clamped(global(e), to: t.frame)); return }
        guard let d = model.drag else { return }
        model.drag = (d.start, d.screen, Geometry.dragRect(from: d.start, to: global(e), within: d.screen))
    }

    override func mouseUp(with e: NSEvent) {
        if drawing, case .session(let t) = model.phase {
            drawing = false
            onStroke?(.move, clamped(global(e), to: t.frame))
            onStroke?(.end, .zero)
            return
        }
        guard let d = model.drag else { return }
        model.drag = nil
        let r = Geometry.dragRect(from: d.start, to: global(e), within: d.screen)
        if Geometry.isUsableArea(r) {
            onPick?(.area(frame: r))
        } else if let last = model.lastArea, last.contains(d.start) {
            onPick?(.area(frame: last))          // click inside the previous area: reuse it
        }
    }

    override func keyDown(with e: NSEvent) { onKey?(e) }

    /// Shortcuts like ⌘Z arrive here instead of keyDown.
    override func performKeyEquivalent(with e: NSEvent) -> Bool {
        guard case .session = model.phase, e.modifierFlags.contains(.command), e.charactersIgnoringModifiers == "z" else { return false }
        onKey?(e)
        return true
    }

    // MARK: Drawing (layers)
    //
    // Redrawing the full screen on every mouse move stuttered. Now the dim overlay, border, label
    // and ink are separate layers; on change only their paths update and the GPU composites.

    private let dimLayer = CAShapeLayer()
    private let borderLayer = CAShapeLayer()
    /// Ink: a container clipped to the target + one shape layer per color.
    private let inkLayer = CALayer()
    private let inkMask = CAShapeLayer()
    private var inkLayers: [InkColor: CAShapeLayer] = [:]
    /// Mark numbers (badges), keyed by the stroke's `t`.
    private let numbersLayer = CALayer()
    private let numbersMask = CAShapeLayer()
    private var numberCache: [Double: CALayer] = [:]
    /// Blurred regions appear on screen as frosted, hatched boxes (the actual pixelation happens in the screenshot).
    private let blurLayer = CAShapeLayer()
    private let blurMask = CAShapeLayer()
    private let badgeLayer = CALayer()
    private let badgeText = CATextLayer()
    /// Stroke path cache: not recomputed unless the stroke changes (point count).
    private var inkCache: [Double: (count: Int, path: CGPath)] = [:]

    func setUpLayers() {
        let root = CALayer()
        layer = root
        wantsLayer = true
        root.frame = bounds
        dimLayer.fillRule = .evenOdd
        borderLayer.fillColor = nil
        inkLayer.mask = inkMask
        for c in InkColor.allCases {
            let l = Self.inkShape(c)
            l.frame = bounds
            inkLayer.addSublayer(l)
            inkLayers[c] = l
        }
        blurLayer.fillColor = NSColor(white: 0.82, alpha: 0.93).cgColor
        blurLayer.strokeColor = NSColor(white: 0.35, alpha: 0.9).cgColor
        blurLayer.lineWidth = 1
        blurLayer.lineDashPattern = [5, 4]
        blurLayer.mask = blurMask
        badgeLayer.backgroundColor = NSColor.black.withAlphaComponent(0.75).cgColor
        badgeText.foregroundColor = NSColor.white.cgColor
        badgeText.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        badgeText.fontSize = 12
        badgeLayer.addSublayer(badgeText)
        numbersLayer.mask = numbersMask
        for l in [dimLayer, blurLayer, inkLayer, numbersLayer, borderLayer, badgeLayer] as [CALayer] {
            l.frame = bounds
            root.addSublayer(l)
        }
        inkMask.frame = bounds
        numbersMask.frame = bounds
        blurMask.frame = bounds
    }

    override func viewDidChangeBackingProperties() {
        let s = window?.backingScaleFactor ?? 2
        [badgeLayer, badgeText].forEach { $0.contentsScale = s }
    }

    /// Number badge: ink-colored disc with a white rim + digit (same as in the screenshot).
    static func makeNumber(_ n: Int, _ color: InkColor, scale: CGFloat) -> CALayer {
        let r = Capture.badgeRadius
        let l = CALayer()
        l.bounds = CGRect(x: 0, y: 0, width: r * 2 + 3, height: r * 2 + 3)
        l.cornerRadius = r + 1.5
        l.backgroundColor = .white
        l.shadowColor = .black; l.shadowOpacity = 0.35; l.shadowRadius = 1.5; l.shadowOffset = CGSize(width: 0, height: -0.5)
        let d = CALayer()
        d.frame = l.bounds.insetBy(dx: 1.5, dy: 1.5); d.cornerRadius = r; d.backgroundColor = color.cg
        l.addSublayer(d)
        let t = CATextLayer()
        t.string = "\(n)"
        t.font = NSFont.systemFont(ofSize: 11, weight: .bold)
        t.fontSize = n > 9 ? 9.5 : 11
        t.foregroundColor = Capture.badgeText(color)
        t.alignmentMode = .center
        t.contentsScale = scale
        let h = t.fontSize + 3
        t.frame = CGRect(x: 0, y: (l.bounds.height - h) / 2 + 0.5, width: l.bounds.width, height: h)
        l.addSublayer(t)
        return l
    }

    private static func inkShape(_ c: InkColor) -> CAShapeLayer {
        let l = CAShapeLayer()
        l.fillColor = c.cg
        l.fillRule = .nonZero
        l.shadowColor = CGColor(gray: 0, alpha: c.shadowAlpha)
        l.shadowOpacity = 1
        l.shadowRadius = 1.2
        l.shadowOffset = CGSize(width: 0, height: -0.5)
        return l
    }

    /// Captured strokes fade out quietly and slowly (no flash or sound, so the flow isn't interrupted).
    func captured(_ strokes: [LiveStroke]) {
        guard case .session(let t) = model.phase, let hole = Geometry.hole(for: t.frame, onScreen: screenFrame), let root = layer else { return }
        let move = CGAffineTransform(translationX: -screenFrame.minX, y: -screenFrame.minY)
        var paths: [InkColor: CGMutablePath] = [:]
        for s in strokes where s.tool != .blur {
            let p = paths[s.color] ?? CGMutablePath()
            p.addPath(Capture.path(for: s), transform: move)
            paths[s.color] = p
        }
        guard !paths.isEmpty else { return }

        let ghost = CALayer()
        ghost.frame = bounds
        for (c, p) in paths {
            let l = Self.inkShape(c)
            l.frame = bounds; l.path = p; l.shadowPath = p
            ghost.addSublayer(l)
        }
        var ghostN = Set<Int>()
        for s in strokes {
            guard let n = s.n, let c = Capture.badgeCenter(s), ghostN.insert(n).inserted else { continue }
            let b = Self.makeNumber(n, s.color, scale: window?.backingScaleFactor ?? 2)
            b.position = CGPoint(x: c.x - screenFrame.minX, y: c.y - screenFrame.minY)
            ghost.addSublayer(b)
        }
        let m = CAShapeLayer(); m.frame = bounds; m.path = CGPath(rect: hole, transform: nil); ghost.mask = m
        ghost.opacity = 0
        root.insertSublayer(ghost, above: inkLayer)

        CATransaction.begin()
        CATransaction.setCompletionBlock { ghost.removeFromSuperlayer() }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1; fade.toValue = 0; fade.duration = 0.8
        fade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        ghost.add(fade, forKey: "fade")
        CATransaction.commit()
    }

    func refresh() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        func local(_ r: CGRect) -> CGRect? { Geometry.hole(for: r, onScreen: screenFrame) }
        var hole: CGRect?
        var dim: CGFloat = 0.35
        var label: String?
        var ghost = false   // previous area: dashed border
        var session = false

        switch model.phase {
        case .choosing(.area):
            if let d = model.drag, d.screen == screenFrame {
                hole = local(d.current)
                label = "\(Int(d.current.width)) × \(Int(d.current.height))"
            } else if model.drag == nil, let last = model.lastArea, let h = local(last) {
                hole = h; ghost = true
                label = "\(Int(last.width)) × \(Int(last.height)) · ⏎ or click inside"
            }
        case .choosing(.window):
            if let h = model.hover { hole = local(h.rect); label = h.label }
        case .choosing(.screen):
            if let h = model.hover, h.rect == screenFrame { hole = bounds; label = h.label; dim = 0.12 }
        case .session(let t):
            hole = local(t.frame); dim = 0.55; session = true
        }

        // Dim overlay, except the hole.
        let dimPath = CGMutablePath()
        dimPath.addRect(bounds)
        if let hole, !(hole == bounds && dim < 0.2) { dimPath.addRect(hole) }
        dimLayer.path = dimPath
        dimLayer.fillColor = NSColor.black.withAlphaComponent(dim).cgColor

        // Border.
        if let hole {
            let inset = session ? 0.75 : 1.5
            borderLayer.path = CGPath(rect: hole.insetBy(dx: inset, dy: inset), transform: nil)
            borderLayer.strokeColor = NSColor.controlAccentColor.withAlphaComponent(session ? 0.9 : 1).cgColor
            borderLayer.lineWidth = session ? 1.5 : (ghost ? 2 : 3)
            borderLayer.lineDashPattern = ghost ? [8, 5] : nil
        } else {
            borderLayer.path = nil
        }

        // Ink: clipped to the target; only changed strokes have their paths recomputed.
        if session, let hole {
            let strokes = model.strokes()
            let move = CGAffineTransform(translationX: -screenFrame.minX, y: -screenFrame.minY)
            var ink: [InkColor: CGMutablePath] = [:]
            var alive = Set<Double>()
            var badged = Set<Double>()
            var badgedN = Set<Int>()
            for s in strokes {
                alive.insert(s.t)
                let path: CGPath
                if let c = inkCache[s.t], c.count == s.points.count, s.tool == .pen {
                    path = c.path
                } else {
                    path = Capture.path(for: s)
                    inkCache[s.t] = (s.points.count, path)
                }
                if !path.isEmpty, let n = s.n, let c = Capture.badgeCenter(s), badgedN.insert(n).inserted {
                    badged.insert(s.t)
                    let b = numberCache[s.t] ?? {
                        let b = Self.makeNumber(n, s.color, scale: window?.backingScaleFactor ?? 2)
                        numbersLayer.addSublayer(b)
                        numberCache[s.t] = b
                        return b
                    }()
                    b.position = CGPoint(x: c.x - screenFrame.minX, y: c.y - screenFrame.minY)
                }
                let p = ink[s.color] ?? CGMutablePath()
                p.addPath(path, transform: move)
                ink[s.color] = p
            }
            inkCache = inkCache.filter { alive.contains($0.key) }
            for (t, b) in numberCache where !badged.contains(t) {
                b.removeFromSuperlayer(); numberCache[t] = nil
            }
            numbersMask.path = CGPath(rect: hole, transform: nil)
            for (c, l) in inkLayers {
                l.path = ink[c]
                l.shadowPath = ink[c]
            }
            inkMask.path = CGPath(rect: hole, transform: nil)
            // Blurred regions: committed ones + the one being dragged.
            var rects = model.blurs()
            for s in strokes where s.tool == .blur {
                if let a = s.points.first, let b = s.points.last {
                    rects.append(CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y)))
                }
            }
            let bp = CGMutablePath()
            for r in rects {
                let l = r.offsetBy(dx: -screenFrame.minX, dy: -screenFrame.minY)
                bp.addRect(l)
                // Hatching: diagonal lines so it reads as "hidden".
                var x = l.minX - l.height
                while x < l.maxX {
                    bp.move(to: CGPoint(x: max(x, l.minX), y: l.minY + max(0, l.minX - x)))
                    let end = min(x + l.height, l.maxX)
                    bp.addLine(to: CGPoint(x: end, y: l.minY + (end - x)))
                    x += 10
                }
            }
            blurLayer.path = bp
            blurMask.path = CGPath(rect: hole, transform: nil)
        } else {
            inkLayers.values.forEach { $0.path = nil; $0.shadowPath = nil }
            blurLayer.path = nil
            inkCache = [:]
            numberCache.values.forEach { $0.removeFromSuperlayer() }
            numberCache = [:]
        }

        // Label.
        if let label, let hole {
            let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
            let size = NSAttributedString(string: label, attributes: [.font: font]).size()
            let pad = CGSize(width: 8, height: 4)
            var r = CGRect(x: hole.minX, y: hole.maxY + 6, width: ceil(size.width) + pad.width * 2, height: ceil(size.height) + pad.height * 2)
            if r.maxY > bounds.maxY - 4 { r.origin.y = hole.maxY - r.height - 6; r.origin.x += 6 }   // no room above: move inside
            r.origin.x = min(max(r.minX, 4), bounds.maxX - r.width - 4)
            badgeLayer.frame = r
            badgeLayer.cornerRadius = r.height / 2
            badgeText.string = label
            badgeText.frame = CGRect(x: pad.width, y: pad.height - 1, width: ceil(size.width) + 2, height: ceil(size.height) + 2)
            badgeLayer.isHidden = false
        } else {
            badgeLayer.isHidden = true
        }
    }
}
