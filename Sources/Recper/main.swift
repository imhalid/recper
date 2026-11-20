import AppKit
import RecperCore

// `Recper --render-preview <dir>`: renders overlay and bar states to PNG (no permissions, no screen capture).
let args = CommandLine.arguments
if let i = args.firstIndex(of: "--render-preview"), i + 1 < args.count {
    MainActor.assumeIsolated { Preview.render(to: args[i + 1]) }
    exit(0)
}

// `Recper --render-md <session.json>`: prints the session as markdown with current rules (incl. fragment merging); writes no file.
if let i = args.firstIndex(of: "--render-md"), i + 1 < args.count,
   let d = try? Data(contentsOf: URL(fileURLWithPath: args[i + 1])) {
    let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
    if var doc = try? dec.decode(SessionDoc.self, from: d) {
        // Re-split from the words with the same cuts as a live session (screenshot moments + mark starts).
        var words: [Word] = [], breaks = Set<Int>()
        for s in doc.segments { words += s.words; if !words.isEmpty { breaks.insert(words.count - 1) } }
        let markCuts = Sentences.alignCuts(Binder.markCuts(doc.shots), words: words)
        let cuts = (doc.shots.compactMap(\.taken) + markCuts).sorted()
        doc.segments = Sentences.tidy(Sentences.split(words, startID: 1, breaks: breaks, cuts: cuts), cuts: cuts, markCuts: markCuts)
        doc.shots = Binder.bind(doc.shots, to: doc.segments)
        print(Writer.markdown(doc))
    }
    exit(0)
}

// `Recper --mcp`: MCP server for agents (stdio).
if args.contains("--mcp") {
    MCPServer.run()
    exit(0)
}

// `Recper --transcribe <audio file>`: runs the live dictation path (Transcriber) on a file, prints sentences and markdown.
if let i = args.firstIndex(of: "--transcribe"), i + 1 < args.count {
    let url = URL(fileURLWithPath: args[i + 1])
    let done = DispatchSemaphore(value: 0)
    Task.detached {   // off the main actor, since the main thread blocks on the semaphore
        let t = Transcriber()
        let start = Date()
        do { try await t.start(sessionStart: start, file: url) } catch { print("error:", error) }
        let segs = await t.stop()
        print("locale", t.localeID, String(format: "%.2fs", Date().timeIntervalSince(start)))
        for s in segs { print(String(format: "[%.2f-%.2f]", s.t0, s.t1), s.text) }
        let doc = SessionDoc(startedAt: start, duration: segs.last?.t1 ?? 0,
                             target: TargetInfo(kind: "area", app: nil, label: "test", size: [0, 0]),
                             locale: t.localeID, segments: segs, shots: [])
        print(Writer.markdown(doc))
        done.signal()
    }
    done.wait()
    exit(0)
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)   // no Dock icon; same as LSUIElement in Info.plist
    let controller = AppController()
    app.delegate = controller
    app.run()
}
