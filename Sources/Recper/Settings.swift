import AppKit
import AVFoundation
import ApplicationServices
import ServiceManagement
import Speech
import SwiftUI
import RecperCore

// MARK: Shared defaults (keeps existing UserDefaults keys intact)

enum AppSettings {
    static let defaultModeKey = "lastMode"
    static let defaultInkColorKey = "defaultInkColor"
    static let defaultToolKey = "defaultTool"
    static let circleGestureKey = "circleGesture"

    static var defaultMode: CaptureMode {
        get { UserDefaults.standard.string(forKey: defaultModeKey).flatMap(CaptureMode.init) ?? .area }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: defaultModeKey) }
    }

    static var defaultInkColor: InkColor {
        get { UserDefaults.standard.string(forKey: defaultInkColorKey).flatMap(InkColor.init) ?? .red }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: defaultInkColorKey) }
    }

    /// Default tool at the start of a new session. `nil` = Cursor (clicks pass through to the app underneath).
    static var defaultTool: Tool? {
        get {
            guard let raw = UserDefaults.standard.string(forKey: defaultToolKey), raw != "cursor", !raw.isEmpty else { return nil }
            return Tool(rawValue: raw)
        }
        set {
            UserDefaults.standard.set(newValue?.rawValue ?? "cursor", forKey: defaultToolKey)
        }
    }

    /// Detect circular pointer loops in cursor mode (without clicking) to create an ellipse mark. On by default.
    static var circleGestureEnabled: Bool {
        get { UserDefaults.standard.object(forKey: circleGestureKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: circleGestureKey) }
    }
}

// MARK: Sections & Model

enum SettingsSection: String, CaseIterable, Identifiable {
    case general, drawing, dictation, shortcuts, permissions, mcp, storage, about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "General"
        case .drawing: "Drawing"
        case .dictation: "Dictation"
        case .shortcuts: "Shortcuts"
        case .permissions: "Permissions"
        case .mcp: "Agents & MCP"
        case .storage: "Storage"
        case .about: "About"
        }
    }

    var symbol: String {
        switch self {
        case .general: "slider.horizontal.3"
        case .drawing: "scribble.variable"
        case .dictation: "waveform"
        case .shortcuts: "command"
        case .permissions: "lock.shield"
        case .mcp: "terminal"
        case .storage: "externaldrive"
        case .about: "info.circle"
        }
    }

    var subtitle: String {
        switch self {
        case .general: "Capture workflow, audio feedback, and startup"
        case .drawing: "Default tool, ink color, circle gesture, and cursor preview"
        case .dictation: "On-device speech language, screen hints, and voice commands"
        case .shortcuts: "Global hotkeys, drawing & editing keys, and the radial dial"
        case .permissions: "Live macOS privacy status for capture and dictation"
        case .mcp: "Connect Claude Code, Codex, Antigravity, or any MCP client"
        case .storage: "Local feedback sessions, screenshots, and disk usage"
        case .about: "On-device voice and drawing feedback for coding agents"
        }
    }
}

enum PermState: Equatable {
    case granted, denied, notDetermined, restricted

    var label: String {
        switch self {
        case .granted: "Granted"
        case .denied: "Denied"
        case .notDetermined: "Not Set"
        case .restricted: "Restricted"
        }
    }
}

struct LocaleOption: Identifiable, Equatable, Sendable {
    let id: String        // BCP-47 identifier (e.g. "en-US")
    let name: String      // Localized display name
    let nativeName: String?
}

@MainActor
final class SettingsModel: ObservableObject {
    @Published var section: SettingsSection = .general

    // General
    @Published var defaultMode: CaptureMode = .area
    @Published var reviewBeforeSend: Bool = true
    @Published var autoCapture: Bool = false
    @Published var soundsEnabled: Bool = true
    @Published var soundVolume: Float = 0.7
    @Published var launchAtLogin: Bool = false
    @Published var loginStatus: SMAppService.Status = .notRegistered
    @Published var loginNotice: String?

    // Drawing
    @Published var defaultTool: Tool? = nil
    @Published var defaultInkColor: InkColor = .red
    @Published var circleGesture: Bool = true
    @Published var previewTool: Tool = .pen
    @Published var previewColor: InkColor = .red

    // Dictation
    /// Empty string = Automatic (system language).
    @Published var selectedLocale: String = ""
    @Published var supportedLocales: [LocaleOption] = []
    @Published var automaticLocaleLabel: String = "System Default"
    @Published var loadingLocales = false
    @Published var axVocabulary: Bool = true

    // Permissions
    @Published var micStatus: PermState = .notDetermined
    @Published var speechStatus: PermState = .notDetermined
    @Published var screenStatus: PermState = .notDetermined
    @Published var accessibilityStatus: PermState = .notDetermined

    // Agents / MCP
    @Published var copiedID: String?

    // Storage
    @Published var sessionCount: Int = 0
    @Published var shotCount: Int = 0
    @Published var totalBytes: Int64 = 0
    @Published var scanningStorage = false
    @Published var storageNotice: String?

    let isPreview: Bool
    var onDefaultModeChanged: ((CaptureMode) -> Void)?
    weak var hostWindow: NSWindow?

    private var copyReset: DispatchWorkItem?
    private var localesLoaded = false

    init(isPreview: Bool = false) {
        self.isPreview = isPreview
        if !isPreview {
            syncFromDefaults()
            previewTool = defaultTool ?? .pen
            previewColor = defaultInkColor
        }
    }

    // MARK: Sync & Refresh

    func syncFromDefaults() {
        guard !isPreview else { return }
        defaultMode = AppSettings.defaultMode
        reviewBeforeSend = ReviewModel.enabled
        autoCapture = Recorder.autoCapture
        soundsEnabled = Sounds.enabled
        soundVolume = Sounds.volume
        defaultTool = AppSettings.defaultTool
        defaultInkColor = AppSettings.defaultInkColor
        circleGesture = AppSettings.circleGestureEnabled
        selectedLocale = UserDefaults.standard.string(forKey: Transcriber.localeKey) ?? ""
        axVocabulary = AXVocabulary.enabled
    }

    func refreshAll() {
        guard !isPreview else { return }
        syncFromDefaults()
        refreshLoginStatus()
        refreshPermissions()
        refreshStorage()
        loadLocalesIfNeeded()
    }

    // MARK: General setters

    func setDefaultMode(_ mode: CaptureMode) {
        guard mode != defaultMode else { return }
        defaultMode = mode
        if !isPreview {
            AppSettings.defaultMode = mode
            Sfx.mode(CaptureMode.allCases.firstIndex(of: mode) ?? 0)
            onDefaultModeChanged?(mode)
        }
    }

    func setReviewBeforeSend(_ v: Bool) {
        reviewBeforeSend = v
        guard !isPreview else { return }
        ReviewModel.enabled = v
    }

    func setAutoCapture(_ v: Bool) {
        autoCapture = v
        guard !isPreview else { return }
        Recorder.autoCapture = v
    }

    func setSoundsEnabled(_ v: Bool) {
        soundsEnabled = v
        guard !isPreview else { return }
        Sounds.enabled = v
        if v { Sfx.done() }
    }

    func setSoundVolume(_ v: Float) {
        let clamped = min(max(v, 0), 1)
        soundVolume = clamped
        guard !isPreview else { return }
        Sounds.volume = clamped
    }

    func testSound() {
        guard !isPreview else { return }
        if !soundsEnabled { setSoundsEnabled(true) }
        else { Sfx.done() }
    }

    func refreshLoginStatus() {
        guard !isPreview else { return }
        let s = SMAppService.mainApp.status
        loginStatus = s
        launchAtLogin = (s == .enabled)
        if s == .requiresApproval {
            loginNotice = "Needs approval in System Settings › Login Items."
        } else if s == .notFound {
            loginNotice = "Available when running from Recper.app."
        } else {
            loginNotice = nil
        }
    }

