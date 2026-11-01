import AppKit
import Carbon
import ClipsodyCore
import ClipsodyServices

/// The history panel. Its list, preview and layout live in extensions in the
/// PanelController+*.swift files.
@MainActor
final class PanelController: NSObject, NSWindowDelegate, NSTextFieldDelegate,
    NSTableViewDataSource, NSTableViewDelegate {
    let store: Store
    let decoder: DecoderClient
    let snippets: SnippetStore
    let fillBar: FillBar
    /// Item, target app, and whether to paste with formatting (default; ⌥⏎ pastes plain text).
    private let onPaste: (ClipItem, NSRunningApplication?, Bool) -> Void
    /// Pastes the text of a snippet into the target app.
    let onPasteText: (String, NSRunningApplication?) -> Void
    /// The app that was frontmost when the panel opened; the paste goes there.
    private(set) var targetApp: NSRunningApplication?

    let panel: KeyPanel
    let search = NSTextField()
    /// Switches between history, pinned entries and snippets (→ / ← at the edge of the search text, or ⇥).
    let sections = NSSegmentedControl()
    let editor = SnippetEditor()
    let table = NSTableView()
    let previewTextScroll = NSTextView.scrollableTextView()
    // scrollableTextView() always creates an NSTextView as its document view.
    // swiftlint:disable:next force_cast
    var previewText: NSTextView { previewTextScroll.documentView as! NSTextView }
    let previewImage = NSImageView()
    let infoLabel = NSTextField(labelWithString: "")
    let hintLabel = NSTextField(labelWithString: "")
    let emptyLabel = NSTextField(labelWithString: String(localized: "No entries"))

    var list = HistoryList()
    var tab = PanelTab.history
    /// The snippets matching the search, shown in the third tab.
    var snippetRows: [Snippet] = []
    /// The snippet a first ⌘⌫ asked about; a second one deletes it.
    var pendingSnippetDeletion: UUID?
    /// Set when a click on "New Snippet" created one; the rest of that double click is ignored.
    var snippetCreatedByClick = false
    /// The history entries of the tab shown; none in the snippets tab.
    var items: [ClipItem] { tab == .snippets ? [] : list.items }
    var query: SearchQuery { list.query }
    let iconCache = NSCache<NSString, NSImage>()
    let previewCache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        // Cost = decoded bytes; a Retina preview is 2–3 MB, so this keeps a handful.
        cache.totalCostLimit = 12_000_000
        return cache
    }()
    var previewTask: Task<Void, Never>?
    /// What the preview currently shows: the item and the search terms it was highlighted for.
    /// Unchanged, it is not rendered (and scrolled) again; a new search must re-highlight it.
    var previewedItem: ClipItem?
    var previewedTerms: [String] = []
    let dateFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = AppLocale.current
        return formatter
    }()

    var isVisible: Bool { panel.isVisible }

    init(store: Store, decoder: DecoderClient, snippets: SnippetStore, fillBar: FillBar,
         onPaste: @escaping (ClipItem, NSRunningApplication?, Bool) -> Void,
         onPasteText: @escaping (String, NSRunningApplication?) -> Void) {
        self.store = store
        self.decoder = decoder
        self.snippets = snippets
        self.fillBar = fillBar
        self.onPaste = onPaste
        self.onPasteText = onPasteText
        panel = KeyPanel(
            contentRect: NSRect(x: 0, y: 0, width: 820, height: 460),
            styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView],
            backing: .buffered,
            defer: true
        )
        super.init()
        configurePanel()
        buildLayout()
        setUpSnippetEditor()
    }

    // MARK: - Show / hide

    func toggle() {
        if isVisible { hide() } else { show() }
    }

    func show() {
        // No target when Clipsody itself is in front (e.g. the settings window): then nothing is pasted.
        let frontmost = NSWorkspace.shared.frontmostApplication
        targetApp = frontmost?.processIdentifier == ProcessInfo.processInfo.processIdentifier ? nil : frontmost
        search.stringValue = ""
        fillBar.close()
        reloadItems()
        showItems()
        positionOnActiveScreen()
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(search)
    }

    func hide() {
        panel.orderOut(nil)
        // Everything is reloaded on the next show; holding texts, index and previews in the
        // background would only cost memory.
        previewTask?.cancel()
        previewedItem = nil
        list = HistoryList()
        tab = .history
        snippetRows = []
        pendingSnippetDeletion = nil
        // Single deletes are wiped from disk in one go when the panel closes.
        store.flushDeletions()
        previewCache.removeAllObjects()
        previewText.string = ""
        previewImage.image = nil
        table.reloadData()
    }

    /// Refreshes the list when the clipboard changes while the panel is open.
    func reloadIfVisible() {
        guard isVisible else { return }
        let selected = selectedItem?.id
        reloadItems()
        // The snippets tab (possibly with a field being edited) does not depend on the history.
        guard tab != .snippets else { return }
        showItems(selecting: selected)
    }

    /// Takes over newly recognised text for one image without reloading the whole list.
    func refreshRecognizedText(_ text: String, forImageFile file: String) {
        guard isVisible else { return }
        let selected = selectedItem?.id
        list.setRecognizedText(text, forImageFile: file)
        guard tab != .snippets else { return }
        showItems(selecting: selected)
    }

    var selectedItem: ClipItem? {
        items.indices.contains(table.selectedRow) ? items[table.selectedRow] : nil
    }

    func windowDidResignKey(_ notification: Notification) {
        hide()
    }

    private func positionOnActiveScreen() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        let size = panel.frame.size
        // Upper third, horizontally centred, like Alfred.
        panel.setFrameOrigin(NSPoint(
            x: visible.midX - size.width / 2,
            y: visible.minY + visible.height * 0.66 - size.height / 2
        ))
    }

    // MARK: - Actions

    func pasteSelected(withFormatting: Bool = true) {
        paste(at: table.selectedRow, withFormatting: withFormatting)
    }

    func paste(at row: Int, withFormatting: Bool = true) {
        if tab == .snippets {
            useSnippet(at: row)
            return
        }
        guard items.indices.contains(row) else {
            NSSound.beep()
            return
        }
        let item = items[row]
        hide()
        onPaste(item, targetApp, withFormatting)
    }

    /// Pins or unpins the selected entry. If it leaves the list shown, the selection moves to its neighbour.
    func togglePinSelected() {
        guard tab != .snippets else {
            NSSound.beep()
            return
        }
        let row = table.selectedRow
        guard items.indices.contains(row) else { return }
        let item = items[row]
        let neighbour = list.neighbour(ofRow: row)
        guard store.setPinned(!item.pinned, for: item) else {
            NSSound.beep()
            return
        }
        reloadItems()
        // Unpinning in the history keeps the entry there; otherwise it moves to the other list.
        showItems(selecting: items.contains { $0.id == item.id } ? item.id : neighbour?.id)
    }

    func show(_ newTab: PanelTab) {
        guard newTab != tab else { return }
        tab = newTab
        if let section = newTab.section { list.show(section) } else { filterSnippets() }
        showItems()
        // The focus stays in the search field, so VoiceOver would not notice the list changing.
        NSAccessibility.post(element: table, notification: .announcementRequested,
                             userInfo: [.announcement: sections.label(forSegment: sections.selectedSegment) ?? ""])
    }

    @objc func sectionClicked() {
        show(PanelTab(rawValue: sections.selectedSegment) ?? .history)
    }

    func deleteSelected() {
        if tab == .snippets {
            requestDeleteSnippet(at: table.selectedRow)
            return
        }
        let row = table.selectedRow
        guard items.indices.contains(row) else { return }
        let item = items[row]
        // Keep the selection on the neighbour that moves into this row.
        let neighbour = list.neighbour(ofRow: row)
        // A pinned entry in the history only leaves the history; deleting it is up to the pinned list.
        if list.section == .history && item.pinned {
            guard store.removeFromHistory(item) else {
                NSSound.beep()
                return
            }
            reloadItems()
            showItems(selecting: neighbour?.id)
            return
        }
        guard store.delete(item) else {
            NSSound.beep()
            return
        }
        list.remove(id: item.id)
        showItems(selecting: neighbour?.id)
    }

    @objc func rowDoubleClicked() {
        // A double click on the empty space below the rows does nothing (and does not beep).
        guard table.clickedRow >= 0 else { return }
        // The first click of a double click on "New Snippet" already created one.
        if tab == .snippets, NSApp.currentEvent?.clickCount ?? 0 > 1, snippetCreatedByClick
            || !snippetRows.indices.contains(table.clickedRow) || snippetRows[table.clickedRow].filledFields.isEmpty { return }
        paste(at: table.clickedRow)
    }

    func move(by delta: Int) {
        guard rowCount > 0 else { return }
        let current = table.selectedRow < 0 ? 0 : table.selectedRow
        select(max(0, min(rowCount - 1, current + delta)))
    }

    func select(_ row: Int) {
        if (0..<rowCount).contains(row) {
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            table.scrollRowToVisible(row)
        }
        // The table posts no selection change when the row number stays the same after a reload,
        // although the item in that row may be a different one.
        updatePreview()
    }

    // MARK: - Filtering

    func showItems(selecting id: Int64? = nil, snippet snippetID: UUID? = nil) {
        table.reloadData()
        updateSectionLabels()
        select(tab == .snippets ? snippetRow(selecting: snippetID) : list.row(selecting: id))
    }

    func controlTextDidChange(_ notification: Notification) {
        list.filter(search.stringValue)
        filterSnippets()
        showItems()
    }

    private func reloadItems() {
        list.load(store.items(), query: search.stringValue)
    }
}
