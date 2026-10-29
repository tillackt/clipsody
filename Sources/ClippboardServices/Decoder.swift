import ClippboardCore
import ClippboardXPC
import Foundation
import Vision

/// What the decoder service does on behalf of the app. Runs sandboxed in the ClippboardDecoder
/// process (see ClippboardDecoder.entitlements) and only ever sees the bytes it is sent.
public final class Decoder: NSObject, DecoderServiceProtocol {
    public func prepareImage(_ data: Data, maxPixels: Int,
                             reply: @escaping @Sendable (Data?, Int, Int, String?) -> Void) {
        // The service enforces its own limit, whatever the caller asks for.
        guard let image = ImageIngest.prepare(data, maxPixels: min(maxPixels, ImageIngest.maxPixels)) else {
            reply(nil, 0, 0, nil)
            return
        }
        reply(image.png, image.width, image.height, image.hash)
    }

    public func recognizeText(inPNG png: Data, reply: @escaping @Sendable (String?) -> Void) {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["de-DE", "en-US"]
        request.usesLanguageCorrection = true
        do {
            try VNImageRequestHandler(data: png).perform([request])
        } catch {
            reply(nil)
            return
        }
        let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
        reply(lines.joined(separator: "\n"))
    }

    public func thumbnail(ofPNG png: Data, maxPixelSize: Int,
                          reply: @escaping @Sendable (Data?, Int, Int, Double, Double) -> Void) {
        guard let thumbnail = ImageIngest.thumbnailPixels(ofPNG: png, maxPixelSize: min(maxPixelSize, 4_096)) else {
            reply(nil, 0, 0, 0, 0)
            return
        }
        reply(thumbnail.pixels, thumbnail.width, thumbnail.height,
              Double(thumbnail.pointSize.width), Double(thumbnail.pointSize.height))
    }

    public func tiff(fromPNG png: Data, reply: @escaping @Sendable (Data?) -> Void) {
        reply(ImageIngest.tiff(fromPNG: png))
    }
}

/// Accepts connections and exports a decoder object to each; used by the service and by tests
/// (with an anonymous listener).
public final class DecoderListenerDelegate: NSObject, NSXPCListenerDelegate {
    private let makeExportedObject: @Sendable () -> DecoderServiceProtocol

    public init(makeExportedObject: @escaping @Sendable () -> DecoderServiceProtocol = { Decoder() }) {
        self.makeExportedObject = makeExportedObject
    }

    public func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.exportedInterface = NSXPCInterface(with: DecoderServiceProtocol.self)
        connection.exportedObject = makeExportedObject()
        connection.resume()
        return true
    }
}
