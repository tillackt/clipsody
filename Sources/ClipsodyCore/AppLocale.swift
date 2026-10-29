import Foundation

/// Locale for numbers, sizes and dates shown next to the app's texts. `Locale.current` follows
/// the Mac's region and system language, not the language chosen for Clipsody, so a French UI
/// would say "vor 2 Stunden". This combines the app's language with the user's region.
public enum AppLocale {
    public static let current: Locale = {
        guard let language = Bundle.main.preferredLocalizations.first else { return .current }
        var components = Locale.Components(identifier: language)
        if components.region == nil { components.region = Locale.current.region }
        return Locale(components: components)
    }()

    /// File size like "612 KB", in the app's language.
    public static func fileSize(_ bytes: Int64) -> String {
        bytes.formatted(.byteCount(style: .file).locale(current))
    }
}
