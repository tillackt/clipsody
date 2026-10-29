import Foundation

/// Interface of the ClippboardDecoder XPC service. Untrusted clipboard images are decoded and
/// screenshots are read there, in a sandboxed process without access to files, network or the
/// history, instead of in the app that holds the Accessibility permission. The app treats every
/// reply as untrusted as well and never parses image formats itself.
@objc public protocol DecoderServiceProtocol {
    /// Converts clipboard image data (PNG or TIFF) to PNG. Replies with nil data if the image was
    /// rejected (format, size) or could not be decoded.
    func prepareImage(_ data: Data, maxPixels: Int,
                      reply: @escaping @Sendable (_ png: Data?, _ width: Int, _ height: Int, _ hash: String?) -> Void)

    /// Recognised text lines joined by newlines; nil if the image could not be read.
    func recognizeText(inPNG png: Data, reply: @escaping @Sendable (_ text: String?) -> Void)

    /// Downscaled preview as raw 8-bit RGBA pixels (premultiplied alpha, sRGB, rows of width × 4
    /// bytes), so the app can show it without decoding an image format. `pointWidth`/`pointHeight`
    /// is the size the original appears at on screen.
    func thumbnail(ofPNG png: Data, maxPixelSize: Int,
                   reply: @escaping @Sendable (_ pixels: Data?, _ width: Int, _ height: Int,
                                               _ pointWidth: Double, _ pointHeight: Double) -> Void)

    /// TIFF version of a stored PNG, for apps that do not accept PNG when pasting.
    func tiff(fromPNG png: Data, reply: @escaping @Sendable (_ tiff: Data?) -> Void)
}

public enum DecoderService {
    /// The service's bundle identifier, derived from the app's so both can be renamed together.
    public static func name(forAppBundleID appBundleID: String) -> String {
        appBundleID + ".decoder"
    }
}
