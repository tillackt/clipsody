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

    /// The translations of one language: a single text or one per plural category.
    static func values(_ localization: [String: Any]) -> [String] {
        if let unit = localization["stringUnit"] as? [String: Any] {
            return [unit["value"] as? String ?? ""]
        }
        let plural = (localization["variations"] as? [String: Any])?["plural"] as? [String: Any] ?? [:]
        return plural.values.compactMap { (($0 as? [String: Any])?["stringUnit"] as? [String: Any])?["value"] as? String }
    }

    static func placeholders(_ text: String) -> [String] {
        let regex = try! NSRegularExpression(pattern: "%(lld|@)")
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
            .map { (text as NSString).substring(with: $0.range) }
    }

    @Test func everyTextIsTranslatedWithTheSamePlaceholders() throws {
        let strings = try Self.catalog()
        #expect(strings.count > 50)
        for (key, entry) in strings {
            let localizations = (entry as? [String: Any])?["localizations"] as? [String: Any] ?? [:]
            for language in Self.languages {
                let values = Self.values(localizations[language] as? [String: Any] ?? [:])
                #expect(!values.isEmpty && !values.contains(""), "\(language) is missing “\(key)”")
                for value in values {
                    #expect(Self.placeholders(value) == Self.placeholders(key), "\(language): “\(value)” for “\(key)”")
                }
            }
        }
    }

    @Test func pluralsCoverPolishForms() throws {
        let strings = try Self.catalog()
        for (key, entry) in strings {
            let localizations = (entry as? [String: Any])?["localizations"] as? [String: Any] ?? [:]
            guard let polish = (localizations["pl"] as? [String: Any])?["variations"] as? [String: Any] else { continue }
            let categories = Set((polish["plural"] as? [String: Any] ?? [:]).keys)
            #expect(categories == ["one", "few", "many", "other"], "pl plural forms for “\(key)”")
        }
    }
}
