import Foundation

/// The entries the panel lists: everything loaded, and the part matching the current search.
public struct HistoryList {
    public private(set) var allItems: [ClipItem] = []
    /// The entries matching `query`, in list order.
    public private(set) var items: [ClipItem] = []
    public private(set) var query = SearchQuery("")
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

    private mutating func applyQuery() {
        if query.isEmpty {
            items = allItems
        } else {
            let index = searchIndex ?? buildSearchIndex()
            items = allItems.filter { query.matches(foldedText: index[$0.id] ?? "") }
        }
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
