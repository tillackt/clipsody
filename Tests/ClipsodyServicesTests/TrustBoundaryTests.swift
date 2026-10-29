import ClipsodyCore
import Foundation
import Testing
@testable import ClipsodyServices

/// What a compromised decoder service may send back, and what the app must make of it.
@MainActor
@Suite struct TrustBoundaryTests {
    let png = makeImage(width: 40, height: 30, type: .png)

    func client(_ reply: LyingDecoder.Reply) -> (TestService, DecoderClient) {
        let service = TestService { LyingDecoder(reply) }
        return (service, service.client(timeout: .seconds(5)))
    }

    @Test func hashIsComputedByTheAppNotTakenFromTheService() async throws {
        let (service, client) = client(.init(png: png, width: 40, height: 30, hash: "../../../Desktop/escaped"))
        let image = try #require(await client.prepareImage(png))
        #expect(image.hash == ImageIngest.sha256(png))
        withExtendedLifetime(service) {}
    }

    @Test(arguments: [(41, 30), (40, 0), (0, 0), (-40, 30)])
    func sizesThatDoNotMatchTheHeaderAreRejected(width: Int, height: Int) async {
        let (service, client) = client(.init(png: png, width: width, height: height, hash: "x"))
        #expect(await client.prepareImage(png) == nil)
        withExtendedLifetime(service) {}
    }

    @Test func invalidPreviewIsDroppedButImageKept() async throws {
        let (service, client) = client(.init(png: png, width: 40, height: 30, hash: "x", preview: Data("junk".utf8)))
        let image = try #require(await client.prepareImage(png))
        #expect(image.preview == nil)
        withExtendedLifetime(service) {}
    }

    @Test func realServiceDeliversAValidPreview() async throws {
        let service = TestService()
        let image = try #require(await service.client().prepareImage(makeImage(width: 2_400, height: 1_200)))
        #expect(image.preview.flatMap(PNGValidator.validatedSize(of:))?.width == ImageIngest.previewMaxPixelSize)
        withExtendedLifetime(service) {}
    }

    @Test func anythingButPNGIsRejected() async {
        let tiff = makeImage(width: 40, height: 30, type: .tiff)
        let (service, client) = client(.init(png: tiff, width: 40, height: 30, hash: "x"))
        #expect(await client.prepareImage(png) == nil)
        withExtendedLifetime(service) {}
    }

    @Test func validPNGWithAppendedPayloadIsRejected() async {
        let (service, client) = client(.init(png: png + Data("payload".utf8), width: 40, height: 30, hash: "x"))
        #expect(await client.prepareImage(png) == nil)
        withExtendedLifetime(service) {}
    }

    @Test func validHeaderFollowedByJunkIsRejected() async {
        let junk = png.prefix(33) + Data(repeating: 0x41, count: 500)
        let (service, client) = client(.init(png: junk, width: 40, height: 30, hash: "x"))
        #expect(await client.prepareImage(png) == nil)
        withExtendedLifetime(service) {}
    }

    @Test func pngWithBadCRCIsRejected() async {
        var damaged = png
        damaged[damaged.count - 20] ^= 0xFF
        let (service, client) = client(.init(png: damaged, width: 40, height: 30, hash: "x"))
        #expect(await client.prepareImage(png) == nil)
        withExtendedLifetime(service) {}
    }

    @Test func recognisedTextIsCappedInLength() async throws {
        let huge = String(repeating: "a", count: DecoderClient.maxRecognizedCharacters + 5_000)
        let (service, client) = client(.init(text: huge))
        guard case .text(let text) = await client.recognizeText(inPNG: png) else {
            Issue.record("no text")
            return
        }
        #expect(text.count == DecoderClient.maxRecognizedCharacters)
        withExtendedLifetime(service) {}
    }

