// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Clippboard",
    platforms: [.macOS(.v13)],
    targets: [
        // Storage, configuration, image handling and search: no AppKit, unit-tested.
        .target(
            name: "ClippboardCore"
        ),
        // XPC interface shared by the app and the decoder service.
        .target(
            name: "ClippboardXPC"
        ),
        // Decoder service implementation, its XPC client and the queues that use it: no AppKit, unit-tested.
        .target(
            name: "ClippboardServices",
            dependencies: ["ClippboardCore", "ClippboardXPC"]
        ),
        // The menu-bar app itself (AppKit UI, hotkey, pasteboard).
        .executableTarget(
            name: "Clippboard",
            dependencies: ["ClippboardCore", "ClippboardServices"]
        ),
        // Sandboxed XPC service that decodes clipboard images and runs text recognition.
        .executableTarget(
            name: "ClippboardDecoder",
            dependencies: ["ClippboardServices"]
        ),
        .testTarget(
            name: "ClippboardCoreTests",
            dependencies: ["ClippboardCore"]
        ),
        .testTarget(
            name: "ClippboardServicesTests",
            dependencies: ["ClippboardServices", "ClippboardCore", "ClippboardXPC"]
        ),
    ]
)
