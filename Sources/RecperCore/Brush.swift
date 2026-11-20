import CoreGraphics
import Foundation

/// Hand-drawn look: a brush that thickens/thins with speed, tapered stroke ends,
/// slightly wobbly, overshooting boxes/arrows. Same result on screen and in screenshots (fixed seed).
public enum Brush {
    /// One brush stamp: center and diameter.
    public struct Stamp: Equatable { public var p: CGPoint; public var w: CGFloat }

    /// Speed (points/s) → width mapping. Slow = thick (ink spreads), fast = thin.
    public static let slow: CGFloat = 60
    public static let fast: CGFloat = 1500

    /// Input smoothing (like Procreate's StreamLine): 0 = raw; closer to 1 is smoother but laggier.
    public static let streamline: CGFloat = 0.5

    /// Smoothed, densified centerline and the width at each point.
    /// `points` and `times` (s) have the same length. `base`: average stroke width.
    public static func profile(_ points: [CGPoint], times: [Double], base: CGFloat) -> (points: [CGPoint], widths: [CGFloat]) {
        guard points.count > 1, times.count == points.count else {
            return (Array(points.prefix(1)), points.isEmpty ? [] : [base * 1.2])
        }
        // 1) Drop samples that are too close (jitter), keep their times.
        var raw: [CGPoint] = [points[0]], ts: [Double] = [times[0]]
        for i in 1..<points.count where hypot(points[i].x - raw.last!.x, points[i].y - raw.last!.y) >= 0.75 {
            raw.append(points[i]); ts.append(times[i])
        }
        if raw.count == 1 { return ([raw[0]], [base * 1.2]) }

        // 2) StreamLine: each point is pulled toward the previous one; the last point stays raw so it keeps up with the cursor.
        var sm: [CGPoint] = [raw[0]]
        for i in 1..<raw.count {
            let s = sm[i - 1], p = raw[i]
            sm.append(CGPoint(x: s.x + (p.x - s.x) * (1 - streamline), y: s.y + (p.y - s.y) * (1 - streamline)))
        }
        sm[sm.count - 1] = raw[raw.count - 1]
        // 2b) Centered Gaussian smoothing (1-4-6-4-1, two passes): removes wobble without lag. Endpoints fixed.
        sm = gaussian(gaussian(sm))

        // 3) Width from speed (slow = thick, fast = thin), with inertia.
        let maxW = base * 1.6, minW = base * 0.45
        var widths: [CGFloat] = [base]
        var w = base
        for i in 1..<sm.count {
            let d = hypot(sm[i].x - sm[i - 1].x, sm[i].y - sm[i - 1].y)
            let v = d / max(ts[i] - ts[i - 1], 1.0 / 240)
            let k = min(max((v - slow) / (fast - slow), 0), 1)
            // Ease-in-out: smooth transition at medium speeds.
            let e = k * k * (3 - 2 * k)
            w += (maxW - (maxW - minW) * e - w) * 0.22
            widths.append(w)
        }

        // 4) Dense, smooth Catmull-Rom curve (~1.5 pt spacing).
        var dp: [CGPoint] = [], dw: [CGFloat] = []
        for i in 0..<(sm.count - 1) {
            let p0 = sm[max(i - 1, 0)], p1 = sm[i], p2 = sm[i + 1], p3 = sm[min(i + 2, sm.count - 1)]
            let n = max(1, Int((hypot(p2.x - p1.x, p2.y - p1.y) / 1.5).rounded(.up)))
            for j in 0..<n {
                let t = CGFloat(j) / CGFloat(n), t2 = t * t, t3 = t2 * t
                func cr(_ a: CGFloat, _ b: CGFloat, _ c: CGFloat, _ d: CGFloat) -> CGFloat {
                    0.5 * (2 * b + (c - a) * t + (2 * a - 5 * b + 4 * c - d) * t2 + (3 * b - a - 3 * c + d) * t3)
                }
                dp.append(CGPoint(x: cr(p0.x, p1.x, p2.x, p3.x), y: cr(p0.y, p1.y, p2.y, p3.y)))
                dw.append(widths[i] + (widths[i + 1] - widths[i]) * t)
            }
        }
        dp.append(sm[sm.count - 1]); dw.append(widths[widths.count - 1])

        // 5) Taper the ends: short at the start, long at the end (thins as the brush lifts). Along a smooth curve.
        let lens = cumulative(dp)
        let total = lens.last ?? 0
        let head = min(8, total * 0.25), tail = min(20, total * 0.35)
        for i in dw.indices {
            var f: CGFloat = 1
            if head > 0, lens[i] < head { let u = lens[i] / head; f = min(f, 0.3 + 0.7 * sin(u * .pi / 2)) }
            if tail > 0, total - lens[i] < tail { let u = (total - lens[i]) / tail; f = min(f, 0.18 + 0.82 * sin(u * .pi / 2)) }
            dw[i] *= f
        }
        return (dp, dw)
    }

    /// Stamps (for tests): the profile's points and widths.
    public static func stamps(_ points: [CGPoint], times: [Double], base: CGFloat) -> [Stamp] {
        let (p, w) = profile(points, times: times, base: base)
        return zip(p, w).map { Stamp(p: $0, w: $1) }
    }

