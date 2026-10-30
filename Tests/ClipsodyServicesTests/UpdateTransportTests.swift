import ClipsodyCore
import Foundation
import Testing
@testable import ClipsodyServices

/// The real URLSession path, with a stub protocol in place of the network.
@Suite(.serialized) struct UpdateTransportTests {
    /// Answers every request with `StubProtocol.body`; no length header, so only the read loop can stop it.
    final class StubProtocol: URLProtocol, @unchecked Sendable {
        private static let lock = NSLock()
        nonisolated(unsafe) private static var storedBody = Data()

        static var body: Data {
            get { lock.lock(); defer { lock.unlock() }; return storedBody }
            set { lock.lock(); storedBody = newValue; lock.unlock() }
        }

        override static func canInit(with request: URLRequest) -> Bool { true }
        override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [:])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Self.body)
            client?.urlProtocolDidFinishLoading(self)
        }

        override func stopLoading() {}
    }

    private static func checker() -> UpdateChecker {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        return UpdateChecker(fetch: UpdateChecker.limitedFetch(using: UpdateChecker.makeSession(configuration)))
    }

    @Test func readsAnOrdinaryAnswer() async throws {
        StubProtocol.body = Data(#"{"tag_name": "v1.2.3", "draft": false, "prerelease": false}"#.utf8)
        let release = try await Self.checker().latestRelease(currentVersion: "1.1.0")
        #expect(release.version.description == "1.2.3")
    }

    @Test func refusesOversizedAnswers() async {
        StubProtocol.body = Data(repeating: 0x20, count: UpdateChecker.maxResponseBytes + 1)
        await #expect(throws: UpdateChecker.Failure.unreadableResponse) {
            try await Self.checker().latestRelease(currentVersion: "1.1.0")
        }
    }
}
