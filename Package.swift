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
        // Image decoding/encoding (ImageIO), text recognition (Vision) and the decoder service object.
        // Only the decoder service and tests link it, so the app cannot decode untrusted images itself.
        .target(
            name: "ClippboardDecoderKit",
            dependencies: ["ClippboardCore", "ClippboardXPC"]
        ),
        // XPC client of the decoder service and the queues that use it: no AppKit, unit-tested.
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
            dependencies: ["ClippboardDecoderKit"]
        ),
        .testTarget(
            name: "ClippboardCoreTests",
            dependencies: ["ClippboardCore", "ClippboardDecoderKit"]
        ),
        .testTarget(
            name: "ClippboardServicesTests",
            dependencies: ["ClippboardServices", "ClippboardCore", "ClippboardXPC", "ClippboardDecoderKit"]
        ),
    ]
)