    func setLaunchAtLogin(_ on: Bool) {
        guard !isPreview else { launchAtLogin = on; return }
        loginNotice = nil
        do {
            if on {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            loginNotice = "Could not update Login Items: \(error.localizedDescription)"
        }
        refreshLoginStatus()
    }

    func openLoginItemsSettings() {
        openSystemSettings("x-apple.systempreferences:com.apple.LoginItems-Settings.extension")
    }

    // MARK: Drawing setters

    func setDefaultTool(_ tool: Tool?) {
        defaultTool = tool
        if let tool { previewTool = tool }
        guard !isPreview else { return }
        AppSettings.defaultTool = tool
        Sfx.tool([nil, Tool.pen, .box, .ellipse, .arrow, .blur].firstIndex(of: tool) ?? 0)
    }

    func setDefaultInkColor(_ color: InkColor) {
        defaultInkColor = color
        previewColor = color
        guard !isPreview else { return }
        AppSettings.defaultInkColor = color
        Sfx.color(InkColor.allCases.firstIndex(of: color) ?? 0)
    }

    func setCircleGesture(_ on: Bool) {
        circleGesture = on
        guard !isPreview else { return }
        AppSettings.circleGestureEnabled = on
    }

    // MARK: Dictation

    func setDictationLocale(_ id: String) {
        selectedLocale = id
        guard !isPreview else { return }
        if id.isEmpty {
            UserDefaults.standard.removeObject(forKey: Transcriber.localeKey)
        } else {
            UserDefaults.standard.set(id, forKey: Transcriber.localeKey)
        }
    }

    func setAXVocabulary(_ on: Bool) {
        axVocabulary = on
        guard !isPreview else { return }
        AXVocabulary.enabled = on
        if on && !AXVocabulary.trusted {
            AXVocabulary.requestTrust()
            refreshPermissions()
        }
    }

    func loadLocalesIfNeeded() {
        guard !isPreview, !localesLoaded, !loadingLocales else { return }
        loadingLocales = true
        Task {
            let raw = await DictationTranscriber.supportedLocales
            let ids = Set(raw.map { $0.identifier(.bcp47) })
            let auto = Transcriber.automaticLocale(from: ids)
            let autoID = auto.identifier(.bcp47)
            let autoName = Locale.current.localizedString(forIdentifier: autoID) ?? autoID

            let options: [LocaleOption] = ids.map { id in
                let display = Locale.current.localizedString(forIdentifier: id) ?? id
                let loc = Locale(identifier: id)
                let native = loc.localizedString(forIdentifier: id)
                let distinctNative = (native != nil && native?.caseInsensitiveCompare(display) != .orderedSame) ? native : nil
                return LocaleOption(id: id, name: display, nativeName: distinctNative)
            }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

            self.supportedLocales = options
            self.automaticLocaleLabel = "\(autoName) (\(autoID))"
            self.loadingLocales = false
            self.localesLoaded = true
        }
    }

    // MARK: Permissions

    var requiredGrantedCount: Int {
        [micStatus, speechStatus, screenStatus].filter { $0 == .granted }.count
    }

    var allGrantedCount: Int {
        [micStatus, speechStatus, screenStatus, accessibilityStatus].filter { $0 == .granted }.count
    }

    func refreshPermissions() {
        guard !isPreview else { return }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: micStatus = .granted
        case .denied: micStatus = .denied
        case .restricted: micStatus = .restricted
        case .notDetermined: micStatus = .notDetermined
        @unknown default: micStatus = .notDetermined
        }

        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: speechStatus = .granted
        case .denied: speechStatus = .denied
        case .restricted: speechStatus = .restricted
        case .notDetermined: speechStatus = .notDetermined
        @unknown default: speechStatus = .notDetermined
        }

        screenStatus = CGPreflightScreenCaptureAccess() ? .granted : .denied
        accessibilityStatus = AXIsProcessTrusted() ? .granted : .denied
    }

    func requestMicrophone() {
        guard !isPreview else { return }
        if micStatus == .notDetermined {
            Task {
                _ = await AVCaptureDevice.requestAccess(for: .audio)
                self.refreshPermissions()
            }
        } else {
            openPrivacyPane("Privacy_Microphone")
        }
    }

    func requestSpeech() {
        guard !isPreview else { return }
        if speechStatus == .notDetermined {
            SFSpeechRecognizer.requestAuthorization { [weak self] _ in
                Task { @MainActor in self?.refreshPermissions() }
            }
        } else {
            openPrivacyPane("Privacy_SpeechRecognition")
        }
    }

    func requestScreenRecording() {
        guard !isPreview else { return }
        if !CGPreflightScreenCaptureAccess() {
            CGRequestScreenCaptureAccess()
        }
        openPrivacyPane("Privacy_ScreenCapture")
        refreshPermissions()
    }

    func requestAccessibility() {
        guard !isPreview else { return }
        AXVocabulary.requestTrust()
        openPrivacyPane("Privacy_Accessibility")
        refreshPermissions()
    }

    func openPrivacyPane(_ anchor: String) {
        openSystemSettings("x-apple.systempreferences:com.apple.preference.security?\(anchor)")
    }

    private func openSystemSettings(_ urlString: String) {
        guard !isPreview, let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: Agents / MCP

    var executablePath: String {
        if isPreview { return "/Applications/Recper.app/Contents/MacOS/Recper" }
        return Bundle.main.executablePath ?? ProcessInfo.processInfo.arguments.first ?? "/Applications/Recper.app/Contents/MacOS/Recper"
    }

    var claudeCommand: String {
        "claude mcp add recper -- \(Self.shellQuote(executablePath)) --mcp"
    }

    var mcpConfigJSON: String {
        let escaped = executablePath.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return """
        {
          "mcpServers": {
            "recper": {
              "command": "\(escaped)",
              "args": ["--mcp"]
            }
          }
        }
        """
    }

    func copy(_ text: String, id: String) {
        guard !isPreview else { copiedID = id; return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        Sfx.done()
        copiedID = id
        copyReset?.cancel()
        let w = DispatchWorkItem { [weak self] in
            if self?.copiedID == id { self?.copiedID = nil }
        }
        copyReset = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8, execute: w)
    }

    private static func shellQuote(_ path: String) -> String {
        let safe = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "/._-+:@"))
        if path.unicodeScalars.allSatisfy({ safe.contains($0) }) { return path }
        return "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    // MARK: Storage

    var sessionsDisplayPath: String {
        if isPreview { return "~/.recper/sessions" }
        let full = Recorder.root.path
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if full.hasPrefix(home) { return "~" + full.dropFirst(home.count) }
        return full
    }

    var formattedDiskUsage: String {
        ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)
    }

    func refreshStorage() {
        guard !isPreview, !scanningStorage else { return }
        scanningStorage = true
        let root = Recorder.rootURL
        Task.detached(priority: .utility) {
            let stats = Self.scanStorage(at: root)
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.sessionCount = stats.sessions
                self.shotCount = stats.shots
                self.totalBytes = stats.bytes
                self.scanningStorage = false
            }
        }
    }

    private nonisolated static func scanStorage(at root: URL) -> (sessions: Int, shots: Int, bytes: Int64) {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else {
            return (0, 0, 0)
        }
        var sessions = 0, shots = 0
        var total: Int64 = 0
        for entry in entries {
            let isDir = (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if isDir { sessions += 1 }
            if let enumerator = fm.enumerator(at: entry, includingPropertiesForKeys: [.isRegularFileKey, .totalFileAllocatedSizeKey, .fileSizeKey], options: [.skipsHiddenFiles]) {
                for case let file as URL in enumerator {
                    let vals = try? file.resourceValues(forKeys: [.isRegularFileKey, .totalFileAllocatedSizeKey, .fileSizeKey])
                    guard vals?.isRegularFile == true else { continue }
                    total += Int64(vals?.totalFileAllocatedSize ?? vals?.fileSize ?? 0)
                    if file.pathExtension.lowercased() == "png" { shots += 1 }
                }
            }
        }
        return (sessions, shots, total)
    }

    func openSessionsFolder() {
        guard !isPreview else { return }
        try? FileManager.default.createDirectory(at: Recorder.root, withIntermediateDirectories: true)
        NSWorkspace.shared.open(Recorder.root)
    }

    func confirmAndClearSessions() {
        guard !isPreview, sessionCount > 0 else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Move \(sessionCount) \(sessionCount == 1 ? "session" : "sessions") to Trash?"
        alert.informativeText = "This will move \(sessionCount) saved \(sessionCount == 1 ? "session" : "sessions") (\(formattedDiskUsage)) from \(sessionsDisplayPath) to the Trash. You can restore them from Trash if needed."
        alert.addButton(withTitle: "Move to Trash")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true

        let finish: (NSApplication.ModalResponse) -> Void = { [weak self] resp in
            guard resp == .alertFirstButtonReturn else { return }
            self?.trashAllSessions()
        }

        if let win = hostWindow {
            alert.beginSheetModal(for: win, completionHandler: finish)
        } else {
            finish(alert.runModal())
        }
    }

    private func trashAllSessions() {
        let root = Recorder.rootURL
        storageNotice = nil
        Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            let entries = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
            var removed = 0
            for entry in entries {
                if (try? fm.trashItem(at: entry, resultingItemURL: nil)) != nil { removed += 1 }
            }
            await MainActor.run { [weak self] in
                guard let self else { return }
                Sfx.undo()
                self.storageNotice = removed > 0 ? "Moved \(removed) \(removed == 1 ? "session" : "sessions") to Trash." : nil
                self.refreshStorage()
            }
        }
    }

    // MARK: App metadata

    var appVersion: String {
        if isPreview { return "0.0.1" }
        return (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0.0.1"
    }

    var appBuild: String {
        if isPreview { return "1" }
        return (Bundle.main.infoDictionary?["CFBundleVersion"] as? String) ?? "1"
    }

    // MARK: Preview factory (zero personal info, deterministic state)

    static func preview(section: SettingsSection) -> SettingsModel {
        let m = SettingsModel(isPreview: true)
        m.section = section
        m.defaultMode = .area
        m.reviewBeforeSend = true
        m.autoCapture = false
        m.soundsEnabled = true
        m.soundVolume = 0.72
        m.launchAtLogin = true
        m.loginStatus = .enabled
        m.defaultTool = .pen
        m.defaultInkColor = .red
        m.circleGesture = true
        m.previewTool = .pen
        m.previewColor = .red
        m.selectedLocale = ""
        m.automaticLocaleLabel = "English (United States) (en-US)"
        m.supportedLocales = [
            LocaleOption(id: "en-US", name: "English (United States)", nativeName: nil),
            LocaleOption(id: "tr-TR", name: "Turkish (Turkey)", nativeName: "Türkçe (Türkiye)"),
            LocaleOption(id: "de-DE", name: "German (Germany)", nativeName: "Deutsch (Deutschland)"),
            LocaleOption(id: "fr-FR", name: "French (France)", nativeName: "Français (France)"),
            LocaleOption(id: "ja-JP", name: "Japanese (Japan)", nativeName: "日本語 (日本)"),
        ]
        m.axVocabulary = true
        m.micStatus = .granted
        m.speechStatus = .granted
        m.screenStatus = .granted
        m.accessibilityStatus = .notDetermined
        m.sessionCount = 14
        m.shotCount = 38
        m.totalBytes = 19_293_798
        return m
    }
}

