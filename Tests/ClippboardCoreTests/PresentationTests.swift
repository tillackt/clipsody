import Foundation
import Testing
@testable import ClippboardCore

@Suite struct PresentationTests {
    func item(_ kind: ClipItem.Kind = .text, text: String = "", paths: [String] = [], app: String? = nil,
              recognized: String? = nil, width: Int = 0, height: Int = 0, bytes: Int64 = 0) -> ClipItem {
        ClipItem(id: 1, kind: kind, text: text, filePaths: paths, imageFile: nil, imageWidth: width,
                 imageHeight: height, byteSize: bytes, app: app, appPath: nil, date: Date(), pinned: false,
                 recognizedText: recognized, hasRichText: false)
    }

    @Test func searchIsCaseAndDiacriticInsensitiveAndNeedsAllTerms() {
        let entry = item(text: "Größe der Übersicht", app: "Pages")
        #expect(SearchQuery("ubersicht GROSSE").matches(entry)) // case folding maps "ß" to "ss"
        #expect(SearchQuery("übersicht größe").matches(entry))
        #expect(SearchQuery("ubersicht pages").matches(entry))
        #expect(SearchQuery("ubersicht mail").matches(entry) == false)
        #expect(SearchQuery("   ").matches(entry))
    }

    @Test func cachedFoldedTextGivesSameResult() {
        let entry = item(text: "Café Größe", app: "Notes")
        let folded = SearchQuery.fold(ItemPresentation.searchText(for: entry))
        for text in ["cafe", "GRÖSSE", "notes cafe", "tee"] {
            #expect(SearchQuery(text).matches(foldedText: folded) == SearchQuery(text).matches(entry))
        }
    }

    @Test func imagesMatchByRecognizedTextAndShowSnippet() {
        let line = "Protokoll vom Dienstag: Der Server meldet einen Fehler 500 beim Speichern der Datei im Archiv, bitte später erneut versuchen"
        let screenshot = item(.image, recognized: "Menü\n" + line, width: 946, height: 858)
        let query = SearchQuery("fehler")
        #expect(query.matches(screenshot))
        let title = ItemPresentation.title(for: screenshot, query: query)
        // Shortened on both sides around the match
        #expect(title.hasPrefix("Bild 946×858 – „…"))
        #expect(title.hasSuffix("…“"))
        #expect(title.contains("Fehler 500"))
        #expect(ItemPresentation.title(for: screenshot, query: SearchQuery("")) == "Bild 946×858")
    }

    @Test func imageLabelIncludesSize() {
        let label = ItemPresentation.imageLabel(for: item(.image, width: 10, height: 20, bytes: 2_000_000))
        #expect(label.hasPrefix("Bild 10×20 ("))
    }

    @Test func textTitleCollapsesLines() {
        let title = ItemPresentation.title(for: item(text: "  first  \n\n second\n"), query: SearchQuery(""))
        #expect(title == "first ⏎ second")
    }

    @Test func filesTitleListsNames() {
        #expect(ItemPresentation.title(for: item(.files, paths: ["/a/one.pdf"]), query: SearchQuery("")) == "one.pdf")
        #expect(ItemPresentation.title(for: item(.files, paths: ["/a/one.pdf", "/b/two.png"]), query: SearchQuery(""))
            == "2 Dateien: one.pdf, two.png")
    }

    @Test func highlightRangesCoverEveryMatch() {
        let ranges = SearchQuery("ab").ranges(in: "AB xx ab")
        #expect(ranges == [NSRange(location: 0, length: 2), NSRange(location: 6, length: 2)])
    }
}
