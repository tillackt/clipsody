import Foundation
import Testing
@testable import ClippboardCore

@Suite struct CapturePolicyTests {
    @Test(arguments: ["org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType", "com.agilebits.onepassword"])
    func concealedContentIsNeverRecorded(_ marker: String) {
        #expect(!CapturePolicy.shouldRecord(pasteboardTypes: ["public.utf8-plain-text", marker],
                                            frontmostApp: "com.apple.Notes", config: Config()))
    }

    @Test func ignoredAppsAreNotRecorded() {
        var config = Config()
        config.ignoredApps = ["com.example.vault"]
        #expect(!CapturePolicy.shouldRecord(pasteboardTypes: ["public.utf8-plain-text"],
                                            frontmostApp: "com.example.vault", config: config))
        #expect(CapturePolicy.shouldRecord(pasteboardTypes: ["public.utf8-plain-text"],
                                           frontmostApp: "com.apple.Notes", config: config))
        #expect(CapturePolicy.shouldRecord(pasteboardTypes: ["public.utf8-plain-text"], frontmostApp: nil, config: config))
    }

    @Test func passwordManagersAreIgnoredByDefault() {
        for app in ["com.1password.1password", "com.bitwarden.desktop", "org.keepassxc.keepassxc"] {
            #expect(!CapturePolicy.shouldRecord(pasteboardTypes: [], frontmostApp: app, config: Config()))
        }
    }

    @Test func blankOrHugeTextIsNotKept() {
        #expect(CapturePolicy.acceptsText("hello"))
        #expect(!CapturePolicy.acceptsText("  \n\t "))
        #expect(!CapturePolicy.acceptsText(String(repeating: "x", count: CaptureLimits.maxTextBytes + 1)))
        #expect(CapturePolicy.acceptsText(String(repeating: "x", count: CaptureLimits.maxTextBytes)))
    }

    @Test func richTextLimit() {
        #expect(CapturePolicy.acceptsRichText(byteCount: CaptureLimits.maxRichTextBytes))
        #expect(!CapturePolicy.acceptsRichText(byteCount: CaptureLimits.maxRichTextBytes + 1))
    }
}
