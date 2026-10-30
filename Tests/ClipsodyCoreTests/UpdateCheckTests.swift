import Foundation
import Testing
@testable import ClipsodyCore

@Suite struct UpdateCheckTests {
    @Test func versionsParseWithAndWithoutPrefix() throws {
        #expect(SemanticVersion("1.2.3")?.description == "1.2.3")
        #expect(SemanticVersion("v10.0.12")?.description == "10.0.12")
        for invalid in ["1.2", "1.2.3.4", "01.2.3", "1.2.3-beta", "v", "", "x1.2.3", "1.2.3 "] {
            #expect(SemanticVersion(invalid) == nil, "\(invalid)")
        }
    }

    @Test func versionsCompareNumerically() throws {
        let order = ["1.0.0", "1.0.9", "1.0.10", "1.1.0", "1.10.0", "2.0.0"].compactMap(SemanticVersion.init)
        #expect(order.count == 6)
        #expect(order == order.sorted())
        #expect(SemanticVersion("1.1.0") == SemanticVersion("v1.1.0"))
    }

    @Test func latestReleaseIsReadFromTheTag() throws {
        let json = #"{"tag_name": "v1.2.0", "draft": false, "prerelease": false, "html_url": "https://example.com/x"}"#
        let release = try #require(UpdateCheck.release(fromLatestJSON: Data(json.utf8)))
        #expect(release.version.description == "1.2.0")
        // The page is built from the version, never taken from the response.
        #expect(release.pageURL.absoluteString == "https://github.com/tillackt/clipsody/releases/tag/v1.2.0")
    }

    @Test func draftsPreReleasesAndOddTagsAreIgnored() {
        for json in [#"{"tag_name": "v1.2.0", "draft": true}"#,
                     #"{"tag_name": "v1.2.0", "prerelease": true}"#,
                     #"{"tag_name": "v1.2.0-rc1"}"#,
                     #"{"tag_name": "../../evil"}"#,
                     #"{"message": "Not Found"}"#,
                     "not json"] {
            #expect(UpdateCheck.release(fromLatestJSON: Data(json.utf8)) == nil, "\(json)")
        }
    }

    @Test func onlyHigherVersionsAreNewer() throws {
        let release = UpdateCheck.Release(version: try #require(SemanticVersion("1.2.0")))
        #expect(UpdateCheck.isNewer(release, than: "1.1.9"))
        #expect(!UpdateCheck.isNewer(release, than: "1.2.0"))
        #expect(!UpdateCheck.isNewer(release, than: "1.10.0"))
        // An unreadable own version never announces anything.
        #expect(!UpdateCheck.isNewer(release, than: "?"))
    }

    @Test func checkIsDueOncePerDay() {
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        #expect(UpdateCheck.isDue(lastCheck: nil, now: now))
        #expect(!UpdateCheck.isDue(lastCheck: now.addingTimeInterval(-3600), now: now))
        #expect(UpdateCheck.isDue(lastCheck: now.addingTimeInterval(-UpdateCheck.interval), now: now))
        // A last check in the future (the clock was set back) must not stop checks for good.
        #expect(UpdateCheck.isDue(lastCheck: now.addingTimeInterval(86_400 * 30), now: now))
    }

    @Test func consentIsUnsetUntilAnsweredAndRoundTrips() throws {
        #expect(Config().checkForUpdates == nil)
        let old = try JSONDecoder().decode(Config.self, from: Data(#"{"retentionDays": 3}"#.utf8))
        #expect(old.checkForUpdates == nil)
        var config = Config()
        config.checkForUpdates = false
        let decoded = try JSONDecoder().decode(Config.self, from: JSONEncoder().encode(config))
        #expect(decoded.checkForUpdates == false)
    }
}
