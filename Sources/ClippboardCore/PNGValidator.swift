import Foundation

/// Checks the chunk structure of a PNG without decoding any pixels. The app uses it on PNGs the
/// decoder service returns: those are stored, sent back to the service and put on the pasteboard
/// verbatim, so a compromised service must not be able to append or hide arbitrary payload.
///
/// IDAT content (zlib-compressed pixel data) and iCCP (compressed colour profile) stay opaque: the
/// app does not inflate them. Their CRC is checked like every other chunk's.
public enum PNGValidator {
    private static let signature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]

    /// Critical chunks plus the standard ancillary chunks for colour and resolution. ImageIO also
    /// writes eXIf (resolution only, as ImageIngest passes nothing else) and cICP (colour signalling
    /// for Display P3). Anything else (text, private chunks) has no business in an image re-encoded
    /// by ImageIngest.
    private static let allowedTypes: Set<String> = [
        "IHDR", "PLTE", "IDAT", "IEND", "pHYs", "iCCP", "sRGB", "gAMA", "cHRM", "tRNS", "eXIf", "cICP",
    ]

    /// Width and height from IHDR if `data` is a well-formed PNG: signature, chunks that stay
    /// within the data, correct CRC everywhere, IHDR first, at least one IDAT, only allowed chunk
    /// types, and IEND last, ending exactly at the end of the data. Nil otherwise.
    public static func validatedSize(of data: Data) -> (width: Int, height: Int)? {
        data.withUnsafeBytes { raw -> (width: Int, height: Int)? in
            let bytes = raw.bindMemory(to: UInt8.self)
            guard bytes.count >= signature.count, bytes.prefix(signature.count).elementsEqual(signature) else {
                return nil
            }
            var offset = signature.count
            var size: (width: Int, height: Int)?
            var sawIDAT = false
            while offset < bytes.count {
                // Length (4), type (4), data (length), CRC (4).
                guard bytes.count - offset >= 12 else { return nil }
                let length = Int(readUInt32(bytes, at: offset))
                guard length <= Int(Int32.max), bytes.count - offset - 12 >= length else { return nil }
                let typeStart = offset + 4
                let dataStart = offset + 8
                let crcStart = dataStart + length
                guard let type = String(bytes: bytes[typeStart..<dataStart], encoding: .ascii),
                      allowedTypes.contains(type),
                      crc32(bytes[typeStart..<crcStart]) == readUInt32(bytes, at: crcStart) else { return nil }
                if size == nil {
                    guard type == "IHDR", length == 13 else { return nil }
                    size = (Int(readUInt32(bytes, at: dataStart)), Int(readUInt32(bytes, at: dataStart + 4)))
                } else if type == "IHDR" {
                    return nil
                }
                if type == "IDAT" { sawIDAT = true }
                offset = crcStart + 4
                if type == "IEND" {
                    // Nothing may follow IEND: that is where appended payload would hide.
                    guard length == 0, offset == bytes.count, sawIDAT else { return nil }
                    return size
                }
            }
            return nil
        }
    }

    private static func readUInt32(_ bytes: UnsafeBufferPointer<UInt8>, at offset: Int) -> UInt32 {
        bytes[offset..<offset + 4].reduce(0) { $0 << 8 | UInt32($1) }
    }

    /// CRC-32 as PNG defines it (ISO 3309 polynomial, reflected), over chunk type and data.
    static func crc32<Bytes: Sequence<UInt8>>(_ bytes: Bytes) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in bytes {
            crc = crcTable[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
        }
        return crc ^ 0xFFFF_FFFF
    }

    private static let crcTable: [UInt32] = (0..<256).map { index in
        (0..<8).reduce(UInt32(index)) { crc, _ in crc & 1 == 1 ? 0xEDB8_8320 ^ (crc >> 1) : crc >> 1 }
    }
}
