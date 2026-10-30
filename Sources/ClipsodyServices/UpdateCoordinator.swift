import ClipsodyCore
import Foundation

/// When to check and what to report, without UI: the app shows the outcomes. At most one request runs
/// at a time; a check that was stopped reports nothing, even if its answer still arrives.
@MainActor
public final class UpdateCoordinator {
    public enum Outcome: Equatable {
        /// A newer version. `userInitiated`: the user asked and waits for an answer.
        case available(UpdateCheck.Release, userInitiated: Bool)
        /// Only reported to a user who asked.
        case upToDate
        case noConnection
        case unusableAnswer
    }

    static let lastCheckKey = "UpdateLastCheck"

    private let checker: UpdateChecker
    private let defaults: UserDefaults
    private let currentVersion: String
    private let now: () -> Date
    private var task: Task<Void, Never>?
    /// Bumped by every start and stop; an answer for an older value is dropped.
    private var generation = 0
    private var userWaits = false
    public var onOutcome: (Outcome) -> Void = { _ in }

    public init(checker: UpdateChecker = UpdateChecker(), defaults: UserDefaults = .standard,
                currentVersion: String, now: @escaping () -> Date = Date.init) {
        self.checker = checker
        self.defaults = defaults
        self.currentVersion = currentVersion
        self.now = now
    }

    public var isChecking: Bool { task != nil }

    /// The automatic check: only if a day has passed since the last one.
    public func checkIfDue() {
        guard task == nil, UpdateCheck.isDue(lastCheck: defaults.object(forKey: Self.lastCheckKey) as? Date, now: now())
        else { return }
        start(userWaits: false)
    }

    /// The user asked. A check already running reports its result to the user instead of starting another.
    public func checkNow() {
        userWaits = true
        if task == nil { start(userWaits: true) }
    }

    /// Automatic checks were turned off: drops a running automatic check, but not one the user waits for.
    public func cancelAutomatic() {
        if !userWaits { stop() }
    }

    /// Drops any running check (uninstall).
    public func stop() {
        generation += 1
        task?.cancel()
        task = nil
        userWaits = false
    }

    private func start(userWaits: Bool) {
        self.userWaits = userWaits
        generation += 1
        let started = generation
        let checker = checker
        let currentVersion = currentVersion
        task = Task { [weak self] in
            let result: Result<UpdateCheck.Release, Error>
            do {
                result = .success(try await checker.latestRelease(currentVersion: currentVersion))
            } catch {
                result = .failure(error)
            }
            guard let self, started == generation else { return }
            task = nil
            finish(result)
        }
    }

    private func finish(_ result: Result<UpdateCheck.Release, Error>) {
        let userWaited = userWaits
        userWaits = false
        // A failed check counts too: at most one automatic request a day, as the privacy policy says.
        defaults.set(now(), forKey: Self.lastCheckKey)
        switch result {
        case .success(let release) where UpdateCheck.isNewer(release, than: currentVersion):
            onOutcome(.available(release, userInitiated: userWaited))
        case .success:
            if userWaited { onOutcome(.upToDate) }
        case .failure(let error):
            logger.error("Update check failed: \(String(describing: error), privacy: .public)")
            if userWaited { onOutcome(error is UpdateChecker.Failure ? .unusableAnswer : .noConnection) }
        }
    }
}
