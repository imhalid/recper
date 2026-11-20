import AppKit
import SwiftUI
import RecperCore

/// After Finish, before sending: fix sentences, inspect/remove screenshots & items. ⌘⏎ sends, Esc saves without copying.
@MainActor
final class ReviewModel: ObservableObject {
    struct Item: Identifiable {
        let id: String                // sentence id, or "shot-<id>" (screenshot without speech)
        var text: String
        var shots: [Shot]
        let t: Double
        let isSegment: Bool
    }

    @Published var items: [Item]
    @Published var lightboxShotID: String? = nil
    let images: [String: NSImage]     // shot id → thumbnail
    let shotURLs: [String: URL]       // shot id → full PNG on disk
    private var fullImageCache: [String: NSImage] = [:]
    private let doc: SessionDoc
    private var finished = false
    var onDone: ((SessionDoc?, _ copy: Bool) -> Void)?
    var onLightboxChange: ((String?) -> Void)?
    var onHeightChange: ((CGFloat) -> Void)?

    static let enabledKey = "reviewBeforeSend"
    static var enabled: Bool {
        get { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    init(doc: SessionDoc, images: [String: NSImage], shotURLs: [String: URL] = [:]) {
        self.doc = doc
        self.images = images
        self.shotURLs = shotURLs
        var list: [Item] = doc.segments.map { seg in
            Item(id: seg.id, text: seg.text, shots: doc.shots.filter { $0.segment == seg.id }, t: seg.t0, isSegment: true)
        }
        list += doc.shots.filter { $0.segment == nil }.map {
            Item(id: "shot-\($0.id)", text: "", shots: [$0], t: $0.t, isSegment: false)
        }
        items = list.sorted { $0.t < $1.t }
    }

    var allShots: [Shot] { items.flatMap(\.shots) }
    var totalShotCount: Int { items.reduce(0) { $0 + $1.shots.count } }

    func shot(for id: String) -> Shot? { allShots.first { $0.id == id } }

    func fullImage(for shotID: String) -> NSImage? {
        if let cached = fullImageCache[shotID] { return cached }
        if let url = shotURLs[shotID], let img = NSImage(contentsOf: url) {
            fullImageCache[shotID] = img
            return img
        }
        return images[shotID]
    }

    func openLightbox(_ shotID: String) {
        lightboxShotID = shotID
        onLightboxChange?(shotID)
    }

    func closeLightbox() {
        guard lightboxShotID != nil else { return }
        lightboxShotID = nil
        onLightboxChange?(nil)
    }

    func stepLightbox(_ delta: Int) {
        let shots = allShots
        guard let cur = lightboxShotID, let i = shots.firstIndex(where: { $0.id == cur }), shots.count > 1 else { return }
        let next = shots[(i + delta + shots.count) % shots.count].id
        lightboxShotID = next
        onLightboxChange?(next)
    }

    func openInPreview(_ shotID: String) {
        if let url = shotURLs[shotID] { NSWorkspace.shared.open(url) }
    }

    func removeShot(_ shotID: String) {
        let before = allShots.map(\.id)
        let idx = before.firstIndex(of: shotID)
        for i in items.indices { items[i].shots.removeAll { $0.id == shotID } }
        items.removeAll { !$0.isSegment && $0.shots.isEmpty }
        fullImageCache[shotID] = nil
        if lightboxShotID == shotID {
            let remaining = allShots
            if remaining.isEmpty {
                closeLightbox()
            } else {
                let nextIdx = min(idx ?? 0, remaining.count - 1)
                let nextID = remaining[nextIdx].id
                lightboxShotID = nextID
                onLightboxChange?(nextID)
            }
        }
    }

    func removeItem(_ id: String) {
        let removedShots = Set(items.first(where: { $0.id == id })?.shots.map(\.id) ?? [])
        items.removeAll { $0.id == id }
        if let cur = lightboxShotID, removedShots.contains(cur) {
            if let next = allShots.first?.id {
                lightboxShotID = next
                onLightboxChange?(next)
            } else {
                closeLightbox()
            }
        }
    }

    func finish(copy: Bool) {
        guard !finished else { return }
        finished = true
        closeLightbox()
        onDone?(result(), copy)
    }

    /// The edited document: removed sentences/screenshots are dropped, texts are updated.
    func result() -> SessionDoc {
        var d = doc
        let texts = Dictionary(uniqueKeysWithValues: items.filter(\.isSegment).map { ($0.id, $0.text) })
        d.segments = doc.segments.compactMap { seg in
            guard let t = texts[seg.id] else { return nil }
            var s = seg
            s.text = t.trimmingCharacters(in: .whitespacesAndNewlines)
            return s.text.isEmpty && !items.contains(where: { $0.id == seg.id && !$0.shots.isEmpty }) ? nil : s
        }
        let kept = Set(items.flatMap { $0.shots.map(\.id) })
        d.shots = doc.shots.filter { kept.contains($0.id) }.map { s in
            var s = s
            if let seg = s.segment, !d.segments.contains(where: { $0.id == seg }) { s.segment = nil }
            return s
        }
        return d
    }
}

// MARK: Calm Flat Design Tokens (matching Settings)

private enum RUI {
    static let width: CGFloat = 640
    static let maxListHeight: CGFloat = 440
    static let bg = Color(red: 0.11, green: 0.115, blue: 0.125)
    static let cardFill = Color.white.opacity(0.038)
    static let cardBorder = Color.white.opacity(0.085)
    static let hair = Color.white.opacity(0.08)
    static let fieldFill = Color.black.opacity(0.24)
    static let soft = Color.white.opacity(0.70)
    static let dim = Color.white.opacity(0.45)
    static let coral = Color(red: 0.95, green: 0.42, blue: 0.40)
    static let go = Color(red: 0.55, green: 1.0, blue: 0.5)
}

// MARK: Review View

struct ReviewView: View {
    @ObservedObject var model: ReviewModel
    @FocusState private var focus: String?

    private var list: some View {
        VStack(spacing: 8) {
            ForEach(Array(model.items.enumerated()), id: \.element.id) { i, item in
                ReviewRow(model: model, index: i, item: item, focus: $focus)
            }
            if model.items.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "tray")
                        .font(.system(size: 18, weight: .regular))
                        .foregroundStyle(RUI.dim)
                    Text("Nothing left to send.")
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(RUI.dim)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 36)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    var body: some View {
        let shell = RoundedRectangle(cornerRadius: 14, style: .continuous)
        VStack(alignment: .leading, spacing: 0) {
            // Header (draggable by background via ReviewHeaderDragArea)
            HStack(alignment: .center, spacing: 10) {
                HStack(spacing: 8) {
                    Circle().fill(RUI.go).frame(width: 7, height: 7)
                    Text("Review Feedback")
                        .font(.system(size: 15, weight: .semibold))
                        .tracking(-0.2)
                        .foregroundStyle(.white)
                }
                Text("\(model.items.count) \(model.items.count == 1 ? "item" : "items") · \(model.totalShotCount) \(model.totalShotCount == 1 ? "screenshot" : "screenshots")")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(RUI.dim)
                    .padding(.horizontal, 8).padding(.vertical, 2.5)
                    .background(Capsule().fill(.white.opacity(0.06)))
                Spacer(minLength: 8)
                Text("Edit text or click screenshots to inspect")
                    .font(.system(size: 11))
                    .foregroundStyle(RUI.dim)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            .background {
                if !BarView.flatBackground { ReviewHeaderDragArea() }
            }

            Rectangle().fill(RUI.hair).frame(height: 1)

            // Scrollable item list (direct layout in flatBackground preview mode for ImageRenderer)
            Group {
                if BarView.flatBackground {
                    list
                } else {
                    ScrollView {
                        list
                    }
                    .scrollIndicators(.automatic)
                    .frame(maxHeight: RUI.maxListHeight)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }

            Rectangle().fill(RUI.hair).frame(height: 1)

            // Footer action buttons
            HStack(spacing: 10) {
                ReviewSecondaryButton(title: "Save without copying", hint: "Esc") {
                    model.finish(copy: false)
                }
                .help("Save session files to disk without copying prompt (Esc)")

                Spacer()

                ReviewPrimaryButton(title: "Send", hint: "⌘⏎") {
                    model.finish(copy: true)
                }
                .help("Save session and copy the agent prompt to the clipboard (⌘⏎)")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .frame(width: RUI.width)
        .background(shell.fill(RUI.bg))
        .overlay(shell.strokeBorder(Color.white.opacity(0.11), lineWidth: 1))
        .clipShape(shell)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { h in
            model.onHeightChange?(h)
        }
        .environment(\.colorScheme, .dark)
    }
}

private struct ReviewRow: View {
    @ObservedObject var model: ReviewModel
    let index: Int
    let item: ReviewModel.Item
    var focus: FocusState<String?>.Binding
    @State private var hover = false
    @State private var hoverDelete = false

    private var isFocused: Bool { focus.wrappedValue == item.id }

    private var textBinding: Binding<String> {
        let id = item.id
        return Binding(
            get: { model.items.first(where: { $0.id == id })?.text ?? item.text },
            set: { newValue in
                if let i = model.items.firstIndex(where: { $0.id == id }) {
                    model.items[i].text = newValue
                }
            }
        )
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        HStack(alignment: .top, spacing: 11) {
            // Index + timestamp column
            VStack(alignment: .trailing, spacing: 3) {
                Text("\(index + 1)")
                    .font(.system(size: 11.5, weight: .semibold).monospacedDigit())
                    .foregroundStyle(isFocused ? .white : RUI.soft)
                Text(Writer.clock(item.t))
                    .font(.system(size: 10, weight: .regular, design: .monospaced))
                    .foregroundStyle(RUI.dim)
            }
            .frame(width: 34, alignment: .trailing)
            .padding(.top, 6)

            // Content column: editable text + screenshots
            VStack(alignment: .leading, spacing: 9) {
                if item.isSegment {
                    Group {
                        if BarView.flatBackground {
                            // ImageRenderer can't draw AppKit-backed TextField; show identically styled text in previews.
                            Text(item.text.isEmpty ? "Feedback note…" : item.text)
                                .font(.system(size: 13))
                                .foregroundStyle(item.text.isEmpty ? RUI.dim : .white)
                                .fixedSize(horizontal: false, vertical: true)
                        } else {
                            TextField("Feedback note…", text: textBinding, axis: .vertical)
                                .textFieldStyle(.plain)
                                .font(.system(size: 13))
                                .foregroundStyle(.white)
                                .lineLimit(1...8)
                                .focused(focus, equals: item.id)
                        }
                    }
                    .padding(.horizontal, 9)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(isFocused ? Color.black.opacity(0.36) : RUI.fieldFill)
                            .overlay(
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .strokeBorder(isFocused ? Color.white.opacity(0.28) : Color.white.opacity(0.08), lineWidth: 1)
                            )
                    )
                    .contentShape(Rectangle())
                } else {
                    Text("(no speech)")
                        .font(.system(size: 12.5))
                        .italic()
                        .foregroundStyle(RUI.dim)
                        .padding(.vertical, 5)
                }

                if !item.shots.isEmpty {
                    let strip = HStack(spacing: 8) {
                        ForEach(item.shots, id: \.id) { s in
                            ReviewShotThumb(model: model, shot: s)
                        }
                    }
                    if BarView.flatBackground || item.shots.count <= 4 {
                        strip
                    } else {
                        ScrollView(.horizontal, showsIndicators: false) { strip }
                    }
                }
            }

            // Always-accessible delete item button
            Button {
                let id = item.id
                withAnimation(.easeOut(duration: 0.14)) { model.removeItem(id) }
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(hoverDelete ? RUI.coral : .white.opacity(hover ? 0.72 : 0.42))
                    .frame(width: 28, height: 28)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(hoverDelete ? RUI.coral.opacity(0.14) : Color.white.opacity(hover ? 0.08 : 0.04))
                    )
                    .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            }
            .buttonStyle(.plain)
            .onHover { hoverDelete = $0 }
            .help("Delete this item and its screenshots")
            .padding(.top, 2)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            shape.fill(isFocused ? Color.white.opacity(0.055) : RUI.cardFill)
                .overlay(shape.strokeBorder(isFocused ? Color.white.opacity(0.16) : RUI.cardBorder, lineWidth: 1))
        )
        .onHover { hover = $0 }
    }
}

private struct ReviewShotThumb: View {
    @ObservedObject var model: ReviewModel
    let shot: Shot
    @State private var hover = false
    @State private var hoverRemove = false

    private var markNumbers: String? {
        let nums = shot.marks.compactMap(\.n)
        guard !nums.isEmpty else { return nil }
        let unique = Array(Set(nums)).sorted()
        return unique.map { "#\($0)" }.joined(separator: " ")
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        ZStack(alignment: .topTrailing) {
            // Main thumbnail click area → opens large lightbox
            Button {
                model.openLightbox(shot.id)
            } label: {
                ZStack {
                    if let img = model.images[shot.id] {
                        Image(nsImage: img)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    } else {
                        Color.white.opacity(0.08)
                    }

                    // Subtle hover zoom affordance
                    if hover {
                        Color.black.opacity(0.28)
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(6)
                            .background(Circle().fill(Color.black.opacity(0.65)))
                    }
                }
                .frame(width: 118, height: 72)
                .clipShape(shape)
                .overlay(alignment: .bottomLeading) {
                    if let badges = markNumbers {
                        Text(badges)
                            .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 5.5).padding(.vertical, 2)
                            .background(Capsule().fill(Color.black.opacity(0.72)))
                            .padding(5)
                    }
                }
                .overlay(shape.strokeBorder(Color.white.opacity(hover ? 0.45 : 0.14), lineWidth: 1))
                .contentShape(shape)
            }
            .buttonStyle(.plain)

            // Remove button tucked cleanly inside the top-right corner (never flickers outside bounds)
            Button {
                withAnimation(.easeOut(duration: 0.14)) { model.removeShot(shot.id) }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 8.5, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 18, height: 18)
                    .background(
                        Circle()
                            .fill(hoverRemove ? RUI.coral : Color.black.opacity(0.75))
                            .overlay(Circle().strokeBorder(.white.opacity(0.25), lineWidth: 0.75))
                    )
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .opacity(hover || hoverRemove ? 1.0 : 0.75)
            .padding(4)
            .onHover { hoverRemove = $0 }
            .help("Remove this screenshot")
        }
        .onHover { hover = $0 }
        .help(shot.marks.isEmpty ? "Click to inspect screenshot" : shot.marks.map(\.summary).joined(separator: "\n") + "\nClick to inspect")
    }
}

private struct ReviewSecondaryButton: View {
    let title: String
    let hint: String
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        Button(action: action) {
            HStack(spacing: 7) {
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(hover ? 0.96 : 0.78))
                Text(hint)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.45))
                    .padding(.horizontal, 5).padding(.vertical, 1.5)
                    .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(.white.opacity(0.08)))
            }
            .padding(.horizontal, 12)
            .frame(height: 31)
            .background(
                shape.fill(.white.opacity(hover ? 0.12 : 0.07))
                    .overlay(shape.strokeBorder(.white.opacity(hover ? 0.20 : 0.12), lineWidth: 1))
            )
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

private struct ReviewPrimaryButton: View {
    let title: String
    let hint: String
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        Button(action: action) {
            HStack(spacing: 7) {
                Text(title)
                    .font(.system(size: 12.5, weight: .semibold))
                Text(hint)
                    .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                    .opacity(0.55)
            }
            .foregroundStyle(Color(white: 0.08))
            .padding(.horizontal, 16)
            .frame(height: 31)
            .background(shape.fill(Color.white.opacity(hover ? 1.0 : 0.92)))
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

/// Allows dragging the Review window by its header bar without interfering with text fields or controls.
private struct ReviewHeaderDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> DragNSView { DragNSView() }
    func updateNSView(_ nsView: DragNSView, context: Context) {}

    final class DragNSView: NSView {
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func mouseDown(with event: NSEvent) {
            window?.performDrag(with: event)
        }
    }
}

// MARK: Large Screenshot Lightbox

private struct ShotLightboxView: View {
    @ObservedObject var model: ReviewModel
    let shotID: String
    @State private var hoverPrev = false
    @State private var hoverNext = false

