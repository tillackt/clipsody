import Foundation

/// Reads the size from a PNG's signature and IHDR chunk by plain byte comparison. The app uses it
/// to check what the decoder service returns without running an image decoder itself.
public enum PNGHeader {
    private static let signature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
    private static let ihdr: [UInt8] = Array("IHDR".utf8)

    /// Width and height, or nil if `data` does not start like a PNG.
    public static func size(of data: Data) -> (width: Int, height: Int)? {
        let bytes = [UInt8](data.prefix(24))
        // Signature (8), chunk length (4), chunk type "IHDR" (4), width (4), height (4).
        guard bytes.count == 24, Array(bytes[0..<8]) == signature, Array(bytes[12..<16]) == ihdr else { return nil }
        let width = bytes[16..<20].reduce(0) { $0 << 8 | Int($1) }
        let height = bytes[20..<24].reduce(0) { $0 << 8 | Int($1) }
        return (width, height)
    }
}
