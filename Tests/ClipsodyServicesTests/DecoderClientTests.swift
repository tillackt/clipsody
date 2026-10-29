import ClipsodyCore
import Foundation
import Testing
@testable import ClipsodyServices

@MainActor
@Suite struct DecoderClientTests {
    @Test func imageRoundTripsThroughXPC() async throws {
        let service = TestService()
        let image = try #require(await service.client().prepareImage(makeImage(width: 30, height: 20)))
        #expect(image.width == 30 && image.height == 20)
        #expect(image.png.starts(with: [0x89, 0x50, 0x4E, 0x47]))
        withExtendedLifetime(service) {}
    }

    @Test func rejectedImageGivesNil() async {
        let service = TestService()
        #expect(await service.client().prepareImage(Data("not an image".utf8)) == nil)
        withExtendedLifetime(service) {}
    }

    @Test func largeImagesCrossTheConnection() async throws {
        let service = TestService()
        let image = try #require(await service.client().prepareImage(makeImage(width: 3_000, height: 2_000)))
        #expect(image.width == 3_000)
        withExtendedLifetime(service) {}
    }

    @Test func textIsRecognisedInTheService() async throws {
        let service = TestService()
        let client = service.client()
        let png = try #require(await client.prepareImage(makeImage(text: "Clipsody 4711", width: 700, height: 120))).png
        guard case .text(let text) = await client.recognizeText(inPNG: png) else {
            Issue.record("no text recognised")
            return
        }
        #expect(text.contains("4711"))
        withExtendedLifetime(service) {}
    }

    @Test func hangingServiceTimesOutWithFallback() async {
        let silent = SilentDecoder()
        let service = TestService { silent }
        let timeout = Duration.milliseconds(500)
        let client = service.client(timeout: timeout)
        let started = ContinuousClock.now
        #expect(await client.prepareImage(makeImage()) == nil)
        let elapsed = ContinuousClock.now - started
        // A real timeout: the request arrived, and the client gave up after `timeout`, long before
        // the 30 s default. Under load the request can reach the service only after the client gave up.
        #expect(await eventually { silent.requestsReceived == 1 })
        #expect(elapsed >= timeout)
        #expect(elapsed < .seconds(10))
        withExtendedLifetime(service) {}
    }

    @Test func cancellingAWaitingCallReturnsPromptly() async {
        let silent = SilentDecoder()
        let service = TestService { silent }
        let client = service.client()
        let started = ContinuousClock.now
        let task = Task { await client.prepareImage(makeImage()) }
        #expect(await eventually { silent.requestsReceived == 1 })
        task.cancel()
        #expect(await task.value == nil)
        #expect(ContinuousClock.now - started < .seconds(10))
        withExtendedLifetime(service) {}
    }

    @Test func oneReconnectAfterTimeoutIsKept() async throws {
        // After a timeout the client reconnects once. The old connection's late invalidation must
        // not throw away the new one, which would make every call open yet another connection.
        let silent = TestService { SilentDecoder() }
        let working = TestService()
        var connections = 0
        let silentEndpoint = silent.listener.endpoint
        let workingEndpoint = working.listener.endpoint
        let client = DecoderClient(timeout: .seconds(2), idleTimeout: .seconds(60)) {
            connections += 1
            return NSXPCConnection(listenerEndpoint: connections == 1 ? silentEndpoint : workingEndpoint)
        }
        #expect(await client.prepareImage(makeImage()) == nil)
        #expect(await client.prepareImage(makeImage()) != nil)
        try await Task.sleep(for: .milliseconds(800))
        #expect(await client.prepareImage(makeImage()) != nil)
        #expect(connections == 2)
        withExtendedLifetime((silent, working)) {}
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
        try await waitForIdleShutdown(of: client)
        #expect(await client.prepareImage(makeImage()) != nil)
        #expect(connections == 2)
        withExtendedLifetime(service) {}
    }

    /// Waits for the idle shutdown itself, not a fixed time: under load (all suites in parallel)
    /// the idle task can run much later than its timeout.
    private func waitForIdleShutdown(of client: DecoderClient) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while client.hasConnection, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(!client.hasConnection)
    }

    @Test func clientRecoversAfterATimeout() async throws {
        // First call hits a silent service; the client must reconnect for the next call.
        let silent = TestService { SilentDecoder() }
        let working = TestService()
        var connections = 0
        let silentEndpoint = silent.listener.endpoint
        let workingEndpoint = working.listener.endpoint
        let client = DecoderClient(timeout: .seconds(2)) {
            connections += 1
            return NSXPCConnection(listenerEndpoint: connections == 1 ? silentEndpoint : workingEndpoint)
        }
        #expect(await client.prepareImage(makeImage()) == nil)
        #expect(await client.prepareImage(makeImage()) != nil)
        withExtendedLifetime((silent, working)) {}
    }

    @Test func tiffTimeoutDropsTheConnection() async throws {
        // A hung TIFF request must not leave later requests queued behind the same service.
        let silent = TestService { SilentDecoder() }
        let working = TestService()
        var connections = 0
        let silentEndpoint = silent.listener.endpoint
        let workingEndpoint = working.listener.endpoint
        let client = DecoderClient(timeout: .seconds(5)) {
            connections += 1
            return NSXPCConnection(listenerEndpoint: connections == 1 ? silentEndpoint : workingEndpoint)
        }
        #expect(client.tiffBlocking(fromPNG: makeImage(type: .png), timeout: 0.3) == nil)
        #expect(await client.prepareImage(makeImage()) != nil)
        #expect(connections == 2)
        withExtendedLifetime((silent, working)) {}
    }

    @Test func connectionOpenedForTIFFIsClosedWhenIdle() async throws {
        let service = TestService()
        var connections = 0
        let endpoint = service.listener.endpoint
        let client = DecoderClient(idleTimeout: .milliseconds(100)) {
            connections += 1
            return NSXPCConnection(listenerEndpoint: endpoint)
        }
        #expect(client.tiffBlocking(fromPNG: makeImage(type: .png)) != nil)
        #expect(connections == 1)
        try await waitForIdleShutdown(of: client)
        #expect(client.tiffBlocking(fromPNG: makeImage(type: .png)) != nil)
        #expect(connections == 2)
        withExtendedLifetime(service) {}
    }
}
