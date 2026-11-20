import CoreGraphics

public enum Geometry {
    /// CGWindowList / Quartz (top-left origin) → Cocoa (bottom-left origin). `primaryHeight`: the primary screen's height.
    public static func cocoa(fromQuartz r: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(x: r.minX, y: primaryHeight - r.maxY, width: r.width, height: r.height)
    }

    /// Cocoa → Quartz (ScreenCaptureKit and CGWindowList expect this layout). The transform is its own inverse.
    public static func quartz(fromCocoa r: CGRect, primaryHeight: CGFloat) -> CGRect {
        cocoa(fromQuartz: r, primaryHeight: primaryHeight)
    }

    /// Rectangle from drag start/end points; clamped to `bounds`, corners rounded to whole pixels.
    public static func dragRect(from a: CGPoint, to b: CGPoint, within bounds: CGRect) -> CGRect {
        func clamp(_ p: CGPoint) -> CGPoint {
            CGPoint(x: min(max(p.x, bounds.minX), bounds.maxX), y: min(max(p.y, bounds.minY), bounds.maxY))
        }
        let p = clamp(a), q = clamp(b)
        let x0 = min(p.x, q.x).rounded(), y0 = min(p.y, q.y).rounded()
        let x1 = max(p.x, q.x).rounded(), y1 = max(p.y, q.y).rounded()
        return CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }

    /// Smallest size that counts as an area selection; a smaller drag counts as a click.
    public static let minimumArea: CGFloat = 8

    public static func isUsableArea(_ r: CGRect) -> Bool {
        r.width >= minimumArea && r.height >= minimumArea
    }

    /// The part of a global-coordinate target that falls on the given screen frame, in the screen's local coordinates.
    /// nil if the target is not on this screen (the screen stays fully dimmed).
    public static func hole(for target: CGRect, onScreen screen: CGRect) -> CGRect? {
        let i = target.intersection(screen)
        guard !i.isNull, i.width > 0, i.height > 0 else { return nil }
        return i.offsetBy(dx: -screen.minX, dy: -screen.minY)
    }
}

/// A window from CGWindowListCopyWindowInfo that is a candidate for selection.
public struct WindowInfo: Equatable, Sendable {
    public var id: UInt32
    public var pid: Int32
    public var app: String
    public var layer: Int
    public var alpha: Double
    /// In Quartz coordinates (top-left origin).
    public var bounds: CGRect

    public init(id: UInt32, pid: Int32, app: String, layer: Int, alpha: Double, bounds: CGRect) {
        self.id = id; self.pid = pid; self.app = app; self.layer = layer; self.alpha = alpha; self.bounds = bounds
    }

    /// Reads from a CGWindowList dictionary. The title (kCGWindowName) requires Screen Recording permission; not used.
    public init?(_ d: [String: Any]) {
        guard let id = d["kCGWindowNumber"] as? Int,
              let pid = d["kCGWindowOwnerPID"] as? Int,
              let b = d["kCGWindowBounds"] as? [String: Any],
              let rect = CGRect(dictionaryRepresentation: b as CFDictionary) else { return nil }
        self.init(id: UInt32(id), pid: Int32(pid), app: d["kCGWindowOwnerName"] as? String ?? "?",
                  layer: d["kCGWindowLayer"] as? Int ?? 0, alpha: d["kCGWindowAlpha"] as? Double ?? 1, bounds: rect)
    }

    /// Selectable: normal layer, visible, not our own, not too small.
    public func selectable(excludingPID own: Int32) -> Bool {
        layer == 0 && alpha > 0.01 && pid != own && bounds.width >= 40 && bounds.height >= 40
    }
}

public enum WindowPicker {
    /// `windows` is ordered front to back (CGWindowList order). Returns the frontmost selectable window under the Quartz point.
    public static func window(at quartzPoint: CGPoint, in windows: [WindowInfo], excludingPID own: Int32) -> WindowInfo? {
        windows.first { $0.selectable(excludingPID: own) && $0.bounds.contains(quartzPoint) }
    }
}
