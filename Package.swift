// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Clipsody",
    platforms: [.macOS(.v13)],
    targets: [
        // Storage, configuration, image handling and search: no AppKit, unit-tested.
        .target(
            name: "ClipsodyCore"
        ),
        // XPC interface shared by the app and the decoder service.
        .target(
            name: "ClipsodyXPC"
        ),
        // Image decoding/encoding (ImageIO), text recognition (Vision) and the decoder service object.
        // Only the decoder service and tests link it, so the app cannot decode untrusted images itself.
        .target(
            name: "ClipsodyDecoderKit",
            dependencies: ["ClipsodyCore", "ClipsodyXPC"]
        ),
        // XPC client of the decoder service and the queues that use it: no AppKit, unit-tested.
        .target(
            name: "ClipsodyServices",
            dependencies: ["ClipsodyCore", "ClipsodyXPC"]
        ),
        // The menu-bar app itself (AppKit UI, hotkey, pasteboard).
        .executableTarget(
            name: "Clipsody",
            dependencies: ["ClipsodyCore", "ClipsodyServices"]
        ),
        // Sandboxed XPC service that decodes clipboard images and runs text recognition.
        .executableTarget(
            name: "ClipsodyDecoder",
            dependencies: ["ClipsodyDecoderKit"]
        ),
        .testTarget(
            name: "ClipsodyCoreTests",
            dependencies: ["ClipsodyCore", "ClipsodyDecoderKit"]
        ),
        .testTarget(
            name: "ClipsodyServicesTests",
            dependencies: ["ClipsodyServices", "ClipsodyCore", "ClipsodyXPC", "ClipsodyDecoderKit"]
        ),
    ]
)
