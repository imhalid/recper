import AppKit
import Carbon.HIToolbox
import SwiftUI

// MARK: Radial menu
//
// ⌥⇧S during a session, from any app, opens a luminous dark-glass dial around the pointer (press again to close).
// Point at an action and click to run it; the center is the optical shutter (screenshot).
// Clicking outside the dial, Esc, or ⌥⇧S again closes it without doing anything.
// The pointer position is polled (NSEvent.mouseLocation) for the live highlight, so no extra permission is needed;
// clicks inside the dial are caught by the panel and never reach the app underneath.

@MainActor
final class RadialModel: ObservableObject {
    struct Pointer: Equatable {
        /// Offset from the ring center in SwiftUI coordinates (y down).
        var offset: CGPoint = .zero
        /// Distance from the ring center in points.
        var distance: CGFloat = 0
        /// Continuous unwrapped angle in degrees (0 = top, clockwise).
        var angle: Double = 0
        /// True once the pointer has moved outside the dead zone during this gesture.
        var hasAngle = false
    }

    /// `RadialMenu.center`, `RadialMenu.cancelled`, or an item index.
    @Published var selected = RadialMenu.center
    @Published var shown = false
    /// True while the panel is on screen (including close/confirm animations); gates live TimelineView motion.
    @Published var visible = false
    /// Increments on every open to replay the entrance shockwave.
    @Published var openTick = 0
    /// Set briefly on release from a visible menu (`center` or item index) to play the confirmation burst.
    @Published var confirming: Int? = nil
    /// Live pointer telemetry in SwiftUI coordinates (y down).
    @Published var pointer = Pointer()
    /// Continuous unwrapped angle for the gliding active sector wedge.
    @Published var selectorAngle: Double = 0
    /// True when moving directly from one sector to another (glide smoothly); false when emerging from center/cancel.
    @Published var glideSelector = false
}

@MainActor
final class RadialMenu {
    struct Item {
        let symbol: String
        let title: String
        let action: () -> Void
    }

    static let center = -1
    static let cancelled = -2
    static let size: CGFloat = 360
    static let inner: CGFloat = 44
    static let outer: CGFloat = 118
    static let deadZone: CGFloat = 24
    static let cancelDistance: CGFloat = 190

    /// Clockwise from the top.
    var items: [Item] = []
    var onShutter: (() -> Void)?

    private let model = RadialModel()
    private var panel: NSPanel?
    private var openAt: Date?
    private var outsideClicks: Any?
    private var escKey: UInt32?
    private var origin: CGPoint = .zero
    private var timer: Timer?
    private var menuShown = false
    private var hideTask: Task<Void, Never>?

    var isActive: Bool { openAt != nil }

    /// ⌥⇧S: opens the dial at the pointer, or closes it if it is already open.
    func toggle() {
        if openAt != nil { close(); return }
        hideTask?.cancel(); hideTask = nil
        openAt = Date()
        origin = NSEvent.mouseLocation
        menuShown = false
        model.confirming = nil
        model.selected = Self.center
        model.pointer = RadialModel.Pointer()
        model.glideSelector = false
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        show()
        // A click anywhere else (it still reaches that app) or Esc closes the dial.
        outsideClicks = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }
        escKey = HotKeys.shared.register(kVK_Escape, 0) { [weak self] in self?.close() }
    }

    /// A click inside the dial: runs what is under the pointer.
    fileprivate func clicked() {
        guard openAt != nil else { return }
        tick()
        let sel = model.selected
        let pan = stereoPan(for: sel)
        end(confirming: sel)
        if sel >= 0, sel < items.count {
            Sfx.radialConfirm(sel, pan: pan)
            items[sel].action()
        } else if sel == Self.center {
            onShutter?()
        } else {
            Sfx.cancel()
        }
    }

    /// Closes without doing anything.
    func close() {
        guard openAt != nil else { return }
        end(confirming: nil)
        Sfx.cancel()
    }

    /// Session ended while the dial was open.
    func cancel() { if openAt != nil { end(confirming: nil) } }

    private func end(confirming: Int?) {
        timer?.invalidate(); timer = nil
        openAt = nil
        if let m = outsideClicks { NSEvent.removeMonitor(m); outsideClicks = nil }
        if let k = escKey { HotKeys.shared.unregister([k]); escKey = nil }
        if menuShown { hide(confirming: confirming) }
        menuShown = false
    }

    private func tick() {
        guard openAt != nil else { return }
        let p = NSEvent.mouseLocation
        let dx = p.x - origin.x, dy = p.y - origin.y
        let d = hypot(dx, dy)
        let sel: Int
        var rawDeg = model.pointer.angle
        if d < Self.deadZone || items.isEmpty {
            sel = Self.center
        } else if d > Self.cancelDistance {
            sel = Self.cancelled
            rawDeg = atan2(-dy, dx) * 180 / .pi + 90
        } else {
            // Screen angle (y down), 0° = top, clockwise.
            rawDeg = atan2(-dy, dx) * 180 / .pi + 90
            let step = 360 / Double(items.count)
            sel = (Int((rawDeg / step).rounded()) % items.count + items.count) % items.count
        }

        // Update continuous unwrapped pointer state only when it moved meaningfully.
        let offset = CGPoint(x: dx, y: -dy)
        let moved = hypot(offset.x - model.pointer.offset.x, offset.y - model.pointer.offset.y) > 0.25
        if moved || sel != model.selected {
            let hasAngle = d >= Self.deadZone && !items.isEmpty
            let nextAngle: Double
            if hasAngle {
                nextAngle = model.pointer.hasAngle
                    ? Self.unwrapAngle(from: model.pointer.angle, to: rawDeg)
                    : Self.normalizeAngle(rawDeg)
            } else {
                nextAngle = model.pointer.angle
            }
            model.pointer = RadialModel.Pointer(offset: offset, distance: d, angle: nextAngle, hasAngle: hasAngle)
        }

        if sel != model.selected {
            let prev = model.selected
            if sel >= 0, !items.isEmpty {
                let target = Double(sel) * (360 / Double(items.count))
                let fromSector = prev >= 0 && prev < items.count
                model.glideSelector = fromSector && menuShown
                model.selectorAngle = fromSector
                    ? Self.unwrapAngle(from: model.selectorAngle, to: target)
                    : target
            }
            model.selected = sel
            if menuShown { Sfx.radialTick(sel, pan: stereoPan(for: sel)) }
        }

    }

    private func show() {
        hideTask?.cancel(); hideTask = nil
        menuShown = true
        let p = panel ?? makePanel()
        panel = p
        let s = Self.size
        p.setFrame(CGRect(x: origin.x - s / 2, y: origin.y - s / 2, width: s, height: s), display: false)
        p.orderFrontRegardless()
        model.confirming = nil
        model.shown = false
        model.visible = true
        if model.selected >= 0, !items.isEmpty {
            model.glideSelector = false
            model.selectorAngle = Double(model.selected) * (360 / Double(items.count))
        }
        model.openTick += 1
        Sfx.radialOpen()
        DispatchQueue.main.async { [weak self] in
            guard let self, self.menuShown else { return }
            self.model.shown = true
        }
    }

    private func hide(confirming: Int?) {
        hideTask?.cancel()
        let isConfirm = confirming != nil && confirming != Self.cancelled
        model.confirming = isConfirm ? confirming : nil
        model.shown = false
        let delayMs = isConfirm ? 250 : 170
        let p = panel
        hideTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(delayMs))
            guard !Task.isCancelled, let self, !self.menuShown else { return }
            self.model.visible = false
            self.model.confirming = nil
            p?.orderOut(nil)
        }
    }

    private func makePanel() -> NSPanel {
        let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 2)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.ignoresMouseEvents = false          // clicks inside the dial choose; it never becomes key or activates the app
        p.isReleasedWhenClosed = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        p.sharingType = .none
        let host = NSHostingView(rootView: RadialView(model: model, items: items.map { ($0.symbol, $0.title) }))
        let catcher = ClickCatcher { [weak self] in self?.clicked() }
        let root = NSView()
        host.autoresizingMask = [.width, .height]
        catcher.autoresizingMask = [.width, .height]
        root.addSubview(host)
        root.addSubview(catcher)
        p.contentView = root
        return p
    }

    private func stereoPan(for sel: Int) -> Double {
        guard sel >= 0, !items.isEmpty else {
            return model.pointer.hasAngle ? sin(model.pointer.angle * .pi / 180) * 0.35 : 0
        }
        let rad = Double(sel) * (2 * .pi / Double(items.count))
        return sin(rad) * 0.45
    }

    private static func normalizeAngle(_ deg: Double) -> Double {
        let m = deg.truncatingRemainder(dividingBy: 360)
        return m < 0 ? m + 360 : m
    }

    /// Advances `current` by the shortest signed angular delta (-180...180) to reach `target` (mod 360).
    private static func unwrapAngle(from current: Double, to target: Double) -> Double {
        var delta = (target - current).truncatingRemainder(dividingBy: 360)
        if delta > 180 { delta -= 360 }
        if delta < -180 { delta += 360 }
        return current + delta
    }
}

