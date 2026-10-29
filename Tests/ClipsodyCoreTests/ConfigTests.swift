import Foundation
import Testing
@testable import ClipsodyCore

@Suite struct ConfigTests {
    @Test func missingKeysUseDefaults() throws {
        let config = try JSONDecoder().decode(Config.self, from: Data(#"{"retentionDays": 3}"#.utf8))
        #expect(config.retentionDays == 3)
        #expect(config.maxItems == Config().maxItems)
        #expect(config.hotkey == Config().hotkey)
    }

    @Test func outOfRangeNumbersAreClamped() throws {
        let json = #"{"retentionDays": 0, "maxItems": -1}"#
        let config = try JSONDecoder().decode(Config.self, from: Data(json.utf8))
        #expect(config.retentionDays == Config.retentionRange.lowerBound)
        #expect(config.maxItems == Config.maxItemsRange.lowerBound)

        let huge = try JSONDecoder().decode(Config.self, from: Data(#"{"maxItems": 99999999}"#.utf8))
        #expect(huge.maxItems == Config.maxItemsRange.upperBound)
    }

    @Test func newDefaultIgnoredAppsReachOldConfigsOnce() throws {
        // Written by an older release: only the first generation, one of them removed by the user.
        let json = #"{"ignoredApps": ["com.1password.1password", "com.example.custom"]}"#
        let config = try JSONDecoder().decode(Config.self, from: Data(json.utf8))

        #expect(config.ignoredApps.contains("org.keepassxc.keepassxc"))
        #expect(config.ignoredApps.contains("com.example.custom"))
        #expect(!config.ignoredApps.contains("com.bitwarden.desktop")) // removed by the user, stays removed
        #expect(config.ignoredAppsDefaultsVersion == Config.defaultIgnoredApps.count)
    }

    @Test func everyDefaultIgnoredAppHasAName() {
        for app in Config.defaultIgnoredApps.joined() {
            #expect(Config.defaultIgnoredAppNames[app] != nil, "\(app)")
        }
    }

    @Test func removedNewDefaultsStayRemoved() throws {
        var config = Config()
        config.ignoredApps.removeAll { $0 == "org.keepassxc.keepassxc" }
        let reloaded = try JSONDecoder().decode(Config.self, from: JSONEncoder().encode(config))
        #expect(!reloaded.ignoredApps.contains("org.keepassxc.keepassxc"))
    }

    @Test func saveAndLoadRoundTrip() throws {
        let directory = try TemporaryDirectory()
        var config = Config()
        config.hotkey = "ctrl+shift+v"
        config.ignoredApps = ["com.example.app"]
        config.save(to: directory.url)
        #expect(Config.load(from: directory.url) == config)
    }

    @Test func invalidFileFallsBackToDefaultsAndIsKeptAside() throws {
        let directory = try TemporaryDirectory()
        try Data("{ not json".utf8).write(to: Config.url(in: directory.url))
        var reported: URL?
        #expect(Config.load(from: directory.url) { reported = $0 } == Config())
        let backup = try #require(reported)
        #expect(String(data: try Data(contentsOf: backup), encoding: .utf8) == "{ not json")
        #expect(!FileManager.default.fileExists(atPath: Config.url(in: directory.url).path))
    }
}

@Suite struct HotKeySpecTests {
    @Test func parsesModifiersAndKey() throws {
        let spec = try #require(HotKeySpec("cmd+option+c"))
        #expect(spec.keyCode == 8)
        #expect(spec.modifiers == HotKeySpec.command | HotKeySpec.option)
        #expect(spec.display == "⌥⌘C")
        #expect(spec.modifierSymbols == "⌥⌘")
    }

    @Test func displayUsesMenuOrder() {
        #expect(HotKeySpec("shift+cmd+ctrl+option+space")?.display == "⌃⌥⇧⌘Space")
    }

    // Option or Shift alone are not accepted by macOS 15 and later.
    @Test(arguments: ["c", "cmd+", "cmd+f13", "", "hyper+c", "option+c", "shift+option+v"])
    func rejectsInvalidSpecs(_ text: String) {
        #expect(HotKeySpec(text) == nil)
    }

    @Test func keyNameRoundTrips() {
        #expect(HotKeySpec.keyName(for: 8) == "c")
        #expect(HotKeySpec.keyName(for: 49) == "space")
        #expect(HotKeySpec.keyName(for: 200) == nil)
    }

    @Test(arguments: ["option+cmd+c", "ctrl+v", "ctrl+option+shift+cmd+space", "shift+cmd+5"])
    func configStringRoundTrips(_ text: String) throws {
        let spec = try #require(HotKeySpec(text))
        #expect(spec.configString == text)
        #expect(HotKeySpec(spec.configString) == spec)
    }

    // Older config files and hand edits use any order and aliases; they must keep their meaning.
    @Test func configStringIsCanonicalForExistingConfigs() throws {
        let spec = try #require(HotKeySpec("cmd+option+c"))
        #expect(spec.configString == "option+cmd+c")
        #expect(HotKeySpec("Command + Alt + C") == spec)
    }

    @Test func initFromKeyCodeMatchesParsedSpec() {
        let spec = HotKeySpec(keyCode: 8, modifiers: HotKeySpec.command | HotKeySpec.option)
        #expect(spec == HotKeySpec("cmd+option+c"))
        #expect(spec?.configString == "option+cmd+c")
        #expect(HotKeySpec(keyCode: 49, modifiers: HotKeySpec.control)?.display == "⌃Space")
    }

    @Test(arguments: [HotKeySpec.option, HotKeySpec.shift, HotKeySpec.option | HotKeySpec.shift, 0])
    func initFromKeyCodeNeedsCommandOrControl(_ modifiers: UInt32) {
        #expect(HotKeySpec(keyCode: 8, modifiers: modifiers) == nil)
    }

    @Test(arguments: [UInt16(53), 105, 200]) // Escape, F13, nothing
    func initFromKeyCodeRejectsUnknownKeys(_ keyCode: UInt16) {
        #expect(HotKeySpec(keyCode: keyCode, modifiers: HotKeySpec.command) == nil)
    }
}