// MARK: Calm Flat Dark Visual Tokens

private enum SUI {
    static let width: CGFloat = 820
    static let height: CGFloat = 616
    static let sidebarWidth: CGFloat = 212

    // Accent used sparingly (toggles, small status dots).
    static let go = Color(red: 0.55, green: 1.0, blue: 0.5)
    static let amber = Color(red: 0.96, green: 0.74, blue: 0.34)
    static let coral = Color(red: 0.95, green: 0.42, blue: 0.40)

    static let bg = Color(red: 0.11, green: 0.115, blue: 0.125)
    static let sidebarBg = Color(red: 0.088, green: 0.092, blue: 0.102)
    static let cardFill = Color.white.opacity(0.038)
    static let cardBorder = Color.white.opacity(0.085)
    static let hair = Color.white.opacity(0.08)

    static let ink = Color.white
    static let soft = Color.white.opacity(0.70)
    static let dim = Color.white.opacity(0.45)

    static func mono(_ s: CGFloat, _ w: Font.Weight = .medium) -> Font {
        .system(size: s, weight: w, design: .monospaced)
    }
}

/// Subtle dark frosted backing for live window mode.
private struct SettingsBackdrop: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .windowBackground
        v.blendingMode = .behindWindow
        v.state = .active
        v.appearance = NSAppearance(named: .darkAqua)
        return v
    }
    func updateNSView(_ v: NSVisualEffectView, context: Context) {}
}

// MARK: Single reusable Settings Window

@MainActor
final class SettingsWindow: NSWindow, NSWindowDelegate {
    let model: SettingsModel

    init(model: SettingsModel) {
        self.model = model
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: SUI.width, height: SUI.height),
            styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        title = "Recper Settings"
        titlebarAppearsTransparent = true
        titleVisibility = .hidden
        isOpaque = false
        // A real (dark) window background lets macOS draw the window's own rounded corners and shadow on all four corners.
        backgroundColor = NSColor(white: 0.09, alpha: 1)
        isMovableByWindowBackground = true
        isReleasedWhenClosed = false
        appearance = NSAppearance(named: .darkAqua)
        collectionBehavior = [.moveToActiveSpace]
        delegate = self
        model.hostWindow = self

        // The content runs under the transparent title bar (the sidebar leaves room for the traffic lights);
        // without this the hosting view insets it by the title bar height, leaving an empty strip on top and clipping the bottom.
        let host = FirstMouseHostingView(rootView: AnyView(SettingsView(model: model).ignoresSafeArea()))
        host.frame = NSRect(x: 0, y: 0, width: SUI.width, height: SUI.height)
        host.sizingOptions = []     // the window keeps exactly SUI.width × SUI.height (no extra title-bar height)
        contentView = host
        // With a full-size content view the whole frame is content: size the frame itself, not the content rect
        // (setContentSize would add the title bar height and leave an empty strip at the bottom).
        setFrame(NSRect(x: 0, y: 0, width: SUI.width, height: SUI.height), display: false)
        center()
    }

    func show(section: SettingsSection? = nil) {
        if let section { model.section = section }
        model.refreshAll()
        if !isVisible { center() }
        NSApp.activate()
        makeKeyAndOrderFront(nil)
        orderFrontRegardless()
    }

    func windowDidBecomeKey(_ notification: Notification) {
        model.refreshAll()
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command) {
            let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
            if key == "w" { close(); return true }
            if key == "q" { NSApp.terminate(nil); return true }
        }
        return super.performKeyEquivalent(with: event)
    }
}

// MARK: Root View

struct SettingsView: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        let shell = RoundedRectangle(cornerRadius: BarView.flatBackground ? 14 : 0, style: .continuous)
        HStack(spacing: 0) {
            sidebar
                .frame(width: SUI.sidebarWidth)
            Rectangle()
                .fill(SUI.hair)
                .frame(width: 1)
            detailPane
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: SUI.width, height: SUI.height)
        .background {
            if BarView.flatBackground {
                SUI.bg
            } else {
                ZStack {
                    SettingsBackdrop()
                    SUI.bg.opacity(0.84)
                }
            }
        }
        .clipShape(shell)
        .overlay {
            if BarView.flatBackground {
                shell.strokeBorder(Color.white.opacity(0.11), lineWidth: 1)
            }
        }
        .environment(\.colorScheme, .dark)
    }

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Room for macOS traffic lights (or preview traffic lights).
            HStack(spacing: 7) {
                if BarView.flatBackground {
                    Circle().fill(Color(red: 1.0, green: 0.37, blue: 0.34)).frame(width: 11, height: 11)
                    Circle().fill(Color(red: 1.0, green: 0.74, blue: 0.18)).frame(width: 11, height: 11)
                    Circle().fill(Color(red: 0.16, green: 0.78, blue: 0.25)).frame(width: 11, height: 11)
                }
                Spacer()
            }
            .padding(.horizontal, 16)
            .frame(height: 36)

            // Brand header
            HStack(spacing: 10) {
                RecperMark(size: 28)
                VStack(alignment: .leading, spacing: 1) {
                    Text("recper")
                        .font(.system(size: 14, weight: .semibold))
                        .tracking(-0.2)
                        .foregroundStyle(.white)
                    Text("v\(model.appVersion) · Settings")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(SUI.dim)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.top, 4)
            .padding(.bottom, 16)

            // Navigation items
            VStack(spacing: 2) {
                ForEach(SettingsSection.allCases) { sec in
                    SidebarRow(section: sec, on: model.section == sec, badge: badge(for: sec)) {
                        model.section = sec
                    }
                }
            }
            .padding(.horizontal, 10)

            Spacer(minLength: 8)

            // Compact live permissions summary button
            Button {
                model.section = .permissions
            } label: {
                let allReq = model.requiredGrantedCount == 3
                let dotColor = allReq ? SUI.go : SUI.amber
                HStack(spacing: 8) {
                    Circle()
                        .fill(dotColor)
                        .frame(width: 6, height: 6)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(allReq ? "All Core Access Ready" : "Permissions Needed")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.white.opacity(0.88))
                        Text("\(model.allGrantedCount)/4 permissions active")
                            .font(.system(size: 10, weight: .regular))
                            .foregroundStyle(SUI.dim)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(SUI.dim)
                }
                .padding(.horizontal, 11)
                .padding(.vertical, 9)
                .background(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(SUI.cardFill)
                        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(SUI.cardBorder, lineWidth: 1))
                )
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 12)
            .padding(.bottom, 14)
        }
        .background(BarView.flatBackground ? SUI.sidebarBg : Color.black.opacity(0.20))
    }

    private func badge(for sec: SettingsSection) -> String? {
        if sec == .permissions, model.requiredGrantedCount < 3 {
            return "\(3 - model.requiredGrantedCount)"
        }
        return nil
    }

    // MARK: Detail Pane

    private var detailPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(model.section.title)
                        .font(.system(size: 19, weight: .semibold))
                        .tracking(-0.3)
                        .foregroundStyle(.white)
                    Text(model.section.subtitle)
                        .font(.system(size: 12, weight: .regular))
                        .foregroundStyle(SUI.dim)
                }
                Spacer(minLength: 0)
                headerAccessory
            }
            .padding(.horizontal, 26)
            .padding(.top, 22)
            .padding(.bottom, 14)

            Rectangle()
                .fill(SUI.hair)
                .frame(height: 1)

            // Body (ScrollView in live app; direct VStack in flatBackground preview mode for ImageRenderer)
            Group {
                if BarView.flatBackground {
                    sectionContent
                        .padding(.horizontal, 24)
                        .padding(.vertical, 16)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .clipped()
                } else {
                    ScrollView {
                        sectionContent
                            .padding(.horizontal, 24)
                            .padding(.vertical, 16)
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                    }
                    .scrollIndicators(.automatic)
                }
            }
        }
    }

    @ViewBuilder
    private var headerAccessory: some View {
        switch model.section {
        case .permissions:
            FlatButton(title: "Refresh", symbol: "arrow.clockwise") { model.refreshPermissions() }
        case .storage:
            FlatButton(title: "Refresh", symbol: "arrow.clockwise") { model.refreshStorage() }
        case .general:
            HStack(spacing: 4) {
                Keycap("⌥"); Keycap("⇧"); Keycap("R")
            }
            .help("Global shortcut to start or finish a session")
        default:
            EmptyView()
        }
    }

    @ViewBuilder
    private var sectionContent: some View {
        switch model.section {
        case .general: GeneralPane(model: model)
        case .drawing: DrawingPane(model: model)
        case .dictation: DictationPane(model: model)
        case .shortcuts: ShortcutsPane()
        case .permissions: PermissionsPane(model: model)
        case .mcp: MCPPane(model: model)
        case .storage: StoragePane(model: model)
        case .about: AboutPane(model: model)
        }
    }
}

