import ClippboardCore
import ClippboardXPC
import Foundation

/// Resumes a continuation exactly once, whichever of reply, XPC error or timeout comes first.
final class ResumeOnce<Value: Sendable>: @unchecked Sendable {
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
public final class DecoderClient {
    private let makeConnection: @MainActor () -> NSXPCConnection
    private let timeout: Duration
    private var connection: NSXPCConnection?

    /// Connects to the XPC service embedded in the app bundle.
    public convenience init(appBundleID: String = Bundle.main.bundleIdentifier ?? "local.thorsten.clippboard") {
        let serviceName = DecoderService.name(forAppBundleID: appBundleID)
        self.init { NSXPCConnection(serviceName: serviceName) }
    }

    /// `makeConnection` lets tests use an anonymous listener instead of the bundled service.
    /// A service that hangs (e.g. on a crafted image) must not block its callers forever: after
    /// `timeout` the call returns its fallback.
    public init(timeout: Duration = .seconds(30), makeConnection: @escaping @MainActor () -> NSXPCConnection) {
        self.timeout = timeout
        self.makeConnection = makeConnection
    }

    public func prepareImage(_ data: Data) async -> PreparedImage? {
        await call(fallback: nil) { proxy, done in
            proxy.prepareImage(data, maxPixels: ImageIngest.maxPixels) { png, width, height, hash in
                guard let png, let hash else { return done(nil) }
                done(PreparedImage(png: png, width: width, height: height, hash: hash))
            }
        }
    }

    public func recognizeText(inPNG png: Data) async -> String? {
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
        let timeout = timeout
        return await withCheckedContinuation { continuation in
            let once = ResumeOnce(continuation)
            // @Sendable: XPC calls this on its own queue. A closure formed here would otherwise be
            // main-actor isolated, and Swift 6 traps when it runs elsewhere.
            let proxy = connection.remoteObjectProxyWithErrorHandler { @Sendable error in
                logger.error("Decoder service error: \(String(describing: error), privacy: .public)")
                once.resume(fallback)
            } as? DecoderServiceProtocol
            guard let proxy else {
                once.resume(fallback)
                return
            }
            send(proxy) { value in once.resume(value) }
            Task { [weak self] in
                try? await Task.sleep(for: timeout)
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
        let connection = makeConnection()
        connection.remoteObjectInterface = NSXPCInterface(with: DecoderServiceProtocol.self)
        // launchd restarts the service on the next message after a crash; only a fully
        // invalidated connection has to be recreated.
        connection.invalidationHandler = { @Sendable [weak self] in
            Task { @MainActor in self?.connection = nil }
        }
        connection.resume()
        self.connection = connection
        return connection
    }
}
