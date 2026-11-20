// swift-tools-version:6.0
import PackageDescription

// RecperCore: pure logic without AppKit (geometry, target model) — tests target this.
// Recper: the menu-bar app (AppKit + SwiftUI).
// On Command Line Tools, Swift Testing paths are passed in scripts/test.sh; cross-import overlays are disabled.
let package = Package(
    name: "Recper",
    platforms: [.macOS("26.0")],
    targets: [
        .target(name: "RecperCore"),
        .executableTarget(name: "Recper", dependencies: ["RecperCore"]),
        .testTarget(name: "RecperCoreTests", dependencies: ["RecperCore"],
                    swiftSettings: [.unsafeFlags(["-Xfrontend", "-disable-cross-import-overlays"])]),
    ]
)
