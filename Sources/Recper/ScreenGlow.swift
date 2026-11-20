import AppKit
import SwiftUI

// MARK: Aurora: the accent while choosing a target
//
// A slowly spinning conic gradient (violet → blue → cyan → pink → amber). Used for the selected mode tile,
// the chooser bar's rim and the glow around the edges of every screen.

enum Aurora {
    static let violet = Color(red: 0.56, green: 0.38, blue: 1.0)
    static let blue = Color(red: 0.22, green: 0.56, blue: 1.0)
    static let cyan = Color(red: 0.28, green: 0.9, blue: 0.96)
    static let pink = Color(red: 1.0, green: 0.38, blue: 0.68)
    static let amber = Color(red: 1.0, green: 0.66, blue: 0.3)
    static let colors = [violet, blue, cyan, pink, amber, violet]
    static let conic = AngularGradient(colors: colors, center: .center)
}

/// Conic aurora that spins forever; sized to cover its container at any angle.
struct SpinningAurora: View {
    var period: Double = 6
    /// When false the gradient stands still and costs nothing. Hidden windows keep their SwiftUI timelines running,
    /// so callers pass false whenever their window is not on screen.
    var active = true
    var body: some View {
        GeometryReader { g in
            let d = hypot(g.size.width, g.size.height)
            TimelineView(.animation(minimumInterval: 1 / 60, paused: !active)) { ctx in
                let a = ctx.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: period) / period * 360
                Aurora.conic
                    .frame(width: d, height: d)
                    .rotationEffect(.degrees(a))
                    .position(x: g.size.width / 2, y: g.size.height / 2)
            }
        }
        .allowsHitTesting(false)
    }
}

// MARK: Screen edge glow

@MainActor
final class GlowState: ObservableObject {
    @Published var on = false
    /// Increments on every show: replays the entrance (two comets racing up the edges).
    @Published var tick = 0
}

/// Half of the screen's outline: from the bottom center, along the bottom, up one side, to the top center.
private struct HalfRim: Shape {
    var progress: CGFloat
    let mirrored: Bool
    let radius: CGFloat
    static let tail: CGFloat = 0.22

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let r = rect.insetBy(dx: 1.5, dy: 1.5)
        let c = max(radius, 1)
        func x(_ v: CGFloat) -> CGFloat { mirrored ? r.minX + r.maxX - v : v }
        var p = Path()
        p.move(to: CGPoint(x: x(r.midX), y: r.maxY))
        p.addArc(tangent1End: CGPoint(x: x(r.maxX), y: r.maxY), tangent2End: CGPoint(x: x(r.maxX), y: r.minY), radius: c)
        p.addArc(tangent1End: CGPoint(x: x(r.maxX), y: r.minY), tangent2End: CGPoint(x: x(r.midX), y: r.minY), radius: c)
        p.addLine(to: CGPoint(x: x(r.midX), y: r.minY))
        let to = min(1, progress), from = max(0, progress - Self.tail)
        return to > from ? p.trimmedPath(from: from, to: to) : Path()
    }
}

/// The glow around a screen's edges: a crisp aurora line, a soft glow and a wide bloom, all spinning slowly.
/// On entrance two bright comets leave the bottom center (where the bar is) and meet at the top.
struct EdgeGlow: View {
    @ObservedObject var state: GlowState
    let radius: CGFloat
    @State private var comet: CGFloat = 0
    @State private var flash = false

    var body: some View {
        let on = state.on
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        ZStack {
            SpinningAurora(period: 9, active: state.on)
                .mask {
                    ZStack {
                        shape.strokeBorder(lineWidth: 2.5)
                        shape.strokeBorder(lineWidth: 12).blur(radius: 9).opacity(0.85)
                        shape.strokeBorder(lineWidth: 44).blur(radius: 38).opacity(0.5)
                    }
                }
                .brightness(flash ? 0.25 : 0)
                .opacity(on ? 1 : 0)
                .scaleEffect(on ? 1 : 1.025)

            ForEach([false, true], id: \.self) { m in
                ZStack {
                    HalfRim(progress: comet, mirrored: m, radius: radius)
                        .stroke(LinearGradient(colors: [Aurora.cyan, Aurora.violet], startPoint: .bottom, endPoint: .top),
                                style: StrokeStyle(lineWidth: 18, lineCap: .round))
                        .blur(radius: 14)
                    HalfRim(progress: comet, mirrored: m, radius: radius)
                        .stroke(.white, style: StrokeStyle(lineWidth: 3.5, lineCap: .round))
                        .blur(radius: 1.2)
                }
            }
            .opacity(on && comet > 0 && comet < 1 + HalfRim.tail ? 1 : 0)
        }
        .animation(on ? .spring(response: 0.45, dampingFraction: 0.85) : .easeIn(duration: 0.2), value: on)
        .allowsHitTesting(false)
        .onAppear(perform: replay)
        .onChange(of: state.tick) { replay() }
    }

    private func replay() {
        var t = Transaction(); t.disablesAnimations = true
        withTransaction(t) { comet = 0; flash = false }
        DispatchQueue.main.async {
            withAnimation(.timingCurve(0.3, 0.0, 0.2, 1, duration: 0.85)) { comet = 1 + HalfRim.tail }
            // When the comets meet at the top, the whole rim flares up briefly.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                withAnimation(.easeOut(duration: 0.12)) { flash = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { withAnimation(.easeOut(duration: 0.6)) { flash = false } }
            }
        }
    }
}

/// One click-through panel per screen holding an `EdgeGlow`. Shown while choosing a target.
/// Our windows are excluded from screenshots, so the glow never ends up in a capture.
@MainActor
final class ScreenGlow {
    private var panels: [NSPanel] = []
    private let state = GlowState()
    private var hider: DispatchWorkItem?

    func show() {
        hider?.cancel(); hider = nil
        if panels.isEmpty { build() }
        panels.forEach { $0.orderFrontRegardless() }
        guard !state.on else { return }
        state.tick += 1
        DispatchQueue.main.async { self.state.on = true }
    }

    func hide() {
        guard state.on || !panels.isEmpty else { return }
        state.on = false
        hider?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.panels.forEach { $0.orderOut(nil) } }
        hider = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: w)
    }

    /// Screens changed: rebuild panels for the new layout.
    func rebuild() {
        panels.forEach { $0.orderOut(nil) }
        panels = []
        if state.on { build(); panels.forEach { $0.orderFrontRegardless() } }
    }

    private func build() {
        panels = NSScreen.screens.map { screen in
            let p = NSPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            p.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
            p.isOpaque = false
            p.backgroundColor = .clear
            p.hasShadow = false
            p.ignoresMouseEvents = true
            p.isReleasedWhenClosed = false
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            p.sharingType = .none
            // Built-in displays with a notch have rounded corners; external ones are square.
            let radius: CGFloat = screen.safeAreaInsets.top > 0 ? 12 : 0
            p.contentView = NSHostingView(rootView: EdgeGlow(state: state, radius: radius))
            p.setFrame(screen.frame, display: false)
            return p
        }
    }
}
