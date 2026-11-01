import Foundation

/// A release version, MAJOR.MINOR.PATCH (README, "Versioning"). Tags carry a leading "v".
public struct SemanticVersion: Comparable, CustomStringConvertible, Sendable {
    public let major: Int
    public let minor: Int
    public let patch: Int

    /// Accepts "1.2.3" and "v1.2.3"; anything else (pre-releases, missing parts) is nil.
    public init?(_ string: String) {
        let number = string.hasPrefix("v") ? String(string.dropFirst()) : string
        guard let match = number.wholeMatch(of: /(0|[1-9][0-9]{0,5})\.(0|[1-9][0-9]{0,5})\.(0|[1-9][0-9]{0,5})/),
              let major = Int(match.1), let minor = Int(match.2), let patch = Int(match.3) else { return nil }
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    public var description: String { "\(major).\(minor).\(patch)" }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }
}

/// What the update check asks and how it reads the answer. Only the version number is taken from
/// the response; the page that opens is built from it, so the response cannot point anywhere else.
public enum UpdateCheck {
    public static let latestReleaseURL = URL(string: "https://api.github.com/repos/tillackt/clipsody/releases/latest")!
    /// How often the automatic check runs.
    public static let interval: TimeInterval = 24 * 60 * 60
    /// The app an update must contain.
    public static let bundleIdentifier = "io.github.tillackt.clipsody"
    /// SHA-256 of the certificate every release is signed with (build.sh, RELEASE_CERT_SHA256; also on
    /// the website). An update signed with anything else is not installed.
    public static let signingCertificateSHA256 = "4d175a00dff7276c393a30bc11f2c9ec29cd17da08946cfada661e16b1f9a9d6"

    public struct Release: Equatable, Sendable {
        public let version: SemanticVersion
        public var pageURL: URL {
            URL(string: "https://github.com/tillackt/clipsody/releases/tag/v\(version)")!
        }
        /// The disk image of exactly this version (not "latest", which may have moved on meanwhile).
        public var diskImageURL: URL {
            URL(string: "https://github.com/tillackt/clipsody/releases/download/v\(version)/Clipsody.dmg")!
        }
        /// "<sha256>  Clipsody.dmg", written by `./build.sh release`.
        public var checksumURL: URL {
            URL(string: "https://github.com/tillackt/clipsody/releases/download/v\(version)/Clipsody.dmg.sha256")!
        }

        public init(version: SemanticVersion) {
            self.version = version
        }
    }

    /// The release in a response of GitHub's "latest release" endpoint; nil for drafts, pre-releases
    /// and anything that is not a plain version tag.
    public static func release(fromLatestJSON data: Data) -> Release? {
        guard let response = try? JSONDecoder().decode(LatestReleaseResponse.self, from: data),
              response.draft != true, response.prerelease != true,
              let version = SemanticVersion(response.tagName) else { return nil }
        return Release(version: version)
    }

    /// Whether `release` is newer than the running version; false if that cannot be read.
    public static func isNewer(_ release: Release, than currentVersion: String) -> Bool {
        guard let current = SemanticVersion(currentVersion) else { return false }
        return release.version > current
    }

    /// The SHA-256 in a checksum file ("<64 hex digits>  Clipsody.dmg"), lowercased; nil for anything else.
    public static func checksum(fromFile data: Data) -> String? {
        guard data.count <= 1_024, let text = String(data: data, encoding: .utf8),
              let first = text.split(whereSeparator: \.isWhitespace).first,
              first.wholeMatch(of: /[0-9a-fA-F]{64}/) != nil else { return nil }
        return first.lowercased()
    }

    /// Whether the automatic check is due. A last check in the future (clock changed) counts as due.
    public static func isDue(lastCheck: Date?, now: Date = Date()) -> Bool {
        guard let lastCheck, lastCheck <= now else { return true }
        return now.timeIntervalSince(lastCheck) >= interval
    }
}

/// The fields of GitHub's release object that the check reads.
private struct LatestReleaseResponse: Decodable {
    let tagName: String
    let draft: Bool?
    let prerelease: Bool?

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name", draft, prerelease
    }
}
