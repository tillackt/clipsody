import Foundation
import Testing

/// The app's version follows Semantic Versioning (README, "Versioning"), so every pull request
/// checks the format, not only the release build.
@Suite struct VersionTests {
    static func infoPlist() throws -> [String: Any] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/Info.plist")
        let plist = try PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil)
        return try #require(plist as? [String: Any])
    }

    @Test func versionIsMajorMinorPatch() throws {
        let version = try #require(try Self.infoPlist()["CFBundleShortVersionString"] as? String)
        // No leading zeros, exactly three numbers: 1.0.0, 1.12.3, not 1.0 or 01.2.3.
        #expect(version.wholeMatch(of: /(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)/) != nil, "\(version)")
    }
}
