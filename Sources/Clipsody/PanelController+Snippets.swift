import AppKit
import ClipsodyCore

/// The panel's three lists.
enum PanelTab: Int, CaseIterable {
    case history, pinned, snippets

    var next: PanelTab? { PanelTab(rawValue: rawValue + 1) }
    var previous: PanelTab? { PanelTab(rawValue: rawValue - 1) }

    /// The history list behind the first two tabs.
    var section: HistoryList.Section? {
        switch self {
        case .history: .history
        case .pinned: .pinned
        case .snippets: nil
        }
    }
}

/// The third tab: snippets the user writes, edited on the right, pasted or filled in with ⏎.
extension PanelController {
    /// Rows in the list shown; the snippets tab ends with a "New Snippet" row.
    var rowCount: Int { tab == .snippets ? snippetRows.count + 1 : items.count }

    /// The last row of the snippets tab, which creates a snippet.
    var isNewSnippetRowSelected: Bool { tab == .snippets && table.selectedRow == snippetRows.count }

    func configureNewSnippetRow(_ cell: ClipRowView) {
        cell.setTitle(String(localized: "New Snippet"), highlights: [], accent: true)
        cell.icon.image = NSImage(systemSymbolName: "plus", accessibilityDescription: nil)
        cell.icon.contentTintColor = .controlAccentColor
        cell.pin.isHidden = true
        cell.shortcut.stringValue = "⌘N"
    }

    /// A single click on the "New Snippet" row creates one; on a snippet it only selects it.
    @objc func rowClicked() {
        guard tab == .snippets, table.clickedRow == snippetRows.count, NSApp.currentEvent?.clickCount ?? 1 == 1 else { return }
        newSnippet()
    }

    var selectedSnippet: Snippet? {
        snippetRows.indices.contains(table.selectedRow) ? snippetRows[table.selectedRow] : nil
    }

    /// The snippets matching the search, in the order they were created.
    func filterSnippets() {
        let query = SearchQuery(search.stringValue)
        snippetRows = query.isEmpty ? snippets.snippets
            : snippets.snippets.filter { query.matches(foldedText: SearchQuery.fold($0.searchText)) }
    }

    func snippetRow(selecting id: UUID?) -> Int {
        id.flatMap { id in snippetRows.firstIndex { $0.id == id } } ?? 0
    }

    func configure(_ cell: ClipRowView, for snippet: Snippet, row: Int) {
        let title = snippet.name.isEmpty ? (snippet.fields.first?.text ?? "") : snippet.name
        let shown = title.isEmpty ? String(localized: "Untitled snippet") : title
        let line = shown.split(whereSeparator: \.isNewline).joined(separator: " ⏎ ")
        cell.setTitle(line, highlights: query.ranges(in: line))
        cell.icon.image = NSImage(systemSymbolName: snippet.isSet ? "square.stack" : "text.quote",
                                  accessibilityDescription: nil)
        cell.icon.contentTintColor = .secondaryLabelColor
        cell.pin.isHidden = true
        cell.shortcut.stringValue = row < 9 ? "⌘\(row + 1)" : ""
    }

    /// The editor for the selected snippet replaces the preview.
    func updateSnippetEditor() {
        if pendingSnippetDeletion != selectedSnippet?.id { pendingSnippetDeletion = nil }
        let showsEditor = tab == .snippets
        editor.isHidden = !showsEditor || selectedSnippet == nil
        if showsEditor {
            previewTextScroll.isHidden = true
            previewImage.isHidden = true
            previewedItem = nil
            if pendingSnippetDeletion == nil {
                infoLabel.stringValue = selectedSnippet != nil ? String(localized: "Changes are saved right away.")
                    : String(localized: "Snippets are texts you paste often, or several fields to fill in a form.")
            }
            if let selectedSnippet { editor.show(selectedSnippet) }
        }
    }

    func setUpSnippetEditor() {
        editor.onChange = { [unowned self] snippet in
            snippets.update(snippet)
            updateHint(for: nil)
            if !snippets.canSave || !snippets.lastSaveSucceeded {
                infoLabel.stringValue = String(localized: "Snippets could not be saved; changes may be lost.")
            }
            // Keeps the list in step without rebuilding the editor the user is typing in.
            if let index = snippetRows.firstIndex(where: { $0.id == snippet.id }) {
                snippetRows[index] = snippet
                table.reloadData(forRowIndexes: IndexSet(integer: index), columnIndexes: IndexSet(integer: 0))
            }
        }
        editor.onUse = { [unowned self] in useSnippet(at: table.selectedRow) }
        editor.onDelete = { [unowned self] in
            // The second ⌘⌫ must reach the panel, not the text field that still has the focus.
            panel.makeFirstResponder(search)
            requestDeleteSnippet(at: table.selectedRow)
        }
        editor.onLeave = { [unowned self] in panel.makeFirstResponder(search) }
        editor.onEscape = { [unowned self] in hide() }
    }

    /// ⌘N: a new, empty snippet, ready to be named.
    func newSnippet() {
        if tab != .snippets { show(.snippets) }
        let snippet = snippets.add()
        search.stringValue = ""
        list.filter("")
        filterSnippets()
        showItems(selecting: nil, snippet: snippet.id)
        editor.focusName()
    }

    /// A single text is pasted where the user was; several fields open the fill bar.
    func useSnippet(at row: Int) {
        if row == snippetRows.count {
            newSnippet()
            return
        }
        guard snippetRows.indices.contains(row) else { return }
        let snippet = snippetRows[row]
        let fields = snippet.filledFields
        guard !fields.isEmpty else {
            NSSound.beep()
            return
        }
        let target = targetApp
        hide()
        if fields.count == 1 {
            onPasteText(fields[0].text, target)
        } else {
            fillBar.show(snippet)
        }
    }

    /// Snippets are typed by hand, so deleting one asks first: the first ⌘⌫ (or Delete…) says what
    /// would go, the second one on the same snippet deletes it. A sheet would close the panel.
    func requestDeleteSnippet(at row: Int) {
        guard snippetRows.indices.contains(row) else { return }
        let snippet = snippetRows[row]
        guard pendingSnippetDeletion == snippet.id else {
            pendingSnippetDeletion = snippet.id
            let name = snippet.name.isEmpty ? String(localized: "Untitled snippet") : snippet.name
            infoLabel.stringValue = String(localized: "Press ⌘⌫ again to delete “\(name)”.")
            NSSound.beep()
            return
        }
        pendingSnippetDeletion = nil
        let neighbour = snippetRows.indices.contains(row + 1) ? snippetRows[row + 1].id
            : (row > 0 ? snippetRows[row - 1].id : nil)
        snippets.delete(id: snippet.id)
        filterSnippets()
        showItems(selecting: nil, snippet: neighbour)
    }

    /// True while the user types in the snippet editor; the panel's shortcuts then stay out of the way.
    var isEditingSnippet: Bool {
        guard let responder = panel.firstResponder as? NSView else { return false }
        return responder.isDescendant(of: editor)
    }
}
