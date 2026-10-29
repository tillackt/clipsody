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

    @Test func pngIsKeptByteForByte() throws {
        let png = makeImage(type: .png)
        let image = try #require(ImageIngest.prepare(png, isPNG: true))
        #expect(image.png == png)
        #expect(image.width == 12 && image.height == 7)
    }

    @Test func dataClaimingToBePNGIsStillConverted() throws {
        let tiff = makeImage(type: .tiff)
        let image = try #require(ImageIngest.prepare(tiff, isPNG: true))
        #expect(imageProperties(of: image.png)[kCGImagePropertyPNGDictionary] != nil)
    }

    @Test func thumbnailIsDownscaled() throws {
        let directory = try TemporaryDirectory()
        let url = directory.url.appendingPathComponent("big.png")
        try makeImage(width: 400, height: 100, type: .png, dpi: 144).write(to: url)
        let thumbnail = try #require(ImageIngest.thumbnail(of: url, maxPixelSize: 100))
        #expect(thumbnail.image.width == 100 && thumbnail.image.height == 25)
        // 400 px at 144 DPI (Retina) appeared as 200 pt on screen
        #expect(thumbnail.pointSize == CGSize(width: 200, height: 50))
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
