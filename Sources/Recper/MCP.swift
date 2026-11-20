import AppKit
import ImageIO
import UniformTypeIdentifiers
import RecperCore

/// `Recper --mcp`: MCP server over stdio (one JSON-RPC message per line).
/// Agents (Claude Code, Codex, Antigravity…) read sessions without the clipboard, check off items,
/// and can ask the user for new feedback.
///
///     claude mcp add recper -- /…/Recper.app/Contents/MacOS/Recper --mcp
enum MCPServer {
    static let protocolVersion = "2025-06-18"

    static func run() {
        setvbuf(stdout, nil, _IOLBF, 0)
        while let line = readLine(strippingNewline: true) {
            guard !line.isEmpty, let data = line.data(using: .utf8),
                  let msg = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            let id = msg["id"]
            let method = msg["method"] as? String ?? ""
            let params = msg["params"] as? [String: Any] ?? [:]
            guard id != nil else { continue }          // notification (notifications/initialized etc.): no reply
            do {
                let result = try handle(method, params)
                send(["jsonrpc": "2.0", "id": id!, "result": result])
            } catch let e as RPCError {
                send(["jsonrpc": "2.0", "id": id!, "error": ["code": e.code, "message": e.message]])
            } catch {
                send(["jsonrpc": "2.0", "id": id!, "error": ["code": -32603, "message": "\(error)"]])
            }
        }
    }

    struct RPCError: Error { let code: Int; let message: String }

    private static func send(_ obj: [String: Any]) {
        guard let d = try? JSONSerialization.data(withJSONObject: obj, options: [.withoutEscapingSlashes]),
              let s = String(data: d, encoding: .utf8) else { return }
        print(s)
    }

    private static func handle(_ method: String, _ p: [String: Any]) throws -> Any {
        switch method {
        case "initialize":
            return [
                "protocolVersion": (p["protocolVersion"] as? String) ?? protocolVersion,
                "capabilities": ["tools": [String: Any]()],
                "serverInfo": ["name": "recper", "version": "0.1.0"],
                "instructions": """
                recper: the user's on-screen voice + drawing feedback. The #n badges in images are marks the user \
                drew. Use get_feedback to read feedback; check off each item you apply with mark_done; \
                use request_feedback to ask the user for visual feedback (waits until the user finishes recording).
                """,
            ]
        case "ping": return [String: Any]()
        case "tools/list": return ["tools": tools]
        case "tools/call":
            let name = p["name"] as? String ?? ""
            let a = p["arguments"] as? [String: Any] ?? [:]
            do {
                return ["content": try call(name, a)]
            } catch let e as ToolError {
                return ["content": [["type": "text", "text": e.message]], "isError": true]
            }
        default: throw RPCError(code: -32601, message: "Unknown method: \(method)")
        }
    }

    struct ToolError: Error { let message: String }

    // MARK: Tools

    private static var sessionArg: [String: Any] { [
        "type": "string", "description": "Session folder name (e.g. 2026-11-20_143005). Empty means the latest session.",
    ] }

    static var tools: [[String: Any]] { [
        [
            "name": "get_feedback",
            "description": "Returns the user's latest (or the given) feedback session: the spoken text as checklist items, the screenshots bound to each item (with the numbered marks the user drew on them), and the UI elements under those marks.",
            "inputSchema": ["type": "object", "properties": [
                "session": sessionArg,
                "images": ["type": "boolean", "description": "Also return images (default: true)."],
                "max_images": ["type": "integer", "description": "Maximum number of images (default: 10)."],
            ]],
            "annotations": ["readOnlyHint": true],
        ],
        [
            "name": "list_sessions",
            "description": "Lists recent feedback sessions: date, duration, screenshot count, done/total items and the first sentence.",
            "inputSchema": ["type": "object", "properties": [
                "limit": ["type": "integer", "description": "Number of sessions (default: 10)."],
            ]],
            "annotations": ["readOnlyHint": true],
        ],
        [
            "name": "mark_done",
            "description": "Marks an item in feedback.md as done (`- [x]`). Call it after applying an item.",
            "inputSchema": ["type": "object", "properties": [
                "session": sessionArg,
                "item": ["type": "integer", "description": "Item number."],
                "done": ["type": "boolean", "description": "false: uncheck the item (default: true)."],
            ], "required": ["item"]],
        ],
        [
            "name": "request_feedback",
            "description": "Opens recper on the user's screen and starts a new feedback session; the user talks and draws, and when they press Finish the session is returned (like get_feedback). Use it to show the user a change and get their opinion.",
            "inputSchema": ["type": "object", "properties": [
                "prompt": ["type": "string", "description": "Short question shown to the user in the bar (e.g. \"How does the new header look?\")."],
                "mode": ["type": "string", "enum": ["window", "area", "screen"], "description": "Target selection mode."],
                "timeout_seconds": ["type": "integer", "description": "Maximum wait in seconds (default: 600)."],
            ]],
        ],
    ] }

    private static func call(_ name: String, _ a: [String: Any]) throws -> [[String: Any]] {
        switch name {
        case "get_feedback":
            let dir = try session(a["session"] as? String)
            return try feedback(dir, images: a["images"] as? Bool ?? true, max: a["max_images"] as? Int ?? 10)
        case "list_sessions":
            return [["type": "text", "text": list(limit: a["limit"] as? Int ?? 10)]]
        case "mark_done":
            guard let n = a["item"] as? Int else { throw ToolError(message: "item is required") }
            let dir = try session(a["session"] as? String)
            let url = dir.appendingPathComponent("feedback.md")
            guard let md = try? String(contentsOf: url, encoding: .utf8) else { throw ToolError(message: "Could not read feedback.md") }
            guard let out = Checklist.mark(md, item: n, done: a["done"] as? Bool ?? true) else {
                throw ToolError(message: "No item \(n)")
            }
            try out.write(to: url, atomically: true, encoding: .utf8)
            let items = Checklist.items(out)
            return [["type": "text", "text": "Item \(n) \(a["done"] as? Bool ?? true ? "done" : "open"). Remaining: \(items.filter { !$0.done }.map { "\($0.n)" }.joined(separator: ", ").ifEmpty("none"))"]]
        case "request_feedback":
            return try request(prompt: a["prompt"] as? String, mode: a["mode"] as? String,
                               timeout: TimeInterval(a["timeout_seconds"] as? Int ?? 600))
        default:
            throw ToolError(message: "Unknown tool: \(name)")
        }
    }

