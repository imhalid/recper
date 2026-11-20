import AppKit
import SwiftUI
import RecperCore

/// The bar at the bottom of the screen: mode buttons while choosing; target + timer + Finish during a session.
@MainActor
final class BarModel: ObservableObject {
    @Published var mode: CaptureMode = .area
    @Published var target: CaptureTarget?
    @Published var startedAt: Date?
    @Published var tool: Tool?
    @Published var color: InkColor = .red
    @Published var shotCount = 0
    @Published var pendingCount = 0
    @Published var liveText = ""
    /// Short status message (error, "copied to clipboard").
    @Published var notice: String?
    /// Thumbnails of the screenshots taken (in order).
    @Published var thumbs: [Thumb] = []
    /// Color palette is open.
    @Published var paletteOpen = false
    /// Increments on every shutter press (button animation).
    @Published var shutterTick = 0
    /// Microphone level (separate object: only the waveform redraws).
    let meter = Meter()

    var onMode: ((CaptureMode) -> Void)?
    var onCancel: (() -> Void)?
    var onRetarget: (() -> Void)?
    var onFinish: (() -> Void)?
    var onTool: ((Tool?) -> Void)?
    var onColor: ((InkColor) -> Void)?
    var onSnapshot: (() -> Void)?
    var onUndo: (() -> Void)?
    var onDeleteShot: ((String) -> Void)?
    var onOpenShot: ((String) -> Void)?
    var onOpenShots: (() -> Void)?
    /// Content size changed (palette opened, caption appeared): the panel is re-centered.
    var onSize: ((CGSize) -> Void)?
}

/// Microphone level history: only the waveform observes it, so the rest of the bar doesn't redraw on every sample.
@MainActor
final class Meter: ObservableObject {
    static let count = 13
    @Published var samples = [Float](repeating: 0, count: Meter.count)
    private var smooth: Float = 0
    func push(_ xs: [Float]) {
        var s = samples
        for x in xs {
            smooth = x > smooth ? smooth * 0.35 + x * 0.65 : smooth * 0.7 + x * 0.3
            s.removeFirst(); s.append(smooth)
        }
        samples = s
    }
}

// MARK: Visual language
//
// Dark frosted glass (the desktop behind shows through blurred), monochrome; the only accents are the red record dot and the ink color.
// The selected tool is marked by a white "pill" that springs between tools.

private enum UI {
    static let h: CGFloat = 38                   // bar height
    static let b: CGFloat = 28                   // button size
    static let ink = Color.white
    static let soft = Color.white.opacity(0.62)
    static let dim = Color.white.opacity(0.4)
    static let hair = Color.white.opacity(0.1)
    static let rec = Color(red: 1, green: 0.28, blue: 0.24)
    static let spring = Animation.spring(response: 0.32, dampingFraction: 0.78)
    static func mono(_ s: CGFloat, _ w: Font.Weight = .medium) -> Font { .system(size: s, weight: w).monospacedDigit() }
}

/// Real glass that blurs what's behind the window (NSVisualEffectView).
private struct Glass: NSViewRepresentable {
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

/// Glass surface + thin highlight edge on top + slight darkening (stays legible on light backgrounds).
private struct Surface<S: InsettableShape>: View {
    let shape: S
    var body: some View {
        ZStack {
            if BarView.flatBackground { shape.fill(Color(white: 0.11)) } else { Glass().clipShape(shape) }
            shape.fill(Color.black.opacity(0.38))
            shape.strokeBorder(LinearGradient(colors: [.white.opacity(0.22), .white.opacity(0.05)], startPoint: .top, endPoint: .bottom), lineWidth: 0.75)
        }
    }
}

struct BarView: View {
    @ObservedObject var model: BarModel
    /// Previews (ImageRenderer) can't draw real glass: use a flat dark background.
    nonisolated(unsafe) static var flatBackground = false

