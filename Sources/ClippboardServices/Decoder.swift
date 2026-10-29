import ClippboardCore
import ClippboardXPC
import Foundation
import Vision

/// What the decoder service does on behalf of the app. Runs sandboxed in the ClippboardDecoder
/// process (see ClippboardDecoder.entitlements) and only ever sees the bytes it is sent.
public final class Decoder: NSObject, DecoderServiceProtocol, Sendable {
    private let watchdogLimit: TimeInterval?

    /// With `watchdogLimit`, the process ends itself when one request runs longer (a crafted image
    /// can make a decoder spin); launchd starts a fresh one for the next request. Only the real
    /// service sets it: in tests it would end the test process.
    public init(watchdogLimit: TimeInterval? = nil) {
        self.watchdogLimit = watchdogLimit
    }

    /// Runs `work` synchronously, so the watchdog covers the work itself, wherever it is dispatched.
    private func watched(_ work: () -> Void) {
        guard let watchdogLimit else { return work() }
        let finished = Flag()
        DispatchQueue.global().asyncAfter(deadline: .now() + watchdogLimit) {
            guard !finished.isSet else { return }
            logger.error("Decoder request exceeded \(watchdogLimit) s; ending the service")
            // _exit: the stuck work still runs on another thread, and atexit handlers or static
            // destructors could crash under it. A failure code keeps the event visible.
            _exit(EXIT_FAILURE)
        }
        work()
        finished.set()
    }

    // XPC runs requests at the sender's QoS, and the app sends from the main thread. Image
    // preparation and OCR run in the background, so they go to a lower QoS (efficiency cores);
    // thumbnail and TIFF stay at the incoming QoS because the user waits for them.

    public func prepareImage(_ data: Data, maxPixels: Int,
                             reply: @escaping @Sendable (Data?, Int, Int, String?) -> Void) {
        DispatchQueue.global(qos: .utility).async { [self] in
            watched { prepare(data, maxPixels: maxPixels, reply: reply) }
        }
    }

    private func prepare(_ data: Data, maxPixels: Int, reply: @escaping @Sendable (Data?, Int, Int, String?) -> Void) {
        // The service enforces its own limit, whatever the caller asks for.
        guard let image = ImageIngest.prepare(data, maxPixels: min(maxPixels, ImageIngest.maxPixels)) else {
            reply(nil, 0, 0, nil)
            return
        }
        reply(image.png, image.width, image.height, image.hash)
    }

    public func recognizeText(inPNG png: Data, reply: @escaping @Sendable (String?) -> Void) {
        DispatchQueue.global(qos: .utility).async { [self] in
            watched { recognize(png, reply: reply) }
        }
    }

    private func recognize(_ png: Data, reply: @escaping @Sendable (String?) -> Void) {
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
        watched { makeThumbnail(png, maxPixelSize: maxPixelSize, reply: reply) }
    }

    private func makeThumbnail(_ png: Data, maxPixelSize: Int,
                               reply: @escaping @Sendable (Data?, Int, Int, Double, Double) -> Void) {
        guard let thumbnail = ImageIngest.thumbnailPixels(ofPNG: png, maxPixelSize: min(maxPixelSize, 4_096)) else {
            reply(nil, 0, 0, 0, 0)
            return
        }
        reply(thumbnail.pixels, thumbnail.width, thumbnail.height,
              Double(thumbnail.pointSize.width), Double(thumbnail.pointSize.height))
    }

    public func tiff(fromPNG png: Data, reply: @escaping @Sendable (Data?) -> Void) {
        watched { reply(ImageIngest.tiff(fromPNG: png)) }
    }
}

/// A thread-safe "done" marker for the watchdog.
private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var isSet: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func set() {
        lock.lock()
        value = true
        lock.unlock()
    }
}

/// Accepts connections and exports a decoder object to each; used by the service and by tests
/// (with an anonymous listener).
public final class DecoderListenerDelegate: NSObject, NSXPCListenerDelegate {
    private let makeExportedObject: @Sendable () -> DecoderServiceProtocol
    private let exitWhenDisconnected: Bool

    /// `exitWhenDisconnected`: the service has exactly one client, the app. When the app closes the
    /// connection (idle, or after a timeout) the process ends and gives back its memory, e.g. the
    /// text recognition model. Only the real service sets it.
    public init(makeExportedObject: @escaping @Sendable () -> DecoderServiceProtocol = { Decoder() },
                exitWhenDisconnected: Bool = false) {
        self.makeExportedObject = makeExportedObject
        self.exitWhenDisconnected = exitWhenDisconnected
    }

    public func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        if exitWhenDisconnected {
            // _exit: no atexit handlers or static destructors while work may still run. A reconnect
            // right after the app dropped the connection may reach this exiting process; that
            // request simply fails closed and the next one gets a fresh process.
            connection.invalidationHandler = { _exit(0) }
        }
        connection.exportedInterface = NSXPCInterface(with: DecoderServiceProtocol.self)
        connection.exportedObject = makeExportedObject()
        connection.resume()
        return true
    }
}
