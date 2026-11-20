import Testing
import CoreGraphics
@testable import RecperCore

@Test func quartzCocoaRoundTrip() {
    let q = CGRect(x: 100, y: 50, width: 300, height: 200)
    let c = Geometry.cocoa(fromQuartz: q, primaryHeight: 900)
    #expect(c == CGRect(x: 100, y: 650, width: 300, height: 200))
    #expect(Geometry.quartz(fromCocoa: c, primaryHeight: 900) == q)
}

@Test func dragRectNormalizesAndClamps() {
    let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
    let r = Geometry.dragRect(from: CGPoint(x: 500.4, y: 400), to: CGPoint(x: 1600, y: -20), within: screen)
    #expect(r == CGRect(x: 500, y: 0, width: 940, height: 400))
    #expect(!Geometry.isUsableArea(Geometry.dragRect(from: .zero, to: CGPoint(x: 3, y: 50), within: screen)))
}

@Test func holeIsLocalToScreen() {
    let second = CGRect(x: 1440, y: 0, width: 1920, height: 1080)
    let target = CGRect(x: 1300, y: 100, width: 400, height: 300)       // spans two screens
    #expect(Geometry.hole(for: target, onScreen: second) == CGRect(x: 0, y: 100, width: 260, height: 300))
    #expect(Geometry.hole(for: CGRect(x: 10, y: 10, width: 50, height: 50), onScreen: second) == nil)
}

@Test func pickerTakesFrontmostSelectable() {
    let own: Int32 = 42
    let ws = [
        WindowInfo(id: 1, pid: own, app: "recper", layer: 0, alpha: 1, bounds: CGRect(x: 0, y: 0, width: 1440, height: 900)),
        WindowInfo(id: 2, pid: 7, app: "Menu", layer: 25, alpha: 1, bounds: CGRect(x: 0, y: 0, width: 1440, height: 24)),
        WindowInfo(id: 3, pid: 8, app: "Tooltip", layer: 0, alpha: 1, bounds: CGRect(x: 90, y: 90, width: 30, height: 20)),
        WindowInfo(id: 4, pid: 9, app: "Chrome", layer: 0, alpha: 1, bounds: CGRect(x: 50, y: 10, width: 800, height: 600)),
        WindowInfo(id: 5, pid: 10, app: "Finder", layer: 0, alpha: 1, bounds: CGRect(x: 0, y: 0, width: 1000, height: 800)),
    ]
    #expect(WindowPicker.window(at: CGPoint(x: 100, y: 100), in: ws, excludingPID: own)?.id == 4)
    #expect(WindowPicker.window(at: CGPoint(x: 900, y: 700), in: ws, excludingPID: own)?.id == 5)
    #expect(WindowPicker.window(at: CGPoint(x: 1200, y: 850), in: ws, excludingPID: own) == nil)
}

@Test func windowInfoParsesCGDictionary() {
    let d: [String: Any] = ["kCGWindowNumber": 12, "kCGWindowOwnerPID": 300, "kCGWindowOwnerName": "Safari",
                            "kCGWindowLayer": 0, "kCGWindowAlpha": 1.0,
                            "kCGWindowBounds": ["X": 10, "Y": 20, "Width": 640, "Height": 480]]
    #expect(WindowInfo(d) == WindowInfo(id: 12, pid: 300, app: "Safari", layer: 0, alpha: 1, bounds: CGRect(x: 10, y: 20, width: 640, height: 480)))
}
