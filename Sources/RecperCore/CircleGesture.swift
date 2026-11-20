import CoreGraphics
import Foundation

/// Pure-Swift detector for circular/looping mouse gestures (without clicking) in cursor mode.
/// Designed for very low per-event CPU cost and high resistance to false positives on normal pointer travel.
public struct CircleGestureDetector: Sendable {
    public struct Config: Sendable {
        /// Minimum sample spacing (pt) to ignore micro-jitter and keep the window compact.
        public var minStep: CGFloat = 4.0
        /// Maximum idle pause between consecutive moves (s) before the trail resets.
        public var maxPause: Double = 0.35
        /// Valid gesture duration range (s).
        public var minDuration: Double = 0.30
        public var maxDuration: Double = 2.0
        /// Allowed semi-axis radius range (pt).
        public var minRadius: CGFloat = 15
        public var maxRadius: CGFloat = 400
        /// Maximum ellipse aspect ratio (allows circling wide UI buttons while rejecting lines).
        public var maxAspectRatio: CGFloat = 3.2
        /// Minimum signed angular sweep (degrees) around the loop center (~320° catches natural hand loops while rejecting arcs).
        public var minSweepDegrees: Double = 320
        /// Maximum allowed normalized start-to-end closure gap (in unit-ellipse coordinates; ~0.52 allows a ~30° gap).
        public var maxClosureNormalized: CGFloat = 0.52
        /// Maximum coefficient of variation of normalized radius around the ellipse.
        public var maxRadiusCV: CGFloat = 0.22
        /// Allowed normalized radius bounds (true ellipse = 1.0; corners of boxes/D-shapes reach 1.414; center crossings dip near 0).
        public var minNormalizedRadius: CGFloat = 0.60
        public var maxNormalizedRadius: CGFloat = 1.24
        /// Allowed Shoelace area / bounding-box area ratio (true ellipse = π/4 ≈ 0.785; rejects triangles and pinched shapes).
        public var minAreaRatio: CGFloat = 0.66
        public var maxAreaRatio: CGFloat = 0.90
        /// Maximum ratio of backward angular wobble to forward sweep.
        public var maxReversalRatio: Double = 0.12
        /// Cooldown after a detection (s) so trailing pointer motion never double-triggers.
        public var cooldown: Double = 1.2
        /// Minimum number of filtered samples needed to form a loop.
        public var minSamples: Int = 12
        /// Maximum samples retained in the rolling buffer.
        public var maxSamples: Int = 220

        public init() {}
    }

    private struct Sample: Sendable {
        var point: CGPoint
        var time: Double
    }

    public var config: Config
    private var samples: [Sample] = []
    private var cooldownUntil: Double = -.infinity

    public init(config: Config = Config()) {
        self.config = config
    }

    /// Clears accumulated pointer history (call on clicks, drags, tool switches, or leaving the session).
    public mutating func reset() {
        samples.removeAll(keepingCapacity: true)
    }

    /// Feeds one pointer position at monotonic timestamp `time` (seconds).
    /// Returns the global bounding `CGRect` of the circled region when a clear loop completes, otherwise `nil`.
    /// When `target` is non-nil, the circled region must lie inside `target`.
    public mutating func add(point p: CGPoint, at time: Double, within target: CGRect? = nil) -> CGRect? {
        if time < cooldownUntil {
            samples.removeAll(keepingCapacity: true)
            return nil
        }

        if let target, !target.contains(p) {
            samples.removeAll(keepingCapacity: true)
            return nil
        }

        if let last = samples.last {
            if time < last.time || time - last.time > config.maxPause {
                samples.removeAll(keepingCapacity: true)
            } else if hypot(p.x - last.point.x, p.y - last.point.y) < config.minStep {
                return nil
            }
        }

        samples.append(Sample(point: p, time: time))

        // Trim expired samples outside the time window.
        let cutoff = time - config.maxDuration
        if let firstValid = samples.firstIndex(where: { $0.time >= cutoff }), firstValid > 0 {
            samples.removeFirst(firstValid)
        }
        if samples.count > config.maxSamples {
            samples.removeFirst(samples.count - config.maxSamples)
        }

        guard samples.count >= config.minSamples else { return nil }

        if let rect = detectLoop(within: target) {
            samples.removeAll(keepingCapacity: true)
            cooldownUntil = time + config.cooldown
            return rect
        }
        return nil
    }