    var body: some View {
        VStack(spacing: 8) {
            // While the palette is open, room is reserved above (the caption is hidden meanwhile).
            if model.paletteOpen { Color.clear.frame(width: 1, height: 66) }
            else if model.notice != nil || (model.target != nil && !model.liveText.isEmpty) { Caption(model: model) }
            Group {
                if let target = model.target { SessionRow(model: model, target: target) } else { ChooseRow(model: model) }
            }
            .frame(height: UI.h)
            .background(Surface(shape: Capsule()))
        }
        .padding(9)                       // room for the shadow
        .shadow(color: .black.opacity(0.28), radius: 1, y: 0.5)          // 1: contact (sharp, close)
        .shadow(color: .black.opacity(0.14), radius: 6, y: 3)            // 2: ambient (soft, light)
        .environment(\.colorScheme, .dark)
        .fixedSize()
        .onGeometryChange(for: CGSize.self) { $0.size } action: { model.onSize?($0) }
    }

    static func clock(_ s: TimeInterval) -> String {
        let n = max(0, Int(s)); return String(format: "%02d:%02d", n / 60, n % 60)
    }
}

// MARK: Choosing

private struct ChooseRow: View {
    @ObservedObject var model: BarModel
    @Namespace private var ns
    var body: some View {
        HStack(spacing: 2) {
            seg(.window, "Window", "macwindow", "1")
            seg(.area, "Area", "rectangle.dashed", "2")
            seg(.screen, "Screen", "display", "3")
            Hair()
            Text(hint).font(.system(size: 10.5)).foregroundStyle(UI.dim).fixedSize().padding(.horizontal, 6)
            Round(symbol: "xmark", help: "Cancel (Esc)") { model.onCancel?() }
        }
        .padding(.horizontal, 5)
    }

    private var hint: String {
        switch model.mode {
        case .window: "Click a window"
        case .area: "Drag · ⏎ last area"
        case .screen: "Click a screen · ⏎"
        }
    }

    private func seg(_ m: CaptureMode, _ title: String, _ symbol: String, _ key: String) -> some View {
        let on = model.mode == m
        return Button { withAnimation(UI.spring) { model.onMode?(m) } } label: {
            HStack(spacing: 6) {
                Image(systemName: symbol).font(.system(size: 11.5, weight: .medium))
                Text(title).font(.system(size: 12, weight: .semibold)).tracking(-0.2)
                Text(key).font(UI.mono(9.5, .semibold)).opacity(on ? 0.35 : 0.3)
            }
            .foregroundStyle(on ? Color.black : UI.soft)
            .padding(.horizontal, 12).frame(height: UI.b)
            .background { if on { Capsule().fill(.white).matchedGeometryEffect(id: "pill", in: ns) } }
            .contentShape(Capsule())
        }
        .buttonStyle(Press()).help("\(title) (\(key))")
    }
}

// MARK: Session

private struct SessionRow: View {
    @ObservedObject var model: BarModel
    let target: CaptureTarget
    @Namespace private var ns

    private static let tools: [(Tool?, String, String)] = [
        (nil, "cursorarrow", "Cursor: clicks go to the app (Esc · ⌥⇧V)"),
        (.pen, "pencil.tip", "Pen (P · ⌥⇧P)"),
        (.box, "rectangle", "Box (B · ⌥⇧B)"),
        (.ellipse, "circle", "Ellipse (O · ⌥⇧O)"),
        (.arrow, "arrow.up.right", "Arrow (A · ⌥⇧A)"),
        (.blur, "eye.slash", "Blur: sensitive info is permanently pixelated in screenshots (X · ⌥⇧X)"),
    ]