/// Transparent view over the dial that takes every click (even when recper is not the active app).
private final class ClickCatcher: NSView {
    let action: () -> Void
    init(_ action: @escaping () -> Void) { self.action = action; super.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError() }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { action() }
    override func rightMouseDown(with event: NSEvent) { action() }
}

// MARK: Visual primitives

@MainActor
private enum Dial {
    static let go = Color(red: 0.55, green: 1.0, blue: 0.5)
    static let goBright = Color(red: 0.88, green: 1.0, blue: 0.87)
    static let cancel = Color(red: 1.0, green: 0.36, blue: 0.34)
    static let sectorInner: CGFloat = RadialMenu.inner + 5.5     // 49.5
    static let sectorOuter: CGFloat = RadialMenu.outer - 6.0     // 112.0
    static let glyphRadius: CGFloat = 78.5                       // optically balanced inside 49.5...112
    static let hubDiameter: CGFloat = RadialMenu.inner * 2 - 2   // 86.0
}

/// Real dark frosted glass behind the radial window (same material language as BarView).
private struct RadialGlass: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .hudWindow
        v.blendingMode = .behindWindow
        v.state = .active
        v.appearance = NSAppearance(named: .darkAqua)
        return v
    }
    func updateNSView(_ v: NSVisualEffectView, context: Context) {}
}

/// True tangent-continuous rounded annular sector with uniform parallel gap channels.
private struct RoundedWedge: Shape {
    var angle: Double
    let span: Double
    let inner: CGFloat
    let outer: CGFloat
    var gap: CGFloat = 4.6
    var outerCorner: CGFloat = 13
    var innerCorner: CGFloat = 7
    var radialShift: CGFloat = 0

    var animatableData: AnimatablePair<Double, CGFloat> {
        get { AnimatablePair(angle, radialShift) }
        set { angle = newValue.first; radialShift = newValue.second }
    }

    func path(in rect: CGRect) -> Path {
        let base = (angle - 90) * .pi / 180
        let c = CGPoint(
            x: rect.midX + radialShift * CGFloat(cos(base)),
            y: rect.midY + radialShift * CGFloat(sin(base))
        )
        let halfSpan = (span / 2) * .pi / 180
        let g = gap / 2

        let maxC = max(0.5, (outer - inner) * 0.42)
        let cOut = min(outerCorner, maxC)
        let cIn = min(innerCorner, maxC)

        let rOutCenter = max(1, outer - cOut)
        let rInCenter = max(1, inner + cIn)

        let dOut = min(halfSpan * 0.92, asin(min(0.95, Double((g + cOut) / rOutCenter))))
        let dIn = min(halfSpan * 0.92, asin(min(0.95, Double((g + cIn) / rInCenter))))

        let aStart = base - halfSpan
        let aEnd = base + halfSpan
        let o1Angle = aStart + dOut
        let o2Angle = aEnd - dOut
        let i2Angle = aEnd - dIn
        let i1Angle = aStart + dIn

        func pt(_ r: CGFloat, _ rad: Double) -> CGPoint {
            CGPoint(x: c.x + r * CGFloat(cos(rad)), y: c.y + r * CGFloat(sin(rad)))
        }

        let o1 = pt(rOutCenter, o1Angle)
        let o2 = pt(rOutCenter, o2Angle)
        let i2 = pt(rInCenter, i2Angle)
        let i1 = pt(rInCenter, i1Angle)

        var p = Path()
        p.addArc(center: o1, radius: cOut, startAngle: .radians(aStart - .pi / 2), endAngle: .radians(o1Angle), clockwise: false)
        p.addArc(center: c, radius: outer, startAngle: .radians(o1Angle), endAngle: .radians(o2Angle), clockwise: false)
        p.addArc(center: o2, radius: cOut, startAngle: .radians(o2Angle), endAngle: .radians(aEnd + .pi / 2), clockwise: false)
        p.addArc(center: i2, radius: cIn, startAngle: .radians(aEnd + .pi / 2), endAngle: .radians(i2Angle + .pi), clockwise: false)
        p.addArc(center: c, radius: inner, startAngle: .radians(i2Angle), endAngle: .radians(i1Angle), clockwise: true)
        p.addArc(center: i1, radius: cIn, startAngle: .radians(i1Angle - .pi), endAngle: .radians(aStart - .pi / 2), clockwise: false)
        p.closeSubpath()
        return p
    }
}