    var body: some View {
        let shots = model.allShots
        let currentIdx = shots.firstIndex(where: { $0.id == shotID }) ?? 0
        let shot = shots.first(where: { $0.id == shotID })
        let img = model.fullImage(for: shotID)
        let shell = RoundedRectangle(cornerRadius: 12, style: .continuous)

        VStack(spacing: 0) {
            // Top toolbar
            HStack(spacing: 10) {
                Text("Screenshot \(currentIdx + 1) of \(max(shots.count, 1))")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                if let shot, shot.size.count == 2 {
                    Text("\(shot.size[0])×\(shot.size[1])")
                        .font(.system(size: 11, weight: .regular, design: .monospaced))
                        .foregroundStyle(RUI.dim)
                }
                Spacer()

                if shots.count > 1 {
                    HStack(spacing: 4) {
                        Button { model.stepLightbox(-1) } label: {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.white.opacity(hoverPrev ? 1 : 0.78))
                                .frame(width: 26, height: 26)
                                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(.white.opacity(hoverPrev ? 0.14 : 0.07)))
                        }
                        .buttonStyle(.plain)
                        .onHover { hoverPrev = $0 }
                        .help("Previous screenshot (←)")

                        Button { model.stepLightbox(1) } label: {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.white.opacity(hoverNext ? 1 : 0.78))
                                .frame(width: 26, height: 26)
                                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(.white.opacity(hoverNext ? 0.14 : 0.07)))
                        }
                        .buttonStyle(.plain)
                        .onHover { hoverNext = $0 }
                        .help("Next screenshot (→)")
                    }
                }

