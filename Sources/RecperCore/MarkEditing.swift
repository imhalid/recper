import CoreGraphics
import Foundation

/// Interactive handle on an editable mark (global Cocoa coordinates: +y is up).
public enum MarkHandle: Equatable, Sendable {
    case topLeft, top, topRight
    case left, right
    case bottomLeft, bottom, bottomRight
    case start, end
    case body
}

/// Lightweight geometry snapshot of an editable on-screen mark (box, ellipse, arrow, blur).
public struct EditableMark: Equatable, Sendable {
    public var id: UUID
    public var tool: Tool
    public var points: [CGPoint]

    public init(id: UUID, tool: Tool, points: [CGPoint]) {
        self.id = id
        self.tool = tool
        self.points = points
    }

    public var isEditableTool: Bool {
        switch tool {
        case .box, .ellipse, .arrow, .blur: true
        case .pen: false
        }
    }
}

public struct MarkHit: Equatable, Sendable {
    public var id: UUID
    public var handle: MarkHandle

    public init(id: UUID, handle: MarkHandle) {
        self.id = id
        self.handle = handle
    }
}

/// Pure geometry, hit-testing, moving, and resizing for editable marks (global Cocoa coordinates).
public enum MarkGeometry {
    /// Minimum width/height for rectangular marks (box, ellipse, blur) and minimum length for arrows.
    public static let minSize: CGFloat = 16
    /// Hit radius around corner/endpoint handles.
    public static let handleHitRadius: CGFloat = 10
    /// Hit band around edges (for resizing a selected rect) and around hollow shape strokes.
    public static let strokeHitBand: CGFloat = 9
    public static let edgeHitBand: CGFloat = 7
    /// Minimum edge length to display midpoint edge handles visually (edge line remains draggable regardless).
    public static let minEdgeHandleSpan: CGFloat = 34

    public static func rect(for points: [CGPoint]) -> CGRect? {
        guard let a = points.first, let b = points.last else { return nil }
        return CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
    }

