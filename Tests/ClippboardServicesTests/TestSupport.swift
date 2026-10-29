import ClippboardServices
import ClippboardXPC
import CoreGraphics
import CoreText
import Foundation
import ImageIO
import os
import UniformTypeIdentifiers

/// A fresh temporary directory per test, removed when the value goes away.
final class TemporaryDirectory {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("ClippboardServicesTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }
}

/// White image with black text (large enough for Vision), encoded as `type`.
func makeImage(text: String = "", width: Int = 12, height: Int = 7, type: UTType = .tiff) -> Data {
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    if !text.isEmpty {
        let font = CTFontCreateWithName("Helvetica" as CFString, 48, nil)
        let attributed = NSAttributedString(string: text, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(red: 0, green: 0, blue: 0, alpha: 1),
        ])
        context.textPosition = CGPoint(x: 20, y: CGFloat(height) / 2 - 16)
        CTLineDraw(CTLineCreateWithAttributedString(attributed), context)
    }
    let output = NSMutableData()
    let destination = CGImageDestinationCreateWithData(output, type.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, context.makeImage()!, nil)
    CGImageDestinationFinalize(destination)
    return output as Data
}

/// Runs a decoder object behind a real XPC connection inside the test process.
final class TestService {
    let listener = NSXPCListener.anonymous()
    private let delegate: DecoderListenerDelegate

    init(_ makeExportedObject: @escaping @Sendable () -> DecoderServiceProtocol = { Decoder() }) {
        delegate = DecoderListenerDelegate(makeExportedObject: makeExportedObject)
        listener.delegate = delegate
        listener.resume()
    }

    /// The client only holds the endpoint: keep the service alive (withExtendedLifetime) for as
    /// long as the client is used, since deinit invalidates the listener.
    @MainActor
    func client(timeout: Duration = .seconds(30)) -> DecoderClient {
        let endpoint = listener.endpoint
        return DecoderClient(timeout: timeout) { NSXPCConnection(listenerEndpoint: endpoint) }
    }

    deinit {
        listener.invalidate()
    }
}

/// A service that accepts requests but never answers, like one stuck on a crafted image. Counts
/// what it received, so a test can tell a timeout from a request that never arrived.
final class SilentDecoder: NSObject, DecoderServiceProtocol, Sendable {
    private let count = OSAllocatedUnfairLock(initialState: 0)

    var requestsReceived: Int { count.withLock { $0 } }

    private func received() {
        count.withLock { $0 += 1 }
    }

    func prepareImage(_ data: Data, maxPixels: Int, reply: @escaping @Sendable (Data?, Int, Int, String?, Data?) -> Void) {
        received()
    }

    func recognizeText(inPNG png: Data, reply: @escaping @Sendable (String?) -> Void) {
        received()
    }

    func thumbnail(ofPNG png: Data, maxPixelSize: Int,
                   reply: @escaping @Sendable (Data?, Int, Int, Double, Double) -> Void) {
        received()
    }

    func tiff(fromPNG png: Data, reply: @escaping @Sendable (Data?) -> Void) {
        received()
    }
}

/// Polls `condition` until it holds or `timeout` passes; returns whether it held.
@MainActor
func eventually(timeout: Duration = .seconds(5), _ condition: () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while !condition() {
        guard ContinuousClock.now < deadline else { return false }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return true
}

/// A compromised service: answers, but with whatever it likes.
final class LyingDecoder: NSObject, DecoderServiceProtocol {
    struct Reply: Sendable {
        var png: Data?
        var width = 0
        var height = 0
        var hash: String?
        var text: String?
        var pixels: Data?
        var tiff: Data?
        var preview: Data?
    }

    let reply: Reply

    init(_ reply: Reply) {
        self.reply = reply
    }

    func prepareImage(_ data: Data, maxPixels: Int, reply: @escaping @Sendable (Data?, Int, Int, String?, Data?) -> Void) {
        reply(self.reply.png, self.reply.width, self.reply.height, self.reply.hash, self.reply.preview)
    }

    func recognizeText(inPNG png: Data, reply: @escaping @Sendable (String?) -> Void) {
        reply(self.reply.text)
    }

    func thumbnail(ofPNG png: Data, maxPixelSize: Int,
                   reply: @escaping @Sendable (Data?, Int, Int, Double, Double) -> Void) {
        reply(self.reply.pixels, self.reply.width, self.reply.height, 100, 100)
    }

    func tiff(fromPNG png: Data, reply: @escaping @Sendable (Data?) -> Void) {
        reply(self.reply.tiff)
    }
}