                if model.shotURLs[shotID] != nil {
                    ReviewSecondaryButton(title: "Open in Preview", hint: "↗") {
                        model.openInPreview(shotID)
                    }
                }

                Button {
                    model.removeShot(shotID)
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "trash").font(.system(size: 11, weight: .medium))
                        Text("Remove").font(.system(size: 11.5, weight: .medium))
                    }
                    .foregroundStyle(RUI.coral)
                    .padding(.horizontal, 10).frame(height: 28)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(RUI.coral.opacity(0.10))
                            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(RUI.coral.opacity(0.28), lineWidth: 1))
                    )
                }
                .buttonStyle(.plain)
                .help("Remove this screenshot (⌫)")

                Button {
                    model.closeLightbox()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.85))
                        .frame(width: 28, height: 28)
                        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(.white.opacity(0.08)))
                }
                .buttonStyle(.plain)
                .help("Close preview (Esc)")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 11)

            Rectangle().fill(RUI.hair).frame(height: 1)

            // Large crisp screenshot canvas
            ZStack {
                Color.black.opacity(0.45)
                if let img {
                    Image(nsImage: img)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .padding(14)
                } else {
                    Text("Image unavailable").foregroundStyle(RUI.dim)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if let shot, !shot.marks.isEmpty {
                Rectangle().fill(RUI.hair).frame(height: 1)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(Array(shot.marks.enumerated()), id: \.offset) { _, m in
                            Text(m.summary)
                                .font(.system(size: 11, weight: .medium, design: .monospaced))
                                .foregroundStyle(RUI.soft)
                                .padding(.horizontal, 8).padding(.vertical, 4)
                                .background(Capsule().fill(.white.opacity(0.06)))
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                }
            }
        }
        .background(shell.fill(RUI.bg))
        .overlay(shell.strokeBorder(Color.white.opacity(0.14), lineWidth: 1))
        .clipShape(shell)
        .environment(\.colorScheme, .dark)
    }
}

