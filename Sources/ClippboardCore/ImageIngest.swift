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
    public static func prepare(_ data: Data) -> PreparedImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0,
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let png = encodePNG(image, properties: properties) else { return nil }
        return PreparedImage(png: png, width: width, height: height, hash: sha256(png))
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
