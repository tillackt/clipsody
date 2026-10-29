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
        // XPC interface shared by the app and the decoder service.
        .target(
            name: "ClippboardXPC"
        ),
        // The menu-bar app itself (AppKit UI, hotkey, pasteboard).
        .executableTarget(
            name: "Clippboard",
            dependencies: ["ClippboardCore", "ClippboardXPC"]
        ),
        // Sandboxed XPC service that decodes clipboard images and runs text recognition.
        .executableTarget(
            name: "ClippboardDecoder",
            dependencies: ["ClippboardCore", "ClippboardXPC"]
        ),
        .testTarget(
            name: "ClippboardCoreTests",
            dependencies: ["ClippboardCore"]
        ),
    ]
)
