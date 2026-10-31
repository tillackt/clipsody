import Foundation
import Testing
@testable import ClipsodyCore

@Suite struct HistoryListTests {
    func text(_ id: Int64, _ text: String) -> ClipItem {
        ClipItem(id: id, kind: .text, text: text, date: Date())
    }

    func image(_ id: Int64, file: String) -> ClipItem {
        ClipItem(id: id, kind: .image, text: "", imageFile: file, date: Date())
    }

    func pinned(_ id: Int64, _ text: String) -> ClipItem {
        ClipItem(id: id, kind: .text, text: text, date: Date(), pinned: true)
    }

    func ids(_ items: [ClipItem]) -> [Int64] { items.map(\.id) }

    @Test func historyAndPinnedAreSeparateLists() {
        var list = HistoryList()
        list.load([pinned(1, "Gruß"), text(2, "a"), pinned(3, "Adresse"), text(4, "b")], query: "")
        #expect(list.section == .history)
        #expect(ids(list.items) == [2, 4])
        #expect(list.count(in: .pinned) == 2)
        #expect(list.count(in: .history) == 2)

        list.show(.pinned)
        #expect(ids(list.items) == [1, 3])
        #expect(list.section.other == .history)

        // A reload keeps the section.
        list.load([pinned(1, "Gruß"), text(2, "a")], query: "")
        #expect(ids(list.items) == [1])
    }

    @Test func searchCountsHitsInTheOtherSection() {
        var list = HistoryList()
        list.load([pinned(1, "Mit freundlichen Grüßen"), text(2, "Grüße aus Berlin"), text(3, "egal")], query: "grüß")
        #expect(ids(list.items) == [2])
        #expect(list.matchCount(in: .pinned) == 1)

        list.filter("freundlich")
        #expect(list.items.isEmpty)
        #expect(list.matchCount(in: .pinned) == 1)
        // The pinned count in the tab title ignores the search.
        #expect(list.count(in: .pinned) == 1)

        list.show(.pinned)
        #expect(ids(list.items) == [1])
        #expect(list.matchCount(in: .history) == 0)
    }

    @Test func filterMatchesAllTermsAndEmptyQueryListsEverything() {
        var list = HistoryList()
        list.load([text(1, "Apfel Birne"), text(2, "Birne"), text(3, "Kirsche")], query: "")
        #expect(ids(list.items) == [1, 2, 3])

        list.filter("birne APFEL")
        #expect(ids(list.items) == [1])
        #expect(list.query.terms == ["birne", "APFEL"])

        list.filter("  ")
        #expect(ids(list.items) == [1, 2, 3])
    }

    @Test func searchIndexIsBuiltOnFirstSearchAndDroppedOnReload() {
        var list = HistoryList()
        list.load([text(1, "alpha")], query: "")
        #expect(list.searchIndex == nil)

        list.filter("alp")
        #expect(list.searchIndex?.count == 1)

        // A stale index would miss the new entry.
        list.load([text(1, "alpha"), text(2, "alpine")], query: "")
        #expect(list.searchIndex == nil)
        list.filter("alp")
        #expect(ids(list.items) == [1, 2])
    }

    @Test func loadWithActiveSearchFiltersRightAway() {
        var list = HistoryList()
        list.load([text(1, "alpha"), text(2, "beta")], query: "beta")
        #expect(ids(list.items) == [2])
        #expect(list.searchIndex != nil)
    }

    @Test func selectionFollowsItemIdAndFallsBackToFirstRow() {
        var list = HistoryList()
        list.load([text(1, "a"), text(2, "b"), text(3, "c")], query: "")
        #expect(list.row(selecting: 2) == 1)

        // A new entry on top moves the selected one down a row.
        list.load([text(4, "d"), text(1, "a"), text(2, "b"), text(3, "c")], query: "")
        #expect(list.row(selecting: 2) == 2)

        list.load([text(1, "a"), text(3, "c")], query: "")
        #expect(list.row(selecting: 2) == 0)
        #expect(list.row(selecting: nil) == 0)
    }

    @Test func neighbourAfterDeleteIsNextElsePrevious() {
        var list = HistoryList()
        list.load([text(1, "a"), text(2, "b"), text(3, "c")], query: "")
        #expect(list.neighbour(ofRow: 1)?.id == 3)
        #expect(list.neighbour(ofRow: 2)?.id == 2)
        #expect(list.neighbour(ofRow: 3) == nil)

        list.remove(id: 2)
        #expect(ids(list.allItems) == [1, 3])
        #expect(ids(list.items) == [1, 3])

        list.load([text(1, "a")], query: "")
        #expect(list.neighbour(ofRow: 0) == nil)
    }

    @Test func recognizedTextWithoutSearchLeavesIndexUnbuilt() {
        var list = HistoryList()
        list.load([image(1, file: "a.png"), image(2, file: "b.png")], query: "")

        list.setRecognizedText("Rechnung", forImageFile: "a.png")

        #expect(list.allItems[0].recognizedText == "Rechnung")
        #expect(list.allItems[1].recognizedText == nil)
        #expect(list.items[0].recognizedText == "Rechnung")
        #expect(list.searchIndex == nil)
        list.filter("rechnung")
        #expect(ids(list.items) == [1])
    }

    @Test func recognizedTextDuringSearchPatchesIndexAndRefilters() {
        var list = HistoryList()
        list.load([image(1, file: "a.png"), image(2, file: "b.png")], query: "rechnung")
        #expect(list.items.isEmpty)

        list.setRecognizedText("Rechnung 42", forImageFile: "b.png")

        #expect(ids(list.items) == [2])
        #expect(list.items[0].recognizedText == "Rechnung 42")
        #expect(list.searchIndex?[2]?.contains("rechnung") == true)
    }
}
