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
}

/// Converts pasteboard image data (TIFF, PNG, …) into PNG with ImageIO, keeping pixels,
/// colour profile and resolution (DPI) unchanged.
public enum ImageIngest {
    /// Larger than any real screenshot (a 6K display is ~20 MP / ~80 MB as TIFF); protects against
    /// clipboard content crafted to exhaust memory or disk.
    public static let maxBytes = 200_000_000
    public static let maxPixels = 50_000_000

    /// `isPNG`: the data already is PNG and is stored byte for byte instead of being re-encoded.
    /// Runs off the main thread in the app; it does not touch shared state.
    public static func prepare(_ data: Data, isPNG: Bool = false, maxPixels: Int = maxPixels) -> PreparedImage? {
        // Size is read from the header first, so oversized images are never decoded.
        guard data.count <= maxBytes,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width * height <= maxPixels else { return nil }
        if isPNG, CGImageSourceGetType(source) as String? == UTType.png.identifier {
            return PreparedImage(png: data, width: width, height: height, hash: sha256(data))
        }
        guard let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let png = encodePNG(image, properties: properties) else { return nil }
        return PreparedImage(png: png, width: width, height: height, hash: sha256(png))
    }

    /// Downscaled version for the preview, so browsing screenshots does not decode full 5K images.
    /// `pointSize` is the size the original appears at (pixels at its DPI), so a Retina screenshot
    /// is not shown twice as large as it was on screen.
    public static func thumbnail(of url: URL, maxPixelSize: Int) -> (image: CGImage, pointSize: CGSize)? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
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
        return (image, CGSize(width: width * scale, height: height * scale))
    }

    /// TIFF version of a stored PNG, for apps that do not accept PNG.
    public static func tiff(fromPNG png: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(png as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        return encode(image, type: .tiff, properties: properties)
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func encodePNG(_ image: CGImage, properties: [CFString: Any]) -> Data? {
        encode(image, type: .png, properties: properties)
    }

    private static func encode(_ image: CGImage, type: UTType, properties: [CFString: Any]) -> Data? {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, type.identifier as CFString, 1, nil) else {
            return nil
        }
        // Only the resolution is carried over; the colour profile travels with the CGImage itself.
        var kept: [CFString: Any] = [:]
        for key in [kCGImagePropertyDPIWidth, kCGImagePropertyDPIHeight] {
            kept[key] = properties[key]
        }
        CGImageDestinationAddImage(destination, image, kept as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }
}
