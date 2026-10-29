import CryptoKit
import Foundation

/// An image converted for storage: lossless PNG plus its pixel size and content hash.
public struct PreparedImage: Sendable {
    public let png: Data
    public let width: Int
    public let height: Int
    public let hash: String
    /// Downscaled copy for the panel's preview (nil when the image is small enough to show as is).
    public let preview: Data?

    public func withPreview(_ preview: Data?) -> PreparedImage {
        PreparedImage(png: png, width: width, height: height, hash: hash, preview: preview)
    }

    public init(png: Data, width: Int, height: Int, hash: String, preview: Data? = nil) {
        self.png = png
        self.width = width
        self.height = height
        self.hash = hash
        self.preview = preview
    }
}

/// Limits and hashing shared by the app and the decoder service. Decoding itself lives in
/// ClipsodyDecoderKit (ImageCodec), which the app does not link.
public enum ImageIngest {
    /// Larger than any real screenshot (a 6K display is ~20 MP / ~80 MB as TIFF); protects against
    /// clipboard content crafted to exhaust memory or disk.
    public static let maxBytes = 200_000_000
    public static let maxPixels = 50_000_000

    /// Longest side of the stored preview; enough for the panel on a Retina screen.
    public static let previewMaxPixelSize = 1_024

    /// Upper bound for thumbnails the service renders and the app accepts.
    public static let maxThumbnailPixelSize = 4_096

    public static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
