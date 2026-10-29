import Foundation
import Testing
@testable import ClippboardCore

@Suite struct ConfigTests {
    @Test func missingKeysUseDefaults() throws {
        let config = try JSONDecoder().decode(Config.self, from: Data(#"{"retentionDays": 3}"#.utf8))
        #expect(config.retentionDays == 3)
        #expect(config.maxItems == Config().maxItems)
        #expect(config.hotkey == Config().hotkey)
    }

    @Test func saveAndLoadRoundTrip() throws {
        let directory = try TemporaryDirectory()
        var config = Config()
        config.hotkey = "ctrl+shift+v"
        config.ignoredApps = ["com.example.app"]
        config.save(to: directory.url)
        #expect(Config.load(from: directory.url) == config)
    }

    @Test func invalidFileFallsBackToDefaults() throws {
        let directory = try TemporaryDirectory()
        try Data("{ not json".utf8).write(to: Config.url(in: directory.url))
        #expect(Config.load(from: directory.url) == Config())
    }
}

@Suite struct HotKeySpecTests {
    @Test func parsesModifiersAndKey() throws {
        let spec = try #require(HotKeySpec("cmd+option+c"))
        #expect(spec.keyCode == 8)
        #expect(spec.modifiers == HotKeySpec.command | HotKeySpec.option)
        #expect(spec.display == "⌥⌘C")
    }

    @Test func displayUsesMenuOrder() {
        #expect(HotKeySpec("shift+cmd+ctrl+option+space")?.display == "⌃⌥⇧⌘Space")
    }

    @Test(arguments: ["c", "cmd+", "cmd+f13", "", "hyper+c"])
    func rejectsInvalidSpecs(_ text: String) {
        #expect(HotKeySpec(text) == nil)
    }

    @Test func keyNameRoundTrips() {
        #expect(HotKeySpec.keyName(for: 8) == "c")
        #expect(HotKeySpec.keyName(for: 49) == "space")
        #expect(HotKeySpec.keyName(for: 200) == nil)
    }
}