/// Circular arc segment centered on `angle` (degrees, 0 = top, clockwise). Animates smoothly along the orbit.
private struct ArcStroke: Shape {
    var angle: Double
    var span: Double
    var radius: CGFloat
    var radialShift: CGFloat = 0

    var animatableData: AnimatablePair<Double, AnimatablePair<Double, CGFloat>> {
        get { AnimatablePair(angle, AnimatablePair(span, radialShift)) }
        set { angle = newValue.first; span = newValue.second.first; radialShift = newValue.second.second }
    }

    func path(in rect: CGRect) -> Path {
        let base = (angle - 90) * .pi / 180
        let c = CGPoint(
            x: rect.midX + radialShift * CGFloat(cos(base)),
            y: rect.midY + radialShift * CGFloat(sin(base))
        )
        let a0 = Angle.degrees(angle - 90 - span / 2)
        let a1 = Angle.degrees(angle - 90 + span / 2)
        var p = Path()
        p.addArc(center: c, radius: radius, startAngle: a0, endAngle: a1, clockwise: false)
        return p
    }
}

/// Six curved optical camera aperture blades inside the center shutter lens.
private struct ApertureBlades: Shape {
    var opening: CGFloat
    let bezelRadius: CGFloat

    var animatableData: CGFloat {
        get { opening }
        set { opening = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let c = CGPoint(x: rect.midX, y: rect.midY)
        let rIn = bezelRadius * (0.34 + 0.28 * opening)
        let twist = Double(1 - opening) * 0.45
        var p = Path()
        for i in 0..<6 {
            let a = Double(i) * (.pi / 3) - .pi / 2 + twist
            let p0 = CGPoint(x: c.x + rIn * CGFloat(cos(a)), y: c.y + rIn * CGFloat(sin(a)))
            let p1 = CGPoint(x: c.x + bezelRadius * CGFloat(cos(a + 0.88)), y: c.y + bezelRadius * CGFloat(sin(a + 0.88)))
            let ctrl = CGPoint(x: c.x + (rIn + bezelRadius) * 0.47 * CGFloat(cos(a + 0.44)),
                               y: c.y + (rIn + bezelRadius) * 0.47 * CGFloat(sin(a + 0.44)))
            p.move(to: p0)
            p.addQuadCurve(to: p1, control: ctrl)
        }
        return p
    }
}

/// Small directional chevron mounted on the center hub rim, pointing toward the live cursor heading.
private struct CompassChevron: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.midX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        p.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.maxY), control: CGPoint(x: rect.midX, y: rect.maxY - 1.6))
        p.closeSubpath()
        return p
    }
}

/// Aurora gradient layer: spins only while the radial menu is live on screen (zero CPU when hidden or in static previews).
private struct RadialAurora: View {
    let live: Bool
    var period: Double = 7
    var body: some View {
        if live {
            SpinningAurora(period: period)
        } else {
            Aurora.conic.rotationEffect(.degrees(-42))
        }
    }
}

// MARK: View

struct RadialView: View {
    @ObservedObject var model: RadialModel
    let items: [(String, String)]

    @State private var shockwave: CGFloat = BarView.flatBackground ? 1 : 0
    @State private var confirmWave: CGFloat = 0

    var body: some View {
        let rendered = model.shown || model.visible || model.confirming != nil
        Group {
            if rendered {
                dialContent
            } else {
                Color.clear
            }
        }
        .frame(width: RadialMenu.size, height: RadialMenu.size)
        .environment(\.colorScheme, .dark)
        .onChange(of: model.openTick) { replayOpen() }
        .onChange(of: model.confirming) { _, next in
            if next != nil { replayConfirm() }
        }
    }

    // MARK: Main dial