    /// Scans backwards from the latest sample for the tightest closed circular/elliptical sub-window.
    /// Walking backwards naturally ignores any straight lead-in travel before the user began circling.
    private func detectLoop(within target: CGRect?) -> CGRect? {
        let lastIdx = samples.count - 1
        let end = samples[lastIdx]

        var minX = end.point.x, maxX = end.point.x
        var minY = end.point.y, maxY = end.point.y
        var arcLen: CGFloat = 0

        let minSweepRad = config.minSweepDegrees * .pi / 180.0
        let maxSweepRad = 450.0 * .pi / 180.0

        // Seed incremental stats with the first `minSamples - 1` steps backwards.
        var idx = lastIdx - 1
        let earliestCheck = lastIdx - (config.minSamples - 1)
        while idx > earliestCheck {
            let cur = samples[idx].point
            let nxt = samples[idx + 1].point
            arcLen += hypot(nxt.x - cur.x, nxt.y - cur.y)
            if cur.x < minX { minX = cur.x } else if cur.x > maxX { maxX = cur.x }
            if cur.y < minY { minY = cur.y } else if cur.y > maxY { maxY = cur.y }
            idx -= 1
        }

        // Now evaluate candidate start indices going backwards from `earliestCheck` to `0`.
        for i in stride(from: earliestCheck, through: 0, by: -1) {
            let cur = samples[i].point
            let nxt = samples[i + 1].point
            arcLen += hypot(nxt.x - cur.x, nxt.y - cur.y)
            if cur.x < minX { minX = cur.x } else if cur.x > maxX { maxX = cur.x }
            if cur.y < minY { minY = cur.y } else if cur.y > maxY { maxY = cur.y }

            let dt = end.time - samples[i].time
            if dt > config.maxDuration { break }
            if dt < config.minDuration { continue }

            let w = maxX - minX
            let h = maxY - minY
            let rx = w * 0.5
            let ry = h * 0.5

            // Bounding box only grows as we walk further back.
            if rx > config.maxRadius || ry > config.maxRadius { break }
            if rx < config.minRadius || ry < config.minRadius { continue }

            let aspect = max(rx, ry) / min(rx, ry)
            if aspect > config.maxAspectRatio { continue }

            // Fast closure check in normalized ellipse space.
            let closeNorm = hypot((end.point.x - cur.x) / rx, (end.point.y - cur.y) / ry)
            if closeNorm > config.maxClosureNormalized { continue }

            // Fast perimeter sanity check (elliptical approximation).
            let perimeter = 2.0 * .pi * sqrt((rx * rx + ry * ry) * 0.5)
            if arcLen < perimeter * 0.78 || arcLen > perimeter * 1.55 { continue }

            // Full geometric validation on samples[i...lastIdx].
            if verify(from: i, to: lastIdx, minX: minX, maxX: maxX, minY: minY, maxY: maxY,
                      minSweepRad: minSweepRad, maxSweepRad: maxSweepRad) {
                let rect = CGRect(x: minX, y: minY, width: w, height: h)
                if let target, !target.contains(rect) { continue }
                return rect
            }
        }
        return nil
    }

    private func verify(from start: Int, to end: Int,
                        minX: CGFloat, maxX: CGFloat, minY: CGFloat, maxY: CGFloat,
                        minSweepRad: Double, maxSweepRad: Double) -> Bool {
        let count = end - start + 1
        guard count >= config.minSamples else { return false }

        let cx = (minX + maxX) * 0.5
        let cy = (minY + maxY) * 0.5
        let rx = (maxX - minX) * 0.5
        let ry = (maxY - minY) * 0.5
        guard rx > 0, ry > 0 else { return false }

        var sumU: CGFloat = 0, sumV: CGFloat = 0
        var sumR: CGFloat = 0, sumR2: CGFloat = 0
        var prevAngle: Double = 0
        var totalSweep: Double = 0
        var posSweep: Double = 0
        var negSweep: Double = 0
        var quadrants: UInt8 = 0
        var shoelace2: CGFloat = 0

        for idx in start...end {
            let p = samples[idx].point
            let u = (p.x - cx) / rx
            let v = (p.y - cy) / ry
            sumU += u; sumV += v

            let r = hypot(u, v)
            if r < config.minNormalizedRadius || r > config.maxNormalizedRadius { return false }
            sumR += r
            sumR2 += r * r

            let nextP = samples[idx < end ? idx + 1 : start].point
            shoelace2 += (p.x - cx) * (nextP.y - cy) - (nextP.x - cx) * (p.y - cy)

            let ang = atan2(Double(v), Double(u))
            // Track all 4 quadrants around the center.
            if u >= 0 && v >= 0 { quadrants |= 1 }
            else if u < 0 && v >= 0 { quadrants |= 2 }
            else if u < 0 && v < 0 { quadrants |= 4 }
            else { quadrants |= 8 }

            if idx > start {
                var d = ang - prevAngle
                if d > .pi { d -= 2 * .pi }
                else if d < -.pi { d += 2 * .pi }
                totalSweep += d
                if d > 0 { posSweep += d } else { negSweep += -d }
            }
            prevAngle = ang
        }

        // Must surround all 4 quadrants.
        guard quadrants == 0b1111 else { return false }

        // Enclosed area vs bounding box area (ellipse = π/4 ≈ 0.785).
        let bboxArea = (maxX - minX) * (maxY - minY)
        guard bboxArea > 0 else { return false }
        let areaRatio = abs(shoelace2) * 0.5 / bboxArea
        guard areaRatio >= config.minAreaRatio, areaRatio <= config.maxAreaRatio else { return false }

        // Centroid must stay reasonably close to the bounding-box center (rejects lopsided tails/loops).
        let n = CGFloat(count)
        let meanU = sumU / n, meanV = sumV / n
        guard hypot(meanU, meanV) <= 0.35 else { return false }

        // Angular sweep in [minSweepRad, maxSweepRad].
        let absSweep = abs(totalSweep)
        guard absSweep >= minSweepRad, absSweep <= maxSweepRad else { return false }

        // Monotonicity: almost all angular motion must be in the dominant winding direction.
        let forward = totalSweep >= 0 ? posSweep : negSweep
        let backward = totalSweep >= 0 ? negSweep : posSweep
        guard forward > 0, backward / forward <= config.maxReversalRatio else { return false }

        // Consistent radius around the unit ellipse.
        let meanR = sumR / n
        guard meanR >= 0.78, meanR <= 1.18 else { return false }
        let variance = max(0, sumR2 / n - meanR * meanR)
        let cv = sqrt(variance) / meanR
        guard cv <= config.maxRadiusCV else { return false }

        return true
    }
}