// MARK: 1. General Pane

private struct GeneralPane: View {
    @ObservedObject var model: SettingsModel

    private static let modes: [(CaptureMode, String, String, String)] = [
        (.window, "Window", "macwindow", "1"),
        (.area, "Area", "viewfinder", "2"),
        (.screen, "Screen", "display", "3"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SettingsCard {
                VStack(alignment: .leading, spacing: 11) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Default Capture Mode")
                            .font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                        Text("Target mode preselected when you start with ⌥⇧R")
                            .font(.system(size: 11.5)).foregroundStyle(SUI.dim)
                    }
                    HStack(spacing: 8) {
                        ForEach(Self.modes, id: \.0) { mode, title, symbol, key in
                            let on = model.defaultMode == mode
                            Button {
                                model.setDefaultMode(mode)
                            } label: {
                                VStack(spacing: 5) {
                                    Image(systemName: symbol)
                                        .font(.system(size: 16, weight: on ? .semibold : .regular))
                                        .foregroundStyle(on ? .white : .white.opacity(0.65))
                                        .frame(height: 19)
                                    Text(title)
                                        .font(.system(size: 11.5, weight: on ? .semibold : .medium))
                                        .foregroundStyle(on ? .white : .white.opacity(0.65))
                                }
                                .frame(maxWidth: .infinity)
                                .frame(height: 54)
                                .overlay(alignment: .topTrailing) {
                                    Text(key)
                                        .font(SUI.mono(9, .medium))
                                        .foregroundStyle(on ? .white.opacity(0.70) : .white.opacity(0.30))
                                        .padding(.top, 6).padding(.trailing, 8)
                                }
                                .background(FlatTileBackground(selected: on, radius: 9))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(14)
            }

            SettingsCard {
                ToggleRow(
                    title: "Review before sending",
                    detail: "Edit transcribed sentences and remove unwanted screenshots before copying the prompt.",
                    isOn: Binding(get: { model.reviewBeforeSend }, set: { model.setReviewBeforeSend($0) })
                )
                CardDivider()
                ToggleRow(
                    title: "Auto-capture at end of sentence",
                    detail: "Automatically take a screenshot when you finish a sentence or pause with drawings on screen.",
                    isOn: Binding(get: { model.autoCapture }, set: { model.setAutoCapture($0) })
                )
            }

            SettingsCard {
                ToggleRow(
                    title: "UI sound effects",
                    detail: "Synthesized tactile clicks and pentatonic chimes for tools, shutter, and radial menu.",
                    isOn: Binding(get: { model.soundsEnabled }, set: { model.setSoundsEnabled($0) })
                )
                CardDivider()
                HStack(spacing: 14) {
                    Image(systemName: model.soundsEnabled && model.soundVolume > 0.01 ? "speaker.wave.2.fill" : "speaker.slash.fill")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(model.soundsEnabled ? .white.opacity(0.75) : SUI.dim)
                        .frame(width: 20)

                    Text("Master Volume")
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(model.soundsEnabled ? .white.opacity(0.88) : SUI.dim)

                    FlatSlider(
                        value: Binding(get: { Double(model.soundVolume) }, set: { model.setSoundVolume(Float($0)) }),
                        disabled: !model.soundsEnabled
                    )

                    Text("\(Int((model.soundVolume * 100).rounded()))%")
                        .font(SUI.mono(11.5, .medium))
                        .foregroundStyle(model.soundsEnabled ? .white.opacity(0.80) : SUI.dim)
                        .frame(width: 38, alignment: .trailing)

                    FlatButton(title: "Test", symbol: "play.fill", compact: true) { model.testSound() }
                        .disabled(!model.soundsEnabled)
                        .opacity(model.soundsEnabled ? 1 : 0.45)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            }

            SettingsCard {
                VStack(alignment: .leading, spacing: 0) {
                    ToggleRow(
                        title: "Launch Recper at login",
                        detail: "Start silently in the menu bar whenever you sign in to macOS.",
                        isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }),
                        disabled: model.loginStatus == .notFound
                    )
                    if let notice = model.loginNotice {
                        HStack(spacing: 8) {
                            Image(systemName: "info.circle.fill")
                                .font(.system(size: 11))
                                .foregroundStyle(SUI.amber)
                            Text(notice)
                                .font(.system(size: 11))
                                .foregroundStyle(.white.opacity(0.68))
                            Spacer()
                            if model.loginStatus == .requiresApproval {
                                FlatButton(title: "Open Login Items", compact: true) { model.openLoginItemsSettings() }
                            }
                        }
                        .padding(.horizontal, 14)
                        .padding(.bottom, 12)
                    }
                }
            }
        }
    }
}

// MARK: 2. Drawing Pane (Default Tool, Default Color, Circle Gesture, Live Retina Cursor Stage)

private struct DrawingPane: View {
    @ObservedObject var model: SettingsModel

