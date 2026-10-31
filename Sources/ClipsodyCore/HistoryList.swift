import Foundation

/// The entries the panel lists: everything loaded, and the part of the current section matching the search.
public struct HistoryList {
    /// The panel shows the history and the pinned entries as two separate lists.
    public enum Section: Sendable {
        case history, pinned

        public var other: Section { self == .history ? .pinned : .history }

        func contains(_ item: ClipItem) -> Bool { item.pinned == (self == .pinned) }
    }

    public private(set) var allItems: [ClipItem] = []
    /// The entries of `section` matching `query`, in list order.
    public private(set) var items: [ClipItem] = []
    public private(set) var query = SearchQuery("")
    public private(set) var section = Section.history
    /// Folded search text per item id, built on the first search after a load instead of on every
    /// keystroke; nil until then, since most openings never search.
    private(set) var searchIndex: [Int64: String]?

    public init() {}

    /// Replaces the entries (a reload from the store) and filters them by `query`.
    public mutating func load(_ items: [ClipItem], query text: String) {
        allItems = items
        searchIndex = nil
        filter(text)
    }

    public mutating func filter(_ text: String) {
        query = SearchQuery(text)
        applyQuery()
    }

    public mutating func show(_ section: Section) {
        self.section = section
        applyQuery()
    }

    /// All entries in `section`, whatever the search.
    public func count(in section: Section) -> Int {
        allItems.reduce(0) { $0 + (section.contains($1) ? 1 : 0) }
    }

    /// Entries in `section` matching the search, e.g. to point to hits in the section not shown.
    public mutating func matchCount(in section: Section) -> Int {
        matching(in: section).count
    }

    private mutating func applyQuery() {
        items = matching(in: section)
    }

    private mutating func matching(in section: Section) -> [ClipItem] {
        if query.isEmpty { return allItems.filter(section.contains) }
        let index = searchIndex ?? buildSearchIndex()
        return allItems.filter { section.contains($0) && query.matches(foldedText: index[$0.id] ?? "") }
    }

    /// The row of the entry with `id`, or the first row if it is no longer listed.
    public func row(selecting id: Int64?) -> Int {
        id.flatMap { id in items.firstIndex { $0.id == id } } ?? 0
    }

    /// The entry to select once the one in `row` is deleted: the one moving into its row, else the one above.
    public func neighbour(ofRow row: Int) -> ClipItem? {
        guard items.indices.contains(row) else { return nil }
        return items.indices.contains(row + 1) ? items[row + 1] : (row > 0 ? items[row - 1] : nil)
    }

    public mutating func remove(id: Int64) {
        allItems.removeAll { $0.id == id }
        items.removeAll { $0.id == id }
    }

    /// Takes over newly recognised text for one image, so a search finds it without a reload.
    public mutating func setRecognizedText(_ text: String, forImageFile file: String) {
        for index in allItems.indices where allItems[index].imageFile == file {
            allItems[index].recognizedText = text
            // Without an index there is nothing to patch; it is built from allItems when needed.
            searchIndex?[allItems[index].id] = SearchQuery.fold(ItemPresentation.searchText(for: allItems[index]))
        }
        applyQuery()
    }

    private mutating func buildSearchIndex() -> [Int64: String] {
        let index = Dictionary(uniqueKeysWithValues: allItems.map {
            ($0.id, SearchQuery.fold(ItemPresentation.searchText(for: $0)))
        })
        searchIndex = index
        return index
    }
}
