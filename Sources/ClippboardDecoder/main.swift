import ClippboardCore
import ClippboardXPC
import Foundation
import Vision

/// Does the risky parsing on behalf of the app. Runs sandboxed (see ClippboardDecoder.entitlements)
/// and only ever sees the bytes it is sent.
final class Decoder: NSObject, DecoderServiceProtocol {
    func prepareImage(_ data: Data, maxPixels: Int,
                      reply: @escaping @Sendable (Data?, Int, Int, String?) -> Void) {
        guard let image = ImageIngest.prepare(data, maxPixels: maxPixels) else {
            reply(nil, 0, 0, nil)
            return
        }
        reply(image.png, image.width, image.height, image.hash)
    }

    func recognizeText(inPNG png: Data, reply: @escaping @Sendable (String?) -> Void) {
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
}

final class ListenerDelegate: NSObject, NSXPCListenerDelegate {
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        // XPC services bundled in an app are only reachable by that app.
        connection.exportedInterface = NSXPCInterface(with: DecoderServiceProtocol.self)
        connection.exportedObject = Decoder()
        connection.resume()
        return true
    }
}

let delegate = ListenerDelegate()
let listener = NSXPCListener.service()
listener.delegate = delegate
// Runs the service's main loop; never returns.
listener.resume()
