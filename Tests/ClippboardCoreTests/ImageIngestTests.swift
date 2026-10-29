import Foundation
import ImageIO
import Testing
@testable import ClippboardCore

@Suite struct ImageIngestTests {
    @Test func tiffBecomesLosslessPNGWithSameResolution() throws {
        let tiff = makeImage(width: 12, height: 7, type: .tiff, dpi: 144)
        let image = try #require(ImageIngest.prepare(tiff))

        #expect(image.width == 12 && image.height == 7)
        #expect(imageProperties(of: image.png)[kCGImagePropertyPNGDictionary] != nil)
        #expect(pixels(of: image.png) == pixels(of: tiff))
        #expect(imageProperties(of: image.png)[kCGImagePropertyDPIWidth] as? Double == 144)
    }

    @Test func pngIsReencodedWithSamePixels() throws {
        let png = makeImage(type: .png)
        let image = try #require(ImageIngest.prepare(png))
        #expect(pixels(of: image.png) == pixels(of: png))
        #expect(image.width == 12 && image.height == 7)
    }

    @Test func metadataSuchAsGPSIsStripped() throws {
        let gps: [CFString: Any] = [kCGImagePropertyGPSLatitude: 52.52, kCGImagePropertyGPSLongitude: 13.40]
        let tagged = makeImage(type: .png, extraProperties: [kCGImagePropertyGPSDictionary: gps])
        #expect(imageProperties(of: tagged)[kCGImagePropertyGPSDictionary] != nil)

        let image = try #require(ImageIngest.prepare(tagged))

        #expect(imageProperties(of: image.png)[kCGImagePropertyGPSDictionary] == nil)
    }

    @Test func otherFormatsAreNotDecoded() {
        #expect(ImageIngest.prepare(makeImage(type: .jpeg)) == nil)
        #expect(ImageIngest.prepare(makeImage(type: .gif)) == nil)
    }

    @Test func thumbnailIsDownscaledRawPixels() throws {
        let png = makeImage(width: 400, height: 100, type: .png, dpi: 144)
        let thumbnail = try #require(ImageIngest.thumbnailPixels(ofPNG: png, maxPixelSize: 100))
        #expect(thumbnail.width == 100 && thumbnail.height == 25)
        #expect(thumbnail.pixels.count == 100 * 25 * 4)
        // 400 px at 144 DPI (Retina) appeared as 200 pt on screen
        #expect(thumbnail.pointSize == CGSize(width: 200, height: 50))
    }

    @Test func thumbnailsAreOnlyMadeFromPNG() {
        #expect(ImageIngest.thumbnailPixels(ofPNG: makeImage(type: .tiff), maxPixelSize: 100) == nil)
    }

    @Test func pngHeaderGivesSizeWithoutDecoding() throws {
        let size = try #require(PNGHeader.size(of: makeImage(width: 321, height: 123, type: .png)))
        #expect(size.width == 321 && size.height == 123)
        #expect(PNGHeader.size(of: makeImage(type: .tiff)) == nil)
        #expect(PNGHeader.size(of: Data([0x89, 0x50, 0x4E, 0x47])) == nil)
        #expect(PNGHeader.size(of: Data()) == nil)
    }

    @Test func sameImageGivesSameHash() throws {
        let data = makeImage()
        #expect(ImageIngest.prepare(data)?.hash == ImageIngest.prepare(data)?.hash)
    }

    @Test func garbageIsRejected() {
        #expect(ImageIngest.prepare(Data("not an image".utf8)) == nil)
    }

    @Test func tiffForPastingKeepsPixels() throws {
        let image = try #require(ImageIngest.prepare(makeImage(type: .png)))
        let tiff = try #require(ImageIngest.tiff(fromPNG: image.png))
        #expect(pixels(of: tiff) == pixels(of: image.png))
    }
}
