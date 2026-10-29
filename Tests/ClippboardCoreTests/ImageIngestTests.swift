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
