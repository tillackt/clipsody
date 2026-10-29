import Foundation

/// Interface of the ClippboardDecoder XPC service. Untrusted clipboard images are decoded and
/// screenshots are read there, in a sandboxed process without access to files, network or the
/// history, instead of in the app that holds the Accessibility permission.
@objc public protocol DecoderServiceProtocol {
    /// Converts clipboard image data (PNG or TIFF) to PNG. Replies with nil data if the image was
    /// rejected (format, size) or could not be decoded.
    func prepareImage(_ data: Data, maxPixels: Int,
                      reply: @escaping @Sendable (_ png: Data?, _ width: Int, _ height: Int, _ hash: String?) -> Void)

    /// Recognised text lines joined by newlines; nil if the image could not be read.
    func recognizeText(inPNG png: Data, reply: @escaping @Sendable (_ text: String?) -> Void)
}

public enum DecoderService {
    /// The service's bundle identifier, derived from the app's so both can be renamed together.
    public static func name(forAppBundleID appBundleID: String) -> String {
        appBundleID + ".decoder"
    }
}
