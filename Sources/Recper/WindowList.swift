import AppKit
import RecperCore

/// On-screen windows (front to back). Needs no permission, so titles are not read.
enum WindowList {
    static let ownPID = ProcessInfo.processInfo.processIdentifier

    static func onScreen() -> [WindowInfo] {
        let raw = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
        return (raw as? [[String: Any]] ?? []).compactMap(WindowInfo.init)
    }

    /// Current frame of a single window (Cocoa). nil if the window was closed.
    static func frame(of id: UInt32) -> CGRect? {
        let raw = CGWindowListCopyWindowInfo([.optionIncludingWindow], CGWindowID(id))
        guard let w = (raw as? [[String: Any]])?.first.flatMap(WindowInfo.init) else { return nil }
        return Geometry.cocoa(fromQuartz: w.bounds, primaryHeight: Screens.primaryHeight)
    }
}

enum Screens {
    static var primaryHeight: CGFloat { NSScreen.screens.first?.frame.height ?? 0 }

    static func displayID(_ s: NSScreen) -> UInt32 {
        (s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }

    static func under(_ p: CGPoint) -> NSScreen? {
        NSScreen.screens.first { NSMouseInRect(p, $0.frame, false) } ?? NSScreen.main
    }

    static func quartz(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x, y: primaryHeight - p.y) }
}