    private static let toolOptions: [(Tool?, String, String, String)] = [
        (nil, "Cursor", "cursorarrow", "V"),
        (.pen, "Pen", "pencil.tip", "P"),
        (.box, "Box", "rectangle", "B"),
        (.ellipse, "Ellipse", "circle", "O"),
        (.arrow, "Arrow", "arrow.up.right", "A"),
        (.blur, "Blur", "eye.slash", "X"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SettingsCard {
                VStack(alignment: .leading, spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Default Tool at Session Start")
                            .font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                        Text("Start sessions in Cursor mode (click-through) or ready to draw immediately")
                            .font(.system(size: 11.5)).foregroundStyle(SUI.dim)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    HStack(spacing: 6) {
                        ForEach(Self.toolOptions, id: \.1) { tool, label, symbol, key in
                            let on = model.defaultTool == tool
                            Button {
                                model.setDefaultTool(tool)
                            } label: {
                                VStack(spacing: 3.5) {
                                    Image(systemName: symbol)
                                        .font(.system(size: 14, weight: on ? .semibold : .regular))
                                        .foregroundStyle(on ? .white : .white.opacity(0.68))
                                        .frame(height: 17)
                                    Text(label)
                                        .font(.system(size: 10.5, weight: on ? .semibold : .medium))
                                        .foregroundStyle(on ? .white : .white.opacity(0.62))
                                }
                                .frame(maxWidth: .infinity)
                                .frame(height: 46)
                                .overlay(alignment: .topTrailing) {
                                    Text(key)
                                        .font(SUI.mono(8.5, .medium))
                                        .foregroundStyle(on ? .white.opacity(0.65) : .white.opacity(0.28))
                                        .padding(.top, 4).padding(.trailing, 6)
                                }
                                .background(FlatTileBackground(selected: on, radius: 8))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(.horizontal, 14).padding(.vertical, 12)

                CardDivider()

                // Default Ink Color
                HStack(spacing: 14) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Default Ink Color")
                            .font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                        Text("Applied at session start (press 1–6 while drawing)")
                            .font(.system(size: 11.5)).foregroundStyle(SUI.dim)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    HStack(spacing: 7) {
                        ForEach(Array(InkColor.allCases.enumerated()), id: \.element) { idx, c in
                            let on = model.defaultInkColor == c
                            Button {
                                model.setDefaultInkColor(c)
                            } label: {
                                ZStack {
                                    Circle()
                                        .fill(Color(nsColor: c.ns))
                                        .frame(width: 22, height: 22)
                                        .overlay(
                                            Circle().strokeBorder(
                                                c == .black ? .white.opacity(0.40) : .white.opacity(0.16),
                                                lineWidth: 0.75
                                            )
                                        )
                                    if on {
                                        Circle()
                                            .strokeBorder(.white.opacity(0.92), lineWidth: 1.75)
                                            .frame(width: 29, height: 29)
                                    }
                                }
                                .frame(width: 30, height: 30)
                                .contentShape(Circle())
                            }
                            .buttonStyle(.plain)
                            .help("\(c.name.capitalized) (\(idx + 1))")
                        }
                    }
                }
                .padding(.horizontal, 14).padding(.vertical, 11)

                CardDivider()

                ToggleRow(
                    title: "Circle gesture in cursor mode",
                    detail: "Loop the mouse around something without clicking to automatically create an ellipse mark.",
                    isOn: Binding(get: { model.circleGesture }, set: { model.setCircleGesture($0) })
                )
            }

            // Live Retina Cursor Preview Stage
            SettingsCard {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 7) {
                                Text("Live Cursor Preview")
                                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                                Text("2× Retina")
                                    .font(SUI.mono(9.5, .medium))
                                    .foregroundStyle(SUI.soft)
                                    .padding(.horizontal, 6).padding(.vertical, 2)
                                    .background(Capsule().fill(.white.opacity(0.08)))
                            }
                            Text(model.isPreview
                                 ? "Double-contrast halos stay sharp on light pages, dark IDEs, and photos"
                                 : "Hover the canvas below to test the live pointer; click a tool to inspect")
                                .font(.system(size: 11.5)).foregroundStyle(SUI.dim)
                        }
                        Spacer()
                        let hs = Cursors.hotSpot(for: model.previewTool)
                        Text("Hot spot \(Int(hs.x)),\(Int(hs.y))")
                            .font(SUI.mono(10.5, .medium))
                            .foregroundStyle(SUI.soft)
                            .padding(.horizontal, 8).padding(.vertical, 3.5)
                            .background(Capsule().fill(.white.opacity(0.06)))
                    }

                    // 3-surface split backdrop: Light Page · Dark IDE · 2× Loupe
                    let curImg = Cursors.cursor(model.previewTool, model.previewColor).image
                    let hot = Cursors.hotSpot(for: model.previewTool)
                    HStack(spacing: 1) {
                        CursorSurfaceTile(
                            label: "Light UI",
                            img: curImg,
                            hot: hot,
                            lightText: false,
                            background: AnyView(
                                ZStack {
                                    Color(white: 0.96)
                                    VStack(alignment: .leading, spacing: 6) {
                                        RoundedRectangle(cornerRadius: 2).fill(Color.black.opacity(0.10)).frame(width: 82, height: 5)
                                        RoundedRectangle(cornerRadius: 2).fill(Color.black.opacity(0.06)).frame(width: 110, height: 4.5)
                                        RoundedRectangle(cornerRadius: 2).fill(Color.black.opacity(0.06)).frame(width: 68, height: 4.5)
                                    }
                                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                                    .padding(12)
                                }
                            )
                        )
                        CursorSurfaceTile(
                            label: "Dark IDE",
                            img: curImg,
                            hot: hot,
                            lightText: true,
                            background: AnyView(
                                ZStack {
                                    Color(red: 0.11, green: 0.12, blue: 0.14)
                                    VStack(alignment: .leading, spacing: 6) {
                                        RoundedRectangle(cornerRadius: 2).fill(Color.white.opacity(0.14)).frame(width: 74, height: 5)
                                        RoundedRectangle(cornerRadius: 2).fill(Color.white.opacity(0.08)).frame(width: 105, height: 4.5)
                                        RoundedRectangle(cornerRadius: 2).fill(Color.white.opacity(0.10)).frame(width: 62, height: 4.5)
                                    }
                                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                                    .padding(12)
                                }
                            )
                        )
                        CursorSurfaceTile(
                            label: "2× Loupe",
                            img: curImg,
                            hot: hot,
                            zoom: 1.75,
                            showCrosshairGuides: true,
                            lightText: true,
                            background: AnyView(Color(red: 0.16, green: 0.18, blue: 0.22))
                        )
                    }
                    .frame(height: 102)
                    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(.white.opacity(0.10), lineWidth: 1))
                    .overlay {
                        if !BarView.flatBackground {
                            LiveCursorHoverArea(tool: model.previewTool, color: model.previewColor)
                        }
                    }

                    // All 5 tool cursors in a quick interactive strip
                    HStack(spacing: 6) {
                        ForEach(Tool.allCases, id: \.self) { t in
                            let selected = model.previewTool == t
                            Button {
                                model.previewTool = t
                            } label: {
                                HStack(spacing: 5) {
                                    Image(nsImage: Cursors.cursor(t, model.previewColor).image)
                                        .resizable()
                                        .interpolation(.high)
                                        .frame(width: 24, height: 24)
                                    Text(t.rawValue.capitalized)
                                        .font(.system(size: 11, weight: selected ? .semibold : .medium))
                                        .foregroundStyle(selected ? .white : SUI.soft)
                                }
                                .frame(maxWidth: .infinity)
                                .frame(height: 32)
                                .background(FlatTileBackground(selected: selected, radius: 8))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(.horizontal, 14).padding(.vertical, 12)
            }
        }
    }
}

private struct CursorSurfaceTile: View {
    let label: String
    let img: NSImage
    let hot: CGPoint
    var zoom: CGFloat = 1.0
    var showCrosshairGuides = false
    let lightText: Bool
    let background: AnyView

    var body: some View {
        ZStack {
            background
            let w = Cursors.canvasSize.width * zoom
            let h = Cursors.canvasSize.height * zoom
            ZStack {
                if showCrosshairGuides {
                    let hx = (hot.x - Cursors.canvasSize.width / 2) * zoom
                    let hy = (hot.y - Cursors.canvasSize.height / 2) * zoom
                    Rectangle().fill(SUI.go.opacity(0.45)).frame(width: 1, height: 84).offset(x: hx)
                    Rectangle().fill(SUI.go.opacity(0.45)).frame(width: 110, height: 1).offset(y: hy)
                }
                Image(nsImage: img)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: w, height: h)
            }
            .offset(y: -4)

            Text(label)
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(lightText ? .white.opacity(0.78) : .black.opacity(0.58))
                .padding(.horizontal, 6.5).padding(.vertical, 2)
                .background(Capsule().fill(lightText ? Color.black.opacity(0.40) : Color.white.opacity(0.76)))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                .padding(6)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Applies the actual NSCursor while the pointer hovers over the live preview canvas.
private struct LiveCursorHoverArea: NSViewRepresentable {
    let tool: Tool
    let color: InkColor

    func makeNSView(context: Context) -> CursorZoneView {
        let v = CursorZoneView()
        v.cursorToShow = Cursors.cursor(tool, color)
        return v
    }

    func updateNSView(_ v: CursorZoneView, context: Context) {
        v.cursorToShow = Cursors.cursor(tool, color)
        v.window?.invalidateCursorRects(for: v)
    }

    final class CursorZoneView: NSView {
        var cursorToShow: NSCursor = .arrow
        override func resetCursorRects() {
            addCursorRect(bounds, cursor: cursorToShow)
        }
    }
}

// MARK: 3. Dictation Pane

private struct DictationPane: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SettingsCard {
                HStack(spacing: 14) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Dictation Language")
                            .font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                        Text("On-device SpeechAnalyzer / DictationTranscriber model. Audio never leaves your Mac.")
                            .font(.system(size: 11.5)).foregroundStyle(SUI.dim)
                    }
                    Spacer(minLength: 10)
                    if model.loadingLocales && model.supportedLocales.isEmpty {
                        ProgressView().controlSize(.small)
                    } else if BarView.flatBackground {
                        HStack(spacing: 8) {
                            Text(model.selectedLocale.isEmpty ? "Automatic (English · en-US)" : displayLabel(for: model.selectedLocale))
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(.white.opacity(0.90))
                                .lineLimit(1)
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.system(size: 9.5, weight: .semibold))
                                .foregroundStyle(SUI.dim)
                        }
                        .padding(.horizontal, 11).frame(height: 28)
                        .background(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(.white.opacity(0.07))
                                .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(.white.opacity(0.12), lineWidth: 1))
                        )
                    } else {
                        Picker("", selection: Binding(get: { model.selectedLocale }, set: { model.setDictationLocale($0) })) {
                            Text("Automatic (\(model.automaticLocaleLabel))").tag("")
                            Divider()
                            ForEach(model.supportedLocales) { opt in
                                if let native = opt.nativeName {
                                    Text("\(opt.name) — \(native) (\(opt.id))").tag(opt.id)
                                } else {
                                    Text("\(opt.name) (\(opt.id))").tag(opt.id)
                                }
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(width: 235)
                    }
                }
                .padding(14)

                CardDivider()

                VStack(alignment: .leading, spacing: 0) {
                    ToggleRow(
                        title: "Feed on-screen terms to dictation",
                        detail: "Reads button labels, titles, and UI words from the target app via Accessibility to boost accuracy for technical terms.",
                        isOn: Binding(get: { model.axVocabulary }, set: { model.setAXVocabulary($0) })
                    )
                    if model.axVocabulary && model.accessibilityStatus != .granted {
                        HStack(spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 11))
                                .foregroundStyle(SUI.amber)
                            Text("Accessibility permission is required to read on-screen labels.")
                                .font(.system(size: 11))
                                .foregroundStyle(.white.opacity(0.72))
                            Spacer()
                            FlatButton(title: "Grant Access", compact: true) { model.requestAccessibility() }
                        }
                        .padding(.horizontal, 14)
                        .padding(.bottom, 12)
                    }
                }
            }