    private var dialContent: some View {
        let n = max(items.count, 1)
        let step = 360 / Double(n)
        let shown = model.shown
        let confirming = model.confirming
        let isConfirming = confirming != nil
        let isCancelled = !isConfirming && model.selected == RadialMenu.cancelled
        let isCenter = confirming == RadialMenu.center || (!isConfirming && model.selected == RadialMenu.center)
        let activeIndex: Int? = {
            if let c = confirming { return (c >= 0 && c < items.count) ? c : nil }
            return (model.selected >= 0 && model.selected < items.count) ? model.selected : nil
        }()

        // When rendered statically (e.g. Preview.swift setting only `shown` + `selected`), synthesize a natural pointer vector.
        let syntheticAngle = activeIndex.map { Double($0) * step } ?? 0
        let hasLiveHeading = model.pointer.hasAngle || activeIndex != nil
        let liveAngle = model.pointer.hasAngle ? model.pointer.angle : syntheticAngle
        let liveDistance: CGFloat = model.pointer.hasAngle ? model.pointer.distance : (activeIndex != nil ? Dial.glyphRadius : 0)
        let selectorAngle = model.pointer.hasAngle ? model.selectorAngle : syntheticAngle

        // Subtle 3D gyroscopic tilt toward the pointer (disabled in static previews for razor-sharp PNG typography).
        let liveSpin = model.visible && !BarView.flatBackground
        let tiltVec: CGPoint = {
            guard liveSpin, shown, !isCancelled, model.pointer.distance > 6 else { return .zero }
            let scale = min(1, model.pointer.distance / RadialMenu.outer)
            let rad = (liveAngle - 90) * .pi / 180
            return CGPoint(x: CGFloat(cos(rad)) * scale, y: CGFloat(sin(rad)) * scale)
        }()
        let tiltDeg = Double(hypot(tiltVec.x, tiltVec.y)) * 4.5
        let tiltAxis: (x: CGFloat, y: CGFloat, z: CGFloat) = tiltDeg > 0.01
            ? (-tiltVec.y, tiltVec.x, 0)
            : (1, 0, 0)

        // Elastic pull tension as pointer moves past the outer rim toward cancelDistance.
        let pullProgress: CGFloat = {
            guard liveDistance > RadialMenu.outer else { return 0 }
            let span = max(1, RadialMenu.cancelDistance - RadialMenu.outer)
            return min(1, (liveDistance - RadialMenu.outer) / span)
        }()

        // Entrance / exit / cancel transforms for the dial body.
        let bodyScale: CGFloat = {
            if isConfirming { return 0.90 }
            if !shown { return 0.58 }
            if isCancelled { return 0.92 }
            return 1.0
        }()
        let bodyOpacity: Double = {
            if isConfirming { return 0.0 }
            if !shown { return 0.0 }
            if isCancelled { return 0.72 }
            return 1.0
        }()

        let confirmedItem = confirming.flatMap { ($0 >= 0 && $0 < items.count) ? $0 : nil }
        let wedgeVisible = (activeIndex != nil && shown) || confirmedItem != nil

        return ZStack {
            // 1. Entrance Aurora shockwave pulse (radiates out from cursor on open).
            if shockwave > 0.001 && shockwave < 0.999 {
                let waveSize = RadialMenu.outer * 2 * (0.42 + 0.88 * shockwave)
                ZStack {
                    RadialAurora(live: liveSpin, period: 5)
                        .mask(Circle().strokeBorder(lineWidth: max(1, 5 * (1 - shockwave))).blur(radius: 3))
                    Circle().strokeBorder(Dial.goBright.opacity(0.6), lineWidth: max(0.5, 1.8 * (1 - shockwave)))
                }
                .frame(width: waveSize, height: waveSize)
                .opacity(Double(1 - shockwave) * 0.9)
            }

            // 2. Dial chassis + sectors + active selector + shutter hub (with subtle 3D tilt).
            ZStack {
                // 2a. Outer ambient Aurora halo + directional emerald spotlight bloom.
                outerHalo(liveSpin: liveSpin, activeIndex: activeIndex, selectorAngle: selectorAngle,
                          step: step, isCenter: isCenter, isCancelled: isCancelled)
                    .opacity(bodyOpacity)

                // 2b. Dark frosted glass disc + vernier bezel + pointer light sweep.
                glassChassis(hasLiveHeading: hasLiveHeading, liveAngle: liveAngle,
                             isCancelled: isCancelled, activeIndex: activeIndex, step: step)
                    .opacity(bodyOpacity)

                // 2c. Recessed glass pockets for all 6 sectors.
                ForEach(0..<items.count, id: \.self) { i in
                    let sectorAngle = Double(i) * step
                    let wedge = RoundedWedge(angle: sectorAngle, span: step, inner: Dial.sectorInner, outer: Dial.sectorOuter)
                    ZStack {
                        wedge.fill(LinearGradient(colors: [.white.opacity(0.058), .white.opacity(0.016)],
                                                  startPoint: .top, endPoint: .bottom))
                        wedge.stroke(LinearGradient(colors: [.white.opacity(0.11), .white.opacity(0.03)],
                                                    startPoint: .top, endPoint: .bottom), lineWidth: 0.75)
                    }
                    .opacity(bodyOpacity)
                }

                // 2d. Gliding machined Graphite + Emerald LED active wedge (always mounted for smooth Center ↔ Sector bloom).
                activeWedge(angle: selectorAngle, span: step, isConfirmed: confirmedItem != nil)
                    .scaleEffect(wedgeVisible ? (confirmedItem != nil ? 1 + confirmWave * 0.04 : 1) : 0.92)
                    .opacity(confirmedItem != nil ? Double(max(0, 1 - confirmWave * 1.15)) : (wedgeVisible ? 1 : 0))
                    .animation(.spring(response: 0.18, dampingFraction: 0.76), value: wedgeVisible)
                    .animation(model.glideSelector ? .spring(response: 0.20, dampingFraction: 0.74) : nil, value: selectorAngle)

                // 2e. Outer prismatic Aurora rim + live pointer specular crystal flare.
                outerRim(liveSpin: liveSpin, hasLiveHeading: hasLiveHeading, liveAngle: liveAngle,
                         isCenter: isCenter, isCancelled: isCancelled, pullProgress: pullProgress)
                    .opacity(bodyOpacity)

                // 2f. 6 Icon + Label glyphs with radial stagger, balanced spacing, and subtle magnetic lean.
                ForEach(0..<items.count, id: \.self) { i in
                    let on = activeIndex == i
                    let isConfirmedItem = confirmedItem == i
                    itemGlyph(index: i, step: step, on: on, shown: shown, isCancelled: isCancelled,
                              isConfirmingOther: isConfirming && !isConfirmedItem,
                              isConfirmedItem: isConfirmedItem,
                              liveAngle: liveAngle, hasLiveHeading: hasLiveHeading)
                }

                // 2g. Recessed center moat + orbiting compass chevron.
                centerMoat(hasLiveHeading: hasLiveHeading && !isCenter, liveAngle: liveAngle, isCancelled: isCancelled)
                    .opacity(bodyOpacity)

                // 2h. Center optical shutter hub (camera lens + aperture blades + cancel morph).
                centerHub(isCenter: isCenter, isCancelled: isCancelled,
                          isConfirmingShutter: confirming == RadialMenu.center,
                          isConfirmingOther: isConfirming && confirming != RadialMenu.center)
                    .opacity(confirming == RadialMenu.center ? Double(max(0, 1 - confirmWave * 1.1)) : bodyOpacity)

                // 2i. Confirmation flash wave (arc shockwave for item confirm, iris ring for shutter confirm).
                if let c = confirming, confirmWave > 0.001 {
                    confirmBurst(for: c, angle: selectorAngle, span: step)
                }

                // 2j. Elastic cancel tension tether (emerges smoothly only when pointer pulls past the outer rim).
                if shown, hasLiveHeading, !isCenter, liveDistance > RadialMenu.outer + 1 {
                    elasticTether(angle: liveAngle, distance: liveDistance,
                                  isCancelled: isCancelled, pullProgress: pullProgress)
                }
            }
            .scaleEffect(bodyScale)
            .rotationEffect(.degrees(shown || isConfirming ? 0 : -11))
            .rotation3DEffect(.degrees(tiltDeg), axis: tiltAxis, perspective: 0.48)
            .animation(shown ? .spring(response: 0.22, dampingFraction: 0.74) : .easeIn(duration: 0.14), value: shown)
            .animation(.spring(response: 0.22, dampingFraction: 0.74), value: isCancelled)
            .animation(.easeOut(duration: 0.15), value: isConfirming)

            // 3. Floating dark-glass status pill beneath the ring.
            statusPill(activeIndex: activeIndex, isCenter: isCenter, isCancelled: isCancelled)
                .offset(y: RadialMenu.outer + 30)
                .scaleEffect(shown && !isConfirming ? 1 : 0.84)
                .opacity(shown && !isConfirming ? 1 : 0)
                .animation(.spring(response: 0.22, dampingFraction: 0.78), value: model.selected)
                .animation(shown ? .spring(response: 0.24, dampingFraction: 0.76).delay(0.03) : .easeIn(duration: 0.1), value: shown)
                .animation(.easeOut(duration: 0.12), value: isConfirming)
        }
    }

