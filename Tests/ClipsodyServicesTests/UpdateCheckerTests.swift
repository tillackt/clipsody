import ClipsodyCore
import Foundation
import Testing
@testable import ClipsodyServices

/// The request and the handling of answers, without network.
@Suite struct UpdateCheckerTests {
    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: URLRequest?
        var request: URLRequest? {
            lock.lock()
            defer { lock.unlock() }
            return stored
        }

        func record(_ request: URLRequest) {
            lock.lock()
            stored = request
            lock.unlock()
        }
    }

    private static func answering(_ status: Int, _ body: String, recorder: Recorder = Recorder()) -> UpdateChecker {
        UpdateChecker { request in
            recorder.record(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            return (Data(body.utf8), response)
        }
    }

    @Test func asksGitHubForTheLatestReleaseOnly() async throws {
        let recorder = Recorder()
        let checker = Self.answering(200, #"{"tag_name": "v2.0.0"}"#, recorder: recorder)
        let release = try await checker.latestRelease(currentVersion: "1.1.0")
        #expect(release.version.description == "2.0.0")

        let request = try #require(recorder.request)
        #expect(request.url == UpdateCheck.latestReleaseURL)
        #expect(request.httpMethod == "GET")
        #expect(request.httpBody == nil)
        #expect(request.value(forHTTPHeaderField: "User-Agent") == "Clipsody/1.1.0")
    }

    @Test func errorsAreReported() async {
        await #expect(throws: UpdateChecker.Failure.httpStatus(403)) {
            try await Self.answering(403, #"{"message": "rate limit"}"#).latestRelease(currentVersion: "1.1.0")
        }
        await #expect(throws: UpdateChecker.Failure.unreadableResponse) {
            try await Self.answering(200, "<html>").latestRelease(currentVersion: "1.1.0")
        }
    }
}
