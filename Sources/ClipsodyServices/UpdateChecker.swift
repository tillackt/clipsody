import ClipsodyCore
import Foundation

/// Asks GitHub for the latest release. The request carries nothing from the history: GitHub sees the
/// IP address and the app version (User-Agent). No cookies, no cache, nothing stored.
public struct UpdateChecker: Sendable {
    public enum Failure: Error, Equatable {
        case httpStatus(Int)
        case unreadableResponse
    }

    public typealias Fetch = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    private let fetch: Fetch

    /// `fetch` is replaced in tests; the default is an ephemeral URLSession.
    public init(fetch: @escaping Fetch = UpdateChecker.ephemeralFetch) {
        self.fetch = fetch
    }

    public static let ephemeralFetch: Fetch = { request in
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        return try await URLSession(configuration: configuration).data(for: request)
    }

    public func latestRelease(currentVersion: String) async throws -> UpdateCheck.Release {
        var request = URLRequest(url: UpdateCheck.latestReleaseURL, cachePolicy: .reloadIgnoringLocalCacheData,
                                 timeoutInterval: 20)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        // GitHub's API requires a User-Agent; the default one would also name the macOS version.
        request.setValue("Clipsody/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await fetch(request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw Failure.httpStatus(http.statusCode)
        }
        guard let release = UpdateCheck.release(fromLatestJSON: data) else { throw Failure.unreadableResponse }
        return release
    }
}
