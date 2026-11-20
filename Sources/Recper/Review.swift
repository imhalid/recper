import AppKit
import SwiftUI
import RecperCore

/// After Finish, before sending: fix sentences, remove unneeded screenshots/items. ⌘⏎ sends, Esc saves without copying.
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
    let images: [String: NSImage]     // shot id → thumbnail
    private let doc: SessionDoc
    var onDone: ((SessionDoc?, _ copy: Bool) -> Void)?

    static let enabledKey = "reviewBeforeSend"
    static var enabled: Bool {
        get { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    init(doc: SessionDoc, images: [String: NSImage]) {
        self.doc = doc
        self.images = images
        var list: [Item] = doc.segments.map { seg in
            Item(id: seg.id, text: seg.text, shots: doc.shots.filter { $0.segment == seg.id }, t: seg.t0, isSegment: true)
        }
        list += doc.shots.filter { $0.segment == nil }.map {
            Item(id: "shot-\($0.id)", text: "", shots: [$0], t: $0.t, isSegment: false)
        }
        items = list.sorted { $0.t < $1.t }
    }

    func removeShot(_ shotID: String) {
        for i in items.indices { items[i].shots.removeAll { $0.id == shotID } }
        items.removeAll { !$0.isSegment && $0.shots.isEmpty }
    }

    func removeItem(_ id: String) { items.removeAll { $0.id == id } }

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

struct ReviewView: View {
    @ObservedObject var model: ReviewModel
    @FocusState private var focus: String?

    private var list: some View {
        VStack(spacing: 2) {
            ForEach(Array(model.items.enumerated()), id: \.element.id) { i, item in
                Row(model: model, index: i, item: item, focus: $focus)
            }
            if model.items.isEmpty {
                Text("Nothing left to send.").font(.system(size: 12)).foregroundStyle(.white.opacity(0.4))
                    .frame(maxWidth: .infinity).padding(.vertical, 30)
            }
        }
        .padding(8)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("Review").font(.system(size: 15, weight: .semibold)).tracking(-0.3)
                Text("\(model.items.count) items · \(model.items.reduce(0) { $0 + $1.shots.count }) screenshots")
                    .font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.45))
                Spacer()
                Text("Fix the text, remove what's not needed").font(.system(size: 11)).foregroundStyle(.white.opacity(0.35))
            }
            .padding(.horizontal, 18).padding(.top, 16).padding(.bottom, 12)

            Rectangle().fill(.white.opacity(0.07)).frame(height: 1)

            Group {
                if BarView.flatBackground { list }          // preview: ImageRenderer can't draw a ScrollView
                else { ScrollView { list }.frame(maxHeight: 460).fixedSize(horizontal: false, vertical: true) }
            }

            Rectangle().fill(.white.opacity(0.07)).frame(height: 1)

            HStack(spacing: 8) {
                Button { model.onDone?(model.result(), false) } label: {
                    Text("Save without copying").font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(0.7))
                        .padding(.horizontal, 12).frame(height: 30)
                        .background(Capsule().fill(.white.opacity(0.08)))
                }
                .buttonStyle(.plain).keyboardShortcut(.cancelAction).help("Esc")
                Spacer()
                Button { model.onDone?(model.result(), true) } label: {
                    HStack(spacing: 7) {
                        Text("Send").font(.system(size: 12.5, weight: .semibold))
                        Text("⌘⏎").font(.system(size: 10.5, weight: .semibold)).opacity(0.4)
                    }
                    .foregroundStyle(.black).padding(.horizontal, 16).frame(height: 30)
                    .background(Capsule().fill(.white))
                }
                .buttonStyle(.plain).keyboardShortcut(.return, modifiers: .command)
                .help("Save and copy the agent prompt to the clipboard")
            }
            .padding(.horizontal, 14).padding(.vertical, 12)
        }
        .frame(width: 600)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color(red: 0.07, green: 0.07, blue: 0.075).opacity(0.97)))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
            .strokeBorder(LinearGradient(colors: [.white.opacity(0.2), .white.opacity(0.05)], startPoint: .top, endPoint: .bottom), lineWidth: 0.75))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .environment(\.colorScheme, .dark)
    }
}

private struct Row: View {
    @ObservedObject var model: ReviewModel
    let index: Int
    let item: ReviewModel.Item
    var focus: FocusState<String?>.Binding
    @State private var hover = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(index + 1)").font(.system(size: 11, weight: .semibold).monospacedDigit())
                .foregroundStyle(.white.opacity(0.35)).frame(width: 18, alignment: .trailing).padding(.top, 5)
            VStack(alignment: .leading, spacing: 8) {
                if item.isSegment {
                    TextField("", text: binding, axis: .vertical)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13)).foregroundStyle(.white)
                        .lineLimit(1...6)
                        .focused(focus, equals: item.id)
                        .padding(.vertical, 4)
                } else {
                    Text("(no speech)").font(.system(size: 12.5)).foregroundStyle(.white.opacity(0.35)).padding(.vertical, 4)
                }
                if !item.shots.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(item.shots, id: \.id) { s in ShotThumb(model: model, shot: s) }
                    }
                }
            }
            Spacer(minLength: 0)
            Button { withAnimation(.easeOut(duration: 0.15)) { model.removeItem(item.id) } } label: {
                Image(systemName: "trash").font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.6))
                    .frame(width: 26, height: 26).background(Circle().fill(.white.opacity(0.08)))
            }
            .buttonStyle(.plain).opacity(hover ? 1 : 0).help("Delete this item (and its screenshots)")
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.white.opacity(hover || focus.wrappedValue == item.id ? 0.05 : 0)))
        .onHover { hover = $0 }
    }

    private var binding: Binding<String> {
        Binding(get: { model.items.first { $0.id == item.id }?.text ?? "" },
                set: { v in if let i = model.items.firstIndex(where: { $0.id == item.id }) { model.items[i].text = v } })
    }
}

private struct ShotThumb: View {
    @ObservedObject var model: ReviewModel
    let shot: Shot
    @State private var hover = false
    var body: some View {
        ZStack(alignment: .topTrailing) {
            Group {
                if let img = model.images[shot.id] { Image(nsImage: img).resizable().aspectRatio(contentMode: .fill) }
                else { Color.white.opacity(0.1) }
            }
            .frame(width: 96, height: 60)
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(.white.opacity(hover ? 0.5 : 0.1), lineWidth: 0.75))
            if hover {
                Button { withAnimation(.easeOut(duration: 0.15)) { model.removeShot(shot.id) } } label: {
                    Image(systemName: "xmark").font(.system(size: 8, weight: .bold)).foregroundStyle(.black)
                        .frame(width: 16, height: 16).background(Circle().fill(.white))
                }
                .buttonStyle(.plain).offset(x: 5, y: -5).help("Remove this screenshot")
            }
        }
        .onHover { hover = $0 }
        .help(shot.marks.map(\.summary).joined(separator: "\n"))
    }
}

/// Borderless panel that can take keyboard input (for text editing).
final class ReviewPanel: NSPanel {
    init(model: ReviewModel) {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let host = NSHostingView(rootView: ReviewView(model: model))
        contentView = host
        let size = host.fittingSize
        if let s = Screens.under(NSEvent.mouseLocation) ?? NSScreen.main {
            setFrame(CGRect(x: (s.visibleFrame.midX - size.width / 2).rounded(), y: (s.visibleFrame.midY - size.height / 2).rounded(),
                            width: size.width, height: size.height), display: true)
        }
    }
    override var canBecomeKey: Bool { true }
}