    var body: some View {
        HStack(spacing: 0) {
            // Recording: dot + live waveform + timer. Hover shows the target's name.
            HStack(spacing: 8) {
                Pulse()
                Wave(meter: model.meter)
                if let start = model.startedAt {
                    TimelineView(.periodic(from: start, by: 1)) { ctx in
                        Text(BarView.clock(ctx.date.timeIntervalSince(start))).font(UI.mono(11.5, .semibold)).foregroundStyle(UI.ink).fixedSize()
                    }
                }
            }
            .padding(.leading, 13).padding(.trailing, 6)
            .help("Recording · \(target.label)")

            Hair()

            // Tools: a white pill slides under the selected one.
            HStack(spacing: 1) {
                ForEach(Self.tools, id: \.1) { t, symbol, help in
                    let on = model.tool == t
                    Button { withAnimation(UI.spring) { model.onTool?(t) } } label: {
                        Image(systemName: symbol).font(.system(size: 12, weight: .medium))
                            .foregroundStyle(on ? Color.black : UI.soft)
                            .frame(width: UI.b, height: UI.b)
                            .background { if on { Capsule().fill(.white).matchedGeometryEffect(id: "tool", in: ns) } }                            .contentShape(Capsule())
                    }
                    .buttonStyle(Press()).help(help)
                }
            }
            .padding(.horizontal, 4)

            Palette(model: model).padding(.trailing, 4).zIndex(2)

            Hair()

            HStack(spacing: 2) {
                Shutter(model: model)
                Deck(model: model)
                Round(symbol: "arrow.uturn.backward", help: "Undo: drawing, blur area or last screenshot (⌘Z · ⌥⇧Z)") { model.onUndo?() }
                    .disabled(model.pendingCount == 0 && model.shotCount == 0)
                    .opacity(model.pendingCount == 0 && model.shotCount == 0 ? 0.35 : 1)
                Round(symbol: "scope", help: "Change target") { model.onRetarget?() }
            }
            .padding(.horizontal, 4)

            Finish { model.onFinish?() }.padding(.trailing, 5).padding(.leading, 2)
        }
    }
}

/// Record dot: a slowly expanding ring.
private struct Pulse: View {
    @State private var on = false
    var body: some View {
        Circle().fill(UI.rec).frame(width: 7, height: 7)
            .background(Circle().fill(UI.rec.opacity(0.5)).scaleEffect(on ? 2.6 : 1).opacity(on ? 0 : 0.9))
            .shadow(color: UI.rec.opacity(0.5), radius: 2)
            .onAppear { withAnimation(.easeOut(duration: 1.8).repeatForever(autoreverses: false)) { on = true } }
    }
}

/// Live waveform: bars symmetric around the center; new samples enter from the right, old ones fade out on the left.
private struct Wave: View {
    @ObservedObject var meter: Meter
    var body: some View {
        Canvas { ctx, size in
            let n = meter.samples.count
            let w: CGFloat = 2, gap = (size.width - CGFloat(n) * w) / CGFloat(max(n - 1, 1))
            for (i, s) in meter.samples.enumerated() {
                let h = max(2, CGFloat(s) * size.height)
                let x = CGFloat(i) * (w + gap)
                let r = CGRect(x: x, y: (size.height - h) / 2, width: w, height: h)
                let fade = 0.25 + 0.75 * Double(i) / Double(n - 1)
                ctx.fill(Path(roundedRect: r, cornerRadius: 1), with: .color(.white.opacity(fade)))
            }
        }
        .frame(width: 38, height: 16)
        .animation(.linear(duration: 0.08), value: meter.samples)
        .accessibilityHidden(true)
    }
}

/// Color: when closed, a single dot (the selected color, ringed by a thin band of all colors).
/// Click: a palette card opens above the button (3×2 color squares); it closes on pick or when the mouse leaves. Shortcuts 1–6.
private struct Palette: View {
    @ObservedObject var model: BarModel
    @State private var hover = false
    @State private var closer: DispatchWorkItem?
    private static let ring = AngularGradient(colors: (InkColor.allCases + [InkColor.allCases[0]]).map { Color(nsColor: $0.ns) }, center: .center)
    static let cell: CGFloat = 24, gap: CGFloat = 5, pad: CGFloat = 6
    static let cols = 3
    static var card: CGSize {
        let rows = (InkColor.allCases.count + cols - 1) / cols
        return CGSize(width: CGFloat(cols) * cell + CGFloat(cols - 1) * gap + pad * 2,
                      height: CGFloat(rows) * cell + CGFloat(rows - 1) * gap + pad * 2)
    }
    /// Gap between the card and the bar.
    static let lift: CGFloat = 8

