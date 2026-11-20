import Testing
import CoreGraphics
@testable import RecperCore

private func line(speed: Double) -> [Brush.Stamp] {
    let pts = (0..<80).map { CGPoint(x: Double($0) * 5, y: 0) }
    let ts = (0..<80).map { Double($0) * 5 / speed }
    return Brush.stamps(pts, times: ts, base: 3)
}

private func midWidth(_ s: [Brush.Stamp]) -> CGFloat { s[s.count / 2].w }

@Test func fasterIsThinner() {
    #expect(midWidth(line(speed: 2000)) < midWidth(line(speed: 50)))
    #expect(midWidth(line(speed: 2000)) >= 3 * 0.4 - 0.01)
    #expect(midWidth(line(speed: 50)) <= 3 * 1.7 + 0.01)
}

@Test func endsTaper() {
    let s = line(speed: 300)
    #expect(s.first!.w < midWidth(s) && s.last!.w < midWidth(s))
}

@Test func shapesAreCleanOutlines() {
    let box = Shapes.box(.zero, CGPoint(x: 200, y: 100))
    #expect(box.contains(CGPoint(x: 100, y: 0.5), using: .winding))        // edge is filled
    #expect(!box.contains(CGPoint(x: 100, y: 50), using: .winding))       // interior is empty
    #expect(!box.contains(CGPoint(x: 0.3, y: 0.3), using: .winding))      // corner is rounded
    let arrow = Shapes.arrow(.zero, CGPoint(x: 100, y: 0))
    #expect(arrow.contains(CGPoint(x: 50, y: 0), using: .winding))
}

@Test func outlineFillsWithoutHoles() {
    // Circles and segments share winding: points on the line are filled under the nonzero rule.
    let pts = (0..<40).map { CGPoint(x: Double($0) * 5, y: 0) }
    let ts = (0..<40).map { Double($0) * 0.01 }
    let path = Brush.outline(pts, times: ts, base: 3)
    for x in stride(from: 10.0, through: 180, by: 7) {
        #expect(path.contains(CGPoint(x: x, y: 0), using: .winding))
    }
    #expect(!path.contains(CGPoint(x: 100, y: 10), using: .winding))
}
