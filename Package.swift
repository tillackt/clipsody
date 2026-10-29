// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Clippboard",
    platforms: [.macOS(.v13)],
    targets: [
        // Storage, configuration, image handling, search and import: no AppKit, unit-tested.
        .target(
            name: "ClippboardCore"
        ),
        // The menu-bar app itself (AppKit UI, hotkey, pasteboard, Vision).
        .executableTarget(
            name: "Clippboard",
            dependencies: ["ClippboardCore"]
        ),
        .testTarget(
            name: "ClippboardCoreTests",
            dependencies: ["ClippboardCore"]
        ),
    ]
)