    // MARK: Dial layers

    @ViewBuilder
    private func outerHalo(liveSpin: Bool, activeIndex: Int?, selectorAngle: Double,
                           step: Double, isCenter: Bool, isCancelled: Bool) -> some View {
        let d = RadialMenu.outer * 2
        ZStack {
            // Soft spinning Aurora atmosphere around the whole dial (matches BarView's Aurora bloom).
            RadialAurora(live: liveSpin, period: 8)
                .mask {
                    Circle().strokeBorder(lineWidth: 13).frame(width: d, height: d).blur(radius: 16)
                }
                .opacity(isCancelled ? 0.12 : 0.68)

            // Directional emerald bloom pooled behind the selected wedge (always mounted for smooth cross-fade).
            ArcStroke(angle: selectorAngle, span: step * 1.08, radius: RadialMenu.outer - 1)
                .stroke(Dial.go, style: StrokeStyle(lineWidth: 15, lineCap: .round))
                .blur(radius: 17)
                .opacity(activeIndex != nil ? 0.44 : 0)
                .animation(.easeOut(duration: 0.16), value: activeIndex != nil)
                .animation(model.glideSelector ? .spring(response: 0.20, dampingFraction: 0.74) : nil, value: selectorAngle)

            if isCenter {
                Circle()
                    .strokeBorder(Dial.go.opacity(0.32), lineWidth: 10)
                    .frame(width: d, height: d)
                    .blur(radius: 16)
            } else if isCancelled {
                Circle()
                    .strokeBorder(Dial.cancel.opacity(0.38), lineWidth: 10)
                    .frame(width: d, height: d)
                    .blur(radius: 16)
            }
        }
        .allowsHitTesting(false)
    }

    private func glassChassis(hasLiveHeading: Bool, liveAngle: Double,
                              isCancelled: Bool, activeIndex: Int?, step: Double) -> some View {
        let d = RadialMenu.outer * 2
        return ZStack {
            // Base frosted glass or rich obsidian fallback for static ImageRenderer previews.
            if BarView.flatBackground {
                Circle().fill(
                    RadialGradient(
                        colors: [Color(red: 0.10, green: 0.11, blue: 0.135), Color(red: 0.052, green: 0.056, blue: 0.072)],
                        center: .center, startRadius: 16, endRadius: RadialMenu.outer
                    )
                )
            } else {
                RadialGlass().clipShape(Circle())
            }

            // Deep darkening veil for bulletproof legibility on white or noisy backgrounds.
            Circle().fill(
                RadialGradient(
                    colors: [Color.black.opacity(BarView.flatBackground ? 0.14 : 0.44),
                             Color.black.opacity(BarView.flatBackground ? 0.34 : 0.68)],
                    center: .center, startRadius: 18, endRadius: RadialMenu.outer
                )
            )

            // Subtle top-lit crystal dome sheen.
            Circle().fill(
                LinearGradient(colors: [.white.opacity(0.085), .clear, .black.opacity(0.18)],
                               startPoint: .top, endPoint: .bottom)
            )

            // Live directional emerald-white light sweep across the glass toward the pointer.
            if hasLiveHeading, !isCancelled, activeIndex != nil {
                let rad = (liveAngle - 90) * .pi / 180
                let spot = UnitPoint(x: 0.5 + 0.38 * cos(rad), y: 0.5 + 0.38 * sin(rad))
                Circle().fill(
                    RadialGradient(colors: [Dial.go.opacity(0.14), Dial.go.opacity(0.04), .clear],
                                   center: spot, startRadius: 4, endRadius: RadialMenu.outer * 0.92)
                )
            }

            // Precision vernier micro-ticks nestled in the 4pt outer optical bezel groove.
            Canvas { ctx, size in
                let center = CGPoint(x: size.width / 2, y: size.height / 2)
                let tickCount = 60
                let dividerOffset = step / 2
                for i in 0..<tickCount {
                    let deg = Double(i) * (360.0 / Double(tickCount))
                    let rad = (deg - 90) * .pi / 180
                    let rel = abs(((deg - dividerOffset).truncatingRemainder(dividingBy: step) + step).truncatingRemainder(dividingBy: step))
                    let isBoundary = min(rel, step - rel) < 1.5
                    let len: CGFloat = isBoundary ? 3.8 : 2.0
                    let r1 = RadialMenu.outer - 2.1
                    let r0 = r1 - len

                    var alpha: Double = isBoundary ? 0.24 : 0.09
                    var tint: Color = .white
                    if hasLiveHeading {
                        var diff = abs((deg - liveAngle).truncatingRemainder(dividingBy: 360))
                        if diff > 180 { diff = 360 - diff }
                        if diff < 34 {
                            let boost = pow(1 - diff / 34, 2)
                            alpha += boost * 0.56
                            tint = isCancelled ? Dial.cancel : Dial.go
                        }
                    }

                    var path = Path()
                    path.move(to: CGPoint(x: center.x + r0 * CGFloat(cos(rad)), y: center.y + r0 * CGFloat(sin(rad))))
                    path.addLine(to: CGPoint(x: center.x + r1 * CGFloat(cos(rad)), y: center.y + r1 * CGFloat(sin(rad))))
                    ctx.stroke(path, with: .color(tint.opacity(alpha)), style: StrokeStyle(lineWidth: isBoundary ? 1.0 : 0.7, lineCap: .round))
                }
            }
        }
        .frame(width: d, height: d)
        .clipShape(Circle())
        // Dual elevation shadow: crisp contact shadow + soft ambient grounding on white backgrounds.
        .shadow(color: .black.opacity(0.45), radius: 2, y: 1)
        .shadow(color: .black.opacity(0.36), radius: 20, y: 9)
    }

