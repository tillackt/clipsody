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
    /// Item, target app, and whether to paste with formatting (default; ⌥⏎ pastes plain text).
    private let onPaste: (ClipItem, NSRunningApplication?, Bool) -> Void
    /// The app that was frontmost when the panel opened; the paste goes there.
    private var targetApp: NSRunningApplication?

    let panel: KeyPanel
    let search = NSTextField()
    /// Switches between the history and the pinned entries (→ / ← at the edge of the search text, or ⇥).
    let sections = NSSegmentedControl()
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
    var items: [ClipItem] { list.items }
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

    init(store: Store, decoder: DecoderClient, onPaste: @escaping (ClipItem, NSRunningApplication?, Bool) -> Void) {
        self.store = store
        self.decoder = decoder
        self.onPaste = onPaste
        panel = KeyPanel(
            contentRect: NSRect(x: 0, y: 0, width: 820, height: 460),
            styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView],
            backing: .buffered,
            defer: true
        )
        super.init()
        configurePanel()
        buildLayout()
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
        showItems(selecting: selected)
    }

    /// Takes over newly recognised text for one image without reloading the whole list.
    func refreshRecognizedText(_ text: String, forImageFile file: String) {
        guard isVisible else { return }
        let selected = selectedItem?.id
        list.setRecognizedText(text, forImageFile: file)
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

    private func pasteSelected(withFormatting: Bool = true) {
        paste(at: table.selectedRow, withFormatting: withFormatting)
    }

    func paste(at row: Int, withFormatting: Bool = true) {
        guard items.indices.contains(row) else { return }
        let item = items[row]
        hide()
        onPaste(item, targetApp, withFormatting)
    }

    /// Moves the selected entry to the other list; the selection stays in this one, on its neighbour.
    private func togglePinSelected() {
        let row = table.selectedRow
        guard items.indices.contains(row) else { return }
        let item = items[row]
        let neighbour = list.neighbour(ofRow: row)
        guard store.setPinned(!item.pinned, for: item) else {
            NSSound.beep()
            return
        }
        reloadItems()
        showItems(selecting: neighbour?.id)
    }

    func show(_ section: HistoryList.Section) {
        guard section != list.section else { return }
        list.show(section)
        showItems()
    }

    @objc func sectionClicked() {
        show(sections.selectedSegment == 1 ? .pinned : .history)
    }

    /// → at the end of the search text opens the pinned entries, ← at its start the history;
    /// anywhere else the arrows move the cursor as usual.
    private func switchSection(by key: Selector, in textView: NSTextView) -> Bool {
        let cursor = textView.selectedRange()
        guard cursor.length == 0 else { return false }
        if key == #selector(NSResponder.moveRight(_:)), cursor.location == textView.string.utf16.count,
           list.section == .history {
            show(.pinned)
            return true
        }
        if key == #selector(NSResponder.moveLeft(_:)), cursor.location == 0, list.section == .pinned {
            show(.history)
            return true
        }
        return false
    }

    private func deleteSelected() {
        let row = table.selectedRow
        guard items.indices.contains(row) else { return }
        let item = items[row]
        // Keep the selection on the neighbour that moves into this row.
        let neighbour = list.neighbour(ofRow: row)
        guard store.delete(item) else {
            NSSound.beep()
            return
        }
        list.remove(id: item.id)
        showItems(selecting: neighbour?.id)
    }

    @objc func rowDoubleClicked() {
        paste(at: table.clickedRow)
    }

    func move(by delta: Int) {
        guard !items.isEmpty else { return }
        let current = table.selectedRow < 0 ? 0 : table.selectedRow
        select(max(0, min(items.count - 1, current + delta)))
    }

    func select(_ row: Int) {
        if items.indices.contains(row) {
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            table.scrollRowToVisible(row)
        }
        // The table posts no selection change when the row number stays the same after a reload,
        // although the item in that row may be a different one.
        updatePreview()
    }

    func handleKeyEquivalent(_ event: NSEvent) -> Bool {
        // Only the four modifier keys count, so Caps Lock does not break the shortcuts.
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        guard flags == .command else { return false }
        // ⌘⌫ deletes the selected entry
        if event.keyCode == UInt16(kVK_Delete) {
            deleteSelected()
            return true
        }
        // ⌘P pins or unpins the selected entry
        if event.keyCode == UInt16(kVK_ANSI_P) {
            togglePinSelected()
            return true
        }
        // ⌘1 … ⌘9 paste the n-th visible entry
        if let chars = event.charactersIgnoringModifiers, let digit = Int(chars), (1...9).contains(digit) {
            paste(at: digit - 1)
            return true
        }
        return false
    }

    // MARK: - Filtering

    func showItems(selecting id: Int64? = nil) {
        table.reloadData()
        updateSectionLabels()
        select(list.row(selecting: id))
    }

    func controlTextDidChange(_ notification: Notification) {
        list.filter(search.stringValue)
        showItems()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveLeft(_:)), #selector(NSResponder.moveRight(_:)):
            return switchSection(by: selector, in: textView)
        case #selector(NSResponder.insertTab(_:)), #selector(NSResponder.insertBacktab(_:)): show(list.section.other)
        case #selector(NSResponder.moveUp(_:)): move(by: -1)
        case #selector(NSResponder.moveDown(_:)): move(by: 1)
        case #selector(NSResponder.scrollPageUp(_:)), #selector(NSResponder.pageUp(_:)): move(by: -10)
        case #selector(NSResponder.scrollPageDown(_:)), #selector(NSResponder.pageDown(_:)): move(by: 10)
        case #selector(NSResponder.insertNewline(_:)): pasteSelected()
        // ⌥⏎ arrives as "insert newline ignoring field editor" and pastes plain text
        case #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)): pasteSelected(withFormatting: false)
        case #selector(NSResponder.cancelOperation(_:)): hide()
        default: return false
        }
        return true
    }

    private func reloadItems() {
        list.load(store.items(), query: search.stringValue)
    }
}