@MainActor
private final class ShotLightboxPanel: NSPanel {
    let model: ReviewModel
    private weak var parentReview: ReviewPanel?
    private var outsideClickMonitor: Any?

    init(model: ReviewModel, parent: ReviewPanel) {
        self.model = model
        self.parentReview = parent
        super.init(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
        level = NSWindow.Level(rawValue: parent.level.rawValue + 1)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        acceptsMouseMovedEvents = true
        appearance = NSAppearance(named: .darkAqua)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown, !isKeyWindow {
            NSApp.activate()
            makeKeyAndOrderFront(nil)
        }
        super.sendEvent(event)
    }

    func show(shotID: String) {
        let host = FirstMouseHostingView(rootView: ShotLightboxView(model: model, shotID: shotID))
        contentView = host

        let screen = parentReview?.screen ?? Screens.under(NSEvent.mouseLocation) ?? NSScreen.main
        let vf = screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1280, height: 800)
        let maxW = min(vf.width * 0.84, 1180)
        let maxH = min(vf.height * 0.82, 820)
        let chromeH: CGFloat = 104
        var w = maxW, h = maxH
        if let img = model.fullImage(for: shotID), img.size.width > 0, img.size.height > 0 {
            let aspect = img.size.width / img.size.height
            let availW = maxW - 28
            let availH = maxH - chromeH
            if availW / availH > aspect {
                let ih = min(availH, max(img.size.height, 420))
                w = max(560, min(maxW, ih * aspect + 28))
                h = max(360, min(maxH, ih + chromeH))
            } else {
                let iw = min(availW, max(img.size.width, 540))
                w = max(560, min(maxW, iw + 28))
                h = max(360, min(maxH, iw / aspect + chromeH))
            }
        }
        let frame = CGRect(x: (vf.midX - w / 2).rounded(), y: (vf.midY - h / 2).rounded(), width: w.rounded(), height: h.rounded())
        setFrame(frame, display: true)
        makeKeyAndOrderFront(nil)
        orderFrontRegardless()

        if outsideClickMonitor == nil {
            outsideClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] e in
                guard let self, self.isVisible else { return e }
                if e.window !== self {
                    self.model.closeLightbox()
                }
                return e
            }
        }
    }

    func dismiss() {
        if let m = outsideClickMonitor { NSEvent.removeMonitor(m); outsideClickMonitor = nil }
        orderOut(nil)
        parentReview?.makeKeyAndOrderFront(nil)
    }

    override func cancelOperation(_ sender: Any?) {
        model.closeLightbox()
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: model.closeLightbox()                    // Esc
        case 123: model.stepLightbox(-1)                  // Left arrow
        case 124: model.stepLightbox(1)                   // Right arrow
        case 51, 117:                                     // Backspace / Delete
            if let id = model.lightboxShotID { model.removeShot(id) }
        default: super.keyDown(with: event)
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.keyCode == 53 { model.closeLightbox(); return true }
        if event.modifierFlags.contains(.command) {
            let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
            if key == "w" { model.closeLightbox(); return true }
            if event.keyCode == 36 || event.keyCode == 76 {
                model.closeLightbox()
                parentReview?.commitAndFinish(copy: true)
                return true
            }
        }
        return super.performKeyEquivalent(with: event)
    }
}

