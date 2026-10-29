import Foundation

/// What the user typed into the search field, split into terms that must all match.
public struct SearchQuery: Sendable {
    public static let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
    public let terms: [String]
    private let foldedTerms: [String]

    public init(_ text: String) {
        terms = text.split(whereSeparator: \.isWhitespace).map(String.init)
        foldedTerms = terms.map(Self.fold)
    }

    public var isEmpty: Bool { terms.isEmpty }

    /// Case- and diacritic-free form; computed once per item so each keystroke is a plain substring search.
    public static func fold(_ text: String) -> String {
        text.folding(options: options, locale: nil)
    }

    public func matches(_ item: ClipItem) -> Bool {
        matches(foldedText: Self.fold(ItemPresentation.searchText(for: item)))
    }

    /// `foldedText` is `SearchQuery.fold(ItemPresentation.searchText(for:))`, cached by the caller.
    public func matches(foldedText: String) -> Bool {
        foldedTerms.allSatisfy { foldedText.contains($0) }
    }

    /// Ranges of all terms in `string`, for highlighting.
    public func ranges(in string: String) -> [NSRange] {
        var ranges: [NSRange] = []
        for term in terms {
            var remaining = string.startIndex..<string.endIndex
            while let found = string.range(of: term, options: Self.options, range: remaining) {
                // An empty match (e.g. a term that is only a combining accent) would never advance.
                guard !found.isEmpty else { break }
                ranges.append(NSRange(found, in: string))
                remaining = found.upperBound..<string.endIndex
            }
        }
        return ranges
    }
}

/// Texts shown for an item in the history list; free of AppKit so it can be tested.
public enum ItemPresentation {
    public static func title(for item: ClipItem, query: SearchQuery) -> String {
        switch item.kind {
        case .image:
            // "Image 478×406 (762 KB)", plus the matching line when found via recognised text
            let base = imageLabel(for: item)
            return recognizedSnippet(for: item, query: query).map { String(localized: "\(base) – “\($0)”") } ?? base
        case .files:
            let names = item.filePaths.map { ($0 as NSString).lastPathComponent }
            return names.count == 1 ? names[0] : String(localized: "\(names.count) files") + ": " + names.joined(separator: ", ")
        case .text:
            let collapsed = item.text.prefix(2_000)
                .split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .joined(separator: " ⏎ ")
            return String(collapsed.prefix(300))
        }
    }

    public static func imageLabel(for item: ClipItem) -> String {
        let size = ByteCountFormatter.string(fromByteCount: item.byteSize, countStyle: .file)
        let label = String(localized: "Image \(item.imageWidth)×\(item.imageHeight)")
        return label + (item.byteSize > 0 ? " (\(size))" : "")
    }

    /// Searchable part of a text; huge texts (logs) would otherwise slow down every keystroke.
    public static let searchablePrefix = CaptureLimits.searchableCharacters

    /// Everything a search term may match: content (its first 100,000 characters), label,
    /// source app and recognised text.
    public static func searchText(for item: ClipItem) -> String {
        let label = item.kind == .image ? String(localized: "Image") : ""
        let content = String(item.text.prefix(searchablePrefix))
        return [content, label, item.app ?? "", item.recognizedText ?? ""].joined(separator: "\n")
    }

    /// First recognised line containing a search term, shortened around the match.
    public static func recognizedSnippet(for item: ClipItem, query: SearchQuery) -> String? {
        guard let text = item.recognizedText, !query.isEmpty else { return nil }
        for line in text.split(whereSeparator: \.isNewline) {
            let line = String(line)
            guard let match = query.terms.lazy.compactMap({ line.range(of: $0, options: SearchQuery.options) }).first
            else { continue }
            let start = line.index(match.lowerBound, offsetBy: -25, limitedBy: line.startIndex) ?? line.startIndex
            let end = line.index(match.upperBound, offsetBy: 40, limitedBy: line.endIndex) ?? line.endIndex
            return (start > line.startIndex ? "…" : "") + line[start..<end] + (end < line.endIndex ? "…" : "")
        }
        return nil
    }
}
