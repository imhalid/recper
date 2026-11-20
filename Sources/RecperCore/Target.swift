import CoreGraphics

/// What is being recorded. All frames are in **global Cocoa coordinates** (bottom-left origin, relative to the primary screen).
public enum CaptureMode: String, CaseIterable, Sendable {
    case window, area, screen
}

public enum CaptureTarget: Equatable, Sendable {
    case window(id: UInt32, pid: Int32, app: String, frame: CGRect)
    case area(frame: CGRect)
    case screen(displayID: UInt32, name: String, frame: CGRect)

    public var frame: CGRect {
        switch self {
        case .window(_, _, _, let f), .area(let f), .screen(_, _, let f): f
        }
    }

    public var mode: CaptureMode {
        switch self {
        case .window: .window
        case .area: .area
        case .screen: .screen
        }
    }

    /// Short name shown in the session bar.
    public var label: String {
        switch self {
        case .window(_, _, let app, _): "Window · \(app)"
        case .area(let f): "Area · \(Int(f.width))×\(Int(f.height))"
        case .screen(_, let name, _): "Screen · \(name)"
        }
    }

    public func with(frame: CGRect) -> CaptureTarget {
        switch self {
        case .window(let id, let pid, let app, _): .window(id: id, pid: pid, app: app, frame: frame)
        case .area: .area(frame: frame)
        case .screen(let d, let n, _): .screen(displayID: d, name: n, frame: frame)
        }
    }
}
