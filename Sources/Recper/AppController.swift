import AppKit
import Carbon.HIToolbox
import RecperCore

/// State machine: idle → choosing (mode) → session (target) → idle.
@MainActor
final class AppController: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    /// Tool hotkeys registered for the duration of a session.
    private var sessionKeys: [UInt32] = []
    /// Session mouse monitors (cursor-mode mark hover/editing + circle gesture). Active only during `.session`.
    private var globalMouseMonitor: Any?
    private var localMouseMonitor: Any?
    private var circleDetector = CircleGestureDetector()
    private var isDraggingMark = false

    private let overlay = OverlayModel()
    private let bar = BarModel()
    private lazy var barPanel = BarPanel(model: bar)
    private var overlays: [(window: OverlayWindow, view: OverlayView)] = []

    private var windows: [WindowInfo] = []
    private var windowsAt = Date.distantPast
    private var tracker: Timer?
    /// Frontmost app before choosing began: focus returns to it once an area/screen is picked.
    private var previousApp: NSRunningApplication?
    /// The ongoing session (survives retargeting).
    private var recorder: Recorder?
    private var finishing = false

    private enum State { case idle, choosing, session }
    private var state = State.idle {
        didSet {
            updateStatusIcon()
            if state == .choosing { glow.show() } else { glow.hide() }
        }
    }
    private let glow = ScreenGlow()
    private var settingsWindow: SettingsWindow?
    private lazy var radial: RadialMenu = {
        let m = RadialMenu()
        m.onShutter = { [weak self] in self?.shutter() }
        m.items = [
            .init(symbol: "cursorarrow", title: "Cursor") { [weak self] in self?.setTool(nil) },
            .init(symbol: "pencil.tip", title: "Pen") { [weak self] in self?.setTool(.pen) },
            .init(symbol: "rectangle", title: "Box") { [weak self] in self?.setTool(.box) },
            .init(symbol: "arrow.up.right", title: "Arrow") { [weak self] in self?.setTool(.arrow) },
            .init(symbol: "checkmark", title: "Finish") { [weak self] in self?.finish() },
            .init(symbol: "arrow.uturn.backward", title: "Undo") { [weak self] in self?.undo() },
            .init(symbol: "eye.slash", title: "Blur") { [weak self] in self?.setTool(.blur) },
        ]
        return m
    }()

    private static let modeKey = "lastMode"
    private static let areaKey = "lastArea"

    func applicationDidFinishLaunching(_ n: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let b = statusItem.button {
            b.target = self
            b.action = #selector(statusClicked)
            b.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        updateStatusIcon()
        HotKeys.shared.register(kVK_ANSI_R) { [weak self] in self?.toggle() }   // ⌥⇧R

        bar.mode = AppSettings.defaultMode
        bar.color = AppSettings.defaultInkColor
        overlay.color = AppSettings.defaultInkColor
        bar.tool = AppSettings.defaultTool
        overlay.lastArea = UserDefaults.standard.string(forKey: Self.areaKey).map(NSRectFromString)
        bar.onMode = { [weak self] in self?.setMode($0) }
        bar.onCancel = { [weak self] in self?.cancel() }
        bar.onFinish = { [weak self] in self?.finish() }
        bar.onRetarget = { [weak self] in self?.retarget() }
        bar.onTool = { [weak self] in self?.setTool($0) }
        bar.onColor = { [weak self] in self?.setColor($0) }
        bar.onSnapshot = { [weak self] in self?.shutter() }
        bar.onUndo = { [weak self] in self?.undo() }
        bar.onDeleteShot = { [weak self] in self?.recorder?.deleteShot($0) }
        bar.onSize = { [weak self] in self?.barPanel.refit($0) }
        bar.onOpenShots = { [weak self] in
            guard let r = self?.recorder else { return }
            let urls = r.shots.compactMap { r.url(ofShot: $0.id) }
            guard !urls.isEmpty else { return }
            NSWorkspace.shared.open(urls, withApplicationAt: URL(fileURLWithPath: "/System/Applications/Preview.app"), configuration: NSWorkspace.OpenConfiguration())
        }
        bar.onOpenShot = { [weak self] id in
            if let u = self?.recorder?.url(ofShot: id) { NSWorkspace.shared.open(u) }
        }
        overlay.onChange = { [weak self] in self?.overlays.forEach { $0.view.refresh() } }
        overlay.strokes = { [weak self] in self?.recorder?.pending ?? [] }
        overlay.blurs = { [weak self] in self?.recorder?.blurs ?? [] }

        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.screensChanged() }
        }
    }

    // MARK: Menu bar

    private func updateStatusIcon() {
        let name = state == .idle ? "record.circle" : "record.circle.fill"
        let img = NSImage(systemSymbolName: name, accessibilityDescription: "recper")
        img?.isTemplate = state == .idle
        statusItem?.button?.image = state == .idle ? img : img?.withSymbolConfiguration(.init(paletteColors: [.systemRed]))
    }

    @objc private func statusClicked() {
        if NSApp.currentEvent?.type == .rightMouseUp || NSApp.currentEvent?.modifierFlags.contains(.option) == true {
            let menu = NSMenu()
            menu.addItem(withTitle: "Start  ⌥⇧R", action: #selector(menuStart), keyEquivalent: "").target = self
            menu.addItem(withTitle: "Sessions folder", action: #selector(openSessions), keyEquivalent: "").target = self
            let vocab = menu.addItem(withTitle: "Feed on-screen terms to dictation", action: #selector(toggleVocabulary), keyEquivalent: "")
            vocab.target = self
            vocab.state = AXVocabulary.enabled && AXVocabulary.trusted ? .on : .off
            vocab.toolTip = "Button and title names in the target app become dictation hints (requires Accessibility permission)."
            let auto = menu.addItem(withTitle: "Auto-capture at end of sentence", action: #selector(toggleAuto), keyEquivalent: "")
            auto.target = self
            auto.state = Recorder.autoCapture ? .on : .off
            let rev = menu.addItem(withTitle: "Review before sending", action: #selector(toggleReview), keyEquivalent: "")
            rev.target = self
            rev.state = ReviewModel.enabled ? .on : .off
            let snd = menu.addItem(withTitle: "Sounds", action: #selector(toggleSounds), keyEquivalent: "")
            snd.target = self
            snd.state = Sounds.enabled ? .on : .off
            menu.addItem(.separator())
            let settings = menu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
            settings.target = self
            menu.addItem(.separator())
            menu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
            statusItem.menu = menu
            statusItem.button?.performClick(nil)
            statusItem.menu = nil
        } else {
            toggle()
        }
    }

    /// `recper://start?mode=area&prompt=…`: an agent (MCP request_feedback) is asking for feedback.
    func application(_ application: NSApplication, open urls: [URL]) {
        // `recper://settings`: opens the Settings window.
        if urls.contains(where: { $0.scheme == "recper" && $0.host == "settings" }) { openSettings() }
        for url in urls where url.scheme == "recper" && url.host == "start" {
            let q = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            if let m = q.first(where: { $0.name == "mode" })?.value.flatMap(CaptureMode.init) { bar.mode = m }
            if state == .idle { startChoosing() }
            let prompt = q.first(where: { $0.name == "prompt" })?.value
            flash(prompt.map { "Agent asks: \($0)" } ?? "Agent wants feedback: pick a target, talk, draw, then Finish.", seconds: 15)
        }
    }

    @objc private func menuStart() { if state == .idle { startChoosing() } }

    @objc private func openSettings() {
        let win: SettingsWindow
        if let existing = settingsWindow {
            win = existing
        } else {
            let m = SettingsModel()
            m.onDefaultModeChanged = { [weak self] mode in
                guard let self, self.state == .idle else { return }
                self.bar.mode = mode
            }
            win = SettingsWindow(model: m)
            settingsWindow = win
        }
        win.show()
    }

    @objc private func toggleAuto() { Recorder.autoCapture.toggle(); settingsWindow?.model.syncFromDefaults() }
    @objc private func toggleSounds() { Sounds.enabled.toggle(); if Sounds.enabled { Sfx.done() }; settingsWindow?.model.syncFromDefaults() }
    @objc private func toggleReview() { ReviewModel.enabled.toggle(); settingsWindow?.model.syncFromDefaults() }

    @objc private func toggleVocabulary() {
        if !AXVocabulary.trusted { AXVocabulary.enabled = true; AXVocabulary.requestTrust() }
        else { AXVocabulary.enabled.toggle() }
        settingsWindow?.model.syncFromDefaults()
        settingsWindow?.model.refreshPermissions()
    }

    @objc private func openSessions() {
        try? FileManager.default.createDirectory(at: Recorder.root, withIntermediateDirectories: true)
        NSWorkspace.shared.open(Recorder.root)
    }

    private func toggle() {
        guard !finishing else { return }
        switch state {
        case .idle: startChoosing()
        case .choosing: cancel()
        case .session: finish()
        }
    }

    // MARK: Choosing

    private func startChoosing() {
        removeSessionMouseMonitors()
        overlay.selectedMarkID = nil
        overlay.hoveredMarkID = nil
        overlay.hoveredHandle = nil
        isDraggingMark = false

        if state == .idle {
            bar.mode = AppSettings.defaultMode
            previousApp = NSWorkspace.shared.frontmostApplication
            Sfx.open()
        } else {
            Sfx.palette()
        }
        tracker?.invalidate(); tracker = nil
        bar.target = nil
        bar.startedAt = nil
        state = .choosing
        buildOverlays(interactive: true)
        setMode(bar.mode)
        showBar()
        NSApp.activate()
        overlayUnderMouse()?.window.makeKeyAndOrderFront(nil)
    }

    private func setMode(_ m: CaptureMode) {
        if m != bar.mode {
            Sfx.mode([CaptureMode.window, .area, .screen].firstIndex(of: m) ?? 0)
        }
        bar.mode = m
        UserDefaults.standard.set(m.rawValue, forKey: Self.modeKey)
        settingsWindow?.model.syncFromDefaults()
        overlay.drag = nil
        overlay.hover = nil
        overlay.phase = .choosing(m)
        if m == .window { refreshWindows(force: true) }
        hover(at: NSEvent.mouseLocation)
        overlays.forEach { $0.window.invalidateCursorRects(for: $0.view) }
        if m == .area { NSCursor.crosshair.set() } else { NSCursor.arrow.set() }
    }

    private func refreshWindows(force: Bool = false) {
        guard force || Date().timeIntervalSince(windowsAt) > 0.5 else { return }
        windows = WindowList.onScreen()
        windowsAt = Date()
    }

    /// Mouse move during target selection: highlights the window under the cursor in window mode, the screen in screen mode.
    private func hover(at p: CGPoint) {
        guard case .choosing(let mode) = overlay.phase else { return }
        if barPanel.isVisible, barPanel.frame.contains(p) { overlay.hover = nil; return }
        switch mode {
        case .area:
            break
        case .window:
            refreshWindows()
            let w = WindowPicker.window(at: Screens.quartz(p), in: windows, excludingPID: WindowList.ownPID)
            if w?.id != hoveredWindow { hoveredWindow = w?.id; if w != nil { Sfx.hover() } }
            overlays.forEach { $0.view.pickedWindow = w }
            overlay.hover = w.map { (Geometry.cocoa(fromQuartz: $0.bounds, primaryHeight: Screens.primaryHeight), $0.app) }
        case .screen:
            if let s = Screens.under(p) { overlay.hover = (s.frame, s.localizedName) }
        }
    }

    private var hoveredWindow: UInt32?

    private func pick(_ target: CaptureTarget) {
        Sfx.take()
        if case .area(let f) = target {
            overlay.lastArea = f
            UserDefaults.standard.set(NSStringFromRect(f), forKey: Self.areaKey)
        }
        startSession(target)
    }

    private func handleKey(_ e: NSEvent) {
        guard state == .choosing else { sessionKey(e); return }
        switch e.keyCode {
        case 53: cancel()                                 // Esc
        case 18: setMode(.window)                         // 1
        case 19: setMode(.area)                           // 2
        case 20: setMode(.screen)                         // 3
        case 36, 76:                                      // ⏎
            switch overlay.phase {
            case .choosing(.screen):
                if let s = Screens.under(NSEvent.mouseLocation) {
                    pick(.screen(displayID: Screens.displayID(s), name: s.localizedName, frame: s.frame))
                }
            case .choosing(.area):
                if let a = overlay.lastArea { pick(.area(frame: a)) }
            default: break
            }
        default: break
        }
    }

    /// Keys during a session: Delete removes selected mark, Esc deselects (then returns to cursor),
    /// ⌘Z undoes; when a drawing tool is active, single letters switch tools/colors/shutter.
    private func sessionKey(_ e: NSEvent) {
        guard state == .session else { return }

        // Delete / Forward Delete removes the currently selected mark.
        if e.keyCode == 51 || e.keyCode == 117 {
            if let id = overlay.selectedMarkID, recorder?.deleteMark(id: id) == true {
                selectMark(nil)
                Sfx.undo()
                updateCursorModeHover(at: NSEvent.mouseLocation)
                return
            }
        }

        // Esc: deselect selected mark first; otherwise switch from drawing tool back to cursor.
        if e.keyCode == 53 {
            if overlay.selectedMarkID != nil {
                selectMark(nil)
                return
            }
            if overlay.tool != nil { setTool(nil) }
            return
        }

        // ⌘Z undoes even when editing a mark in cursor mode.
        if e.modifierFlags.contains(.command), e.charactersIgnoringModifiers?.lowercased() == "z" {
            undo()
            return
        }

        // In cursor mode (only key because a mark is selected), ignore normal typing keys.
        guard overlay.tool != nil else { return }

        if e.keyCode == 36 || e.keyCode == 76 { shutter(); return }       // ⏎
        let ch = e.charactersIgnoringModifiers?.lowercased() ?? ""
        if let n = Int(ch), (1...InkColor.allCases.count).contains(n) {
            setColor(InkColor.allCases[n - 1]); return
        }
        switch ch {
        case "p": setTool(.pen)
        case "b", "r": setTool(.box)
        case "o", "e", "c": setTool(.ellipse)
        case "a": setTool(.arrow)
        case "x": setTool(.blur)
        case "v": setTool(nil)
        case "s", "t", " ": shutter()
        case "z": undo()
        default: break
        }
    }

    private func undo() {
        guard let r = recorder else { return }
        r.undo()
        if let sel = overlay.selectedMarkID, !r.hasMark(id: sel) {
            selectMark(nil)
        }
        Sfx.undo()
    }

    /// Shutter: capture the target now, with the on-screen drawings (or plain if there are none).
    private func shutter() {
        circleDetector.reset()
        if overlay.selectedMarkID != nil { selectMark(nil) }
        recorder?.snapshot()
        bar.shutterTick += 1
        Sfx.shutter()
    }

    // MARK: Session

    private func startSession(_ target: CaptureTarget) {
        state = .session
        overlay.hover = nil
        overlay.drag = nil
        overlay.selectedMarkID = nil
        overlay.hoveredMarkID = nil
        overlay.hoveredHandle = nil
        overlay.phase = .session(target)
        bar.target = target
        if let r = recorder {
            r.retarget(target)
        } else {
            // Apply configured drawing defaults at the start of every new session.
            let defaultColor = AppSettings.defaultInkColor
            bar.color = defaultColor
            overlay.color = defaultColor
            bar.tool = AppSettings.defaultTool

            let r = Recorder(target: target)
            recorder = r
            bar.startedAt = r.startedAt
            bar.shotCount = 0; bar.pendingCount = 0; bar.liveText = ""; bar.notice = nil; bar.thumbs = []
            r.onChange = { [weak self, weak r] in
                guard let self, let r else { return }
                bar.shotCount = r.shots.count
                bar.pendingCount = r.canUndo ? max(1, r.pending.count) : 0
                if bar.thumbs.map(\.id) != r.thumbs.map(\.id) { bar.thumbs = r.thumbs; replaceBar() }
                if let sel = overlay.selectedMarkID, !r.hasMark(id: sel) { overlay.selectedMarkID = nil }
                overlay.changed()
            }
            r.onError = { [weak self] in Sfx.error(); self?.flash($0) }
            r.onCaptured = { [weak self] s in self?.overlays.forEach { $0.view.captured(s) } }
            registerSessionKeys()
            r.transcriber.onText = { [weak self] text in
                guard let self else { return }
                recorder?.heard()
                let wasEmpty = bar.liveText.isEmpty
                bar.liveText = text
                if wasEmpty != text.isEmpty { replaceBar() }
            }
            r.transcriber.onLevel = { [weak self] in self?.bar.meter.push($0) }
            r.transcriber.onCommand = { [weak self] cmd in
                guard let self, let r = recorder else { return }
                switch cmd {
                case .snapshot: r.snapshot(); flash("Voice command: screenshot taken")
                case .undo: undo(); flash("Voice command: undone")
                case .finish: finish()
                }
            }
            r.transcriber.onStatus = { [weak self] in self?.flash($0) }
            r.transcriber.onFinal = { [weak r] in r?.sentenceEnded() }
            r.transcriber.onError = { [weak self] in self?.flash("Dictation: \($0)") }
            // Screen Recording permission is requested at session start, not at the first screenshot; it takes effect after the app is reopened.
            if !CGPreflightScreenCaptureAccess() {
                CGRequestScreenCaptureAccess()
                flash("Screen Recording permission needed: allow recper in System Settings, then reopen recper.")
            }
            Task { [weak self] in
                do { try await r.transcriber.start(sessionStart: r.startedAt) }
                catch { Sfx.error(); self?.flash("Dictation failed to start: \(error.localizedDescription)") }
                // On-screen terms (with Accessibility permission): helps with English UI words spoken in another language.
                if AXVocabulary.enabled, AXVocabulary.trusted, let pid = self?.vocabularyPID(for: target) {
                    let terms = await Task.detached { AXVocabulary.terms(pid: pid) }.value
                    await r.transcriber.addVocabulary(terms)
                }
            }
        }
        showBar()
        installSessionMouseMonitors()

        // Focus: with the cursor tool it returns to the user's app; with a drawing tool the overlay takes the keyboard.
        overlay.tool = nil
        if bar.tool == nil { focusTarget() }
        setTool(bar.tool)

        // If the target window moves or resizes, the cutout follows it.
        tracker?.invalidate(); tracker = nil
        if case .window(let id, _, _, _) = target {
            tracker = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.trackWindow(id) }
            }
        }
    }

    // MARK: Session Mouse Monitors (Cursor-Mode Mark Editing + Circle Gesture)

    private func installSessionMouseMonitors() {
        removeSessionMouseMonitors()
        circleDetector.reset()
        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDown, .rightMouseDown, .otherMouseDown, .leftMouseDragged]
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            let type = event.type
            let time = event.timestamp
            MainActor.assumeIsolated {
                self?.handleMonitoredMouse(type: type, time: time, isGlobal: true)
            }
        }
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            let type = event.type
            let time = event.timestamp
            MainActor.assumeIsolated {
                self?.handleMonitoredMouse(type: type, time: time, isGlobal: false)
            }
            return event
        }
    }

    private func removeSessionMouseMonitors() {
        if let m = globalMouseMonitor { NSEvent.removeMonitor(m); globalMouseMonitor = nil }
        if let m = localMouseMonitor { NSEvent.removeMonitor(m); localMouseMonitor = nil }
        circleDetector.reset()
    }

    private func handleMonitoredMouse(type: NSEvent.EventType, time: Double, isGlobal: Bool) {
        guard state == .session, !finishing else { return }

        if type != .mouseMoved {
            circleDetector.reset()
            // Clicking outside Recper (in the underlying app) while a mark was selected in cursor mode deselects it without stealing the click.
            if isGlobal, overlay.tool == nil, overlay.selectedMarkID != nil, !isDraggingMark {
                selectMark(nil, refocus: false)
            }
            return
        }

        guard overlay.tool == nil, !radial.isActive, !isDraggingMark else { return }
        let p = NSEvent.mouseLocation

        if barPanel.isVisible, barPanel.frame.contains(p) {
            circleDetector.reset()
            if overlay.hoveredMarkID != nil { applyCursorModeHover(nil, at: p) }
            return
        }

        // 1. Cursor-mode mark editing: only intercept mouse events on the overlay while the pointer is directly over a mark or handle.
        updateCursorModeHover(at: p)

        // 2. Circle gesture without a drawing tool.
        guard AppSettings.circleGestureEnabled, let r = recorder else { return }
        if let rect = circleDetector.add(point: p, at: time, within: r.target.frame) {
            let stroke = r.addGestureEllipse(rect, color: overlay.color)
            Sfx.circleGesture()
            overlays.forEach { $0.view.animateGestureMark(stroke) }
        }
    }

    private func updateCursorModeHover(at p: CGPoint) {
        guard state == .session, overlay.tool == nil, !isDraggingMark else { return }
        guard let r = recorder else {
            applyCursorModeHover(nil, at: p)
            return
        }
        let marks = r.editableMarks
        let hit = marks.isEmpty ? nil : MarkGeometry.hitTest(point: p, marks: marks, selectedID: overlay.selectedMarkID)
        applyCursorModeHover(hit, at: p)
    }

    private func applyCursorModeHover(_ hit: MarkHit?, at p: CGPoint) {
        let prevID = overlay.hoveredMarkID
        let prevHandle = overlay.hoveredHandle
        overlay.hoveredMarkID = hit?.id
        overlay.hoveredHandle = hit?.handle

        if let hit {
            // Only the overlay under the pointer accepts clicks while directly over a mark/handle.
            for o in overlays {
                o.window.ignoresMouseEvents = !o.window.frame.contains(p)
            }
            if prevID != hit.id || prevHandle != hit.handle {
                OverlayView.cursor(for: hit, dragging: false, tool: nil, color: overlay.color).set()
            }
        } else {
            // Pointer moved off all marks: immediately pass all clicks straight through to the app underneath.
            for o in overlays where !o.window.ignoresMouseEvents {
                o.window.ignoresMouseEvents = true
            }
            if prevID != nil { NSCursor.arrow.set() }
        }
    }

    private func selectMark(_ id: UUID?, refocus: Bool = true) {
        let wasSelected = (overlay.selectedMarkID != nil)
        overlay.selectedMarkID = id
        guard state == .session, overlay.tool == nil else { return }

        if id != nil {
            // Enable keyboard handling (Delete/Esc/⌘Z) on the overlay containing the selected mark.
            overlays.forEach { $0.window.keyable = true }
            NSApp.activate()
            overlayUnderMouse()?.window.makeKeyAndOrderFront(nil)
        } else {
            overlays.forEach { $0.window.keyable = false }
            updateCursorModeHover(at: NSEvent.mouseLocation)
            if wasSelected && refocus { focusTarget() }
        }
    }

    private func handleHoverMark(_ hit: MarkHit?) {
        overlay.hoveredMarkID = hit?.id
        overlay.hoveredHandle = hit?.handle
        if state == .session, overlay.tool == nil, !isDraggingMark, hit == nil {
            for o in overlays { o.window.ignoresMouseEvents = true }
        }
    }

    /// nil = cursor: the overlay passes clicks through to the app underneath (except when directly hovering an editable mark).
    /// With a tool selected the overlay also takes the keyboard (Esc, letters, 1–6 colors); switching back to the cursor returns focus to the user's app.
    private func setTool(_ t: Tool?) {
        let was = overlay.tool
        if state == .session, t != was {
            Sfx.tool([nil, Tool.pen, .box, .ellipse, .arrow, .blur].firstIndex(of: t) ?? 0)
        }
        circleDetector.reset()
        overlay.selectedMarkID = nil
        overlay.hoveredMarkID = nil
        overlay.hoveredHandle = nil
        isDraggingMark = false
        bar.tool = t
        overlay.tool = t
        overlays.forEach {
            $0.window.ignoresMouseEvents = (t == nil)
            $0.window.keyable = (t != nil)
        }
        // Don't coalesce mouse events while drawing: more samples, smoother strokes.
        NSEvent.isMouseCoalescingEnabled = (t == nil)
        guard state == .session else { return }
        if let t {
            if was == nil {
                NSApp.activate()
                overlayUnderMouse()?.window.makeKeyAndOrderFront(nil)
            }
            Cursors.cursor(t, overlay.color).set()
        } else {
            NSCursor.arrow.set()
            if was != nil { focusTarget() }
        }
    }

    private func setColor(_ c: InkColor) {
        if c != bar.color { Sfx.color(InkColor.allCases.firstIndex(of: c) ?? 0) }
        bar.color = c
        overlay.color = c
        if overlay.tool == .blur || overlay.tool == nil { setTool(.pen) }   // picking a color = wanting to draw
        else if let t = overlay.tool { Cursors.cursor(t, c).set() }
    }

    /// Gives focus to the target's app (or to the app that was frontmost before choosing).
    private func focusTarget() {
        if case .session(let t) = overlay.phase, case .window(_, let pid, _, _) = t {
            NSRunningApplication(processIdentifier: pid)?.activate()
        } else {
            previousApp?.activate()
        }
    }

    private func trackWindow(_ id: UInt32) {
        guard case .session(let t) = overlay.phase, let f = WindowList.frame(of: id), f != t.frame else { return }
        let nt = t.with(frame: f)
        overlay.phase = .session(nt)
        bar.target = nt
        recorder?.retarget(nt)
    }

    private func retarget() {
        if case .session(let t) = overlay.phase { bar.mode = t.mode }
        startChoosing()
    }

    private func stroke(_ phase: OverlayView.StrokePhase, _ p: CGPoint) {
        guard let r = recorder else { return }
        switch phase {
        case .begin: if let t = overlay.tool { r.begin(t, color: overlay.color, at: p); Sfx.grab() }
        case .move: r.extend(to: p)
        case .end: r.end(); Sfx.drop()
        }
    }

    /// Esc / ✕: cancel choosing. If a session is ongoing (retargeting), return to the previous target.
    private func cancel() {
        if let r = recorder, state == .choosing {
            startSession(r.target)
            return
        }
        Sfx.cancel()
        teardown()
        previousApp?.activate()
    }

    private func finish() {
        guard let r = recorder, !finishing else { teardown(); return }
        finishing = true
        removeSessionMouseMonitors()
        overlay.selectedMarkID = nil
        overlay.hoveredMarkID = nil
        overlay.hoveredHandle = nil
        isDraggingMark = false
        Sfx.finish()
        tracker?.invalidate(); tracker = nil
        overlays.forEach { $0.window.orderOut(nil) }
        overlays = []
        bar.notice = "Saving…"
        replaceBar()
        Task { [weak self] in
            let doc = await r.collect()
            guard let self else { return }
            if ReviewModel.enabled, !doc.segments.isEmpty || !doc.shots.isEmpty {
                review(doc, r)
            } else {
                await complete(r, doc, copy: true)
            }
        }
    }

    private var reviewPanel: ReviewPanel?

    /// Before sending: fix sentences, inspect/remove screenshots & items.
    private func review(_ doc: SessionDoc, _ r: Recorder) {
        barPanel.orderOut(nil)
        var images: [String: NSImage] = [:]
        var urls: [String: URL] = [:]
        for s in doc.shots {
            let url = r.dir.appendingPathComponent(s.file)
            urls[s.id] = url
            if let d = MCPServer.jpeg(url, maxSide: 420), let img = NSImage(data: d) { images[s.id] = img }
        }
        let m = ReviewModel(doc: doc, images: images, shotURLs: urls)
        let panel = ReviewPanel(model: m)
        reviewPanel = panel
        m.onDone = { [weak self, weak panel] edited, copy in
            panel?.dismissAll()
            self?.reviewPanel = nil
            Task { await self?.complete(r, edited ?? doc, copy: copy) }
        }
        panel.present()
    }

    /// Writes the files, puts the agent prompt on the clipboard (if requested), shows a short notice on the bar.
    private func complete(_ r: Recorder, _ doc: SessionDoc, copy: Bool) async {
        let md = r.write(doc)
        if copy {
            let prompt = "Read this feedback and apply it (screenshots are in the same folder): \(md.path)"
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(prompt, forType: .string)
            bar.notice = "Copied to clipboard · \(doc.shots.count) screenshots"
            Sfx.done()
        } else {
            bar.notice = "Saved ·\(md.deletingLastPathComponent().lastPathComponent)"
        }
        barPanel.orderFrontRegardless()
        replaceBar()
        focusTarget()
        try? await Task.sleep(for: .seconds(1.6))
        finishing = false
        teardown()
    }

    private func vocabularyPID(for t: CaptureTarget) -> pid_t? {
        if case .window(_, let pid, _, _) = t { return pid }
        return previousApp?.processIdentifier
    }

    /// ⌥⇧ + V cursor, P pen, B box, O ellipse, A arrow, X blur, S screenshot, Z undo.
    private func registerSessionKeys() {
        let k = HotKeys.shared
        sessionKeys = [
            k.register(kVK_ANSI_V) { [weak self] in self?.setTool(nil) },
            k.register(kVK_ANSI_P) { [weak self] in self?.setTool(.pen) },
            k.register(kVK_ANSI_B) { [weak self] in self?.setTool(.box) },
            k.register(kVK_ANSI_O) { [weak self] in self?.setTool(.ellipse) },
            k.register(kVK_ANSI_A) { [weak self] in self?.setTool(.arrow) },
            k.register(kVK_ANSI_X) { [weak self] in self?.setTool(.blur) },
            // ⌥⇧S: radial menu at the pointer (click an action; the center takes a screenshot).
            k.register(kVK_ANSI_S) { [weak self] in self?.radial.toggle() },
            k.register(kVK_ANSI_Z) { [weak self] in self?.undo() },
        ]
    }

    private func teardown() {
        removeSessionMouseMonitors()
        radial.cancel()
        reviewPanel?.dismissAll()
        reviewPanel = nil
        NSEvent.isMouseCoalescingEnabled = true
        HotKeys.shared.unregister(sessionKeys)
        sessionKeys = []
        tracker?.invalidate(); tracker = nil
        overlays.forEach { $0.window.orderOut(nil) }
        overlays = []
        barPanel.orderOut(nil)
        recorder = nil
        bar.target = nil
        bar.startedAt = nil
        bar.liveText = ""
        bar.notice = nil
        overlay.hover = nil
        overlay.drag = nil
        overlay.tool = nil
        overlay.selectedMarkID = nil
        overlay.hoveredMarkID = nil
        overlay.hoveredHandle = nil
        isDraggingMark = false
        state = .idle
        NSCursor.arrow.set()
    }

    /// Short notice: stays on the bar for 4 s.
    private func flash(_ msg: String, seconds: Double = 4) {
        bar.notice = msg
        replaceBar()
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard let self, bar.notice == msg, !finishing else { return }
            bar.notice = nil
            replaceBar()
        }
    }

    // MARK: Windows

    private func buildOverlays(interactive: Bool) {
        overlays.forEach { $0.window.orderOut(nil) }
        overlays = NSScreen.screens.map { screen in
            let w = OverlayWindow(screen: screen)
            let v = OverlayView(model: overlay, screenFrame: screen.frame)
            v.screenName = screen.localizedName
            v.displayID = Screens.displayID(screen)
            v.onPick = { [weak self] in self?.pick($0) }
            v.onKey = { [weak self] in self?.handleKey($0) }
            v.onHover = { [weak self] in self?.hover(at: $0) }
            v.onStroke = { [weak self] in self?.stroke($0, $1) }
            v.onSelectMark = { [weak self] in self?.selectMark($0) }
            v.onHoverMark = { [weak self] in self?.handleHoverMark($0) }
            v.onMoveMark = { [weak self] id, pts in self?.recorder?.updateMark(id: id, points: pts) }
            v.onCommitMarkEdit = { [weak self] id, old in self?.recorder?.commitMarkEdit(id: id, oldPoints: old) }
            v.onMarkDragChange = { [weak self] dragging in
                self?.isDraggingMark = dragging
                if dragging { self?.circleDetector.reset() }
            }
            w.contentView = v
            w.ignoresMouseEvents = !interactive
            w.keyable = interactive
            w.orderFrontRegardless()
            w.makeFirstResponder(v)
            return (w, v)
        }
    }

    private func overlayUnderMouse() -> (window: OverlayWindow, view: OverlayView)? {
        let p = NSEvent.mouseLocation
        return overlays.first { $0.window.frame.contains(p) } ?? overlays.first
    }

    private var barScreen: NSScreen?

    private func showBar() {
        guard let screen = Screens.under(NSEvent.mouseLocation) else { return }
        barScreen = screen
        bar.appearTick += 1        // replay the entrance animation
        barPanel.orderFrontRegardless()
        replaceBar()
    }

    /// SwiftUI content resizes on the next run loop pass (choosing ↔ session, live caption row).
    private func replaceBar() {
        guard let s = barScreen else { return }
        barPanel.place(on: s)
        DispatchQueue.main.async { [weak self] in self?.barPanel.place(on: s) }
    }

    private func screensChanged() {
        glow.rebuild()
        switch state {
        case .idle: break
        case .choosing: buildOverlays(interactive: true); setMode(bar.mode); showBar()
        case .session: buildOverlays(interactive: false); setTool(bar.tool); showBar()
        }
    }
}
