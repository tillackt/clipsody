import ClipsodyDecoderKit
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import ClipsodyCore

@Suite struct ImageIngestTests {
    @Test func tiffBecomesLosslessPNGWithSameResolution() throws {
        let tiff = makeImage(width: 12, height: 7, type: .tiff, dpi: 144)
        let image = try #require(ImageCodec.prepare(tiff))

        #expect(image.width == 12 && image.height == 7)
        #expect(imageProperties(of: image.png)[kCGImagePropertyPNGDictionary] != nil)
        #expect(pixels(of: image.png) == pixels(of: tiff))
        #expect(imageProperties(of: image.png)[kCGImagePropertyDPIWidth] as? Double == 144)
    }

    @Test func pngIsReencodedWithSamePixels() throws {
        let png = makeImage(type: .png)
        let image = try #require(ImageCodec.prepare(png))
        #expect(pixels(of: image.png) == pixels(of: png))
        #expect(image.width == 12 && image.height == 7)
    }

    @Test func metadataSuchAsGPSIsStripped() throws {
        let gps: [CFString: Any] = [kCGImagePropertyGPSLatitude: 52.52, kCGImagePropertyGPSLongitude: 13.40]
        let tagged = makeImage(type: .png, extraProperties: [kCGImagePropertyGPSDictionary: gps])
        #expect(imageProperties(of: tagged)[kCGImagePropertyGPSDictionary] != nil)

        let image = try #require(ImageCodec.prepare(tagged))

        #expect(imageProperties(of: image.png)[kCGImagePropertyGPSDictionary] == nil)
    }

    @Test func otherFormatsAreNotDecoded() {
        #expect(ImageCodec.prepare(makeImage(type: .jpeg)) == nil)
        #expect(ImageCodec.prepare(makeImage(type: .gif)) == nil)
    }

    @Test func thumbnailIsDownscaledRawPixels() throws {
        let png = makeImage(width: 400, height: 100, type: .png, dpi: 144)
        let thumbnail = try #require(ImageCodec.thumbnailPixels(ofPNG: png, maxPixelSize: 100))
        #expect(thumbnail.width == 100 && thumbnail.height == 25)
        #expect(thumbnail.pixels.count == 100 * 25 * 4)
        // 400 px at 144 DPI (Retina) appeared as 200 pt on screen
        #expect(thumbnail.pointSize == CGSize(width: 200, height: 50))
    }

    @Test func thumbnailsAreOnlyMadeFromPNG() {
        #expect(ImageCodec.thumbnailPixels(ofPNG: makeImage(type: .tiff), maxPixelSize: 100) == nil)
    }

    @Test func pngHeaderGivesSizeWithoutDecoding() throws {
        let size = try #require(PNGHeader.size(of: makeImage(width: 321, height: 123, type: .png)))
        #expect(size.width == 321 && size.height == 123)
        #expect(PNGHeader.size(of: makeImage(type: .tiff)) == nil)
        #expect(PNGHeader.size(of: Data([0x89, 0x50, 0x4E, 0x47])) == nil)
        #expect(PNGHeader.size(of: Data()) == nil)
    }

    @Test func largeImagesGetAPreviewWithTheSameOnScreenSize() throws {
        let image = try #require(ImageCodec.prepare(makeImage(width: 3_000, height: 1_500, dpi: 144)))
        let preview = try #require(image.preview)
        let size = try #require(PNGValidator.validatedSize(of: preview))
        #expect(size.width == ImageIngest.previewMaxPixelSize && size.height == 512)
        // 3,000 px at 144 DPI appeared as 1,500 pt; the preview must keep that.
        let thumbnail = try #require(ImageCodec.thumbnailPixels(ofPNG: preview, maxPixelSize: 4_096))
        #expect(abs(thumbnail.pointSize.width - 1_500) < 2)
    }

    @Test func smallImagesNeedNoPreview() throws {
        #expect(try #require(ImageCodec.prepare(makeImage(width: 800, height: 600))).preview == nil)
    }

    @Test func sameImageGivesSameHash() throws {
        let data = makeImage()
        let first = ImageCodec.prepare(data)?.hash
        let second = ImageCodec.prepare(data)?.hash
        #expect(first != nil && first == second)
    }

    @Test func garbageIsRejected() {
        #expect(ImageCodec.prepare(Data("not an image".utf8)) == nil)
    }

    @Test func tiffForPastingKeepsPixels() throws {
        let image = try #require(ImageCodec.prepare(makeImage(type: .png)))
        let tiff = try #require(ImageCodec.tiff(fromPNG: image.png))
        #expect(pixels(of: tiff) == pixels(of: image.png))
        let tiffProperties = imageProperties(of: tiff)[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        #expect(tiffProperties?[kCGImagePropertyTIFFCompression] as? Int == 5) // 5 = LZW
    }

    @Test func tiffForPastingIsCompressed() throws {
        let width = 400, height = 300
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let output = NSMutableData()
        let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        CGImageDestinationFinalize(destination)
        let png = output as Data

        let tiff = try #require(ImageCodec.tiff(fromPNG: png))

        #expect(tiff.count < width * height * 4 / 10)
        #expect(pixels(of: tiff) == pixels(of: png))
    }
}
