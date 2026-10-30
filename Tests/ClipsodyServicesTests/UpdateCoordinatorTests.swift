import ClipsodyCore
import Foundation
import Testing
@testable import ClipsodyServices

/// When the coordinator asks GitHub and what it reports, with a fetch the test answers by hand.
@MainActor
@Suite struct UpdateCoordinatorTests {
    /// A fetch that waits until the test answers it.
    private final class PendingFetch: @unchecked Sendable {
        private let lock = NSLock()
        private var waiting: [CheckedContinuation<(Data, URLResponse), Error>] = []
        private var requests = 0

        var count: Int {
            lock.lock()
            defer { lock.unlock() }
            return requests
        }

        func fetch(_ request: URLRequest) async throws -> (Data, URLResponse) {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                requests += 1
                waiting.append(continuation)
                lock.unlock()
            }
        }

        func answer(tag: String) {
            resume(.success((Data(#"{"tag_name": "\#(tag)"}"#.utf8), Self.response(200))))
        }

        func fail(_ error: Error) {
            resume(.failure(error))
        }

        private func resume(_ result: Result<(Data, URLResponse), Error>) {
            lock.lock()
            let continuation = waiting.isEmpty ? nil : waiting.removeFirst()
            lock.unlock()
            continuation?.resume(with: result)
        }

        static func response(_ status: Int) -> URLResponse {
            HTTPURLResponse(url: UpdateCheck.latestReleaseURL, statusCode: status, httpVersion: nil, headerFields: nil)!
        }
    }

    private let fetch = PendingFetch()
    private let defaults: UserDefaults
    private var clock = Date(timeIntervalSinceReferenceDate: 800_000_000)

    init() {
        let suite = "UpdateCoordinatorTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
    }

    private func coordinator(version: String = "1.1.0") -> (UpdateCoordinator, () -> [UpdateCoordinator.Outcome]) {
        let fetch = fetch
        let now = clock
        let coordinator = UpdateCoordinator(checker: UpdateChecker { try await fetch.fetch($0) }, defaults: defaults,
                                            currentVersion: version, now: { now })
        var outcomes: [UpdateCoordinator.Outcome] = []
        coordinator.onOutcome = { outcomes.append($0) }
        return (coordinator, { outcomes })
    }

    /// Waits until the coordinator's task has finished (or until the fetch was asked `requests` times).
    private func settle(_ coordinator: UpdateCoordinator) async {
        for _ in 0..<200 where coordinator.isChecking {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    private func waitForRequests(_ count: Int) async {
        for _ in 0..<200 where fetch.count < count {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    private static func release(_ version: String) -> UpdateCheck.Release {
        UpdateCheck.Release(version: SemanticVersion(version)!)
    }

    @Test func automaticCheckReportsOnlyANewerVersion() async {
        let (coordinator, outcomes) = coordinator()
        coordinator.checkIfDue()
        await waitForRequests(1)
        fetch.answer(tag: "v1.1.0")
        await settle(coordinator)
        #expect(outcomes().isEmpty)

        let (later, laterOutcomes) = self.coordinator(version: "1.0.0")
        defaults.removeObject(forKey: UpdateCoordinator.lastCheckKey)
        later.checkIfDue()
        await waitForRequests(2)
        fetch.answer(tag: "v1.1.0")
        await settle(later)
        #expect(laterOutcomes() == [.available(Self.release("1.1.0"), userInitiated: false)])
    }

    @Test func atMostOneAutomaticRequestADayEvenAfterFailures() async {
        let (coordinator, outcomes) = coordinator()
        coordinator.checkIfDue()
        await waitForRequests(1)
        fetch.fail(URLError(.notConnectedToInternet))
        await settle(coordinator)
        coordinator.checkIfDue()
        #expect(!coordinator.isChecking)
        #expect(fetch.count == 1)
        // Failures of automatic checks are only logged.
        #expect(outcomes().isEmpty)
    }

    @Test func userIsAlwaysAnswered() async {
        let (coordinator, outcomes) = coordinator()
        coordinator.checkNow()
        await waitForRequests(1)
        fetch.answer(tag: "v1.1.0")
        await settle(coordinator)

        coordinator.checkNow()
        await waitForRequests(2)
        fetch.fail(URLError(.timedOut))
        await settle(coordinator)

        coordinator.checkNow()
        await waitForRequests(3)
        fetch.answer(tag: "nightly")
        await settle(coordinator)
        #expect(outcomes() == [.upToDate, .noConnection, .unusableAnswer])
    }

    @Test func askingDuringAnAutomaticCheckReportsItsResult() async {
        let (coordinator, outcomes) = coordinator()
        coordinator.checkIfDue()
        await waitForRequests(1)
        coordinator.checkNow()
        fetch.answer(tag: "v1.1.0")
        await settle(coordinator)
        #expect(fetch.count == 1)
        #expect(outcomes() == [.upToDate])
    }

    @Test func stoppedChecksReportNothing() async {
        let (coordinator, outcomes) = coordinator(version: "1.0.0")
        coordinator.checkNow()
        await waitForRequests(1)
        coordinator.stop()
        fetch.answer(tag: "v2.0.0")
        try? await Task.sleep(for: .milliseconds(50))
        #expect(outcomes().isEmpty)
        // Not even the time of the check is written (uninstall deletes the defaults first).
        #expect(defaults.object(forKey: UpdateCoordinator.lastCheckKey) == nil)
    }

    @Test func turningOffDropsOnlyAutomaticChecks() async {
        let (coordinator, outcomes) = coordinator(version: "1.0.0")
        coordinator.checkIfDue()
        await waitForRequests(1)
        coordinator.cancelAutomatic()
        fetch.answer(tag: "v2.0.0")
        try? await Task.sleep(for: .milliseconds(50))
        #expect(outcomes().isEmpty)

        coordinator.checkNow()
        await waitForRequests(2)
        coordinator.cancelAutomatic()
        fetch.answer(tag: "v2.0.0")
        await settle(coordinator)
        #expect(outcomes() == [.available(Self.release("2.0.0"), userInitiated: true)])
    }

    @Test func redirectsStayOnTheAPIHost() {
        #expect(SameHostRedirects.allows(URL(string: "https://api.github.com/repositories/1/releases/latest")))
        #expect(!SameHostRedirects.allows(URL(string: "http://api.github.com/x")))
        #expect(!SameHostRedirects.allows(URL(string: "https://example.com/x")))
        #expect(!SameHostRedirects.allows(nil))
    }
}