    var body: some View {
        let open = model.paletteOpen
        Button { set(!open) } label: {
            ZStack {
                Circle().strokeBorder(Self.ring, lineWidth: 1.5).frame(width: 18, height: 18)
                    .rotationEffect(.degrees(open ? 180 : hover ? 120 : 0))
                Circle().fill(Color(nsColor: model.color.ns)).frame(width: 10, height: 10)
                    .overlay(Circle().strokeBorder(.white.opacity(model.color == .black ? 0.5 : 0.15), lineWidth: 0.75))
            }
            .frame(width: UI.b, height: UI.b)
            .background(Circle().fill(.white.opacity(hover || open ? 0.1 : 0)))
            .contentShape(Circle())
            .animation(.spring(response: 0.45, dampingFraction: 0.7), value: hover)
            .animation(UI.spring, value: open)
        }
        .buttonStyle(Press()).onHover { hover = $0; keepOpen($0) }
        .help("Color: \(model.color.name) (1–6)")
        .overlay(alignment: .bottom) {
            let c = Self.card
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(Self.cell), spacing: Self.gap), count: Self.cols), spacing: Self.gap) {
                ForEach(Array(InkColor.allCases.enumerated()), id: \.element) { i, color in
                    Swatch(color: color, on: model.color == color, key: i + 1) {
                        model.onColor?(color)
                        set(false)
                    }
                    .scaleEffect(open ? 1 : 0.4)
                    .opacity(open ? 1 : 0)
                    .animation(.spring(response: 0.34, dampingFraction: 0.72).delay(open ? 0.04 + Double(i) * 0.02 : 0), value: open)
                }
            }
            .padding(Self.pad)
            .frame(width: c.width, height: c.height)
            .background(Surface(shape: RoundedRectangle(cornerRadius: 12, style: .continuous)))
            .shadow(color: .black.opacity(0.28), radius: 1, y: 0.5)
            .shadow(color: .black.opacity(0.14), radius: 6, y: 3)
            // Emerges from the button: grows open from the bottom center.
            .scaleEffect(open ? 1 : 0.2, anchor: .bottom)
            .opacity(open ? 1 : 0)
            // The card's bottom sits `lift` above the bar's top edge (the button is vertically centered in the bar).
            .offset(y: -(UI.b + (UI.h - UI.b) / 2 + Self.lift))
            .animation(.spring(response: 0.32, dampingFraction: 0.8), value: open)
            .onHover { keepOpen($0) }
            .allowsHitTesting(open)
            .fixedSize()
        }
    }

    private func set(_ v: Bool) {
        closer?.cancel(); closer = nil
        model.paletteOpen = v
    }

    /// Stays open while the mouse is over the palette (button or card); closes shortly after it leaves.
    private func keepOpen(_ inside: Bool) {
        closer?.cancel(); closer = nil
        guard !inside, model.paletteOpen else { return }
        let w = DispatchWorkItem { model.paletteOpen = false }
        closer = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: w)
    }
}

/// A single palette color: rounded square; the selected one has a white inner border.
private struct Swatch: View {
    let color: InkColor, on: Bool, key: Int, action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
            shape.fill(Color(nsColor: color.ns))
                .overlay(shape.strokeBorder(.white.opacity(color == .black ? 0.28 : 0.12), lineWidth: 0.75))
                .overlay { if on { RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(color == .white || color == .yellow ? .black.opacity(0.75) : .white, lineWidth: 1.5).padding(3) } }
                .frame(width: Palette.cell, height: Palette.cell)
                .scaleEffect(hover ? 1.1 : 1)
                .contentShape(shape)
                .animation(.spring(response: 0.25, dampingFraction: 0.6), value: hover)
        }
        .buttonStyle(Press()).onHover { hover = $0 }.help("\(color.name.capitalized) (\(key))")
    }
}

