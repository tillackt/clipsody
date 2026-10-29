import ClippboardCore
import ClippboardXPC
import Foundation

/// Resumes a continuation exactly once, whichever of reply, XPC error or timeout comes first.
private final class ResumeOnce<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Never>?

    init(_ continuation: CheckedContinuation<Value, Never>) {
        self.continuation = continuation
    }

    /// Returns false if the continuation was already resumed.
    @discardableResult
    func resume(_ value: Value) -> Bool {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(returning: value)
        return pending != nil
    }
}

/// Talks to the sandboxed ClippboardDecoder XPC service, which decodes untrusted clipboard images
/// and reads screenshots. Fails closed: without the service no image is stored.
@MainActor
final class DecoderClient {
    private let serviceName: String
    private var connection: NSXPCConnection?
    /// A service that hangs (e.g. on a crafted image) must not block the image queue forever.
    private static let timeout = Duration.seconds(30)

    init(appBundleID: String = Bundle.main.bundleIdentifier ?? "local.thorsten.clippboard") {
        serviceName = DecoderService.name(forAppBundleID: appBundleID)
    }

    func prepareImage(_ data: Data) async -> PreparedImage? {
        await call(fallback: nil) { proxy, done in
            proxy.prepareImage(data, maxPixels: ImageIngest.maxPixels) { png, width, height, hash in
                guard let png, let hash else { return done(nil) }
                done(PreparedImage(png: png, width: width, height: height, hash: hash))
            }
        }
    }

    func recognizeText(inPNG png: Data) async -> String? {
        await call(fallback: nil) { proxy, done in
            proxy.recognizeText(inPNG: png) { text in done(text) }
        }
    }

    /// Sends one request; `fallback` is returned on XPC errors, crashes of the service and timeouts.
    private func call<Value: Sendable>(
        fallback: Value,
        _ send: @escaping (DecoderServiceProtocol, @escaping @Sendable (Value) -> Void) -> Void
    ) async -> Value {
        let connection = currentConnection()
        return await withCheckedContinuation { continuation in
            let once = ResumeOnce(continuation)
            let proxy = connection.remoteObjectProxyWithErrorHandler { error in
                logger.error("Decoder service error: \(String(describing: error), privacy: .public)")
                once.resume(fallback)
            } as? DecoderServiceProtocol
            guard let proxy else {
                once.resume(fallback)
                return
            }
            send(proxy) { value in once.resume(value) }
            Task { [weak self] in
                try? await Task.sleep(for: Self.timeout)
                if once.resume(fallback) {
                    logger.error("Decoder service timed out; restarting it")
                    connection.invalidate()
                    self?.connection = nil
                }
            }
        }
    }

    private func currentConnection() -> NSXPCConnection {
        if let connection { return connection }
        let connection = NSXPCConnection(serviceName: serviceName)
        connection.remoteObjectInterface = NSXPCInterface(with: DecoderServiceProtocol.self)
        // launchd restarts the service on the next message after a crash; only a fully
        // invalidated connection has to be recreated.
        connection.invalidationHandler = { [weak self] in
            Task { @MainActor in self?.connection = nil }
        }
        connection.resume()
        self.connection = connection
        return connection
    }
}
