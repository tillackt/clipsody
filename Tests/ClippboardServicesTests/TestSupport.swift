import ClippboardServices
import ClippboardXPC
import CoreGraphics
import CoreText
import Foundation
import ImageIO
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

    @MainActor
    func client(timeout: Duration = .seconds(30)) -> DecoderClient {
        let endpoint = listener.endpoint
        return DecoderClient(timeout: timeout) { NSXPCConnection(listenerEndpoint: endpoint) }
    }

    deinit {
        listener.invalidate()
    }
}

/// A service that accepts requests but never answers, like one stuck on a crafted image.
final class SilentDecoder: NSObject, DecoderServiceProtocol {
    func prepareImage(_ data: Data, maxPixels: Int, reply: @escaping @Sendable (Data?, Int, Int, String?) -> Void) {}
    func recognizeText(inPNG png: Data, reply: @escaping @Sendable (String?) -> Void) {}
}