    private func activeWedge(angle: Double, span: Double, isConfirmed: Bool) -> some View {
        // Strictly concentric while hovering (exact uniform 4pt vernier channel & parallel sector seams);
        // launches outward along its radial vector on release confirmation.
        let confirmShift: CGFloat = isConfirmed ? confirmWave * 13 : 0
        let wedgeOuter = Dial.sectorOuter + 1.8      // 113.8 — cleanly inside the 118pt bezel
        let wedgeInner = Dial.sectorInner - 0.8      // 48.7
        let wedge = RoundedWedge(
            angle: angle,
            span: span,
            inner: wedgeInner,
            outer: wedgeOuter,
            gap: 4.3,
            outerCorner: 13.5,
            innerCorner: 7,
            radialShift: confirmShift
        )
        let rad = (angle - 90) * .pi / 180
        let ledOrigin = UnitPoint(x: 0.5 + 0.34 * cos(rad), y: 0.5 + 0.34 * sin(rad))
        let outerGlowStart = UnitPoint(x: 0.5 + 0.42 * cos(rad), y: 0.5 + 0.42 * sin(rad))
        let outerGlowEnd = UnitPoint(x: 0.5 - 0.15 * cos(rad), y: 0.5 - 0.15 * sin(rad))

        return ZStack {
            // Machined graphite pill body (matching BarView's GraphitePill material).
            wedge
                .fill(LinearGradient(colors: [Color(white: 0.30), Color(white: 0.145)],
                                     startPoint: .top, endPoint: .bottom))
                .shadow(color: .black.opacity(0.55), radius: 6, y: 2)
                .shadow(color: Dial.go.opacity(isConfirmed ? 0.55 : 0.24), radius: 13)

            // Soft emerald light scatter bleeding inward from the curved green LED bar.
            wedge
                .fill(RadialGradient(
                    colors: [Dial.go.opacity(isConfirmed ? 0.44 : 0.22), Dial.go.opacity(0.05), .clear],
                    center: ledOrigin, startRadius: 4, endRadius: 76
                ))

            // Machined metallic specular bevel (top bright → bottom faint, like GraphitePill).
            wedge.stroke(
                LinearGradient(colors: [.white.opacity(0.36), .white.opacity(0.08)],
                               startPoint: .top, endPoint: .bottom),
                lineWidth: 1.0
            )

            // Directional emerald rim reflection: vivid along the outer LED edge, fading gently inward.
            wedge.stroke(
                LinearGradient(colors: [Dial.go.opacity(isConfirmed ? 1.0 : 0.78), Dial.go.opacity(0.18)],
                               startPoint: outerGlowStart, endPoint: outerGlowEnd),
                lineWidth: isConfirmed ? 1.6 : 1.15
            )
            .shadow(color: Dial.go.opacity(0.45), radius: 5)

            // Signature Recper curved glowing green LED bar nestled neatly along the outer arc.
            let ledRadius = wedgeOuter - 4.2   // 109.6 — crisp 13pt clearance from the glyph
            let ledArc = ArcStroke(angle: angle, span: isConfirmed ? 30 : 18.5, radius: ledRadius, radialShift: confirmShift)
            ledArc
                .stroke(Dial.go, style: StrokeStyle(lineWidth: 3.1, lineCap: .round))
                .shadow(color: Dial.go, radius: 4)
                .shadow(color: Dial.go.opacity(0.75), radius: 11)
            ledArc
                .stroke(Dial.goBright, style: StrokeStyle(lineWidth: 1.2, lineCap: .round))
        }
    }

    private func outerRim(liveSpin: Bool, hasLiveHeading: Bool, liveAngle: Double,
                          isCenter: Bool, isCancelled: Bool, pullProgress: CGFloat) -> some View {
        let d = RadialMenu.outer * 2
        return ZStack {
            // Crisp outer prismatic Aurora rim (Recper signature).
            if isCancelled {
                Circle().strokeBorder(Dial.cancel.opacity(0.74), lineWidth: 1.4).frame(width: d, height: d)
            } else {
                RadialAurora(live: liveSpin, period: 7)
                    .mask(Circle().strokeBorder(lineWidth: 1.45).frame(width: d, height: d))
                    .opacity(0.90)
            }

            // Physical glass top specular bevel.
            Circle()
                .strokeBorder(
                    LinearGradient(colors: [.white.opacity(0.32), .white.opacity(0.03), .white.opacity(0.10)],
                                   startPoint: .top, endPoint: .bottom),
                    lineWidth: 0.9
                )
                .frame(width: d - 1.5, height: d - 1.5)

            // Live incandescent rim flare riding flush along the beveled crystal edge at the exact pointer angle.
            if hasLiveHeading, !isCenter {
                let flareColor = isCancelled ? Dial.cancel : (pullProgress > 0.55 ? Aurora.amber : Dial.go)
                let flareSpan = isCancelled ? 44.0 : 52.0
                let flare = ArcStroke(angle: liveAngle, span: flareSpan, radius: RadialMenu.outer - 0.75)
                flare
                    .stroke(flareColor.opacity(0.8), style: StrokeStyle(lineWidth: 5.5, lineCap: .round))
                    .blur(radius: 4.5)
                flare
                    .stroke(
                        AngularGradient(
                            colors: [.clear, flareColor, .white.opacity(0.95), flareColor, .clear],
                            center: .center,
                            startAngle: .degrees(liveAngle - 90 - flareSpan / 2),
                            endAngle: .degrees(liveAngle - 90 + flareSpan / 2)
                        ),
                        style: StrokeStyle(lineWidth: 2.2, lineCap: .round)
                    )
            }
        }
        .allowsHitTesting(false)
    }