            // Voice Commands Reference
            SettingsCard {
                VStack(alignment: .leading, spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Voice Commands")
                            .font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                        Text("Say a short standalone command during a session; phrases inside normal sentences are kept as narration.")
                            .font(.system(size: 11.5)).foregroundStyle(SUI.dim)
                    }

                    VStack(spacing: 6) {
                        VoiceCommandRow(
                            symbol: "camera.aperture",
                            action: "Take screenshot",
                            phrases: ["\"take screenshot\"", "\"snapshot\"", "\"capture\""],
                            note: "Captures current marks now"
                        )
                        VoiceCommandRow(
                            symbol: "arrow.uturn.backward",
                            action: "Undo",
                            phrases: ["\"undo\"", "\"delete that\"", "\"remove that\""],
                            note: "Undoes last mark or shot"
                        )
                        VoiceCommandRow(
                            symbol: "checkmark.circle",
                            action: "Finish",
                            phrases: ["\"finish\"", "\"done\"", "\"stop recording\""],
                            note: "Ends session & saves"
                        )
                    }

                    HStack(spacing: 6) {
                        Image(systemName: "globe")
                            .font(.system(size: 10.5))
                            .foregroundStyle(SUI.dim)
                        Text("Short lead-ins like \"okay undo\" or \"please finish\" and Turkish equivalents are also recognized.")
                            .font(.system(size: 11))
                            .foregroundStyle(SUI.dim)
                    }
                    .padding(.top, 2)
                }
                .padding(14)
            }
        }
    }

    private func displayLabel(for id: String) -> String {
        model.supportedLocales.first(where: { $0.id == id })?.name ?? id
    }
}

private struct VoiceCommandRow: View {
    let symbol: String
    let action: String
    let phrases: [String]
    let note: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(.white.opacity(0.82))
                .frame(width: 28, height: 28)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(.white.opacity(0.06)))

            VStack(alignment: .leading, spacing: 2) {
                Text(action)
                    .font(.system(size: 12.5, weight: .semibold)).foregroundStyle(.white)
                Text(note)
                    .font(.system(size: 10.5)).foregroundStyle(SUI.dim)
                    .lineLimit(1)
            }
            .frame(width: 152, alignment: .leading)

            HStack(spacing: 5) {
                ForEach(phrases, id: \.self) { p in
                    Text(p)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.85))
                        .fixedSize(horizontal: true, vertical: false)
                        .padding(.horizontal, 8).padding(.vertical, 3.5)
                        .background(
                            Capsule()
                                .fill(.white.opacity(0.06))
                                .overlay(Capsule().strokeBorder(.white.opacity(0.09), lineWidth: 0.75))
                        )
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10).padding(.vertical, 7.5)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(.white.opacity(0.03)))
    }
}

// MARK: 4. Shortcuts Pane

private struct ShortcutsPane: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Radial Menu Card
            SettingsCard {
                HStack(spacing: 15) {
                    RadialMiniDiagram()
                        .frame(width: 74, height: 74)

                    VStack(alignment: .leading, spacing: 5) {
                        HStack(spacing: 8) {
                            Text("Radial Menu")
                                .font(.system(size: 13.5, weight: .semibold)).foregroundStyle(.white)
                            HStack(spacing: 3) { Keycap("⌥"); Keycap("⇧"); Keycap("S") }
                        }
                        Text("Opens a dial at your pointer during a session from any app. Click Cursor, Pen, Box, Arrow, Finish, Undo, or Blur — or click the center to take a screenshot.")
                            .font(.system(size: 11.5))
                            .foregroundStyle(SUI.soft)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: 12) {
                            Label("Center = Screenshot", systemImage: "camera.aperture")
                            Label("Esc / ⌥⇧S / click outside closes", systemImage: "xmark.circle")
                        }
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(SUI.dim)
                    }
                }
                .padding(13)
            }

            // Two-column shortcut groups
            HStack(alignment: .top, spacing: 12) {
                VStack(spacing: 12) {
                    ShortcutGroupCard(title: "Session & Target Picker", rows: [
                        (["⌥", "⇧", "R"], "Start / finish a session"),
                        (["1", "2", "3"], "Window / Area / Screen mode"),
                        (["⏎"], "Confirm screen or reuse last area"),
                        (["Esc"], "Cancel picker"),
                    ])

                    ShortcutGroupCard(title: "Global During Session (Any App)", rows: [
                        (["⌥", "⇧", "V"], "Cursor (pass clicks through)"),
                        (["⌥", "⇧", "P B O A X"], "Drawing tools"),
                        (["⌥", "⇧", "S"], "Open radial menu at pointer"),
                        (["⌥", "⇧", "Z"], "Undo last action"),
                    ])
                }

                VStack(spacing: 12) {
                    ShortcutGroupCard(title: "Drawing & Editing Marks", rows: [
                        (["P B O A X"], "Pen, Box, Ellipse, Arrow, Blur"),
                        (["1–6"], "Switch ink color"),
                        (["Click mark"], "Select to move or resize"),
                        (["⌫"], "Delete selected mark"),
                        (["Space", "T", "⏎"], "Take screenshot"),
                        (["⌘", "Z"], "Undo last mark or edit"),
                        (["Esc"], "Deselect mark, then cursor"),
                        (["Circle"], "Loop mouse in cursor mode"),
                    ])
                }
            }
        }
    }
}

private struct ShortcutGroupCard: View {
    let title: String
    let rows: [([String], String)]

    var body: some View {
        SettingsCard {
            VStack(alignment: .leading, spacing: 0) {
                Text(title)
                    .font(.system(size: 10.5, weight: .semibold))
                    .textCase(.uppercase)
                    .tracking(0.5)
                    .foregroundStyle(SUI.dim)
                    .padding(.horizontal, 12)
                    .padding(.top, 9)
                    .padding(.bottom, 7)

                CardDivider()

                VStack(spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { idx, row in
                        HStack(spacing: 8) {
                            Text(row.1)
                                .font(.system(size: 11.5, weight: .regular))
                                .foregroundStyle(.white.opacity(0.84))
                                .lineLimit(1)
                                .minimumScaleFactor(0.9)
                            Spacer(minLength: 4)
                            HStack(spacing: 3) {
                                ForEach(Array(row.0.enumerated()), id: \.offset) { _, k in
                                    Keycap(k)
                                }
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        if idx < rows.count - 1 {
                            Rectangle().fill(.white.opacity(0.05)).frame(height: 1).padding(.leading, 12)
                        }
                    }
                }
                .padding(.bottom, 4)
            }
        }
    }
}

/// Flat monochrome schematic of Recper's 7-sector Radial Menu.
private struct RadialMiniDiagram: View {
    private static let symbols = ["cursorarrow", "pencil.tip", "rectangle", "arrow.up.right", "checkmark", "arrow.uturn.backward", "eye.slash"]

    var body: some View {
        ZStack {
            Circle()
                .fill(Color.white.opacity(0.05))
                .overlay(Circle().strokeBorder(Color.white.opacity(0.14), lineWidth: 1))

            ForEach(0..<Self.symbols.count, id: \.self) { i in
                let a = Double(i) * 360 / Double(Self.symbols.count) - 90
                let rad = a * .pi / 180
                Image(systemName: Self.symbols[i])
                    .font(.system(size: 8.5, weight: .medium))
                    .foregroundStyle(i == 0 ? .white : .white.opacity(0.55))
                    .offset(x: 24 * CGFloat(cos(rad)), y: 24 * CGFloat(sin(rad)))
            }

            Circle()
                .fill(Color.white.opacity(0.10))
                .frame(width: 24, height: 24)
                .overlay(Circle().strokeBorder(Color.white.opacity(0.24), lineWidth: 1))
                .overlay(Circle().fill(.white).frame(width: 8, height: 8))
        }
    }
}

// MARK: 5. Permissions Pane

private struct PermissionsPane: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SettingsCard {
                PermissionRow(
                    symbol: "mic.fill",
                    title: "Microphone",
                    detail: "Live on-device dictation while you speak. Audio is never recorded or saved.",
                    state: model.micStatus,
                    optional: false,
                    actionTitle: model.micStatus == .notDetermined ? "Request Access" : "Open Settings"
                ) { model.requestMicrophone() }

                CardDivider()

                PermissionRow(
                    symbol: "waveform.and.mic",
                    title: "Speech Recognition",
                    detail: "Apple SpeechAnalyzer on-device transcription without sending audio off-device.",
                    state: model.speechStatus,
                    optional: false,
                    actionTitle: model.speechStatus == .notDetermined ? "Request Access" : "Open Settings"
                ) { model.requestSpeech() }

                CardDivider()

                PermissionRow(
                    symbol: "rectangle.dashed.badge.record",
                    title: "Screen Recording",
                    detail: "Captures your chosen window, area, or screen with drawn marks and permanent blur.",
                    state: model.screenStatus,
                    optional: false,
                    actionTitle: model.screenStatus == .granted ? "Open Settings" : "Allow & Open Settings"
                ) { model.requestScreenRecording() }

                CardDivider()

                PermissionRow(
                    symbol: "accessibility",
                    title: "Accessibility",
                    detail: "Optional: identifies the UI element under each mark (e.g. AXButton \"Save\") and feeds on-screen terms to dictation.",
                    state: model.accessibilityStatus,
                    optional: true,
                    actionTitle: model.accessibilityStatus == .granted ? "Open Settings" : "Grant Access"
                ) { model.requestAccessibility() }
            }

            // Helpful macOS Screen Recording relaunch callout
            HStack(spacing: 10) {
                Image(systemName: "info.circle")
                    .font(.system(size: 13))
                    .foregroundStyle(SUI.soft)
                Text("After enabling Screen Recording in System Settings, macOS requires quitting and reopening Recper once for screen capture to take effect.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(SUI.soft)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(SUI.cardFill)
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(SUI.cardBorder, lineWidth: 1))
            )
        }
    }
}