    public static func points(for rect: CGRect) -> [CGPoint] {
        [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.maxY)]
    }

    /// Visual handle positions for a selected mark.
    public static func handles(for mark: EditableMark) -> [(handle: MarkHandle, point: CGPoint)] {
        guard mark.isEditableTool else { return [] }
        if mark.tool == .arrow {
            guard let a = mark.points.first, let b = mark.points.last else { return [] }
            return [(.start, a), (.end, b)]
        }
        guard let r = rect(for: mark.points) else { return [] }
        var out: [(MarkHandle, CGPoint)] = [
            (.topLeft, CGPoint(x: r.minX, y: r.maxY)),
            (.topRight, CGPoint(x: r.maxX, y: r.maxY)),
            (.bottomLeft, CGPoint(x: r.minX, y: r.minY)),
            (.bottomRight, CGPoint(x: r.maxX, y: r.minY)),
        ]
        if r.width >= minEdgeHandleSpan {
            out.append((.top, CGPoint(x: r.midX, y: r.maxY)))
            out.append((.bottom, CGPoint(x: r.midX, y: r.minY)))
        }
        if r.height >= minEdgeHandleSpan {
            out.append((.left, CGPoint(x: r.minX, y: r.midY)))
            out.append((.right, CGPoint(x: r.maxX, y: r.midY)))
        }
        return out
    }

    /// Hit-tests `point` against editable marks (topmost first, with the currently selected mark's handles prioritized).
    /// Unselected hollow marks (box, ellipse) only hit near their outline (unless very small) so clicks inside pass through.
    /// Selected marks also hit anywhere inside their bounding rect so dragging the body is effortless.
    public static func hitTest(point p: CGPoint, marks: [EditableMark], selectedID: UUID?) -> MarkHit? {
        // 1. Prioritize handles on the currently selected mark.
        if let selectedID, let sel = marks.first(where: { $0.id == selectedID }), sel.isEditableTool {
            if let h = hitSelectedHandles(point: p, mark: sel) {
                return MarkHit(id: sel.id, handle: h)
            }
        }

        // 2. Hit-test bodies in reverse (front-to-back) order.
        for mark in marks.reversed() where mark.isEditableTool {
            let isSelected = (mark.id == selectedID)
            if hitBody(point: p, mark: mark, isSelected: isSelected) {
                return MarkHit(id: mark.id, handle: .body)
            }
        }
        return nil
    }

    private static func hitSelectedHandles(point p: CGPoint, mark: EditableMark) -> MarkHandle? {
        if mark.tool == .arrow {
            guard let a = mark.points.first, let b = mark.points.last else { return nil }
            let da = hypot(p.x - a.x, p.y - a.y)
            let db = hypot(p.x - b.x, p.y - b.y)
            if da <= handleHitRadius && da <= db { return .start }
            if db <= handleHitRadius { return .end }
            return nil
        }
        guard let r = rect(for: mark.points) else { return nil }

        // Check corners first so they take precedence over edges.
        let corners: [(MarkHandle, CGPoint)] = [
            (.topLeft, CGPoint(x: r.minX, y: r.maxY)),
            (.topRight, CGPoint(x: r.maxX, y: r.maxY)),
            (.bottomLeft, CGPoint(x: r.minX, y: r.minY)),
            (.bottomRight, CGPoint(x: r.maxX, y: r.minY)),
        ]
        var bestCorner: (MarkHandle, CGFloat)?
        for (h, c) in corners {
            let d = hypot(p.x - c.x, p.y - c.y)
            if d <= handleHitRadius, d < (bestCorner?.1 ?? .infinity) {
                bestCorner = (h, d)
            }
        }
        if let best = bestCorner { return best.0 }

        // Check the 4 edges (within edgeHitBand along the edge span).
        let onX = p.x >= r.minX - edgeHitBand && p.x <= r.maxX + edgeHitBand
        let onY = p.y >= r.minY - edgeHitBand && p.y <= r.maxY + edgeHitBand
        var bestEdge: (MarkHandle, CGFloat)?
        func consider(_ h: MarkHandle, _ d: CGFloat) {
            if d <= edgeHitBand, d < (bestEdge?.1 ?? .infinity) { bestEdge = (h, d) }
        }
        if onX {
            consider(.top, abs(p.y - r.maxY))
            consider(.bottom, abs(p.y - r.minY))
        }
        if onY {
            consider(.left, abs(p.x - r.minX))
            consider(.right, abs(p.x - r.maxX))
        }
        return bestEdge?.0
    }

    private static func hitBody(point p: CGPoint, mark: EditableMark, isSelected: Bool) -> Bool {
        switch mark.tool {
        case .blur:
            guard let r = rect(for: mark.points) else { return false }
            return r.insetBy(dx: -4, dy: -4).contains(p)

        case .box:
            guard let r = rect(for: mark.points) else { return false }
            let outer = r.insetBy(dx: -strokeHitBand, dy: -strokeHitBand)
            guard outer.contains(p) else { return false }
            if isSelected || r.width < 28 || r.height < 28 { return true }
            let inner = r.insetBy(dx: strokeHitBand, dy: strokeHitBand)
            return !inner.contains(p)

        case .ellipse:
            guard let r = rect(for: mark.points) else { return false }
            let outer = r.insetBy(dx: -strokeHitBand, dy: -strokeHitBand)
            guard outer.contains(p) else { return false }
            let rx = max(r.width / 2, 1), ry = max(r.height / 2, 1)
            let dx = p.x - r.midX, dy = p.y - r.midY
            if isSelected {
                // Selected: allow dragging anywhere inside the bounding rect (handles were already checked).
                return r.contains(p) || distanceToEllipse(dx: dx, dy: dy, rx: rx, ry: ry) <= strokeHitBand
            }
            if r.width < 28 || r.height < 28 {
                let norm = (dx * dx) / (rx * rx) + (dy * dy) / (ry * ry)
                return norm <= 1.35
            }
            return distanceToEllipse(dx: dx, dy: dy, rx: rx, ry: ry) <= strokeHitBand

        case .arrow:
            guard let a = mark.points.first, let b = mark.points.last else { return false }
            return distanceToSegment(p, a, b) <= strokeHitBand

        case .pen:
            return false
        }
    }

    /// Approximate Euclidean distance from `(dx, dy)` (relative to ellipse center) to the ellipse perimeter `(rx, ry)`.
    private static func distanceToEllipse(dx: CGFloat, dy: CGFloat, rx: CGFloat, ry: CGFloat) -> CGFloat {
        let len = hypot(dx, dy)
        guard len > 0.001 else { return min(rx, ry) }
        // Exact ray intersection with the ellipse scaled by local gradient gives a tight distance estimate.
        let nx = dx / rx, ny = dy / ry
        let k = hypot(nx, ny)
        guard k > 0.0001 else { return min(rx, ry) }
        let px = dx / k, py = dy / k
        return hypot(dx - px, dy - py)
    }

    private static func distanceToSegment(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let vx = b.x - a.x, vy = b.y - a.y
        let l2 = vx * vx + vy * vy
        guard l2 > 0.0001 else { return hypot(p.x - a.x, p.y - a.y) }
        let t = max(0, min(1, ((p.x - a.x) * vx + (p.y - a.y) * vy) / l2))
        return hypot(p.x - (a.x + t * vx), p.y - (a.y + t * vy))
    }

    /// Moves a mark from its initial geometry by `delta`, clamped strictly inside `target`.
    public static func move(mark: EditableMark, by delta: CGSize, within target: CGRect) -> [CGPoint] {
        guard mark.isEditableTool, let a = mark.points.first, let b = mark.points.last else { return mark.points }
        if mark.tool == .arrow {
            let minX = min(a.x, b.x), maxX = max(a.x, b.x)
            let minY = min(a.y, b.y), maxY = max(a.y, b.y)
            let dxMin = target.minX - minX, dxMax = target.maxX - maxX
            let dyMin = target.minY - minY, dyMax = target.maxY - maxY
            let dx = dxMin <= dxMax ? min(max(delta.width, dxMin), dxMax) : 0
            let dy = dyMin <= dyMax ? min(max(delta.height, dyMin), dyMax) : 0
            return [CGPoint(x: a.x + dx, y: a.y + dy), CGPoint(x: b.x + dx, y: b.y + dy)]
        }
        guard let r = rect(for: mark.points) else { return mark.points }
        let maxX = max(target.minX, target.maxX - r.width)
        let maxY = max(target.minY, target.maxY - r.height)
        let nx = min(max(r.minX + delta.width, target.minX), maxX)
        let ny = min(max(r.minY + delta.height, target.minY), maxY)
        return points(for: CGRect(x: nx, y: ny, width: r.width, height: r.height))
    }

    /// Resizes a mark from its initial geometry by dragging `handle` from `startPoint` to `currentPoint`,
    /// preserving minimum size and clamping strictly inside `target`.
    public static func resize(mark: EditableMark, handle: MarkHandle, from startPoint: CGPoint, to currentPoint: CGPoint, within target: CGRect) -> [CGPoint] {
        guard mark.isEditableTool else { return mark.points }
        if handle == .body {
            return move(mark: mark, by: CGSize(width: currentPoint.x - startPoint.x, height: currentPoint.y - startPoint.y), within: target)
        }

        let clampedCurrent = clamp(currentPoint, to: target)

        if mark.tool == .arrow {
            guard let a0 = mark.points.first, let b0 = mark.points.last else { return mark.points }
            let dx = currentPoint.x - startPoint.x, dy = currentPoint.y - startPoint.y
            switch handle {
            case .start:
                var na = clamp(CGPoint(x: a0.x + dx, y: a0.y + dy), to: target)
                na = enforceMinDistance(moving: na, anchor: b0, minDist: minSize, within: target, fallback: a0)
                return [na, b0]
            case .end:
                var nb = clamp(CGPoint(x: b0.x + dx, y: b0.y + dy), to: target)
                nb = enforceMinDistance(moving: nb, anchor: a0, minDist: minSize, within: target, fallback: b0)
                return [a0, nb]
            default:
                return mark.points
            }
        }

        guard let r0 = rect(for: mark.points) else { return mark.points }
        let dx = currentPoint.x - startPoint.x, dy = currentPoint.y - startPoint.y
        let minW = min(minSize, target.width)
        let minH = min(minSize, target.height)

        var x0 = r0.minX, x1 = r0.maxX
        var y0 = r0.minY, y1 = r0.maxY

        switch handle {
        case .left, .topLeft, .bottomLeft:
            x0 = min(max(r0.minX + dx, target.minX), x1 - minW)
        case .right, .topRight, .bottomRight:
            x1 = max(min(r0.maxX + dx, target.maxX), x0 + minW)
        default: break
        }

        switch handle {
        case .bottom, .bottomLeft, .bottomRight:
            y0 = min(max(r0.minY + dy, target.minY), y1 - minH)
        case .top, .topLeft, .topRight:
            y1 = max(min(r0.maxY + dy, target.maxY), y0 + minH)
        default: break
        }

        _ = clampedCurrent
        return points(for: CGRect(x: x0, y: y0, width: max(minW, x1 - x0), height: max(minH, y1 - y0)))
    }

    private static func clamp(_ p: CGPoint, to r: CGRect) -> CGPoint {
        CGPoint(x: min(max(p.x, r.minX), r.maxX), y: min(max(p.y, r.minY), r.maxY))
    }

    private static func enforceMinDistance(moving p: CGPoint, anchor: CGPoint, minDist: CGFloat, within target: CGRect, fallback: CGPoint) -> CGPoint {
        let d = hypot(p.x - anchor.x, p.y - anchor.y)
        guard d < minDist else { return p }
        // Push outward along current direction (or fallback direction if coincident with anchor).
        let ux: CGFloat, uy: CGFloat
        if d > 0.001 {
            ux = (p.x - anchor.x) / d; uy = (p.y - anchor.y) / d
        } else {
            let fd = hypot(fallback.x - anchor.x, fallback.y - anchor.y)
            guard fd > 0.001 else { return fallback }
            ux = (fallback.x - anchor.x) / fd; uy = (fallback.y - anchor.y) / fd
        }
        let pushed = clamp(CGPoint(x: anchor.x + ux * minDist, y: anchor.y + uy * minDist), to: target)
        return hypot(pushed.x - anchor.x, pushed.y - anchor.y) >= minDist - 0.5 ? pushed : fallback
    }
}