    @Test(arguments: [(10, 10, 399), (10, 10, 401), (0, 10, 0), (5_000, 1, 20_000)])
    func pixelBuffersThatDoNotFitTheirSizeAreRejected(width: Int, height: Int, bytes: Int) async {
        let (service, client) = client(.init(width: width, height: height, pixels: Data(count: bytes)))
        #expect(await client.thumbnail(ofPNG: png, maxPixelSize: 4_096) == nil)
        withExtendedLifetime(service) {}
    }

    @Test func fittingPixelBufferBecomesAnImage() async throws {
        let (service, client) = client(.init(width: 10, height: 10, pixels: Data(count: 400)))
        let thumbnail = try #require(await client.thumbnail(ofPNG: png, maxPixelSize: 100))
        #expect(thumbnail.image.width == 10)
        withExtendedLifetime(service) {}
    }

    @Test(arguments: [
        (10, 10, 1e6, 1e6), (10, 10, 100_001, 100_001), (10, 10, .infinity, 100), (10, 10, .nan, 100),
        (10, 10, 100_000, 1), (10, 10, 1, 100_000), (400, 100, 100, 400), (400, 1, 1, 5_000),
    ] as [(Int, Int, Double, Double)])
    func pointSizesOutOfBoundsOrAspectAreRejected(width: Int, height: Int, pointWidth: Double, pointHeight: Double) {
        let pixels = DecoderClient.RawPixels(data: Data(count: width * height * 4), width: width, height: height,
                                             pointSize: CGSize(width: pointWidth, height: pointHeight))
        #expect(DecoderClient.thumbnail(from: pixels, maxPixelSize: 4_096) == nil)
    }

    @Test(arguments: [(10, 10, 100, 100), (400, 100, 800, 200), (400, 1, 5_000, 1), (3, 400, 7.5, 1_000)]
          as [(Int, Int, Double, Double)])
    func pointSizesOfRealImagesAreAccepted(width: Int, height: Int, pointWidth: Double, pointHeight: Double) {
        let pixels = DecoderClient.RawPixels(data: Data(count: width * height * 4), width: width, height: height,
                                             pointSize: CGSize(width: pointWidth, height: pointHeight))
        #expect(DecoderClient.thumbnail(from: pixels, maxPixelSize: 4_096) != nil)
    }
}

@MainActor
@Suite struct ServiceOutputTests {
    @Test func realThumbnailComesBackAsPixels() async throws {
        let service = TestService()
        let png = makeImage(width: 800, height: 200, type: .png)
        let thumbnail = try #require(await service.client().thumbnail(ofPNG: png, maxPixelSize: 400))
        #expect(thumbnail.image.width == 400 && thumbnail.image.height == 100)
        withExtendedLifetime(service) {}
    }

    @Test func tiffIsMadeByTheService() throws {
        let service = TestService()
        let tiff = try #require(service.client().tiffBlocking(fromPNG: makeImage(type: .png)))
        // "II*\0" (little endian) or "MM\0*" (big endian)
        #expect(tiff.starts(with: [0x49, 0x49, 0x2A, 0x00]) || tiff.starts(with: [0x4D, 0x4D, 0x00, 0x2A]))
        withExtendedLifetime(service) {}
    }

    @Test func tiffWithoutTIFFSignatureIsRejected() {
        let service = TestService { LyingDecoder(.init(tiff: makeImage(type: .png))) }
        #expect(service.client(timeout: .seconds(5)).tiffBlocking(fromPNG: makeImage(type: .png)) == nil)
        withExtendedLifetime(service) {}
    }

    @Test func tiffRequestToAHangingServiceGivesUp() async {
        let silent = SilentDecoder()
        let service = TestService { silent }
        let started = ContinuousClock.now
        #expect(service.client().tiffBlocking(fromPNG: makeImage(type: .png), timeout: 0.3) == nil)
        let elapsed = ContinuousClock.now - started
        // Under load the request can reach the service only after the client gave up.
        #expect(await eventually { silent.requestsReceived == 1 })
        #expect(elapsed >= .milliseconds(300))
        // Below the 5 s default: the given 0.3 s was used, with room for a loaded runner.
        #expect(elapsed < .milliseconds(4_500))
        withExtendedLifetime(service) {}
    }
}
