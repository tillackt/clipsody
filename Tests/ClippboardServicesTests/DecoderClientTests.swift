import ClippboardCore
import Foundation
import Testing
@testable import ClippboardServices

@MainActor
@Suite struct DecoderClientTests {
    @Test func imageRoundTripsThroughXPC() async throws {
        let service = TestService()
        let image = try #require(await service.client().prepareImage(makeImage(width: 30, height: 20)))
        #expect(image.width == 30 && image.height == 20)
        #expect(image.png.starts(with: [0x89, 0x50, 0x4E, 0x47]))
    }

    @Test func rejectedImageGivesNil() async {
        let service = TestService()
        #expect(await service.client().prepareImage(Data("not an image".utf8)) == nil)
    }

    @Test func largeImagesCrossTheConnection() async throws {
        let service = TestService()
        let image = try #require(await service.client().prepareImage(makeImage(width: 3_000, height: 2_000)))
        #expect(image.width == 3_000)
    }

    @Test func textIsRecognisedInTheService() async throws {
        let service = TestService()
        let client = service.client()
        let png = try #require(await client.prepareImage(makeImage(text: "Clippboard 4711", width: 700, height: 120))).png
        guard case .text(let text) = await client.recognizeText(inPNG: png) else {
            Issue.record("no text recognised")
            return
        }
        #expect(text.contains("4711"))
    }

    @Test func hangingServiceTimesOutWithFallback() async {
        let service = TestService { SilentDecoder() }
        let client = service.client(timeout: .milliseconds(200))
        let started = ContinuousClock.now
        #expect(await client.prepareImage(makeImage()) == nil)
        #expect(ContinuousClock.now - started < .seconds(5))
    }

    @Test func oneReconnectAfterTimeoutIsKept() async throws {
        // After a timeout the client reconnects once. The old connection's late invalidation must
        // not throw away the new one, which would make every call open yet another connection.
        let silent = TestService { SilentDecoder() }
        let working = TestService()
        var connections = 0
        let silentEndpoint = silent.listener.endpoint
        let workingEndpoint = working.listener.endpoint
        let client = DecoderClient(timeout: .milliseconds(200), idleTimeout: .seconds(60)) {
            connections += 1
            return NSXPCConnection(listenerEndpoint: connections == 1 ? silentEndpoint : workingEndpoint)
        }
        #expect(await client.prepareImage(makeImage()) == nil)
        #expect(await client.prepareImage(makeImage()) != nil)
        try await Task.sleep(for: .milliseconds(300))
        #expect(await client.prepareImage(makeImage()) != nil)
        #expect(connections == 2)
    }

    @Test func idleConnectionIsClosedAndReopenedOnDemand() async throws {
        let service = TestService()
        var connections = 0
        let endpoint = service.listener.endpoint
        let client = DecoderClient(idleTimeout: .milliseconds(100)) {
            connections += 1
            return NSXPCConnection(listenerEndpoint: endpoint)
        }
        #expect(await client.prepareImage(makeImage()) != nil)
        #expect(await client.prepareImage(makeImage()) != nil)
        #expect(connections == 1)
        try await Task.sleep(for: .milliseconds(400))
        #expect(await client.prepareImage(makeImage()) != nil)
        #expect(connections == 2)
    }

    @Test func clientRecoversAfterATimeout() async throws {
        // First call hits a silent service; the client must reconnect for the next call.
        let silent = TestService { SilentDecoder() }
        let working = TestService()
        var useWorking = false
        let silentEndpoint = silent.listener.endpoint
        let workingEndpoint = working.listener.endpoint
        let client = DecoderClient(timeout: .milliseconds(200)) {
            NSXPCConnection(listenerEndpoint: useWorking ? workingEndpoint : silentEndpoint)
        }
        #expect(await client.prepareImage(makeImage()) == nil)
        useWorking = true
        #expect(await client.prepareImage(makeImage()) != nil)
    }
}
