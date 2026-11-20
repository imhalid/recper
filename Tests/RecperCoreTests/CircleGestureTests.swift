import Testing
import CoreGraphics
import Foundation
@testable import RecperCore

private let testTarget = CGRect(x: 0, y: 0, width: 1440, height: 900)

private func feed(_ points: [(CGPoint, Double)], target: CGRect? = testTarget, into detector: inout CircleGestureDetector) -> CGRect? {
    for (p, t) in points {
        if let rect = detector.add(point: p, at: t, within: target) {
            return rect
        }
    }
    return nil
}

private func circlePath(center: CGPoint, rx: CGFloat, ry: CGFloat, degrees: Double, clockwise: Bool = false,
                        steps: Int = 48, startTime: Double = 1.0, duration: Double = 0.8,
                        wobble: CGFloat = 0) -> [(CGPoint, Double)] {
    let dir = clockwise ? -1.0 : 1.0
    let totalRad = degrees * .pi / 180.0
    return (0...steps).map { i in
        let frac = Double(i) / Double(steps)
        let a = dir * frac * totalRad
        let noiseR: CGFloat = wobble > 0 ? 1 + wobble * CGFloat(sin(Double(i) * 1.7)) : 1
        let x = center.x + rx * noiseR * CGFloat(cos(a))
        let y = center.y + ry * noiseR * CGFloat(sin(a))
        return (CGPoint(x: x, y: y), startTime + frac * duration)
    }
}

@Test func detectsCleanCircleCCWAndCW() {
    var d1 = CircleGestureDetector()
    let r1 = feed(circlePath(center: CGPoint(x: 400, y: 300), rx: 60, ry: 60, degrees: 360, clockwise: false), into: &d1)
    #expect(r1 != nil)
    if let r1 {
        #expect(abs(r1.midX - 400) < 10)
        #expect(abs(r1.midY - 300) < 10)
        #expect(abs(r1.width - 120) < 12)
        #expect(abs(r1.height - 120) < 12)
    }

    var d2 = CircleGestureDetector()
    let r2 = feed(circlePath(center: CGPoint(x: 700, y: 500), rx: 80, ry: 50, degrees: 350, clockwise: true, wobble: 0.08), into: &d2)
    #expect(r2 != nil)
    if let r2 {
        #expect(abs(r2.midX - 700) < 15)
        #expect(abs(r2.midY - 500) < 15)
    }
}

@Test func detectsCircleAfterStraightLeadIn() {
    var d = CircleGestureDetector()
    // Move horizontally from x=100 to x=560 (lead-in travel), then circle around (500, 400) with radius 60.
    var pts: [(CGPoint, Double)] = []
    for i in 0..<25 {
        let frac = Double(i) / 24.0
        pts.append((CGPoint(x: 100 + 460 * frac, y: 400), frac * 0.4))
    }
    pts += circlePath(center: CGPoint(x: 500, y: 400), rx: 60, ry: 45, degrees: 360, steps: 44, startTime: 0.42, duration: 0.75, wobble: 0.06)
    let r = feed(pts, into: &d)
    #expect(r != nil)
    if let r {
        #expect(abs(r.midX - 500) < 15)
        #expect(abs(r.midY - 400) < 15)
        #expect(r.width > 95 && r.width < 145)
    }
}

@Test func rejectsStraightLineAndBackAndForth() {
    var d1 = CircleGestureDetector()
    let line = (0..<40).map { i in (CGPoint(x: 100 + CGFloat(i) * 10, y: 300 + CGFloat(i) * 2), 1.0 + Double(i) * 0.02) }
    #expect(feed(line, into: &d1) == nil)

    // There and back (closes on start, but zero area / cuts through center).
    var d2 = CircleGestureDetector()
    var backAndForth: [(CGPoint, Double)] = []
    for i in 0..<25 { backAndForth.append((CGPoint(x: 200 + CGFloat(i) * 10, y: 300), 1.0 + Double(i) * 0.015)) }
    for i in 0..<25 { backAndForth.append((CGPoint(x: 440 - CGFloat(i) * 10, y: 302), 1.4 + Double(i) * 0.015)) }
    #expect(feed(backAndForth, into: &d2) == nil)
}

@Test func rejectsZigZag() {
    var d = CircleGestureDetector()
    let pts: [(CGPoint, Double)] = (0..<60).map { i in
        let x = 200 + CGFloat(i) * 8
        let y = 300 + ((i % 6 < 3) ? CGFloat(i % 3) * 35 : CGFloat(3 - (i % 3)) * 35)
        return (CGPoint(x: x, y: y), 1.0 + Double(i) * 0.018)
    }
    #expect(feed(pts, into: &d) == nil)
}

