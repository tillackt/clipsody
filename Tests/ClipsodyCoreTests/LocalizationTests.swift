import Foundation
import Testing

/// Checks Resources/Localizable.xcstrings: every text is translated into every language of the
/// app, with the same placeholders, so no language falls back to English or crashes on a format.
@Suite struct LocalizationTests {
    static let languages = ["de", "es", "fr", "it", "nl", "pl", "pt-BR"]

    static func catalog() throws -> [String: Any] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/Localizable.xcstrings")
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
        return try #require((json as? [String: Any])?["strings"] as? [String: Any])
    }

    static func localizations(_ entry: Any) -> [String: Any] {
        (entry as? [String: Any])?["localizations"] as? [String: Any] ?? [:]
    }

    /// Plural forms by category, or nil for a single text.
    static func pluralForms(_ localization: Any?) -> [String: String]? {
        guard let plural = ((localization as? [String: Any])?["variations"] as? [String: Any])?["plural"] as? [String: Any]
        else { return nil }
        return plural.compactMapValues { (($0 as? [String: Any])?["stringUnit"] as? [String: Any])?["value"] as? String }
    }

    /// The translations of one language: a single text or one per plural category.
    static func values(_ localization: Any?) -> [String] {
        if let unit = (localization as? [String: Any])?["stringUnit"] as? [String: Any] {
            return [unit["value"] as? String ?? ""]
        }
        return pluralForms(localization).map { Array($0.values) } ?? []
    }

    /// Placeholders regardless of position ("%2$@" counts as "%@"), so a translation may reorder them.
    static func placeholders(_ text: String) -> [String] {
        text.matches(of: /%(?:[0-9]+\$)?(lld|@)/).map { "%" + $0.output.1 }.sorted()
    }

    @Test func everyTextIsTranslatedWithTheSamePlaceholders() throws {
        let strings = try Self.catalog()
        #expect(strings.count > 50)
        for (key, entry) in strings {
            let localizations = Self.localizations(entry)
            for language in Self.languages {
                let values = Self.values(localizations[language])
                #expect(!values.isEmpty && !values.contains(""), "\(language) is missing “\(key)”")
                for value in values {
                    #expect(Self.placeholders(value) == Self.placeholders(key), "\(language): “\(value)” for “\(key)”")
                }
            }
        }
    }

    /// Texts with a number that is not a count of a noun in the text, so they need no plural forms.
    static let numbersWithoutPlural: Set = [
        "Image %lld×%lld", "Pinned · %lld",
        "No matches here – %lld in History (←)", "No matches here – %lld in Pinned (→)",
        "Snippets · %lld", "Label of field %lld", "Text of field %lld",
    ]

    /// A count text needs plural forms in every language, English included ("1 files" otherwise),
    /// with at least "one" and "other", and Polish with all four of its forms.
    @Test func countTextsHaveCompletePluralForms() throws {
        let strings = try Self.catalog()
        for (key, entry) in strings where Self.placeholders(key).contains("%lld") {
            guard !Self.numbersWithoutPlural.contains(key) else { continue }
            let localizations = Self.localizations(entry)
            for language in ["en"] + Self.languages {
                let forms = Self.pluralForms(localizations[language])
                let required: Set<String> = language == "pl" ? ["one", "few", "many", "other"] : ["one", "other"]
                #expect(forms.map { required.isSubset(of: $0.keys) } == true, "\(language) plural forms for “\(key)”")
            }
        }
    }
}