private struct PermissionRow: View {
    let symbol: String
    let title: String
    let detail: String
    let state: PermState
    let optional: Bool
    let actionTitle: String
    let action: () -> Void

    var body: some View {
        let granted = state == .granted
        let statusColor: Color = granted ? SUI.go : (optional ? SUI.dim : SUI.amber)
        HStack(spacing: 13) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.white.opacity(0.82))
                .frame(width: 32, height: 32)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(.white.opacity(0.06))
                        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.white.opacity(0.08), lineWidth: 1))
                )

            VStack(alignment: .leading, spacing: 2.5) {
                HStack(spacing: 7) {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                    if optional {
                        Text("Optional")
                            .font(.system(size: 9.5, weight: .medium))
                            .foregroundStyle(SUI.dim)
                            .padding(.horizontal, 6).padding(.vertical, 1.5)
                            .background(Capsule().fill(.white.opacity(0.07)))
                    }
                    StatusBadge(text: granted ? "Granted" : (optional ? "Off" : state.label), dotColor: statusColor)
                }
                Text(detail)
                    .font(.system(size: 11.5))
                    .foregroundStyle(SUI.dim)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            FlatButton(title: actionTitle, primary: !granted && !optional, compact: true, action: action)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }
}

// MARK: 6. Agents & MCP Pane

private struct MCPPane: View {
    @ObservedObject var model: SettingsModel

    private static let tools: [(String, String, String)] = [
        ("doc.text.image", "get_feedback", "Returns latest feedback checklist, mark summaries, and screenshots."),
        ("list.bullet.rectangle", "list_sessions", "Lists recent sessions with duration, progress, and first sentence."),
        ("checkmark.square", "mark_done", "Checks off or unchecks an item directly in feedback.md."),
        ("bell.badge", "request_feedback", "Opens Recper on your screen with a question and waits for Finish."),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Claude Code one-liner
            SettingsCard {
                VStack(alignment: .leading, spacing: 9) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Claude Code")
                                .font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                            Text("Run this in your terminal to register Recper's built-in stdio MCP server (Recper --mcp)")
                                .font(.system(size: 11.5)).foregroundStyle(SUI.dim)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer()
                        CopyButton(copied: model.copiedID == "claude") {
                            model.copy(model.claudeCommand, id: "claude")
                        }
                    }

                    Text(model.claudeCommand)
                        .font(SUI.mono(11.5, .regular))
                        .foregroundStyle(.white.opacity(0.92))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 12).padding(.vertical, 9)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(Color.black.opacity(0.32))
                                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.white.opacity(0.08), lineWidth: 1))
                        )
                }
                .padding(13)
            }

            // Generic JSON snippet
            SettingsCard {
                VStack(alignment: .leading, spacing: 9) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Other MCP Clients (Antigravity, Codex, Cursor, Claude Desktop)")
                                .font(.system(size: 12.5, weight: .semibold)).foregroundStyle(.white)
                            Text("Add this entry to your client's MCP server configuration")
                                .font(.system(size: 11.5)).foregroundStyle(SUI.dim)
                        }
                        Spacer()
                        CopyButton(copied: model.copiedID == "json") {
                            model.copy(model.mcpConfigJSON, id: "json")
                        }
                    }

                    Text(model.mcpConfigJSON)
                        .font(SUI.mono(10.5, .regular))
                        .foregroundStyle(.white.opacity(0.84))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(Color.black.opacity(0.28))
                                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.white.opacity(0.08), lineWidth: 1))
                        )
                }
                .padding(13)
            }

            // MCP Tools 2×2 grid
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                ForEach(Self.tools, id: \.1) { symbol, name, desc in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: symbol)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.white.opacity(0.80))
                            .frame(width: 26, height: 26)
                            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(.white.opacity(0.06)))
                        VStack(alignment: .leading, spacing: 2.5) {
                            Text(name)
                                .font(SUI.mono(11.5, .semibold))
                                .foregroundStyle(.white)
                            Text(desc)
                                .font(.system(size: 10.5))
                                .foregroundStyle(SUI.dim)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(11)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(SUI.cardFill)
                            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(SUI.cardBorder, lineWidth: 1))
                    )
                }
            }
        }
    }
}

// MARK: 7. Storage Pane

private struct StoragePane: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Metric tiles
            HStack(spacing: 10) {
                StatTile(symbol: "folder.fill", value: "\(model.sessionCount)", label: "Sessions")
                StatTile(symbol: "photo.stack.fill", value: "\(model.shotCount)", label: "Screenshots")
                StatTile(symbol: "internaldrive.fill", value: model.formattedDiskUsage, label: "Disk Usage")
            }

            // Sessions folder card
            SettingsCard {
                VStack(alignment: .leading, spacing: 11) {
                    HStack(spacing: 12) {
                        Image(systemName: "folder.badge.gearshape")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(.white.opacity(0.82))
                            .frame(width: 32, height: 32)
                            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.white.opacity(0.06)))

                        VStack(alignment: .leading, spacing: 2) {
                            Text("Sessions Folder")
                                .font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                            Text(model.sessionsDisplayPath)
                                .font(SUI.mono(11.5, .regular))
                                .foregroundStyle(SUI.soft)
                        }
                        Spacer()
                        FlatButton(title: "Open in Finder", symbol: "arrow.up.forward.square", primary: true) {
                            model.openSessionsFolder()
                        }
                    }

                    Text("Each session saves feedback.md, session.json, and shots/*.png with marks and blur burned in. Audio and video are never recorded.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(SUI.dim)
                }
                .padding(14)
            }

            // Cleanup card (always asks confirmation)
            SettingsCard {
                HStack(spacing: 14) {
                    VStack(alignment: .leading, spacing: 2.5) {
                        Text("Clean Up Sessions")
                            .font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                        Text(model.storageNotice ?? "Move all saved feedback sessions to the Trash to free disk space. You will be asked to confirm first.")
                            .font(.system(size: 11.5))
                            .foregroundStyle(model.storageNotice != nil ? SUI.soft : SUI.dim)
                    }
                    Spacer()
                    Button { model.confirmAndClearSessions() } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "trash").font(.system(size: 11, weight: .medium))
                            Text("Clear All Sessions…").font(.system(size: 12, weight: .medium))
                        }
                        .foregroundStyle(model.sessionCount > 0 ? SUI.coral : SUI.dim)
                        .padding(.horizontal, 12).frame(height: 29)
                        .background(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(model.sessionCount > 0 ? SUI.coral.opacity(0.10) : .white.opacity(0.04))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                                        .strokeBorder(model.sessionCount > 0 ? SUI.coral.opacity(0.28) : .white.opacity(0.08), lineWidth: 1)
                                )
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(model.sessionCount == 0)
                }
                .padding(14)
            }
        }
    }
}

private struct StatTile: View {
    let symbol: String, value: String, label: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(SUI.soft)
            VStack(alignment: .leading, spacing: 2) {
                Text(value)
                    .font(.system(size: 20, weight: .semibold).monospacedDigit())
                    .tracking(-0.3)
                    .foregroundStyle(.white)
                Text(label)
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(SUI.dim)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(SUI.cardFill)
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(SUI.cardBorder, lineWidth: 1))
        )
    }
}

// MARK: 8. About Pane

private struct AboutPane: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SettingsCard {
                HStack(spacing: 16) {
                    RecperMark(size: 56)

                    VStack(alignment: .leading, spacing: 5) {
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text("recper")
                                .font(.system(size: 22, weight: .bold))
                                .tracking(-0.5)
                                .foregroundStyle(.white)
                            Text("Version \(model.appVersion) (\(model.appBuild))")
                                .font(SUI.mono(11, .medium))
                                .foregroundStyle(SUI.soft)
                                .padding(.horizontal, 8).padding(.vertical, 2.5)
                                .background(Capsule().fill(.white.opacity(0.07)))
                        }
                        Text("Talk and draw on your screen; your coding agent gets a clean, timestamped checklist with annotated screenshots — via clipboard or over MCP.")
                            .font(.system(size: 12.5))
                            .foregroundStyle(SUI.soft)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(16)
            }