    // MARK: Sessions

    static var root: URL { Recorder.rootURL }

    /// Completed sessions (session.json written), newest first.
    static func sessions() -> [URL] {
        let fm = FileManager.default
        let dirs = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        return dirs.filter { fm.fileExists(atPath: $0.appendingPathComponent("session.json").path) }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    private static func session(_ name: String?) throws -> URL {
        if let name, !name.isEmpty {
            // A session is a plain folder name inside the sessions root; anything else (paths, "..") could
            // read or, via mark_done, write a feedback.md elsewhere on disk.
            guard !name.contains("/"), !name.contains("\\"), name != ".", name != "..", !name.hasPrefix(".") else {
                throw ToolError(message: "Invalid session name: \(name)")
            }
            let u = root.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: u.appendingPathComponent("feedback.md").path) else {
                throw ToolError(message: "No such session: \(name)")
            }
            return u
        }
        guard let last = sessions().first else { throw ToolError(message: "No sessions yet. The user can record one with ⌥⇧R, or use request_feedback.") }
        return last
    }

    private static func load(_ dir: URL) -> SessionDoc? {
        guard let d = try? Data(contentsOf: dir.appendingPathComponent("session.json")) else { return nil }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        return try? dec.decode(SessionDoc.self, from: d)
    }

    private static func list(limit: Int) -> String {
        let all = sessions().prefix(max(1, limit))
        guard !all.isEmpty else { return "No sessions yet." }
        return all.map { dir in
            let doc = load(dir)
            let md = (try? String(contentsOf: dir.appendingPathComponent("feedback.md"), encoding: .utf8)) ?? ""
            let items = Checklist.items(md)
            let first = doc?.segments.first?.text ?? "(no speech)"
            return "- \(dir.lastPathComponent) · \(Writer.clock(doc?.duration ?? 0)) · \(doc?.shots.count ?? 0) screenshots · "
                + "\(items.filter(\.done).count)/\(items.count) done — \(first.prefix(80))"
        }.joined(separator: "\n")
    }

    /// Text (feedback.md + folder path) and images (downscaled JPEG, each preceded by its name).
    private static func feedback(_ dir: URL, images: Bool, max: Int) throws -> [[String: Any]] {
        guard let md = try? String(contentsOf: dir.appendingPathComponent("feedback.md"), encoding: .utf8) else {
            throw ToolError(message: "Could not read feedback.md")
        }
        var out: [[String: Any]] = [["type": "text", "text": "Session: \(dir.lastPathComponent)\nFolder: \(dir.path)\n\n\(md)"]]
        guard images, let doc = load(dir) else { return out }
        for (i, s) in doc.shots.prefix(max).enumerated() {
            guard let jpg = jpeg(dir.appendingPathComponent(s.file)) else { continue }
            let marks = s.marks.map(\.summary).joined(separator: "; ")
            out.append(["type": "text", "text": "Screenshot \(i + 1) (\(s.file))" + (marks.isEmpty ? "" : " — \(marks)")])
            out.append(["type": "image", "data": jpg.base64EncodedString(), "mimeType": "image/jpeg"])
        }
        if doc.shots.count > max { out.append(["type": "text", "text": "(\(doc.shots.count - max) more screenshots in \(dir.path)/shots)"]) }
        return out
    }

    /// JPEG with the long side at most 1568 px (enough for model input, keeps the message small).
    static func jpeg(_ url: URL, maxSide: Int = 1568) -> Data? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let img = CGImageSourceCreateThumbnailAtIndex(src, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceThumbnailMaxPixelSize: maxSide,
                  kCGImageSourceCreateThumbnailWithTransform: true,
              ] as CFDictionary) else { return nil }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, img, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        return CGImageDestinationFinalize(dest) ? data as Data : nil
    }

    // MARK: Request feedback

    /// Opens the app via `recper://start` (launching it if needed) and waits until a new session finishes.
    private static func request(prompt: String?, mode: String?, timeout: TimeInterval) throws -> [[String: Any]] {
        let before = Set(sessions().map(\.lastPathComponent))
        var c = URLComponents()
        c.scheme = "recper"; c.host = "start"
        var q: [URLQueryItem] = []
        if let mode { q.append(URLQueryItem(name: "mode", value: mode)) }
        if let prompt, !prompt.isEmpty { q.append(URLQueryItem(name: "prompt", value: prompt)) }
        c.queryItems = q.isEmpty ? nil : q
        guard let url = c.url, NSWorkspace.shared.open(url) else {
            throw ToolError(message: "Could not open recper (Recper.app must have been opened manually once).")
        }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            Thread.sleep(forTimeInterval: 1)
            if let new = sessions().first(where: { !before.contains($0.lastPathComponent) }) {
                Thread.sleep(forTimeInterval: 0.5)          // don't read files while they are being written
                return try feedback(new, images: true, max: 10)
            }
        }
        throw ToolError(message: "The user gave no feedback within \(Int(timeout)) s.")
    }
}

private extension String {
    func ifEmpty(_ s: String) -> String { isEmpty ? s : self }
}