    /// Brush stroke shape: a circle at each point + tangent quads wrapping consecutive circles.
    /// Joins are always round, no spikes on sharp turns. All parts wind counter-clockwise,
    /// so overlaps merge under nonzero fill (opposite winding would punch holes).
    public static func outline(_ points: [CGPoint], times: [Double], base: CGFloat) -> CGPath {
        let (p, w) = profile(points, times: times, base: base)
        let path = CGMutablePath()
        func dot(_ c: CGPoint, _ r: CGFloat) {
            path.move(to: CGPoint(x: c.x + r, y: c.y))
            path.addArc(center: c, radius: r, startAngle: 0, endAngle: 2 * .pi, clockwise: false)
            path.closeSubpath()
        }
        for i in p.indices { dot(p[i], w[i] / 2) }
        guard p.count > 1 else { return path }
        for i in 0..<(p.count - 1) {
            let a = p[i], b = p[i + 1], r1 = w[i] / 2, r2 = w[i + 1] / 2
            let L = hypot(b.x - a.x, b.y - a.y)
            guard L > abs(r1 - r2) + 0.001 else { continue }     // one contains the other: the circle suffices
            let ux = (b.x - a.x) / L, uy = (b.y - a.y) / L
            let c = (r1 - r2) / L, s = (1 - c * c).squareRoot()
            // Outer tangent points: n = c·u ± s·v (v perpendicular to u).
            let n1 = CGPoint(x: c * ux - s * uy, y: c * uy + s * ux)
            let n2 = CGPoint(x: c * ux + s * uy, y: c * uy - s * ux)
            // a+r1·n2 → b+r2·n2 → b+r2·n1 → a+r1·n1: counter-clockwise.
            path.move(to: CGPoint(x: a.x + r1 * n2.x, y: a.y + r1 * n2.y))
            path.addLine(to: CGPoint(x: b.x + r2 * n2.x, y: b.y + r2 * n2.y))
            path.addLine(to: CGPoint(x: b.x + r2 * n1.x, y: b.y + r2 * n1.y))
            path.addLine(to: CGPoint(x: a.x + r1 * n1.x, y: a.y + r1 * n1.y))
            path.closeSubpath()
        }
        return path
    }

    static func gaussian(_ p: [CGPoint]) -> [CGPoint] {
        guard p.count > 4 else { return p }
        let k: [CGFloat] = [1, 4, 6, 4, 1]
        var out = p
        for i in 1..<(p.count - 1) {
            var x: CGFloat = 0, y: CGFloat = 0, sum: CGFloat = 0
            for j in -2...2 {
                let idx = i + j
                guard idx >= 0, idx < p.count else { continue }
                x += p[idx].x * k[j + 2]; y += p[idx].y * k[j + 2]; sum += k[j + 2]
            }
            out[i] = CGPoint(x: x / sum, y: y / sum)
        }
        return out
    }

    /// Total path length (to tell a click from a drawing).
    public static func length(_ p: [CGPoint]) -> CGFloat { cumulative(p).last ?? 0 }

    static func cumulative(_ p: [CGPoint]) -> [CGFloat] {
        var s: CGFloat = 0
        var out: [CGFloat] = [0]
        for i in 1..<max(p.count, 1) {
            s += hypot(p[i].x - p[i - 1].x, p[i].y - p[i - 1].y); out.append(s)
        }
        return out
    }
}

/// Box, ellipse and arrow: not hand-drawn, but clean with constant width (box corners slightly rounded).
/// Returns a fill path (stroke outline converted to a shape), drawn through the same pipeline as the pen.
public enum Shapes {
    public static let width: CGFloat = 3

    public static func rect(_ a: CGPoint, _ b: CGPoint) -> CGRect {
        CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
    }

    public static func box(_ a: CGPoint, _ b: CGPoint, width: CGFloat = width) -> CGPath {
        let r = rect(a, b)
        let radius = min(7, r.width / 4, r.height / 4)
        return CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil)
            .copy(strokingWithWidth: width, lineCap: .round, lineJoin: .round, miterLimit: 10)
    }

    public static func ellipse(_ a: CGPoint, _ b: CGPoint, width: CGFloat = width) -> CGPath {
        CGPath(ellipseIn: rect(a, b), transform: nil)
            .copy(strokingWithWidth: width, lineCap: .round, lineJoin: .round, miterLimit: 10)
    }

    /// Shaft + head: the head is two short arms with round joins (like Figma arrows).
    public static func arrow(_ a: CGPoint, _ b: CGPoint, width: CGFloat = width) -> CGPath {
        let len = hypot(b.x - a.x, b.y - a.y)
        let p = CGMutablePath()
        guard len > 1 else { return p }
        let ang = atan2(b.y - a.y, b.x - a.x)
        let head = min(16, max(9, len * 0.3))
        let spread: CGFloat = .pi / 6
        p.move(to: a); p.addLine(to: b)
        p.move(to: CGPoint(x: b.x - head * cos(ang - spread), y: b.y - head * sin(ang - spread)))
        p.addLine(to: b)
        p.addLine(to: CGPoint(x: b.x - head * cos(ang + spread), y: b.y - head * sin(ang + spread)))
        return p.copy(strokingWithWidth: width, lineCap: .round, lineJoin: .round, miterLimit: 10)
    }
}
