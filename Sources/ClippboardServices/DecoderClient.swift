import ClippboardCore
import ClippboardXPC
import CoreGraphics
import Foundation

/// Resumes a continuation exactly once, whichever of reply, XPC error or timeout comes first.
final class ResumeOnce<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Never>?
    private var onResume: (@Sendable () -> Void)?

    init(_ continuation: CheckedContinuation<Value, Never>) {
        self.continuation = continuation
    }

    /// Runs `action` once the continuation is resumed (right away if it already was); used to
    /// cancel the timeout as soon as a reply arrives.
    func whenResumed(_ action: @escaping @Sendable () -> Void) {
        lock.lock()
        let alreadyResumed = continuation == nil
        if !alreadyResumed { onResume = action }
        lock.unlock()
        if alreadyResumed { action() }
    }

    /// Returns false if the continuation was already resumed.
    @discardableResult
    func resume(_ value: Value) -> Bool {
        lock.lock()
        let pending = continuation
        let action = onResume
        continuation = nil
        onResume = nil
        lock.unlock()
        pending?.resume(returning: value)
        if pending != nil { action?() }
        return pending != nil
    }
}

/// Holds the first value delivered from another thread for a caller waiting synchronously.
private final class BlockingResult<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var value: Value?
    private var finished = false

    func finish(_ value: Value?) {
        lock.lock()
        defer { lock.unlock() }
        guard !finished else { return }
        finished = true
        self.value = value
        semaphore.signal()
    }

    func wait(timeout: TimeInterval) -> Value? {
        guard semaphore.wait(timeout: .now() + timeout) == .success else { return nil }
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

/// A preview built from raw pixels the service sent; no image format was parsed in the app.
public struct Thumbnail {
    public let image: CGImage
    /// Size the original appears at on screen.
    public let pointSize: CGSize
}

/// Talks to the sandboxed ClippboardDecoder XPC service, which decodes untrusted clipboard images
/// and reads screenshots. Its replies are untrusted too: a compromised service is exactly the case
/// the sandbox is for, so every reply is checked and nothing it says becomes a path.
/// Fails closed: without the service no image is stored.
@MainActor
public final class DecoderClient {
    private let makeConnection: @MainActor () -> NSXPCConnection
    private let timeout: Duration
    private let idleTimeout: Duration
    private var connection: NSXPCConnection?
    /// Counts connections, so a late handler of an old one can tell it is no longer current.
    private var connectionGeneration = 0
    private var callsInFlight = 0
    private var idleTask: Task<Void, Never>?

    /// Recognised text is stored for search only; more than this is cut off.
    public nonisolated static let maxRecognizedCharacters = 100_000

    /// Connects to the XPC service embedded in the app bundle and only accepts it if it is signed
    /// like the app (same certificate), so a replaced service binary is refused.
    public convenience init(appBundleID: String = Bundle.main.bundleIdentifier ?? "local.thorsten.clippboard") {
        let serviceName = DecoderService.name(forAppBundleID: appBundleID)
        let requirement = CodeSigningRequirement.forService(identifier: serviceName)
        self.init {
            let connection = NSXPCConnection(serviceName: serviceName)
            if let requirement { connection.setCodeSigningRequirement(requirement) }
            return connection
        }
    }

    /// `makeConnection` lets tests use an anonymous listener instead of the bundled service.
    /// A service that hangs (e.g. on a crafted image) must not block its callers forever: after
    /// `timeout` the call returns its fallback. After `idleTimeout` without calls the connection is
    /// closed, so the service process can end and give back its memory.
    public init(timeout: Duration = .seconds(30), idleTimeout: Duration = .seconds(60),
                makeConnection: @escaping @MainActor () -> NSXPCConnection) {
        self.timeout = timeout
        self.idleTimeout = idleTimeout
        self.makeConnection = makeConnection
    }

    public func prepareImage(_ data: Data) async -> PreparedImage? {
        await call(fallback: nil) { proxy, done in
            // The hash the service sends is ignored: it becomes a file name, so the app computes it.
            proxy.prepareImage(data, maxPixels: ImageIngest.maxPixels) { png, width, height, _ in
                done(Self.validatedImage(png: png, width: width, height: height))
            }
        }
    }

    public func recognizeText(inPNG png: Data) async -> String? {
        await call(fallback: nil) { proxy, done in
            proxy.recognizeText(inPNG: png) { text in
                done(text.map { String($0.prefix(Self.maxRecognizedCharacters)) })
            }
        }
    }

    public func thumbnail(ofPNG png: Data, maxPixelSize: Int) async -> Thumbnail? {
        let pixels: RawPixels? = await call(fallback: nil) { proxy, done in
            proxy.thumbnail(ofPNG: png, maxPixelSize: maxPixelSize) { pixels, width, height, pointWidth, pointHeight in
                done(pixels.map { RawPixels(data: $0, width: width, height: height,
                                            pointSize: CGSize(width: pointWidth, height: pointHeight)) })
            }
        }
        return pixels.flatMap { Self.thumbnail(from: $0, maxPixelSize: maxPixelSize) }
    }

    /// For the pasteboard's synchronous request for TIFF data. The reply arrives on an XPC queue,
    /// so waiting here (on the main thread) cannot deadlock; `timeout` keeps a hanging service from
    /// freezing the app. The bytes are handed to the pasteboard unparsed.
    public func tiffBlocking(fromPNG png: Data, timeout: TimeInterval = 5) -> Data? {
        let connection = currentConnection()
        let result = BlockingResult<Data>()
        let proxy = connection.remoteObjectProxyWithErrorHandler { @Sendable _ in
            result.finish(nil)
        } as? DecoderServiceProtocol
        proxy?.tiff(fromPNG: png) { tiff in result.finish(tiff) }
        guard let tiff = result.wait(timeout: timeout), tiff.count <= ImageIngest.maxBytes else { return nil }
        return tiff
    }

    // MARK: - Validation of replies

    /// Accepts only a PNG whose header matches the reported size within the limits; the size is read
    /// by comparing bytes, not by decoding the image.
    nonisolated static func validatedImage(png: Data?, width: Int, height: Int) -> PreparedImage? {
        guard let png, png.count <= ImageIngest.maxBytes,
              let header = PNGHeader.size(of: png), header.width == width, header.height == height,
              width > 0, height > 0 else { return nil }
        let (pixels, overflow) = width.multipliedReportingOverflow(by: height)
        guard !overflow, pixels <= ImageIngest.maxPixels else { return nil }
        return PreparedImage(png: png, width: width, height: height, hash: ImageIngest.sha256(png))
    }

    struct RawPixels: Sendable {
        let data: Data
        let width: Int
        let height: Int
        let pointSize: CGSize
    }

    /// Wraps raw RGBA bytes in a CGImage after checking that size and buffer length agree.
    nonisolated static func thumbnail(from pixels: RawPixels, maxPixelSize: Int) -> Thumbnail? {
        let limit = min(maxPixelSize, 4_096)
        guard pixels.width > 0, pixels.height > 0, pixels.width <= limit, pixels.height <= limit,
              pixels.data.count == pixels.width * pixels.height * 4,
              pixels.pointSize.width > 0, pixels.pointSize.height > 0,
              pixels.pointSize.width.isFinite, pixels.pointSize.height.isFinite,
              let provider = CGDataProvider(data: pixels.data as CFData),
              let image = CGImage(width: pixels.width, height: pixels.height, bitsPerComponent: 8, bitsPerPixel: 32,
                                  bytesPerRow: pixels.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        else { return nil }
        return Thumbnail(image: image, pointSize: pixels.pointSize)
    }

    // MARK: - Connection

    /// Sends one request; `fallback` is returned on XPC errors, crashes of the service and timeouts.
    private func call<Value: Sendable>(
        fallback: Value,
        _ send: @escaping (DecoderServiceProtocol, @escaping @Sendable (Value) -> Void) -> Void
    ) async -> Value {
        let connection = currentConnection()
        let timeout = timeout
        callsInFlight += 1
        idleTask?.cancel()
        defer {
            callsInFlight -= 1
            scheduleIdleShutdown()
        }
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
            let timer = Task { [weak self] in
                try? await Task.sleep(for: timeout)
                guard !Task.isCancelled, once.resume(fallback) else { return }
                // Closing the connection ends the service process (it exits when disconnected);
                // launchd starts a fresh one for the next request.
                logger.error("Decoder service timed out; restarting it")
                self?.drop(connection)
            }
            once.whenResumed { timer.cancel() }
        }
    }

    private func currentConnection() -> NSXPCConnection {
        if let connection { return connection }
        let connection = makeConnection()
        connectionGeneration += 1
        let generation = connectionGeneration
        connection.remoteObjectInterface = NSXPCInterface(with: DecoderServiceProtocol.self)
        // launchd restarts the service on the next message after a crash; only a fully
        // invalidated connection has to be recreated. The generation check matters: this handler
        // may run after a newer connection has replaced this one.
        connection.invalidationHandler = { @Sendable [weak self] in
            Task { @MainActor in
                guard let self, self.connectionGeneration == generation else { return }
                self.connection = nil
            }
        }
        connection.interruptionHandler = { @Sendable in
            logger.error("Decoder service ended unexpectedly; it is restarted on the next request")
        }
        connection.resume()
        self.connection = connection
        return connection
    }

    /// Closes `connection` and forgets it, unless a newer one has already taken its place.
    private func drop(_ connection: NSXPCConnection) {
        connection.invalidate()
        if self.connection === connection { self.connection = nil }
    }

    private func scheduleIdleShutdown() {
        guard callsInFlight == 0, connection != nil else { return }
        idleTask?.cancel()
        let idleTimeout = idleTimeout
        idleTask = Task { [weak self] in
            try? await Task.sleep(for: idleTimeout)
            guard let self, !Task.isCancelled, callsInFlight == 0, let connection else { return }
            drop(connection)
        }
    }
}