    private func itemGlyph(index i: Int, step: Double, on: Bool, shown: Bool, isCancelled: Bool,
                           isConfirmingOther: Bool, isConfirmedItem: Bool,
                           liveAngle: Double, hasLiveHeading: Bool) -> some View {
        let a = Double(i) * step
        let rad = (a - 90) * .pi / 180

        // Subtle magnetic pull toward the actual live pointer heading when this sector is active.
        let magOffset: CGSize = {
            guard on, hasLiveHeading, !isConfirmedItem else { return .zero }
            let liveRad = (liveAngle - 90) * .pi / 180
            return CGSize(width: cos(liveRad) * 1.4, height: sin(liveRad) * 1.4)
        }()

        // Radial radius: blooms outward from inner moat on entrance, lifts subtly on selection, pops out on confirm.
        let radius: CGFloat = {
            if isConfirmedItem { return Dial.glyphRadius + 2.0 + confirmWave * 13 }
            if !shown { return Dial.sectorInner + 5 }
            return Dial.glyphRadius + (on ? 1.0 : 0)
        }()

        let itemOpacity: Double = {
            if isConfirmedItem { return Double(max(0, 1 - confirmWave * 1.15)) }
            if isConfirmingOther { return 0 }
            if !shown { return 0 }
            if isCancelled { return 0.45 }
            return 1
        }()

        let itemScale: CGFloat = {
            if isConfirmedItem { return 1.10 + confirmWave * 0.14 }
            if !shown { return 0.42 }
            return on ? 1.08 : 1.0
        }()

        return VStack(spacing: 3.5) {
            Image(systemName: items[i].0)
                .font(.system(size: 18, weight: on ? .semibold : .medium))
                .foregroundStyle(on ? Dial.go : .white.opacity(0.86))
                .shadow(color: Dial.go.opacity(on ? 0.72 : 0), radius: 6)
                .symbolEffect(.bounce.up.byLayer, value: on)
                .frame(height: 20)
            Text(items[i].1)
                .font(.system(size: 10.5, weight: on ? .semibold : .medium))
                .tracking(-0.15)
                .foregroundStyle(on ? .white : .white.opacity(0.58))
                .shadow(color: .black.opacity(0.55), radius: 2, y: 1)
        }
        .scaleEffect(itemScale)
        .opacity(itemOpacity)
        .offset(x: radius * CGFloat(cos(rad)) + magOffset.width,
                y: radius * CGFloat(sin(rad)) + magOffset.height)
        .animation(shown ? .spring(response: 0.24, dampingFraction: 0.72).delay(Double(i) * 0.014) : .easeIn(duration: 0.11), value: shown)
        .animation(.spring(response: 0.20, dampingFraction: 0.64), value: on)
    }

    private func centerMoat(hasLiveHeading: Bool, liveAngle: Double, isCancelled: Bool) -> some View {
        ZStack {
            // Deep machined circular moat separating the sector ring from the central optical lens.
            Circle()
                .strokeBorder(Color.black.opacity(0.64), lineWidth: 5.5)
                .frame(width: Dial.sectorInner * 2 + 0.5, height: Dial.sectorInner * 2 + 0.5)

            // Precision compass chevron orbiting the hub rim, pointing straight at the pointer.
            if hasLiveHeading {
                let accent = isCancelled ? Dial.cancel : Dial.go
                CompassChevron()
                    .fill(accent)
                    .frame(width: 7.5, height: 5.2)
                    .shadow(color: accent.opacity(0.85), radius: 4)
                    .offset(y: -(RadialMenu.inner + 2.8))
                    .rotationEffect(.degrees(liveAngle))
                    .transition(.scale(scale: 0.3).combined(with: .opacity))
            }
        }
        .allowsHitTesting(false)
    }

    private func centerHub(isCenter: Bool, isCancelled: Bool,
                           isConfirmingShutter: Bool, isConfirmingOther: Bool) -> some View {
        let d = Dial.hubDiameter
        let bladeOpening: CGFloat = isConfirmingShutter ? 0.16 : (isCenter ? 1.0 : 0.72)

        return ZStack {
            // Optical lens housing.
            Circle()
                .fill(
                    RadialGradient(
                        colors: isCenter
                            ? [Color(white: 0.24), Color(white: 0.095)]
                            : [Color(white: 0.13), Color(white: 0.065)],
                        center: .top, startRadius: 4, endRadius: d * 0.65
                    )
                )
                .shadow(color: .black.opacity(0.6), radius: 6, y: 2)
                .shadow(color: isCenter ? Dial.go.opacity(0.45) : (isCancelled ? Dial.cancel.opacity(0.32) : .clear), radius: 13)

            // Inner emerald/cancel lens glow when active.
            if isCenter || isCancelled {
                Circle()
                    .fill(RadialGradient(
                        colors: [(isCancelled ? Dial.cancel : Dial.go).opacity(0.18), .clear],
                        center: .center, startRadius: 6, endRadius: d * 0.52
                    ))
            }

            // 6-blade optical aperture iris.
            ApertureBlades(opening: bladeOpening, bezelRadius: d / 2 - 2)
                .stroke(
                    isCenter ? Dial.go.opacity(0.24) : (isCancelled ? Dial.cancel.opacity(0.18) : .white.opacity(0.085)),
                    lineWidth: 0.85
                )
                .clipShape(Circle())
                .animation(.spring(response: 0.24, dampingFraction: 0.72), value: bladeOpening)

            // Machined inner lens ring.
            Circle()
                .strokeBorder(.white.opacity(isCenter ? 0.12 : 0.06), lineWidth: 0.75)
                .padding(5.5)

            // Hub perimeter bezel stroke (specular metallic top, fading gracefully toward the bottom LED).
            Circle()
                .strokeBorder(
                    LinearGradient(
                        colors: isCenter
                            ? [.white.opacity(0.36), Dial.go.opacity(0.48)]
                            : isCancelled
                                ? [Dial.cancel.opacity(0.85), Dial.cancel.opacity(0.42)]
                                : [.white.opacity(0.20), .white.opacity(0.05)],
                        startPoint: .top, endPoint: .bottom
                    ),
                    lineWidth: isCenter || isCancelled ? 1.3 : 0.9
                )

            // Cleanly inset curved green LED glint at the bottom of the shutter hub when Center is active.
            if isCenter {
                let led = ArcStroke(angle: 180, span: 28, radius: d / 2 - 5.5)
                led
                    .stroke(Dial.go, style: StrokeStyle(lineWidth: 2.6, lineCap: .round))
                    .shadow(color: Dial.go, radius: 4)
                    .shadow(color: Dial.go.opacity(0.75), radius: 9)
                led
                    .stroke(Dial.goBright, style: StrokeStyle(lineWidth: 1.0, lineCap: .round))
            }

            // Center glyph: camera shutter (normal/center) or crisp coral cancel mark (cancelled).
            if isCancelled {
                Image(systemName: "xmark")
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(Dial.cancel)
                    .shadow(color: Dial.cancel.opacity(0.65), radius: 6)
                    .transition(.scale(scale: 0.5).combined(with: .opacity))
            } else {
                ZStack {
                    Circle()
                        .strokeBorder(.white.opacity(isCenter ? 0.96 : 0.55), lineWidth: 2.0)
                        .frame(width: 31, height: 31)
                    Circle()
                        .fill(isCenter ? .white : .white.opacity(0.68))
                        .frame(width: 21, height: 21)
                        .scaleEffect(isConfirmingShutter ? 0.42 : (isCenter ? 1.03 : 0.84))
                        .shadow(color: .white.opacity(isCenter ? 0.45 : 0), radius: 6)
                }
                .scaleEffect(isConfirmingOther ? 0.8 : 1)
                .transition(.scale(scale: 0.6).combined(with: .opacity))
            }
        }
        .frame(width: d, height: d)
        .animation(.spring(response: 0.22, dampingFraction: 0.68), value: isCenter)
        .animation(.spring(response: 0.22, dampingFraction: 0.68), value: isCancelled)
    }

