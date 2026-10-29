import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

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

/// Converts pasteboard image data (PNG or TIFF) into PNG with ImageIO, keeping pixels,
/// colour profile and resolution (DPI). Everything else is dropped on purpose: re-encoding
/// strips metadata such as GPS positions and text chunks, and bounds the stored size.
public enum ImageIngest {
    /// Larger than any real screenshot (a 6K display is ~20 MP / ~80 MB as TIFF); protects against
    /// clipboard content crafted to exhaust memory or disk.
    public static let maxBytes = 200_000_000
    public static let maxPixels = 50_000_000

    /// Formats ImageIO may decode here; anything else is rejected before decoding, which keeps
    /// the attack surface of untrusted clipboard data small.
    private static let acceptedTypes: Set<String> = [UTType.png.identifier, UTType.tiff.identifier]

    /// Runs in the sandboxed decoder service; it does not touch shared state.
    public static func prepare(_ data: Data, maxPixels: Int = maxPixels) -> PreparedImage? {
        // Format and size are read from the header first, so oversized images are never decoded.
        guard data.count <= maxBytes,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let type = CGImageSourceGetType(source) as String?, acceptedTypes.contains(type),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0 else { return nil }
        // A crafted header can claim sizes whose product overflows Int.
        let (pixels, overflow) = width.multipliedReportingOverflow(by: height)
        guard !overflow, pixels <= maxPixels,
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let png = encodePNG(image, properties: properties) else { return nil }
        let preview = makePreview(of: image, properties: properties)
        return PreparedImage(png: png, width: width, height: height, hash: sha256(png), preview: preview)
    }

    /// Longest side of the stored preview; enough for the panel on a Retina screen.
    public static let previewMaxPixelSize = 1_024

    /// A small PNG for the panel, so showing a 5K screenshot does not decode all of it each time.
    /// Its DPI is scaled down with the pixels, so it appears at the same on-screen size.
    private static func makePreview(of image: CGImage, properties: [CFString: Any]) -> Data? {
        let longest = max(image.width, image.height)
        guard longest > previewMaxPixelSize else { return nil }
        let scale = Double(previewMaxPixelSize) / Double(longest)
        let width = max(1, Int((Double(image.width) * scale).rounded()))
        let height = max(1, Int((Double(image.height) * scale).rounded()))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let small = context.makeImage() else { return nil }
        let dpi = properties[kCGImagePropertyDPIWidth] as? Double ?? 72
        let scaledDPI = (dpi > 0 ? dpi : 72) * Double(width) / Double(image.width)
        return encodePNG(small, properties: [kCGImagePropertyDPIWidth: scaledDPI, kCGImagePropertyDPIHeight: scaledDPI])
    }

    /// Downscaled preview as raw 8-bit RGBA pixels (premultiplied, sRGB, rows of width × 4 bytes),
    /// made in the decoder service so the app never decodes an image format. `pointSize` is the size
    /// the original appears at (pixels at its DPI), so a Retina screenshot is not shown twice as large.
    public static func thumbnailPixels(ofPNG png: Data, maxPixelSize: Int)
        -> (pixels: Data, width: Int, height: Int, pointSize: CGSize)? {
        guard let source = CGImageSourceCreateWithData(png as CFData, nil),
              CGImageSourceGetType(source) as String? == UTType.png.identifier,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Double,
              let height = properties[kCGImagePropertyPixelHeight] as? Double else { return nil }
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ] as CFDictionary
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else { return nil }
        let dpi = properties[kCGImagePropertyDPIWidth] as? Double ?? 72
        let scale = 72 / (dpi > 0 ? dpi : 72)
        guard let pixels = rgbaPixels(of: image) else { return nil }
        return (pixels, image.width, image.height, CGSize(width: width * scale, height: height * scale))
    }

    /// Redraws `image` into a plain RGBA buffer in the layout `thumbnailPixels` promises.
    private static func rgbaPixels(of image: CGImage) -> Data? {
        let bytesPerRow = image.width * 4
        var buffer = Data(count: bytesPerRow * image.height)
        let drawn = buffer.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(data: raw.baseAddress, width: image.width, height: image.height,
                                          bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return true
        }
        return drawn ? buffer : nil
    }

    /// TIFF version of a stored PNG, for apps that do not accept PNG.
    public static func tiff(fromPNG png: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(png as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        // Lossless LZW (5): uncompressed, a 5K screenshot would put ~59 MB on the pasteboard.
        let lzw: [CFString: Any] = [kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFCompression: 5]]
        return encode(image, type: .tiff, properties: properties, extra: lzw)
    }

    public static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func encodePNG(_ image: CGImage, properties: [CFString: Any]) -> Data? {
        encode(image, type: .png, properties: properties)
    }

    private static func encode(_ image: CGImage, type: UTType, properties: [CFString: Any],
                               extra: [CFString: Any] = [:]) -> Data? {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, type.identifier as CFString, 1, nil) else {
            return nil
        }
        // Only the resolution is carried over; the colour profile travels with the CGImage itself.
        var kept: [CFString: Any] = [:]
        for key in [kCGImagePropertyDPIWidth, kCGImagePropertyDPIHeight] {
            kept[key] = properties[key]
        }
        kept.merge(extra) { $1 }
        CGImageDestinationAddImage(destination, image, kept as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }
}
