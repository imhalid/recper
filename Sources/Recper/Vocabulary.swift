import AppKit
import ApplicationServices

/// Words on the target app's screen (buttons, titles, labels, web page text) → hints for dictation.
/// Terms like "header" or "sidebar" spoken in another language are more likely transcribed correctly if they're on screen.
/// Requires Accessibility permission; without it, silently does nothing (only requested from the menu).
enum AXVocabulary {
    static let enabledKey = "axVocabulary"

    static var trusted: Bool { AXIsProcessTrusted() }

    static var enabled: Bool {
        get { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    /// Opens the system permission prompt.
    static func requestTrust() {
        let key = "AXTrustedCheckOptionPrompt" as CFString   // kAXTrustedCheckOptionPrompt
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    /// Terms from the frontmost window's accessibility tree. Bounded: at most `maxNodes` elements, `budget` seconds.
    static func terms(pid: pid_t, maxNodes: Int = 1500, budget: TimeInterval = 1.2, limit: Int = 200) -> [String] {
        guard trusted else { return [] }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.25)
        let start = Date()
        var roots: [AXUIElement] = []
        if let w: AXUIElement = attr(app, kAXFocusedWindowAttribute) { roots.append(w) }
        else if let ws: [AXUIElement] = attr(app, kAXWindowsAttribute) { roots += ws.prefix(2) }

        var queue = roots, seen = 0
        var counts: [String: Int] = [:]
        while !queue.isEmpty, seen < maxNodes, Date().timeIntervalSince(start) < budget {
            let el = queue.removeFirst(); seen += 1
            for key in [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute, kAXHelpAttribute] {
                if let s: String = attr(el, key) { collect(s, into: &counts) }
            }
            if let kids: [AXUIElement] = attr(el, kAXChildrenAttribute) { queue += kids }
        }
        // Most frequent first; shorter phrases preferred.
        return counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key.count < $1.key.count }
            .prefix(limit).map(\.key)
    }

    private static func attr<T>(_ el: AXUIElement, _ key: String) -> T? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, key as CFString, &v) == .success else { return nil }
        return v as? T
    }

    /// Short 1–3 word labels are kept whole; from longer text only individual words.
    private static func collect(_ raw: String, into counts: inout [String: Int]) {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty, s.count <= 400 else { return }
        let words = s.split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "-" && $0 != "_" }).map(String.init)
        if (1...3).contains(words.count), s.count <= 40 { counts[words.joined(separator: " "), default: 0] += 1 }
        for w in words where w.count >= 3 && w.count <= 30 && w.contains(where: \.isLetter) {
            counts[w, default: 0] += 1
        }
    }
}

/// UI element under a mark: button/link name, plus #id and .classes on the web. Helps the agent find it in code.
enum AXElement {
    private static let interactive: Set<String> = [
        "AXButton", "AXLink", "AXCheckBox", "AXRadioButton", "AXPopUpButton", "AXMenuItem", "AXMenuButton",
        "AXTextField", "AXTextArea", "AXTab", "AXComboBox", "AXSlider", "AXSearchField", "AXDisclosureTriangle",
    ]

    /// `quartz`: global Quartz point (top-left origin). nil without permission or if nothing is found.
    static func describe(at quartz: CGPoint, pid: pid_t) -> String? {
        guard AXIsProcessTrusted() else { return nil }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.3)
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(app, Float(quartz.x), Float(quartz.y), &hit) == .success, let hit else { return nil }

        // Walk up to a clickable ancestor (if the text is inside a button, describe the button).
        var el = hit
        var cur: AXUIElement? = hit
        for _ in 0..<4 {
            guard let c = cur else { break }
            if let r: String = attr(c, kAXRoleAttribute), interactive.contains(r) { el = c; break }
            cur = attr(c, kAXParentAttribute)
        }
        let role: String = attr(el, kAXRoleAttribute) ?? "AXUnknown"
        guard role != "AXWindow", role != "AXApplication", role != "AXScrollArea", role != "AXWebArea" else { return nil }

        var label = [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute, kAXHelpAttribute]
            .lazy.compactMap { (k: String) -> String? in (attr(el, k) as String?)?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
        if label == nil, !CFEqual(el, hit) {
            label = (attr(hit, kAXValueAttribute) as String?) ?? (attr(hit, kAXTitleAttribute) as String?)
        }
        var out = role
        if let label, !label.isEmpty { out += " \"\(label.count > 60 ? String(label.prefix(57)) + "…" : label)\"" }
        if let id: String = attr(el, "AXDOMIdentifier"), !id.isEmpty { out += " #\(id)" }
        else if let id: String = attr(el, "AXIdentifier"), !id.isEmpty, !id.hasPrefix("_NS") { out += " id=\(id)" }
        if let cls: [String] = attr(el, "AXDOMClassList"), !cls.isEmpty { out += " ." + cls.prefix(3).joined(separator: ".") }
        return out == "AXUnknown" || out == "AXGroup" || out == "AXStaticText" ? nil : out
    }

    private static func attr<T>(_ el: AXUIElement, _ key: String) -> T? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, key as CFString, &v) == .success else { return nil }
        return v as? T
    }
}