@Test func rejectsSmallJitter() {
    var d = CircleGestureDetector()
    // Tiny 8pt circle (below minRadius 15pt).
    let tiny = circlePath(center: CGPoint(x: 300, y: 300), rx: 8, ry: 8, degrees: 380, steps: 36, duration: 0.6)
    #expect(feed(tiny, into: &d) == nil)
}

@Test func rejectsHalfCircleAndThreeQuarterArc() {
    var d1 = CircleGestureDetector()
    let half = circlePath(center: CGPoint(x: 400, y: 400), rx: 70, ry: 70, degrees: 180, steps: 32, duration: 0.6)
    #expect(feed(half, into: &d1) == nil)

    var d2 = CircleGestureDetector()
    let threeQuarter = circlePath(center: CGPoint(x: 400, y: 400), rx: 70, ry: 70, degrees: 270, steps: 40, duration: 0.7)
    #expect(feed(threeQuarter, into: &d2) == nil)
}

@Test func rejectsFigureEight() {
    var d = CircleGestureDetector()
    // Figure-8 over 0.55 s: crosses center and reverses winding across both lobes.
    let pts: [(CGPoint, Double)] = (0...80).map { i in
        let a = Double(i) / 80.0 * 2.0 * .pi
        let x = 500 + 90 * CGFloat(sin(a))
        let y = 400 + 60 * CGFloat(sin(2 * a))
        return (CGPoint(x: x, y: y), 1.0 + Double(i) * (0.55 / 80.0))
    }
    #expect(feed(pts, into: &d) == nil)
}

@Test func rejectsTooSlowTooFastAndTooLarge() {
    var dSlow = CircleGestureDetector()
    let slow = circlePath(center: CGPoint(x: 400, y: 400), rx: 60, ry: 60, degrees: 360, steps: 60, duration: 4.0)
    #expect(feed(slow, into: &dSlow) == nil)

    var dFast = CircleGestureDetector()
    let fast = circlePath(center: CGPoint(x: 400, y: 400), rx: 60, ry: 60, degrees: 360, steps: 30, duration: 0.08)
    #expect(feed(fast, into: &dFast) == nil)

    var dHuge = CircleGestureDetector()
    let huge = circlePath(center: CGPoint(x: 700, y: 450), rx: 450, ry: 450, degrees: 360, steps: 80, duration: 1.0)
    #expect(feed(huge, target: CGRect(x: 0, y: 0, width: 2000, height: 2000), into: &dHuge) == nil)
}

@Test func rejectsRectangleAndDShape() {
    // Sharp square navigation path: corners reach r = √2, should not trigger circle gesture.
    var dSq = CircleGestureDetector()
    var sq: [(CGPoint, Double)] = []
    for i in 0..<15 { sq.append((CGPoint(x: 300 + CGFloat(i) * 10, y: 300), 1.0 + Double(i) * 0.015)) }
    for i in 0..<15 { sq.append((CGPoint(x: 440, y: 300 + CGFloat(i) * 10), 1.23 + Double(i) * 0.015)) }
    for i in 0..<15 { sq.append((CGPoint(x: 440 - CGFloat(i) * 10, y: 440), 1.46 + Double(i) * 0.015)) }
    for i in 0..<15 { sq.append((CGPoint(x: 300, y: 440 - CGFloat(i) * 10), 1.69 + Double(i) * 0.015)) }
    #expect(feed(sq, into: &dSq) == nil)
}

@Test func respectsTargetBoundsAndCooldown() {
    let smallTarget = CGRect(x: 100, y: 100, width: 300, height: 300)
    var d = CircleGestureDetector()
    // Circle outside target is ignored.
    let outside = circlePath(center: CGPoint(x: 700, y: 500), rx: 50, ry: 50, degrees: 360, startTime: 1.0, duration: 0.7)
    #expect(feed(outside, target: smallTarget, into: &d) == nil)

    // Circle inside target triggers once, then cooldown suppresses an immediate second circle.
    let inside1 = circlePath(center: CGPoint(x: 250, y: 250), rx: 50, ry: 50, degrees: 360, startTime: 2.0, duration: 0.7)
    #expect(feed(inside1, target: smallTarget, into: &d) != nil)

    let duringCooldown = circlePath(center: CGPoint(x: 250, y: 250), rx: 50, ry: 50, degrees: 360, startTime: 2.8, duration: 0.6)
    #expect(feed(duringCooldown, target: smallTarget, into: &d) == nil)

    // After cooldown expires, a new circle triggers again.
    let afterCooldown = circlePath(center: CGPoint(x: 250, y: 250), rx: 50, ry: 50, degrees: 360, startTime: 4.2, duration: 0.7)
    #expect(feed(afterCooldown, target: smallTarget, into: &d) != nil)
}