// MARK: Review Panel (activating, first-mouse, full keyboard support)

/// Borderless activating panel for LSUIElement app: handles first click immediately, supports text editing,
/// standard Cmd+A/C/V/X/Z, Cmd+Return (send), Esc (save without copying), and large screenshot lightbox.
@MainActor
final class ReviewPanel: NSPanel {
    let model: ReviewModel
    private var lightbox: ShotLightboxPanel?

    init(model: ReviewModel) {
        self.model = model
        // Do NOT use .nonactivatingPanel: clicks must activate this LSUIElement app and focus text fields on first click.
        super.init(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
        level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        acceptsMouseMovedEvents = true
        appearance = NSAppearance(named: .darkAqua)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let host = FirstMouseHostingView(rootView: ReviewView(model: model))
        contentView = host
        let size = CGSize(width: RUI.width, height: max(220, min(host.fittingSize.height, 580)))
        if let s = Screens.under(NSEvent.mouseLocation) ?? NSScreen.main {
            setFrame(CGRect(x: (s.visibleFrame.midX - size.width / 2).rounded(),
                            y: (s.visibleFrame.midY - size.height / 2).rounded(),
                            width: size.width, height: size.height), display: true)
        }

        model.onLightboxChange = { [weak self] shotID in
            self?.updateLightbox(shotID)
        }
        model.onHeightChange = { [weak self] newHeight in
            self?.adjustHeight(newHeight)
        }
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown, !isKeyWindow {
            NSApp.activate()
            makeKeyAndOrderFront(nil)
        }
        super.sendEvent(event)
    }

    func present() {
        NSApp.activate()
        makeKeyAndOrderFront(nil)
        orderFrontRegardless()
    }

    func dismissAll() {
        lightbox?.dismiss()
        lightbox = nil
        orderOut(nil)
    }

    fileprivate func commitAndFinish(copy: Bool) {
        // Flush any in-progress field editor or IME text composition before building SessionDoc.
        makeFirstResponder(nil)
        model.finish(copy: copy)
    }

    private func updateLightbox(_ shotID: String?) {
        if let shotID {
            let lb = lightbox ?? ShotLightboxPanel(model: model, parent: self)
            lightbox = lb
            lb.show(shotID: shotID)
        } else {
            lightbox?.dismiss()
        }
    }

    /// Keeps the top edge anchored when rows are added/removed so buttons never jump under the pointer.
    private func adjustHeight(_ measured: CGFloat) {
        guard isVisible else { return }
        let clamped = max(210, min(measured.rounded(), 580))
        guard abs(clamped - frame.height) > 1.5 else { return }
        let topY = frame.maxY
        var next = CGRect(x: frame.minX, y: (topY - clamped).rounded(), width: RUI.width, height: clamped)
        if let vf = (screen ?? NSScreen.main)?.visibleFrame {
            if next.minY < vf.minY + 16 { next.origin.y = vf.minY + 16 }
            if next.maxY > vf.maxY - 16 { next.origin.y = vf.maxY - 16 - next.height }
        }
        setFrame(next, display: true)
    }

    override func cancelOperation(_ sender: Any?) {
        if model.lightboxShotID != nil {
            model.closeLightbox()
        } else {
            commitAndFinish(copy: false)
        }
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            cancelOperation(nil)
            return
        }
        if event.modifierFlags.contains(.command), (event.keyCode == 36 || event.keyCode == 76) {
            commitAndFinish(copy: true)
            return
        }
        super.keyDown(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if event.keyCode == 53, mods.isEmpty {
            cancelOperation(nil)
            return true
        }
        if mods.contains(.command) {
            if event.keyCode == 36 || event.keyCode == 76 {
                commitAndFinish(copy: true)
                return true
            }
            let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
            if key == "w" {
                commitAndFinish(copy: false)
                return true
            }
            // LSUIElement app has no main Edit menu: route standard text editing shortcuts directly to firstResponder.
            switch key {
            case "a": if NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: self) { return true }
            case "c": if NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: self) { return true }
            case "v": if NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: self) { return true }
            case "x": if NSApp.sendAction(#selector(NSText.cut(_:)), to: nil, from: self) { return true }
            case "z":
                if mods.contains(.shift) {
                    if NSApp.sendAction(Selector(("redo:")), to: nil, from: self) { return true }
                } else {
                    if NSApp.sendAction(Selector(("undo:")), to: nil, from: self) { return true }
                }
            default: break
            }
        }
        return super.performKeyEquivalent(with: event)
    }
}