/// Screenshot deck: the last three screenshots stacked in a slight fan; a new one "drops" on top.
/// Click: open all in Preview. Right-click: delete the last screenshot. With no screenshots: take one now.
private struct Deck: View {
    @ObservedObject var model: BarModel
    @State private var hover = false
    var body: some View {
        if !model.thumbs.isEmpty {
            let top = Array(model.thumbs.suffix(3))
            Button { model.onOpenShots?() } label: {
                ZStack {
                    ForEach(Array(top.enumerated()), id: \.element.id) { i, t in
                        let k = Double(top.count - 1 - i)          // 0 = topmost
                        Image(nsImage: t.image).resizable().aspectRatio(contentMode: .fill)
                            .frame(width: 30, height: 20)
                            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(.white.opacity(0.55), lineWidth: 0.75))
                            .shadow(color: .black.opacity(0.25), radius: 1, y: 0.5)
                            .rotationEffect(.degrees(k * (hover ? -11 : -6)), anchor: .bottom)
                            .offset(x: k * (hover ? -5 : -2), y: k * -1)
                            .transition(.asymmetric(insertion: .scale(scale: 1.8).combined(with: .opacity), removal: .opacity))
                    }
                    Text("\(model.shotCount)").font(UI.mono(9, .bold)).foregroundStyle(.black)
                        .padding(.horizontal, 4).frame(minWidth: 15, minHeight: 15)
                        .background(Capsule().fill(.white))
                        .offset(x: 15, y: -9)
                }
                .frame(width: 46, height: UI.b)
                .contentShape(Rectangle())
                .animation(UI.spring, value: model.thumbs.map(\.id))
                .animation(UI.spring, value: hover)
            }
            .buttonStyle(Press())
            .onHover { hover = $0 }
            .contextMenu {
                Button("Delete last screenshot") { if let id = model.thumbs.last?.id { model.onDeleteShot?(id) } }
                Button("Take screenshot now") { model.onSnapshot?() }
            }
            .help("\(model.shotCount) screenshots — click: open in Preview · right-click: delete")
        }
    }
}

/// Live text, like subtitles: the latest words are bright, earlier ones dimmed and fading out to the left.
private struct Caption: View {
    @ObservedObject var model: BarModel
    var body: some View {
        let notice = model.notice
        HStack(spacing: 8) {
            if notice != nil {
                Circle().fill(Color(red: 1, green: 0.8, blue: 0.35)).frame(width: 6, height: 6)
            } else {
                Image(systemName: "waveform").font(.system(size: 10, weight: .semibold)).foregroundStyle(UI.dim)
            }
            Group {
                if let notice {
                    Text(notice).foregroundStyle(UI.ink)
                } else {
                    let (old, fresh) = Self.split(model.liveText)
                    Text(old).foregroundStyle(UI.soft) + Text(fresh).foregroundStyle(UI.ink)
                }
            }
            .font(.system(size: 12.5, weight: .medium)).tracking(-0.15)
            .lineLimit(1).truncationMode(.head)
            .frame(maxWidth: 380, alignment: notice != nil ? .leading : .trailing)
            .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: notice != nil ? 0 : 0.14)],
                                 startPoint: .leading, endPoint: .trailing))
        }
        .padding(.horizontal, 14).frame(height: 30)
        .background(Surface(shape: Capsule()))
        .fixedSize()
    }

    /// The last 4 words are "fresh".
    static func split(_ s: String) -> (String, String) {
        let words = s.split(separator: " ", omittingEmptySubsequences: false)
        guard words.count > 4 else { return ("", s) }
        return (words.dropLast(4).joined(separator: " ") + " ", words.suffix(4).joined(separator: " "))
    }
}

private struct Hair: View {
    var body: some View { Rectangle().fill(UI.hair).frame(width: 1, height: 16).padding(.horizontal, 3) }
}

/// Shrinks slightly when pressed.
private struct Press: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.9 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

private struct Round: View {
    let symbol: String, help: String, action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 12, weight: .medium))
                .foregroundStyle(hover ? UI.ink : UI.soft)
                .frame(width: UI.b, height: UI.b)
                .background(Circle().fill(.white.opacity(hover ? 0.1 : 0)))
                .contentShape(Circle())
                .animation(.easeOut(duration: 0.12), value: hover)
        }
        .buttonStyle(Press()).onHover { hover = $0 }.help(help)
    }
}

