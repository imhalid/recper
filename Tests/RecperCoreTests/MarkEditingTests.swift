import Testing
import CoreGraphics
import Foundation
@testable import RecperCore

@Test func hitTestsBoxOutlineVsHollowInterior() {
    let id = UUID()
    let box = EditableMark(id: id, tool: .box, points: [CGPoint(x: 100, y: 100), CGPoint(x: 300, y: 240)])
    // Unselected: outline hits, hollow center misses (so clicks inside pass to app).
    #expect(MarkGeometry.hitTest(point: CGPoint(x: 100, y: 170), marks: [box], selectedID: nil) == MarkHit(id: id, handle: .body))
    #expect(MarkGeometry.hitTest(point: CGPoint(x: 200, y: 170), marks: [box], selectedID: nil) == nil)

    // Selected: corners, edges, and interior all hit appropriately.
    #expect(MarkGeometry.hitTest(point: CGPoint(x: 100, y: 240), marks: [box], selectedID: id) == MarkHit(id: id, handle: .topLeft))
    #expect(MarkGeometry.hitTest(point: CGPoint(x: 300, y: 100), marks: [box], selectedID: id) == MarkHit(id: id, handle: .bottomRight))
    #expect(MarkGeometry.hitTest(point: CGPoint(x: 200, y: 240), marks: [box], selectedID: id) == MarkHit(id: id, handle: .top))
    #expect(MarkGeometry.hitTest(point: CGPoint(x: 200, y: 170), marks: [box], selectedID: id) == MarkHit(id: id, handle: .body))
}

@Test func hitTestsBlurAndArrow() {
    let blurID = UUID(), arrowID = UUID()
    let blur = EditableMark(id: blurID, tool: .blur, points: [CGPoint(x: 50, y: 50), CGPoint(x: 250, y: 120)])
    let arrow = EditableMark(id: arrowID, tool: .arrow, points: [CGPoint(x: 300, y: 300), CGPoint(x: 450, y: 400)])

    // Blur hits anywhere inside its body even when unselected.
    #expect(MarkGeometry.hitTest(point: CGPoint(x: 150, y: 85), marks: [blur], selectedID: nil) == MarkHit(id: blurID, handle: .body))

    // Arrow hits along shaft; when selected, endpoints take priority.
    #expect(MarkGeometry.hitTest(point: CGPoint(x: 375, y: 350), marks: [arrow], selectedID: nil) == MarkHit(id: arrowID, handle: .body))
    #expect(MarkGeometry.hitTest(point: CGPoint(x: 302, y: 301), marks: [arrow], selectedID: arrowID) == MarkHit(id: arrowID, handle: .start))
    #expect(MarkGeometry.hitTest(point: CGPoint(x: 449, y: 398), marks: [arrow], selectedID: arrowID) == MarkHit(id: arrowID, handle: .end))
}

@Test func moveClampsToTargetPreservingSize() {
    let target = CGRect(x: 100, y: 100, width: 500, height: 400)
    let box = EditableMark(id: UUID(), tool: .box, points: [CGPoint(x: 200, y: 200), CGPoint(x: 320, y: 280)])
    let moved = MarkGeometry.move(mark: box, by: CGSize(width: 500, height: -400), within: target)
    let r = MarkGeometry.rect(for: moved)!
    #expect(r == CGRect(x: 480, y: 100, width: 120, height: 80))

    let arrow = EditableMark(id: UUID(), tool: .arrow, points: [CGPoint(x: 200, y: 200), CGPoint(x: 300, y: 250)])
    let movedArrow = MarkGeometry.move(mark: arrow, by: CGSize(width: -300, height: 400), within: target)
    #expect(movedArrow[0] == CGPoint(x: 100, y: 450))
    #expect(movedArrow[1] == CGPoint(x: 200, y: 500))
}

@Test func resizeEnforcesMinimumSizeAndTargetBounds() {
    let target = CGRect(x: 0, y: 0, width: 500, height: 400)
    let box = EditableMark(id: UUID(), tool: .blur, points: [CGPoint(x: 100, y: 100), CGPoint(x: 200, y: 200)])

    // Drag left edge past right edge: clamps to minSize.
    let shrunk = MarkGeometry.resize(mark: box, handle: .left, from: CGPoint(x: 100, y: 150), to: CGPoint(x: 280, y: 150), within: target)
    let sr = MarkGeometry.rect(for: shrunk)!
    #expect(sr.maxX == 200)
    #expect(sr.width == MarkGeometry.minSize)

    // Drag topRight past target bounds: clamps to target.
    let expanded = MarkGeometry.resize(mark: box, handle: .topRight, from: CGPoint(x: 200, y: 200), to: CGPoint(x: 900, y: 900), within: target)
    let er = MarkGeometry.rect(for: expanded)!
    #expect(er == CGRect(x: 100, y: 100, width: 400, height: 300))

    // Arrow endpoint drag enforces minimum length and target clamping.
    let arrow = EditableMark(id: UUID(), tool: .arrow, points: [CGPoint(x: 100, y: 100), CGPoint(x: 200, y: 100)])
    let shortArrow = MarkGeometry.resize(mark: arrow, handle: .end, from: CGPoint(x: 200, y: 100), to: CGPoint(x: 102, y: 100), within: target)
    #expect(hypot(shortArrow[1].x - shortArrow[0].x, shortArrow[1].y - shortArrow[0].y) >= MarkGeometry.minSize - 0.1)
}
