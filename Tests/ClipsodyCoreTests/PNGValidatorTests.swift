import ClipsodyDecoderKit
import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import ClipsodyCore

@Suite struct PNGValidatorTests {
    /// A PNG as the app stores it: re-encoded by ImageIngest.
    let png = ImageCodec.prepare(makeImage(width: 40, height: 30, type: .tiff))!.png

    @Test func crcMatchesTheStandardCheckValue() {
        #expect(PNGValidator.crc32(Array("123456789".utf8)) == 0xCBF4_3926)
    }

    @Test(arguments: [CGColorSpace.sRGB, CGColorSpace.displayP3, CGColorSpace.genericGrayGamma2_2].map { $0 as String })
    func pngsReencodedByImageIngestPass(colorSpace: String) throws {
        let source = try #require(encode(width: 33, height: 17, colorSpace: colorSpace, type: .png))
        let prepared = try #require(ImageCodec.prepare(source))
        let size = try #require(PNGValidator.validatedSize(of: prepared.png))
        #expect(size.width == 33 && size.height == 17)
    }

    @Test func pngsFromTIFFPass() throws {
        let size = try #require(PNGValidator.validatedSize(of: png))
        #expect(size.width == 40 && size.height == 30)
    }

    @Test func truncatedDataIsRejected() {
        #expect(PNGValidator.validatedSize(of: png.dropLast()) == nil)
        #expect(PNGValidator.validatedSize(of: png.prefix(png.count / 2)) == nil)
        #expect(PNGValidator.validatedSize(of: png.prefix(8)) == nil)
        #expect(PNGValidator.validatedSize(of: Data()) == nil)
    }

    @Test func wrongCRCIsRejected() throws {
        var damaged = png
        let idat = try #require(chunks(of: png).first { $0.type == "IDAT" })
        damaged[idat.range.lowerBound + 8] ^= 0x01
        #expect(PNGValidator.validatedSize(of: damaged) == nil)
    }

    @Test func unknownChunkTypeIsRejectedEvenWithValidCRC() throws {
        let ihdr = try #require(chunks(of: png).first { $0.type == "IHDR" })
        var tagged = png
        tagged.insert(contentsOf: chunk("tEXt", Data("Comment\0payload".utf8)), at: ihdr.range.upperBound)
        #expect(PNGValidator.validatedSize(of: tagged) == nil)
    }

    @Test func bytesAfterIENDAreRejected() {
        #expect(PNGValidator.validatedSize(of: png + Data("payload".utf8)) == nil)
        #expect(PNGValidator.validatedSize(of: png + chunk("IEND", Data())) == nil)
    }

    @Test func missingIENDIsRejected() {
        #expect(PNGValidator.validatedSize(of: png.dropLast(12)) == nil)
    }

    @Test func ihdrMustComeFirst() {
        var reordered = png
        reordered.insert(contentsOf: chunk("pHYs", Data(count: 9)), at: 8)
        #expect(PNGValidator.validatedSize(of: reordered) == nil)
    }

    @Test func otherFormatsAreRejected() {
        #expect(PNGValidator.validatedSize(of: makeImage(type: .tiff)) == nil)
        #expect(PNGValidator.validatedSize(of: Data("not a png".utf8)) == nil)
    }

    // MARK: - Helpers

    private func chunks(of data: Data) -> [(type: String, range: Range<Int>)] {
        let bytes = [UInt8](data)
        var result: [(String, Range<Int>)] = []
        var offset = 8
        while offset + 12 <= bytes.count {
            let length = bytes[offset..<offset + 4].reduce(0) { $0 << 8 | Int($1) }
            let type = String(decoding: bytes[offset + 4..<offset + 8], as: UTF8.self)
            result.append((type, offset..<offset + 12 + length))
            offset += 12 + length
        }
        return result
    }

    /// A chunk with a correct CRC, so only the property under test is wrong.
    private func chunk(_ type: String, _ body: Data) -> Data {
        let typeAndBody = Data(type.utf8) + body
        return bigEndian(UInt32(body.count)) + typeAndBody + bigEndian(PNGValidator.crc32(typeAndBody))
    }

    private func bigEndian(_ value: UInt32) -> Data {
        withUnsafeBytes(of: value.bigEndian) { Data($0) }
    }

    private func encode(width: Int, height: Int, colorSpace: String, type: UTType) -> Data? {
        guard let space = CGColorSpace(name: colorSpace as CFString) else { return nil }
        let gray = space.model == .monochrome
        let alpha: CGImageAlphaInfo = gray ? .none : .premultipliedLast
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: space, bitmapInfo: alpha.rawValue) else { return nil }
        context.setFillColor(CGColor(gray: 0.3, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width / 2, height: height))
        guard let image = context.makeImage() else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, type.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImagePropertyDPIWidth: 144,
                                                        kCGImagePropertyDPIHeight: 144] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? output as Data : nil
    }
}
