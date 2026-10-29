import ClipsodyCore
import ClipsodyXPC
import CoreGraphics
import Foundation
import os

/// Resumes a continuation exactly once, whichever of reply, XPC error, timeout or cancellation
/// comes first. Created before the continuation exists, so a cancellation that arrives before the
/// request is sent still decides the result.
final class ResumeOnce<Value: Sendable>: Sendable {
    private enum Phase: Sendable {
        case pending
        case waiting(CheckedContinuation<Value, Never>)
        /// Resumed before a continuation was attached.
        case resolved(Value)
        case done
    }

    private struct State: Sendable {
        var phase = Phase.pending
        var onResume: (@Sendable () -> Void)?
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    /// Whether the value was delivered now, plus what to resume and run outside the lock.
    private typealias Resolution = (Bool, CheckedContinuation<Value, Never>?, (@Sendable () -> Void)?)

    init() {}

    /// Returns false if a value was already delivered; `continuation` is then resumed with it
    /// right away and the request should not be sent.
    func attach(_ continuation: CheckedContinuation<Value, Never>) -> Bool {
        // Returns the phase found, so an early value can be delivered outside the lock.
        let found = state.withLock { state in
            let found = state.phase
            switch found {
            case .pending: state.phase = .waiting(continuation)
            case .resolved: state.phase = .done
            case .waiting, .done: preconditionFailure("continuation attached twice")
            }
            return found
        }
        guard case .resolved(let value) = found else { return true }
        continuation.resume(returning: value)
        return false
    }

    /// Runs `action` once the continuation is resumed (right away if it already was); used to
    /// cancel the timeout as soon as a reply arrives.
    func whenResumed(_ action: @escaping @Sendable () -> Void) {
        let alreadyResumed = state.withLock { state in
            switch state.phase {
            case .pending, .waiting:
                state.onResume = action
                return false
            case .resolved, .done:
                return true
            }
        }
        if alreadyResumed { action() }
    }

    /// Returns false if a value was already delivered.
    @discardableResult
    func resume(_ value: Value) -> Bool {
        let (delivered, continuation, action) = state.withLock { state -> Resolution in
            switch state.phase {
            case .pending:
                state.phase = .resolved(value)
                return (true, nil, nil)
            case .waiting(let continuation):
                defer { state = State(phase: .done) }
                return (true, continuation, state.onResume)
            case .resolved, .done:
                return (false, nil, nil)
            }
        }
        continuation?.resume(returning: value)
        action?()
        return delivered
    }
}

/// Holds the first value delivered from another thread for a caller waiting synchronously.
private final class BlockingResult<Value: Sendable>: @unchecked Sendable {
    enum Outcome {
        case finished(Value?)
        case timedOut
    }

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

    func wait(timeout: TimeInterval) -> Outcome {
        guard semaphore.wait(timeout: .now() + timeout) == .success else { return .timedOut }
        lock.lock()
        defer { lock.unlock() }
        return .finished(value)
    }
}

/// Outcome of text recognition. A failure of the service (crash, timeout, unreachable) is not the
/// same as an image without text: only the latter is final.
public enum RecognitionResult: Sendable, Equatable {
    case text(String)
    /// The service could read the request but not the image.
    case unreadable
    /// The service did not answer; worth trying again later.
    case failed
}

/// A preview built from raw pixels the service sent; no image format was parsed in the app.
public struct Thumbnail {
    public let image: CGImage
    /// Size the original appears at on screen.
    public let pointSize: CGSize
}

/// Talks to the sandboxed ClipsodyDecoder XPC service, which decodes untrusted clipboard images
/// and reads screenshots. Its replies are untrusted too: a compromised service is exactly the case
/// the sandbox is for, so every reply is checked and nothing it says becomes a path.
/// Fails closed: without the service no image is stored.
@MainActor
public final class DecoderClient {
    private let makeConnection: @MainActor () -> NSXPCConnection
    private let timeout: Duration
    private let idleTimeout: Duration
    private var connection: NSXPCConnection?
    /// For tests: whether a connection is currently open.
    var hasConnection: Bool { connection != nil }
    /// Counts connections, so a late handler of an old one can tell it is no longer current.
    private var connectionGeneration = 0
    private var callsInFlight = 0
    private var idleTask: Task<Void, Never>?

    /// Recognised text is stored for search only; more than this is cut off.
    nonisolated public static let maxRecognizedCharacters = CaptureLimits.recognizedCharacters

    /// Connects to the XPC service embedded in the app bundle and only accepts it if it is signed
    /// like the app (see CodeSigningRequirement), so a replaced service binary is refused.
    /// Without a requirement no service is contacted: every call returns its fallback.
    public convenience init(appBundleID: String? = Bundle.main.bundleIdentifier) {
        // Without a bundle (e.g. a bare binary) there is no embedded service to verify.
        let serviceName = appBundleID.map(DecoderService.name(forAppBundleID:)) ?? "invalid.decoder"
        guard appBundleID != nil, let requirement = CodeSigningRequirement.forService(identifier: serviceName) else {
            // An already invalidated connection fails every message right away without launching
            // anything, so clipboard data never reaches an unverified process.
            self.init {
                let connection = NSXPCConnection(serviceName: serviceName)
                connection.invalidate()
                return connection
            }
            return
        }
        self.init {
            let connection = NSXPCConnection(serviceName: serviceName)
            connection.setCodeSigningRequirement(requirement)
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
            proxy.prepareImage(data, maxPixels: ImageIngest.maxPixels) { png, width, height, _, preview in
                done(Self.validatedImage(png: png, width: width, height: height)
                    .map { $0.withPreview(Self.validatedPreview(preview, width: width, height: height)) })
            }
        }
    }