private struct Finish: View {
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Text("Finish").font(.system(size: 12, weight: .semibold)).tracking(-0.2)
            }
            .foregroundStyle(.black)
            .padding(.horizontal, 13).frame(height: UI.b)
            .background(Capsule().fill(.white))
            .overlay(Capsule().fill(.white.opacity(hover ? 0.0 : 0)))
            .shadow(color: .white.opacity(hover ? 0.25 : 0), radius: 4)
            .contentShape(Capsule())
            .animation(.easeOut(duration: 0.15), value: hover)
        }
        .buttonStyle(Press()).onHover { hover = $0 }.help("Finish and copy the prompt to the clipboard (⌥⇧R)")
    }
}

/// Accepts the first click (even when the panel is inactive).
final class FirstMouseHostingView<V: View>: NSHostingView<V> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

final class BarPanel: NSPanel {
    init(model: BarModel) {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false        // SwiftUI draws the shadow (capsule-shaped)
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        sharingType = .none
        becomesKeyOnlyIfNeeded = true
        let host = FirstMouseHostingView(rootView: BarView(model: model))
        host.sizingOptions = [.intrinsicContentSize]   // measure the size, but we position the window ourselves (keeps it centered)
        contentView = host
    }

    /// Sizes to its content and sits at the bottom center of the screen (14 pt shadow margin + 14 pt gap).
    func place(on screen: NSScreen) {
        self.screen0 = screen
        shrink?.cancel(); shrink = nil
        guard let v = contentView else { return }
        set(v.fittingSize)
    }

    private var screen0: NSScreen?
    private var shrink: DispatchWorkItem?

    /// On content size change: grow immediately (so animations aren't clipped), shrink once the animation ends.
    func refit(_ size: CGSize) {
        guard isVisible, screen0 != nil else { return }
        shrink?.cancel(); shrink = nil
        if size.width >= frame.width - 0.5, size.height >= frame.height - 0.5 { set(size); return }
        if size.width > frame.width || size.height > frame.height {
            set(CGSize(width: max(size.width, frame.width), height: max(size.height, frame.height)))
        }
        let w = DispatchWorkItem { [weak self] in self?.set(size) }
        shrink = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: w)
    }

    private func set(_ size: CGSize) {
        guard let vf = screen0?.visibleFrame else { return }
        setFrame(CGRect(x: (vf.midX - size.width / 2).rounded(), y: vf.minY + 19, width: size.width, height: size.height), display: true)
    }
}

struct Thumb: Identifiable, Equatable {
    let id: String
    let image: NSImage
    static func == (a: Thumb, b: Thumb) -> Bool { a.id == b.id }
}


/// Shutter: white ring + inner disc; on press the disc closes and reopens (like a camera).
/// Space · T · ⏎ while drawing, ⌥⇧S anywhere.
private struct Shutter: View {
    @ObservedObject var model: BarModel
    @State private var hover = false
    @State private var snap = false
    var body: some View {
        Button { model.onSnapshot?() } label: {
            ZStack {
                Circle().strokeBorder(.white.opacity(hover ? 1 : 0.85), lineWidth: 1.75).frame(width: 22, height: 22)
                Circle().fill(.white).frame(width: 15, height: 15)
                    .scaleEffect(snap ? 0.45 : (hover ? 1.06 : 1))
                    .opacity(snap ? 0.6 : 1)
            }
            .frame(width: UI.b, height: UI.b)
            .contentShape(Circle())
            .animation(.spring(response: 0.25, dampingFraction: 0.6), value: hover)
        }
        .buttonStyle(Press()).onHover { hover = $0 }
        .help("Take screenshot — Space · T · ⏎ while drawing, ⌥⇧S anywhere")
        .onChange(of: model.shutterTick) {
            withAnimation(.easeIn(duration: 0.08)) { snap = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.55)) { snap = false }
            }
        }
    }
}
