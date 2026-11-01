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

    /// A release object is a few kilobytes; anything far larger is not a real answer.
    static let maxResponseBytes = 512 * 1024

    private let fetch: Fetch

    /// `fetch` is replaced in tests; the default uses `session`.
    public init(fetch: @escaping Fetch = UpdateChecker.limitedFetch) {
        self.fetch = fetch
    }

    /// One session for all checks: ephemeral (no cookies, no cache on disk) and only following
    /// redirects that stay on the API host.
    static let session = makeSession(.ephemeral)

    static func makeSession(_ configuration: URLSessionConfiguration,
                            delegate: URLSessionTaskDelegate = SameHostRedirects()) -> URLSession {
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        return URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
    }

    public static let limitedFetch: Fetch = limitedFetch(using: session)

    /// Reads at most `maxResponseBytes`.
    static func limitedFetch(using session: URLSession) -> Fetch {
        { request in try await limitedData(for: request, using: session) }
    }

    private static func limitedData(for request: URLRequest, using session: URLSession) async throws -> (Data, URLResponse) {
        let (bytes, response) = try await session.bytes(for: request)
        guard response.expectedContentLength <= Int64(maxResponseBytes) else { throw Failure.unreadableResponse }
        var data = Data()
        for try await byte in bytes {
            data.append(byte)
            if data.count > maxResponseBytes { throw Failure.unreadableResponse }
        }
        return (data, response)
    }

    public func latestRelease(currentVersion: String) async throws -> UpdateCheck.Release {
        var request = URLRequest(url: UpdateCheck.latestReleaseURL, cachePolicy: .reloadIgnoringLocalCacheData,
                                 timeoutInterval: 20)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        // GitHub's API requires a User-Agent; the default one would also name the macOS version.
        request.setValue("Clipsody/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        // Otherwise the system sends the user's preferred languages.
        request.setValue("en", forHTTPHeaderField: "Accept-Language")
        let (data, response) = try await fetch(request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw Failure.httpStatus(http.statusCode)
        }
        guard let release = UpdateCheck.release(fromLatestJSON: data) else { throw Failure.unreadableResponse }
        return release
    }
}

/// Follows a redirect only to the API host itself, over HTTPS; the request's headers would go along.
final class SameHostRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? {
        Self.allows(request.url) ? request : nil
    }

    static func allows(_ url: URL?) -> Bool {
        url?.scheme == "https" && url?.host == UpdateCheck.latestReleaseURL.host
    }
}
