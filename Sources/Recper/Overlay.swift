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
    /// Blurred regions (global coordinates, editable LiveStrokes).
    var blurs: () -> [LiveStroke] = { [] }
    /// Currently selected editable mark (shows resize/move handles).
    var selectedMarkID: UUID? { didSet { if oldValue != selectedMarkID { changed() } } }
    /// Editable mark currently under the pointer (shows subtle grabbable highlight).
    var hoveredMarkID: UUID? { didSet { if oldValue != hoveredMarkID { changed() } } }
    /// Handle under the pointer when hovering a mark.
    var hoveredHandle: MarkHandle?

    /// All currently editable marks (blurs underneath ink marks, matching visual z-order).
    var editableMarks: [EditableMark] {
        blurs().map { EditableMark(id: $0.id, tool: $0.tool, points: $0.points) }
            + strokes().filter { $0.tool != .pen && $0.tool != .blur }
                .map { EditableMark(id: $0.id, tool: $0.tool, points: $0.points) }
    }

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
    /// Takes keyboard focus while choosing, drawing, or editing a selected mark.
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
    /// Mark editing callbacks.
    var onSelectMark: ((UUID?) -> Void)?
    var onHoverMark: ((MarkHit?) -> Void)?
    var onMoveMark: ((UUID, [CGPoint]) -> Void)?
    var onCommitMarkEdit: ((UUID, [CGPoint]) -> Void)?
    var onMarkDragChange: ((Bool) -> Void)?

    var screenName = ""
    var displayID: UInt32 = 0
    /// In Window mode, the window under the mouse (set by the controller).
    var pickedWindow: WindowInfo?

    enum StrokePhase { case begin, move, end }

    private struct MarkDrag {
        var mark: EditableMark
        var handle: MarkHandle
        var startPoint: CGPoint
        var moved = false
    }

    private var drawing = false
    private var markDrag: MarkDrag?
    /// Deferred draw-begin when a click on empty space first deselects a mark (avoids stray grab/drop sounds).
    private var pendingDrawStart: CGPoint?

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
        case .session:
            if let drag = markDrag {
                Self.cursor(for: MarkHit(id: drag.mark.id, handle: drag.handle), dragging: true, tool: model.tool, color: model.color).set()
            } else if let id = model.hoveredMarkID, let h = model.hoveredHandle {
                Self.cursor(for: MarkHit(id: id, handle: h), dragging: false, tool: model.tool, color: model.color).set()
            } else if let t = model.tool {
                Cursors.cursor(t, model.color).set()
            } else {
                NSCursor.arrow.set()
            }
        default: NSCursor.arrow.set()
        }
    }

    /// Resolves the appropriate cursor for mark hover/drag handles or active drawing tool.
    static func cursor(for hit: MarkHit?, dragging: Bool, tool: Tool?, color: InkColor) -> NSCursor {
        if let hit {
            switch hit.handle {
            case .body: return dragging ? .closedHand : .openHand
            case .start, .end: return dragging ? .closedHand : .crosshair
            case .left: return .frameResize(position: .left, directions: .all)
            case .right: return .frameResize(position: .right, directions: .all)
            case .top: return .frameResize(position: .top, directions: .all)
            case .bottom: return .frameResize(position: .bottom, directions: .all)
            case .topLeft: return .frameResize(position: .topLeft, directions: .all)
            case .topRight: return .frameResize(position: .topRight, directions: .all)
            case .bottomLeft: return .frameResize(position: .bottomLeft, directions: .all)
            case .bottomRight: return .frameResize(position: .bottomRight, directions: .all)
            }
        }
        if let tool { return Cursors.cursor(tool, color) }
        return .arrow
    }

    private func global(_ e: NSEvent) -> CGPoint {
        let p = convert(e.locationInWindow, from: nil)
        return CGPoint(x: p.x + screenFrame.minX, y: p.y + screenFrame.minY)
    }

    private func clamped(_ p: CGPoint, to r: CGRect) -> CGPoint {
        CGPoint(x: min(max(p.x, r.minX), r.maxX), y: min(max(p.y, r.minY), r.maxY))
    }

    // MARK: Mouse

    override func mouseMoved(with e: NSEvent) {
        let p = global(e)
        if case .session = model.phase {
            let hit = MarkGeometry.hitTest(point: p, marks: model.editableMarks, selectedID: model.selectedMarkID)
            onHoverMark?(hit)
            Self.cursor(for: hit, dragging: false, tool: model.tool, color: model.color).set()
            return
        }
        onHover?(p)
    }

    override func mouseDown(with e: NSEvent) {
        let p = global(e)
        switch model.phase {
        case .session(let t):
            // 1. Check editable marks & selection handles first (works in both drawing and cursor mode).
            if let hit = MarkGeometry.hitTest(point: p, marks: model.editableMarks, selectedID: model.selectedMarkID),
               let mark = model.editableMarks.first(where: { $0.id == hit.id }) {
                onSelectMark?(hit.id)
                markDrag = MarkDrag(mark: mark, handle: hit.handle, startPoint: p)
                onMarkDragChange?(true)
                Self.cursor(for: hit, dragging: true, tool: model.tool, color: model.color).set()
                return
            }

            // 2. Clicked outside any editable mark: deselect if needed, then draw if a tool is active.
            let hadSelection = (model.selectedMarkID != nil)
            if hadSelection { onSelectMark?(nil) }

            guard model.tool != nil, t.frame.contains(p) else { return }
            if hadSelection {
                pendingDrawStart = p
            } else {
                drawing = true
                onStroke?(.begin, p)
            }
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
        let p = global(e)
        if var drag = markDrag, case .session(let t) = model.phase {
            if !drag.moved {
                guard hypot(p.x - drag.startPoint.x, p.y - drag.startPoint.y) >= 2.5 else { return }
                drag.moved = true
                Sfx.grab()
            }
            markDrag = drag
            let next = MarkGeometry.resize(mark: drag.mark, handle: drag.handle, from: drag.startPoint, to: p, within: t.frame)
            onMoveMark?(drag.mark.id, next)
            Self.cursor(for: MarkHit(id: drag.mark.id, handle: drag.handle), dragging: true, tool: model.tool, color: model.color).set()
            return
        }
        if let start = pendingDrawStart, case .session(let t) = model.phase {
            if hypot(p.x - start.x, p.y - start.y) >= 4 {
                pendingDrawStart = nil
                drawing = true
                onStroke?(.begin, start)
                onStroke?(.move, clamped(p, to: t.frame))
            }
            return
        }
        if drawing, case .session(let t) = model.phase { onStroke?(.move, clamped(p, to: t.frame)); return }
        guard let d = model.drag else { return }
        model.drag = (d.start, d.screen, Geometry.dragRect(from: d.start, to: p, within: d.screen))
    }

    override func mouseUp(with e: NSEvent) {
        let p = global(e)
        if let drag = markDrag, case .session(let t) = model.phase {
            markDrag = nil
            onMarkDragChange?(false)
            if drag.moved {
                let next = MarkGeometry.resize(mark: drag.mark, handle: drag.handle, from: drag.startPoint, to: p, within: t.frame)
                onMoveMark?(drag.mark.id, next)
                onCommitMarkEdit?(drag.mark.id, drag.mark.points)
                Sfx.drop()
            }
            let hit = MarkGeometry.hitTest(point: p, marks: model.editableMarks, selectedID: model.selectedMarkID)
            onHoverMark?(hit)
            Self.cursor(for: hit, dragging: false, tool: model.tool, color: model.color).set()
            return
        }
        if pendingDrawStart != nil {
            pendingDrawStart = nil
            return
        }
        if drawing, case .session(let t) = model.phase {
            drawing = false
            onStroke?(.move, clamped(p, to: t.frame))
            onStroke?(.end, .zero)
            return
        }
        guard let d = model.drag else { return }
        model.drag = nil
        let r = Geometry.dragRect(from: d.start, to: p, within: d.screen)
        if Geometry.isUsableArea(r) {
            onPick?(.area(frame: r))
        } else if let last = model.lastArea, last.contains(d.start) {
            onPick?(.area(frame: last))          // click inside the previous area: reuse it
        }
    }

    override func keyDown(with e: NSEvent) { onKey?(e) }

    /// Shortcuts like ⌘Z arrive here instead of keyDown.
    override func performKeyEquivalent(with e: NSEvent) -> Bool {
        guard case .session = model.phase, e.modifierFlags.contains(.command), e.charactersIgnoringModifiers?.lowercased() == "z" else { return false }
        onKey?(e)
        return true
    }

    // MARK: Drawing (layers)
    //
    // Redrawing the full screen on every mouse move stuttered. Now the dim overlay, border, label,
    // ink, and editing handles are separate layers; on change only their paths update and the GPU composites.

    private static let selectionAccent = CGColor(srgbRed: 0.24, green: 0.58, blue: 1.0, alpha: 1.0)

    private let dimLayer = CAShapeLayer()
    private let borderLayer = CAShapeLayer()
    /// Ink: a container clipped to the target + one shape layer per color.
    private let inkLayer = CALayer()
    private let inkMask = CAShapeLayer()
    private var inkLayers: [InkColor: CAShapeLayer] = [:]
    /// Mark numbers (badges), keyed by the stroke's unique `id`.
    private let numbersLayer = CALayer()
    private let numbersMask = CAShapeLayer()
    private var numberCache: [UUID: CALayer] = [:]
    /// Blurred regions appear on screen only as their outline (dark halo + white dashes) with a small tag: what's under them
    /// stays readable for the user; the pixelation happens in the screenshot only.
    private let blurLayer = CAShapeLayer()
    private let blurHalo = CAShapeLayer()
    private let blurTags = CALayer()
    private var blurTagPool: [CALayer] = []
    private let blurMask = CAShapeLayer()
    /// Hover highlight + selection outline & interactive resize handles.
    private let editLayer = CALayer()
    private let hoverHaloLayer = CAShapeLayer()
    private let hoverLayer = CAShapeLayer()
    private let selectionHaloLayer = CAShapeLayer()
    private let selectionLayer = CAShapeLayer()
    private var handleLayers: [CALayer] = []
    private let badgeLayer = CALayer()
    private let badgeText = CATextLayer()
    /// Stroke path cache: not recomputed unless the stroke changes (point count for pen).
    private var inkCache: [UUID: (count: Int, path: CGPath)] = [:]

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
        blurHalo.fillColor = NSColor(white: 1, alpha: 0.04).cgColor
        blurHalo.strokeColor = NSColor(white: 0, alpha: 0.55).cgColor
        blurHalo.lineWidth = 3.5
        blurLayer.fillColor = nil
        blurLayer.strokeColor = NSColor.white.cgColor
        blurLayer.lineWidth = 1.5
        blurLayer.lineDashPattern = [6, 4]
        blurLayer.addSublayer(blurHalo)
        blurLayer.addSublayer(blurTags)
        blurLayer.mask = blurMask

        hoverHaloLayer.fillColor = nil
        hoverHaloLayer.strokeColor = NSColor.black.withAlphaComponent(0.35).cgColor
        hoverHaloLayer.lineWidth = 4.0
        hoverHaloLayer.lineCap = .round
        hoverHaloLayer.lineJoin = .round
        hoverLayer.fillColor = nil
        hoverLayer.strokeColor = NSColor.white.withAlphaComponent(0.85).cgColor
        hoverLayer.lineWidth = 1.6
        hoverLayer.lineCap = .round
        hoverLayer.lineJoin = .round

        selectionHaloLayer.fillColor = nil
        selectionHaloLayer.strokeColor = NSColor.black.withAlphaComponent(0.40).cgColor
        selectionHaloLayer.lineWidth = 3.2
        selectionHaloLayer.lineCap = .round
        selectionHaloLayer.lineJoin = .round
        selectionLayer.fillColor = nil
        selectionLayer.strokeColor = Self.selectionAccent
        selectionLayer.lineWidth = 1.5
        selectionLayer.lineCap = .round
        selectionLayer.lineJoin = .round

        for l in [hoverHaloLayer, hoverLayer, selectionHaloLayer, selectionLayer] {
            l.frame = bounds
            editLayer.addSublayer(l)
        }

        badgeLayer.backgroundColor = NSColor.black.withAlphaComponent(0.75).cgColor
        badgeText.foregroundColor = NSColor.white.cgColor
        badgeText.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        badgeText.fontSize = 12
        badgeLayer.addSublayer(badgeText)
        numbersLayer.mask = numbersMask
        for l in [dimLayer, blurLayer, inkLayer, numbersLayer, borderLayer, editLayer, badgeLayer] as [CALayer] {
            l.frame = bounds
            root.addSublayer(l)
        }
        inkMask.frame = bounds
        numbersMask.frame = bounds
        blurMask.frame = bounds
        blurHalo.frame = bounds
        blurTags.frame = bounds
        blurHalo.zPosition = -1
    }

    private func handleLayer(_ i: Int) -> CALayer {
        while handleLayers.count <= i {
            let h = CALayer()
            h.backgroundColor = CGColor.white
            h.borderColor = Self.selectionAccent
            h.borderWidth = 1.6
            h.shadowColor = CGColor.black
            h.shadowOpacity = 0.35
            h.shadowRadius = 2
            h.shadowOffset = CGSize(width: 0, height: -0.5)
            h.contentsScale = window?.backingScaleFactor ?? 2
            editLayer.addSublayer(h)
            handleLayers.append(h)
        }
        return handleLayers[i]
    }

    /// A small "eye.slash Blurred" pill at the top-left inside a blur region.
    private func blurTag(_ i: Int) -> CALayer {
        while blurTagPool.count <= i {
            let pill = CALayer()
            pill.backgroundColor = NSColor.black.withAlphaComponent(0.72).cgColor
            pill.borderColor = NSColor.white.withAlphaComponent(0.25).cgColor
            pill.borderWidth = 0.5
            let scale = window?.backingScaleFactor ?? 2
            let icon = CALayer()
            if let img = NSImage(systemSymbolName: "eye.slash.fill", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 9, weight: .semibold).applying(.init(paletteColors: [.white]))) {
                icon.contents = img.layerContents(forContentsScale: scale)
                icon.contentsScale = scale
                icon.frame = CGRect(x: 7, y: 4, width: img.size.width, height: img.size.height)
            }
            let t = CATextLayer()
            t.string = "Blurred in screenshot"
            t.font = NSFont.systemFont(ofSize: 10, weight: .semibold)
            t.fontSize = 10
            t.foregroundColor = NSColor.white.cgColor
            t.contentsScale = scale
            t.frame = CGRect(x: 23, y: 3, width: 112, height: 14)
            pill.addSublayer(icon); pill.addSublayer(t)
            pill.bounds = CGRect(x: 0, y: 0, width: 133, height: 19)
            pill.cornerRadius = 9.5
            pill.anchorPoint = .zero
            blurTags.addSublayer(pill)
            blurTagPool.append(pill)
        }
        return blurTagPool[i]
    }

    override func viewDidChangeBackingProperties() {
        let s = window?.backingScaleFactor ?? 2
        [badgeLayer, badgeText].forEach { $0.contentsScale = s }
        handleLayers.forEach { $0.contentsScale = s }
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

    /// Subtle short appear animation when a cursor-mode circle gesture creates an ellipse mark.
    /// Self-removes on completion (zero ongoing CPU).
    func animateGestureMark(_ stroke: LiveStroke) {
        guard case .session(let t) = model.phase,
              let hole = Geometry.hole(for: t.frame, onScreen: screenFrame),
              let rect = MarkGeometry.rect(for: stroke.points),
              let root = layer else { return }
        let localRect = rect.offsetBy(dx: -screenFrame.minX, dy: -screenFrame.minY)
        guard localRect.intersects(hole) else { return }

        let ripple = CAShapeLayer()
        let pad: CGFloat = 14
        let containerRect = localRect.insetBy(dx: -pad, dy: -pad)
        ripple.frame = containerRect
        ripple.path = CGPath(ellipseIn: CGRect(x: pad, y: pad, width: localRect.width, height: localRect.height), transform: nil)
        ripple.fillColor = nil
        ripple.strokeColor = stroke.color.cg
        ripple.lineWidth = 3.0
        ripple.opacity = 0
        root.insertSublayer(ripple, above: inkLayer)

        CATransaction.begin()
        CATransaction.setCompletionBlock { ripple.removeFromSuperlayer() }

        let scale = CABasicAnimation(keyPath: "transform.scale")
        scale.fromValue = 0.88
        scale.toValue = 1.12
        scale.duration = 0.32
        scale.timingFunction = CAMediaTimingFunction(name: .easeOut)

        let opacity = CAKeyframeAnimation(keyPath: "opacity")
        opacity.values = [0.0, 0.78, 0.0]
        opacity.keyTimes = [0.0, 0.18, 1.0]
        opacity.duration = 0.32

        let group = CAAnimationGroup()
        group.animations = [scale, opacity]
        group.duration = 0.32
        ripple.add(group, forKey: "gesturePop")
        CATransaction.commit()
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
        // While choosing, the frame has softly rounded corners (the screenshot itself stays rectangular).
        let corner: CGFloat = session || hole == bounds ? 0 : 10
        if let hole, !(hole == bounds && dim < 0.2) {
            let r = min(corner, hole.width / 2, hole.height / 2)
            dimPath.addRoundedRect(in: hole, cornerWidth: r, cornerHeight: r)
        }
        dimLayer.path = dimPath
        dimLayer.fillColor = NSColor.black.withAlphaComponent(dim).cgColor

        // Border.
        if let hole {
            let inset = session ? 0.75 : 1.5
            let b = hole.insetBy(dx: inset, dy: inset)
            let r = max(0, min(corner - inset, b.width / 2, b.height / 2))
            borderLayer.path = CGPath(roundedRect: b, cornerWidth: r, cornerHeight: r, transform: nil)
            borderLayer.strokeColor = NSColor.controlAccentColor.withAlphaComponent(session ? 0.9 : 1).cgColor
            borderLayer.lineWidth = session ? 1.5 : (ghost ? 2 : 3)
            borderLayer.lineDashPattern = ghost ? [8, 5] : nil
        } else {
            borderLayer.path = nil
        }

        // Ink & Blurs & Edit Chrome.
        if session, let hole {
            let strokes = model.strokes()
            let blurStrokes = model.blurs()
            let move = CGAffineTransform(translationX: -screenFrame.minX, y: -screenFrame.minY)
            var ink: [InkColor: CGMutablePath] = [:]
            var alive = Set<UUID>()
            var badged = Set<UUID>()
            var badgedN = Set<Int>()
            for s in strokes {
                alive.insert(s.id)
                let path: CGPath
                if let c = inkCache[s.id], c.count == s.points.count, s.tool == .pen {
                    path = c.path
                } else {
                    path = Capture.path(for: s)
                    inkCache[s.id] = (s.points.count, path)
                }
                if !path.isEmpty, let n = s.n, let c = Capture.badgeCenter(s), badgedN.insert(n).inserted {
                    badged.insert(s.id)
                    let b = numberCache[s.id] ?? {
                        let b = Self.makeNumber(n, s.color, scale: window?.backingScaleFactor ?? 2)
                        numbersLayer.addSublayer(b)
                        numberCache[s.id] = b
                        return b
                    }()
                    b.position = CGPoint(x: c.x - screenFrame.minX, y: c.y - screenFrame.minY)
                }
                let p = ink[s.color] ?? CGMutablePath()
                p.addPath(path, transform: move)
                ink[s.color] = p
            }
            inkCache = inkCache.filter { alive.contains($0.key) }
            for (id, b) in numberCache where !badged.contains(id) {
                b.removeFromSuperlayer(); numberCache[id] = nil
            }
            numbersMask.path = CGPath(rect: hole, transform: nil)
            for (c, l) in inkLayers {
                l.path = ink[c]
                l.shadowPath = ink[c]
            }
            inkMask.path = CGPath(rect: hole, transform: nil)

            // Blurred regions: committed ones + any blur currently being dragged.
            var rects = blurStrokes.compactMap { MarkGeometry.rect(for: $0.points) }
            for s in strokes where s.tool == .blur {
                if let r = MarkGeometry.rect(for: s.points) { rects.append(r) }
            }
            let bp = CGMutablePath()
            var tags = 0
            for r in rects {
                let l = r.offsetBy(dx: -screenFrame.minX, dy: -screenFrame.minY).insetBy(dx: 0.75, dy: 0.75)
                guard l.width > 2, l.height > 2 else { continue }
                let radius = min(8, l.width / 2, l.height / 2)
                bp.addRoundedRect(in: l, cornerWidth: radius, cornerHeight: radius)
                // Tag only where it fits; it sits inside the top-left corner.
                if l.width > 150, l.height > 30 {
                    let tag = blurTag(tags)
                    tag.position = CGPoint(x: l.minX + 6, y: l.maxY - 25)
                    tag.isHidden = false
                    tags += 1
                }
            }
            blurTagPool.dropFirst(tags).forEach { $0.isHidden = true }
            blurHalo.path = bp
            blurLayer.path = bp
            blurMask.path = CGPath(rect: hole, transform: nil)

            refreshEditChrome(editableMarks: model.editableMarks)
        } else {
            inkLayers.values.forEach { $0.path = nil; $0.shadowPath = nil }
            blurLayer.path = nil
            blurHalo.path = nil
            blurTagPool.forEach { $0.isHidden = true }
            inkCache = [:]
            numberCache.values.forEach { $0.removeFromSuperlayer() }
            numberCache = [:]
            clearEditChrome()
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

    private func clearEditChrome() {
        hoverHaloLayer.path = nil
        hoverLayer.path = nil
        selectionHaloLayer.path = nil
        selectionLayer.path = nil
        handleLayers.forEach { $0.isHidden = true }
    }

    private func refreshEditChrome(editableMarks: [EditableMark]) {
        func toLocal(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x - screenFrame.minX, y: p.y - screenFrame.minY) }
        func toLocal(_ r: CGRect) -> CGRect { r.offsetBy(dx: -screenFrame.minX, dy: -screenFrame.minY) }

        // 1. Subtle hover highlight on an unselected editable mark.
        if let hoverID = model.hoveredMarkID, hoverID != model.selectedMarkID,
           let mark = editableMarks.first(where: { $0.id == hoverID }) {
            let p = CGMutablePath()
            switch mark.tool {
            case .box, .blur:
                if let r = MarkGeometry.rect(for: mark.points) {
                    let lr = toLocal(r).insetBy(dx: -2, dy: -2)
                    let rad = min(8, lr.width / 4, lr.height / 4)
                    p.addRoundedRect(in: lr, cornerWidth: rad, cornerHeight: rad)
                }
            case .ellipse:
                if let r = MarkGeometry.rect(for: mark.points) {
                    p.addEllipse(in: toLocal(r).insetBy(dx: -2, dy: -2))
                }
            case .arrow:
                if let a = mark.points.first, let b = mark.points.last {
                    p.move(to: toLocal(a))
                    p.addLine(to: toLocal(b))
                }
            case .pen: break
            }
            hoverHaloLayer.path = p
            hoverLayer.path = p
        } else {
            hoverHaloLayer.path = nil
            hoverLayer.path = nil
        }

        // 2. Selected mark bounding outline + resize/endpoint handles.
        guard let selID = model.selectedMarkID,
              let mark = editableMarks.first(where: { $0.id == selID }) else {
            selectionHaloLayer.path = nil
            selectionLayer.path = nil
            handleLayers.forEach { $0.isHidden = true }
            return
        }

        let outline = CGMutablePath()
        if mark.tool == .arrow {
            if let a = mark.points.first, let b = mark.points.last {
                outline.move(to: toLocal(a))
                outline.addLine(to: toLocal(b))
            }
            selectionLayer.lineDashPattern = [4, 3]
            selectionHaloLayer.lineDashPattern = [4, 3]
        } else if let r = MarkGeometry.rect(for: mark.points) {
            let lr = toLocal(r)
            outline.addRect(lr)
            selectionLayer.lineDashPattern = nil
            selectionHaloLayer.lineDashPattern = nil
        }
        selectionHaloLayer.path = outline
        selectionLayer.path = outline

        let handles = MarkGeometry.handles(for: mark)
        var used = 0
        for (kind, globalPt) in handles {
            let lp = toLocal(globalPt)
            guard bounds.insetBy(dx: -14, dy: -14).contains(lp) else { continue }
            let layer = handleLayer(used)
            switch kind {
            case .top, .bottom:
                layer.bounds = CGRect(x: 0, y: 0, width: 12, height: 5)
                layer.cornerRadius = 2.5
            case .left, .right:
                layer.bounds = CGRect(x: 0, y: 0, width: 5, height: 12)
                layer.cornerRadius = 2.5
            case .start, .end:
                layer.bounds = CGRect(x: 0, y: 0, width: 10, height: 10)
                layer.cornerRadius = 5
            default:
                layer.bounds = CGRect(x: 0, y: 0, width: 9, height: 9)
                layer.cornerRadius = 4.5
            }
            layer.position = lp
            layer.isHidden = false
            used += 1
        }
        handleLayers.dropFirst(used).forEach { $0.isHidden = true }
    }
}