    @ViewBuilder
    private func confirmBurst(for sel: Int, angle: Double, span: Double) -> some View {
        let fade = Double(max(0, 1 - confirmWave))
        if sel == RadialMenu.center {
            // Optical shutter flash ring expanding outward from center.
            let r = 18 + confirmWave * 78
            Circle()
                .strokeBorder(Dial.goBright, lineWidth: max(0.8, 3.5 * (1 - confirmWave)))
                .frame(width: r * 2, height: r * 2)
                .shadow(color: Dial.go, radius: 8)
                .opacity(fade)
        } else if sel >= 0 {
            // Directional emerald energy arc launching outward from the confirmed sector.
            ArcStroke(angle: angle, span: span * (0.72 + 0.35 * confirmWave),
                      radius: RadialMenu.outer + confirmWave * 28)
                .stroke(Dial.goBright, style: StrokeStyle(lineWidth: max(0.8, 3.2 * (1 - confirmWave)), lineCap: .round))
                .shadow(color: Dial.go, radius: 9)
                .opacity(fade)
        }
    }

    /// Elastic tension tether and luminous bead that detach from the rim only when pulling outward toward cancel.
    private func elasticTether(angle: Double, distance: CGFloat, isCancelled: Bool, pullProgress: CGFloat) -> some View {
        let rad = (angle - 90) * .pi / 180
        let ux = CGFloat(cos(rad)), uy = CGFloat(sin(rad))
        let rimR = RadialMenu.outer + 0.5
        let extra = min(30, (distance - RadialMenu.outer) * 0.38)
        let pipR = rimR + extra
        let accent = isCancelled ? Dial.cancel : (pullProgress > 0.55 ? Aurora.amber : Dial.go)

        return ZStack {
            Path { p in
                p.move(to: CGPoint(x: RadialMenu.size / 2 + rimR * ux, y: RadialMenu.size / 2 + rimR * uy))
                p.addLine(to: CGPoint(x: RadialMenu.size / 2 + pipR * ux, y: RadialMenu.size / 2 + pipR * uy))
            }
            .stroke(
                LinearGradient(colors: [accent.opacity(0.28), accent.opacity(0.88)],
                               startPoint: .center, endPoint: UnitPoint(x: 0.5 + 0.5 * ux, y: 0.5 + 0.5 * uy)),
                style: StrokeStyle(lineWidth: 1.4, lineCap: .round, dash: isCancelled ? [3, 3] : [])
            )

            Circle()
                .fill(accent)
                .frame(width: isCancelled ? 6.5 : 5.5, height: isCancelled ? 6.5 : 5.5)
                .overlay(Circle().strokeBorder(.white.opacity(0.7), lineWidth: 0.8))
                .shadow(color: accent, radius: 5)
                .shadow(color: accent.opacity(0.65), radius: 10)
                .offset(x: pipR * ux, y: pipR * uy)
        }
        .allowsHitTesting(false)
    }

    private func statusPill(activeIndex: Int?, isCenter: Bool, isCancelled: Bool) -> some View {
        let (title, cue) = statusText(activeIndex: activeIndex, isCenter: isCenter, isCancelled: isCancelled)
        let accent = isCancelled ? Dial.cancel : Dial.go
        let shape = Capsule()

        return HStack(spacing: 6) {
            if isCancelled {
                Image(systemName: "xmark")
                    .font(.system(size: 8.5, weight: .bold))
                    .foregroundStyle(Dial.cancel)
            } else if isCenter {
                Circle()
                    .strokeBorder(Dial.go, lineWidth: 1.4)
                    .background(Circle().fill(.white).padding(2.4))
                    .frame(width: 9, height: 9)
                    .shadow(color: Dial.go.opacity(0.8), radius: 4)
            } else {
                Circle()
                    .fill(Dial.go)
                    .frame(width: 6, height: 6)
                    .shadow(color: Dial.go, radius: 4)
            }

            Text(title)
                .font(.system(size: 11.5, weight: .semibold))
                .tracking(-0.15)
                .foregroundStyle(.white.opacity(0.96))

            if !cue.isEmpty {
                Text("·")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white.opacity(0.28))
                Text(cue)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.54))
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 26)
        .background {
            ZStack {
                if BarView.flatBackground {
                    shape.fill(Color(red: 0.08, green: 0.09, blue: 0.11).opacity(0.94))
                } else {
                    RadialGlass().clipShape(shape)
                    shape.fill(Color.black.opacity(0.45))
                }
                shape.strokeBorder(
                    LinearGradient(colors: [.white.opacity(0.22), accent.opacity(0.32)],
                                   startPoint: .top, endPoint: .bottom),
                    lineWidth: 0.85
                )
            }
        }
        .shadow(color: .black.opacity(0.35), radius: 1.5, y: 0.5)
        .shadow(color: .black.opacity(0.28), radius: 10, y: 4)
        .fixedSize()
    }

    // MARK: Choreography & copy helpers

    private func replayOpen() {
        guard !BarView.flatBackground else { shockwave = 1; return }
        var t = Transaction(); t.disablesAnimations = true
        withTransaction(t) { shockwave = 0; confirmWave = 0 }
        DispatchQueue.main.async {
            withAnimation(.timingCurve(0.16, 1.0, 0.3, 1.0, duration: 0.34)) { shockwave = 1 }
        }
    }

    private func replayConfirm() {
        guard !BarView.flatBackground else { return }
        var t = Transaction(); t.disablesAnimations = true
        withTransaction(t) { confirmWave = 0 }
        DispatchQueue.main.async {
            withAnimation(.timingCurve(0.16, 1.0, 0.3, 1.0, duration: 0.24)) { confirmWave = 1 }
        }
    }

    private func statusText(activeIndex: Int?, isCenter: Bool, isCancelled: Bool) -> (String, String) {
        if isCancelled { return ("Close", "click") }
        if isCenter { return ("Screenshot", "click") }
        guard let i = activeIndex, i < items.count else { return ("", "") }
        let title = items[i].1
        let cue: String = switch title.lowercased() {
        case "cursor": "clicks go to the app"
        case "pen": "freehand"
        case "box": "frame"
        case "arrow": "point"
        case "finish": "save & copy"
        case "undo": "step back"
        case "blur": "redact"
        default: "click"
        }
        return (title, cue)
    }
}