            HStack(spacing: 10) {
                PrivacyPillar(symbol: "cpu", title: "100% On-Device", detail: "Apple SpeechAnalyzer transcribes locally.")
                PrivacyPillar(symbol: "film.stack", title: "No Video or Audio", detail: "Only Markdown, JSON, and annotated PNGs.")
                PrivacyPillar(symbol: "eye.slash.fill", title: "Permanent Blur", detail: "Redacted regions are pixelated before saving.")
            }

            SettingsCard {
                VStack(spacing: 0) {
                    MetaRow(label: "Platform", value: "macOS 26+ · Apple Silicon")
                    CardDivider()
                    MetaRow(label: "Privacy", value: "Zero network requests · zero telemetry")
                    CardDivider()
                    MetaRow(label: "Interface", value: "Menu-bar utility (LSUIElement) · Local MCP server")
                    CardDivider()
                    MetaRow(label: "License", value: "MIT License")
                }
            }
        }
    }
}

private struct PrivacyPillar: View {
    let symbol: String, title: String, detail: String
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 13.5, weight: .medium))
                .foregroundStyle(.white.opacity(0.78))
            Text(title)
                .font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
            Text(detail)
                .font(.system(size: 11)).foregroundStyle(SUI.dim)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(13)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(SUI.cardFill)
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(SUI.cardBorder, lineWidth: 1))
        )
    }
}

private struct MetaRow: View {
    let label: String, value: String
    var body: some View {
        HStack {
            Text(label).font(.system(size: 12, weight: .regular)).foregroundStyle(SUI.dim)
            Spacer()
            Text(value).font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(0.86))
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }
}

// MARK: Reusable Flat Visual Primitives

/// The recper logo: a rounded tile with an inward-fading aurora rim, a white ring and a green dot.
/// `solid` gives the tile an opaque dark fill (for places without a dark background, like the README).
struct RecperMark: View {
    let size: CGFloat
    var solid = false
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.25, style: .continuous)
        ZStack {
            if solid {
                shape.fill(LinearGradient(colors: [Color(white: 0.16), Color(white: 0.07)], startPoint: .top, endPoint: .bottom))
            } else {
                shape.fill(Color.white.opacity(0.08))
            }
            // Aurora rim that fades inward: a blurred band clipped to the tile (so it only bleeds inside) under a thin crisp edge.
            shape.strokeBorder(Aurora.conic, lineWidth: size * 0.16)
                .blur(radius: size * 0.09)
                .clipShape(shape)
                .opacity(0.45)
            shape.strokeBorder(Aurora.conic, lineWidth: max(1, size * 0.012)).opacity(0.65)
            Circle()
                .strokeBorder(.white.opacity(0.82), lineWidth: max(1.4, size * 0.055))
                .frame(width: size * 0.56, height: size * 0.56)
            Circle()
                .fill(SUI.go)
                .frame(width: size * 0.26, height: size * 0.26)
        }
        .frame(width: size, height: size)
    }
}

private struct SidebarRow: View {
    let section: SettingsSection
    let on: Bool
    let badge: String?
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: section.symbol)
                    .font(.system(size: 13, weight: on ? .semibold : .regular))
                    .foregroundStyle(on ? .white : .white.opacity(hover ? 0.88 : 0.60))
                    .frame(width: 18)

                Text(section.title)
                    .font(.system(size: 12.5, weight: on ? .semibold : .regular))
                    .foregroundStyle(on ? .white : .white.opacity(hover ? 0.90 : 0.70))

                Spacer(minLength: 4)

                if let badge {
                    Text(badge)
                        .font(SUI.mono(9.5, .bold))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 5.5).frame(minWidth: 16, minHeight: 16)
                        .background(Capsule().fill(SUI.amber))
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(shape.fill(on ? Color.white.opacity(0.11) : Color.white.opacity(hover ? 0.05 : 0)))
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

private struct FlatTileBackground: View {
    let selected: Bool
    let radius: CGFloat

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        shape
            .fill(selected ? Color.white.opacity(0.12) : Color.white.opacity(0.03))
            .overlay(
                shape.strokeBorder(selected ? Color.white.opacity(0.26) : Color.white.opacity(0.075), lineWidth: 1)
            )
    }
}

private struct SettingsCard<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        VStack(alignment: .leading, spacing: 0, content: content)
            .background(shape.fill(SUI.cardFill))
            .overlay(shape.strokeBorder(SUI.cardBorder, lineWidth: 1))
            .clipShape(shape)
    }
}

private struct CardDivider: View {
    var body: some View {
        Rectangle().fill(SUI.hair).frame(height: 1).padding(.leading, 14)
    }
}

private struct ToggleRow: View {
    let title: String
    let detail: String
    @Binding var isOn: Bool
    var disabled = false

    var body: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(disabled ? SUI.dim : .white)
                Text(detail)
                    .font(.system(size: 11.5))
                    .foregroundStyle(SUI.dim)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 10)
            FlatSwitch(isOn: $isOn, disabled: disabled)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .opacity(disabled ? 0.6 : 1)
    }
}

/// Calm flat capsule toggle with green accent tint and zero glow.
private struct FlatSwitch: View {
    @Binding var isOn: Bool
    var disabled = false

    var body: some View {
        Button {
            guard !disabled else { return }
            withAnimation(.easeOut(duration: 0.16)) { isOn.toggle() }
        } label: {
            ZStack(alignment: isOn ? .trailing : .leading) {
                Capsule()
                    .fill(isOn ? SUI.go : Color.white.opacity(0.16))
                    .frame(width: 38, height: 21)

                Circle()
                    .fill(.white)
                    .frame(width: 17, height: 17)
                    .padding(2)
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .accessibilityAddTraits(.isToggle)
    }
}

/// Flat dark-track slider with zero glow.
private struct FlatSlider: View {
    @Binding var value: Double
    var disabled = false

    var body: some View {
        GeometryReader { g in
            let w = max(1, g.size.width)
            let clamped = min(max(value, 0), 1)
            let knob: CGFloat = 14
            let usable = max(1, w - knob)
            let x = usable * CGFloat(clamped)

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.white.opacity(0.12))
                    .frame(height: 4)
                Capsule()
                    .fill(disabled ? Color.white.opacity(0.25) : SUI.go)
                    .frame(width: max(4, x + knob / 2), height: 4)
                Circle()
                    .fill(.white)
                    .frame(width: knob, height: knob)
                    .overlay(Circle().strokeBorder(.black.opacity(0.22), lineWidth: 0.5))
                    .offset(x: x)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        guard !disabled else { return }
                        let pct = (drag.location.x - knob / 2) / usable
                        value = Double(min(max(pct, 0), 1))
                    }
            )
        }
        .frame(height: 22)
    }
}

private struct FlatButton: View {
    let title: String
    var symbol: String? = nil
    var primary = false
    var compact = false
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 7, style: .continuous)
        Button(action: action) {
            HStack(spacing: 5) {
                if let symbol {
                    Image(systemName: symbol).font(.system(size: compact ? 10 : 11, weight: .medium))
                }
                Text(title).font(.system(size: compact ? 11.5 : 12, weight: .medium))
            }
            .foregroundStyle(primary ? Color(white: 0.08) : .white.opacity(hover ? 1 : 0.88))
            .padding(.horizontal, compact ? 10 : 12)
            .frame(height: compact ? 27 : 29)
            .background {
                if primary {
                    shape.fill(Color.white.opacity(hover ? 1.0 : 0.92))
                } else {
                    shape.fill(.white.opacity(hover ? 0.13 : 0.075))
                        .overlay(shape.strokeBorder(.white.opacity(hover ? 0.20 : 0.12), lineWidth: 1))
                }
            }
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

private struct CopyButton: View {
    let copied: Bool
    let action: () -> Void

    var body: some View {
        FlatButton(
            title: copied ? "Copied" : "Copy",
            symbol: copied ? "checkmark" : "doc.on.doc",
            primary: copied,
            compact: true,
            action: action
        )
    }
}

private struct StatusBadge: View {
    let text: String
    let dotColor: Color

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(dotColor)
                .frame(width: 6, height: 6)
            Text(text)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(.white.opacity(0.75))
        }
        .padding(.horizontal, 7).padding(.vertical, 2)
        .background(Capsule().fill(.white.opacity(0.06)))
    }
}

private struct Keycap: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(SUI.mono(10.5, .medium))
            .foregroundStyle(.white.opacity(0.86))
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, text.count > 1 ? 6 : 5)
            .frame(minWidth: 21).frame(height: 20)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color.white.opacity(0.08))
                    .overlay(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.14), lineWidth: 0.75)
                    )
            )
    }
}