    public func recognizeText(inPNG png: Data) async -> RecognitionResult {
        await call(fallback: .failed) { proxy, done in
            proxy.recognizeText(inPNG: png) { text in
                done(text.map { .text(String($0.prefix(Self.maxRecognizedCharacters))) } ?? .unreadable)
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
    /// freezing the app. The bytes are handed to the pasteboard unparsed, after a signature check.
    public func tiffBlocking(fromPNG png: Data, timeout: TimeInterval = 5) -> Data? {
        let connection = currentConnection()
        callsInFlight += 1
        idleTask?.cancel()
        defer {
            callsInFlight -= 1
            scheduleIdleShutdown()
        }
        let result = BlockingResult<Data>()
        let proxy = connection.remoteObjectProxyWithErrorHandler { @Sendable error in
            logger.error("Decoder service error: \(String(describing: error), privacy: .public)")
            result.finish(nil)
        } as? DecoderServiceProtocol
        guard let proxy else { return nil }
        proxy.tiff(fromPNG: png) { tiff in result.finish(tiff) }
        switch result.wait(timeout: timeout) {
        case .timedOut:
            // As in call(): later requests must not queue behind the hung service.
            logger.error("Decoder service timed out on TIFF; restarting it")
            drop(connection)
            return nil
        case .finished(let tiff):
            // "II*\0" (little endian) or "MM\0*" (big endian)
            guard let tiff, tiff.count <= ImageIngest.maxBytes,
                  tiff.starts(with: [0x49, 0x49, 0x2A, 0x00]) || tiff.starts(with: [0x4D, 0x4D, 0x00, 0x2A])
            else { return nil }
            return tiff
        }
    }

    // MARK: - Validation of replies

    /// Accepts only a well-formed PNG (whole chunk structure, see PNGValidator) whose IHDR matches the
    /// reported size within the limits. The PNG is stored and pasted verbatim, so nothing may be
    /// appended or hidden in extra chunks; pixels are not decoded.
    /// A preview is optional: one that is not a well-formed PNG of preview size with the image's
    /// aspect ratio is dropped (the full image is used instead), the image itself is kept.
    nonisolated static func validatedPreview(_ preview: Data?, width: Int, height: Int) -> Data? {
        guard let preview, let size = PNGValidator.validatedSize(of: preview),
              size.width <= ImageIngest.previewMaxPixelSize, size.height <= ImageIngest.previewMaxPixelSize,
              abs(Double(size.width) / Double(size.height) - Double(width) / Double(height))
                  <= 2 / Double(min(size.width, size.height)) + 0.01 else { return nil }
        return preview
    }

    nonisolated static func validatedImage(png: Data?, width: Int, height: Int) -> PreparedImage? {
        guard let png, png.count <= ImageIngest.maxBytes,
              let header = PNGValidator.validatedSize(of: png), header.width == width, header.height == height,
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

    /// Far beyond any real image side (a 6K display is 6,016 px wide); the point size drives layout,
    /// so a huge value from the service must not reach it.
    nonisolated static let maxPointSize: CGFloat = 100_000

    /// Wraps raw RGBA bytes in a CGImage after checking that size and buffer length agree.
    nonisolated static func thumbnail(from pixels: RawPixels, maxPixelSize: Int) -> Thumbnail? {
        let limit = min(maxPixelSize, ImageIngest.maxThumbnailPixelSize)
        guard pixels.width > 0, pixels.height > 0, pixels.width <= limit, pixels.height <= limit,
              pixels.data.count == pixels.width * pixels.height * 4,
              pointSizeFits(pixels),
              let provider = CGDataProvider(data: pixels.data as CFData),
              let image = CGImage(width: pixels.width, height: pixels.height, bitsPerComponent: 8, bitsPerPixel: 32,
                                  bytesPerRow: pixels.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        else { return nil }
        return Thumbnail(image: image, pointSize: pixels.pointSize)
    }

    /// The point size must be bounded and have the thumbnail's aspect ratio. Downscaling rounds each
    /// side, so the pixel ratio may be off by one pixel per side; a side of one pixel says nothing
    /// about the upper bound (a 5000 × 1 image still becomes 400 × 1).
    nonisolated private static func pointSizeFits(_ pixels: RawPixels) -> Bool {
        let point = pixels.pointSize
        guard point.width.isFinite, point.height.isFinite, point.width > 0, point.height > 0,
              point.width <= maxPointSize, point.height <= maxPointSize else { return false }
        let ratio = point.width / point.height
        let width = CGFloat(pixels.width), height = CGFloat(pixels.height)
        let lower = (width - 1) / (height + 1)
        let upper = height > 1 ? (width + 1) / (height - 1) : .infinity
        return ratio >= lower && ratio <= upper
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
        let once = ResumeOnce<Value>()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard once.attach(continuation) else { return }
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
        } onCancel: {
            // The caller no longer waits; a late reply is ignored.
            once.resume(fallback)
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
