import AppKit
import Carbon
import ClippboardCore
import ClippboardServices

@MainActor
final class PanelController: NSObject, NSWindowDelegate, NSTextFieldDelegate, NSTableViewDataSource, NSTableViewDelegate {
    private let store: Store
    private let decoder: DecoderClient
    /// Item, target app, and whether to paste with formatting (default; ⌥⏎ pastes plain text).
    private let onPaste: (ClipItem, NSRunningApplication?, Bool) -> Void
    /// The app that was frontmost when the panel opened; the paste goes there.
    private var targetApp: NSRunningApplication?

    private let panel: KeyPanel
    private let search = NSTextField()
    private let table = NSTableView()
    private let previewTextScroll = NSTextView.scrollableTextView()
    private var previewText: NSTextView { previewTextScroll.documentView as! NSTextView }
    private let previewImage = NSImageView()
    private let infoLabel = NSTextField(labelWithString: "")
    private let hintLabel = NSTextField(labelWithString: "⏎ einfügen   ⌥⏎ ohne Formatierung   ⌘P anpinnen   ⌘⌫ löschen")
    private let emptyLabel = NSTextField(labelWithString: "Keine Einträge")

    private var list = HistoryList()
    private var items: [ClipItem] { list.items }
    private var query: SearchQuery { list.query }
    private let iconCache = NSCache<NSString, NSImage>()
    private let previewCache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        // Cost = decoded bytes; a Retina preview is 2–3 MB, so this keeps a handful.
        cache.totalCostLimit = 12_000_000
        return cache
    }()
    private var previewTask: Task<Void, Never>?
    /// What the preview currently shows: the item and the search terms it was highlighted for.
    /// Unchanged, it is not rendered (and scrolled) again; a new search must re-highlight it.
    private var previewedItem: ClipItem?
    private var previewedTerms: [String] = []
    private let dateFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "de_DE")
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
        isVisible ? hide() : show()
    }

    func show() {
        // No target when Clippboard itself is in front (e.g. the settings window): then nothing is pasted.
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

    private var selectedItem: ClipItem? {
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

    private func paste(at row: Int, withFormatting: Bool = true) {
        guard items.indices.contains(row) else { return }
        let item = items[row]
        hide()
        onPaste(item, targetApp, withFormatting)
    }

    private func togglePinSelected() {
        let row = table.selectedRow
        guard items.indices.contains(row) else { return }
        let item = items[row]
        guard store.setPinned(!item.pinned, for: item) else {
            NSSound.beep()
            return
        }
        reloadItems()
        showItems(selecting: item.id)
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

    @objc private func rowDoubleClicked() {
        paste(at: table.clickedRow)
    }

    private func move(by delta: Int) {
        guard !items.isEmpty else { return }
        let current = table.selectedRow < 0 ? 0 : table.selectedRow
        select(max(0, min(items.count - 1, current + delta)))
    }

    private func select(_ row: Int) {
        if items.indices.contains(row) {
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            table.scrollRowToVisible(row)
        }
        // The table posts no selection change when the row number stays the same after a reload,
        // although the item in that row may be a different one.
        updatePreview()
    }

    private func handleKeyEquivalent(_ event: NSEvent) -> Bool {
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

    private func showItems(selecting id: Int64? = nil) {
        table.reloadData()
        emptyLabel.isHidden = !items.isEmpty
        select(list.row(selecting: id))
    }

    func controlTextDidChange(_ notification: Notification) {
        list.filter(search.stringValue)
        showItems()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
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

    // MARK: - Table

    func numberOfRows(in tableView: NSTableView) -> Int {
        items.count
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let id = NSUserInterfaceItemIdentifier("row")
        if let reused = tableView.makeView(withIdentifier: id, owner: nil) as? EmphasizedRowView { return reused }
        let rowView = EmphasizedRowView()
        rowView.identifier = id
        return rowView
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("clip")
        let cell = tableView.makeView(withIdentifier: id, owner: nil) as? ClipRowView ?? ClipRowView(identifier: id)
        let item = items[row]
        let text = ItemPresentation.title(for: item, query: query)
        cell.setTitle(text, highlights: query.ranges(in: text))
        cell.icon.image = icon(for: item)
        cell.pin.isHidden = !item.pinned
        cell.shortcut.stringValue = row < 9 ? "⌘\(row + 1)" : ""
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        updatePreview()
    }

    /// Icon of the app the entry was copied from; for files the icon of the (first) file.
    private func icon(for item: ClipItem) -> NSImage? {
        if item.kind == .files {
            guard let path = item.filePaths.first else { return nil }
            if let cached = iconCache.object(forKey: path as NSString) { return cached }
            // Checking a file on a disconnected network volume can block for seconds.
            let reachable = !path.hasPrefix("/Volumes/") && FileManager.default.fileExists(atPath: path)
            let icon = reachable ? NSWorkspace.shared.icon(forFile: path)
                                 : NSImage(systemSymbolName: "doc", accessibilityDescription: nil)!
            iconCache.setObject(icon, forKey: path as NSString)
            return icon
        }
        let key = item.appPath ?? ""
        if let cached = iconCache.object(forKey: (key + "#\(item.kind.rawValue)") as NSString) { return cached }

        let image: NSImage
        if let path = item.appPath, FileManager.default.fileExists(atPath: path) {
            image = NSWorkspace.shared.icon(forFile: path)
        } else {
            image = NSImage(systemSymbolName: item.kind == .image ? "photo" : "doc.text", accessibilityDescription: nil)!
        }
        // Cached either way, so a missing app is not looked up again for every row.
        iconCache.setObject(image, forKey: (key + "#\(item.kind.rawValue)") as NSString)
        return image
    }

    private func updatePreview() {
        let row = table.selectedRow
        guard items.indices.contains(row) else {
            previewTextScroll.isHidden = true
            previewImage.isHidden = true
            infoLabel.stringValue = ""
            previewedItem = nil
            return
        }
        let item = items[row]
        guard item != previewedItem || query.terms != previewedTerms else { return }
        previewedItem = item
        previewedTerms = query.terms
        announceForVoiceOver(item)
        var info = [item.app ?? "Unbekannte App", dateFormatter.localizedString(for: item.date, relativeTo: Date())]
        if item.pinned { info.insert("Angepinnt", at: 0) }
        switch item.kind {
        case .text:
            showPreviewText(item.text)
            let bytes = item.textByteCount
            if bytes > ItemPresentation.searchablePrefix {
                // Counting characters and lines of a multi-MB text would stall arrowing through the list.
                info.append(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file))
            } else {
                let lines = item.text.split(whereSeparator: \.isNewline).count
                info.append("\(item.text.count) Zeichen" + (lines > 1 ? ", \(lines) Zeilen" : ""))
            }
            if item.hasRichText { info.append("mit Formatierung") }
        case .files:
            let paths = item.filePaths
            showPreviewText(paths.joined(separator: "\n"))
            // Paths on network volumes are not checked: a disconnected server blocks for seconds.
            let missing = paths.filter { !$0.hasPrefix("/Volumes/") && !FileManager.default.fileExists(atPath: $0) }.count
            info.append(paths.count == 1 ? "1 Datei" : "\(paths.count) Dateien")
            if missing > 0 { info.append("\(missing) nicht mehr vorhanden") }
        case .image:
            previewTextScroll.isHidden = true
            previewImage.isHidden = false
            showPreviewImage(for: item)
            info.append(ItemPresentation.imageLabel(for: item))
            if let text = item.recognizedText, !text.isEmpty { info.append("Text erkannt") }
        }
        infoLabel.stringValue = info.joined(separator: " · ")
    }

    private func reloadItems() {
        list.load(store.items(), query: search.stringValue)
    }

    /// Shows a downscaled image, made by the decoder service as raw pixels (the app never decodes
    /// image formats) and cached, so holding ↓ over screenshots does not decode full-size images.
    private func showPreviewImage(for item: ClipItem) {
        previewTask?.cancel()
        // The small preview stored with large images; older entries fall back to the full image.
        guard let url = store.previewURL(for: item) ?? store.imageURL(for: item) else {
            previewImage.image = nil
            return
        }
        let key = url.lastPathComponent as NSString
        if let cached = previewCache.object(forKey: key) {
            previewImage.image = cached
            return
        }
        previewImage.image = nil
        let scale = panel.backingScaleFactor
        let maxPixelSize = Int(max(previewImage.bounds.width, previewImage.bounds.height, 400) * scale)
        previewTask = Task { [weak self, decoder] in
            // Holding ↓ over screenshots: only the image the selection rests on is decoded.
            try? await Task.sleep(for: .milliseconds(100))
            guard !Task.isCancelled else { return }
            // Reading a multi-MB file must not block the main thread.
            let png = await Task.detached(priority: .userInitiated) { try? Data(contentsOf: url) }.value
            guard let png, !Task.isCancelled,
                  let result = await decoder.thumbnail(ofPNG: png, maxPixelSize: maxPixelSize),
                  let self, !Task.isCancelled else { return }
            let thumbnail = NSImage(cgImage: result.image, size: result.pointSize)
            previewCache.setObject(thumbnail, forKey: key, cost: result.image.bytesPerRow * result.image.height)
            previewImage.image = thumbnail
        }
    }

    /// Focus stays in the search field, so VoiceOver would not notice the selection moving.
    private func announceForVoiceOver(_ item: ClipItem) {
        guard NSWorkspace.shared.isVoiceOverEnabled else { return }
        var parts = [ItemPresentation.title(for: item, query: query)]
        if item.pinned { parts.append("angepinnt") }
        NSAccessibility.post(element: panel, notification: .announcementRequested, userInfo: [
            .announcement: parts.joined(separator: ", "),
            .priority: NSAccessibilityPriorityLevel.high.rawValue,
        ])
    }

    private func showPreviewText(_ text: String) {
        previewTextScroll.isHidden = false
        previewImage.isHidden = true
        let shown = String(text.prefix(ItemPresentation.searchablePrefix))
        let string = NSMutableAttributedString(string: shown, attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular), .foregroundColor: NSColor.labelColor,
        ])
        for range in query.ranges(in: shown) {
            string.addAttributes([.backgroundColor: NSColor.findHighlightColor, .foregroundColor: NSColor.black], range: range)
        }
        previewText.textStorage?.setAttributedString(string)
        if let first = query.ranges(in: shown).first {
            previewText.scrollRangeToVisible(first)
        } else {
            previewText.scrollToBeginningOfDocument(nil)
        }
    }

    // MARK: - Layout

    private func configurePanel() {
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            panel.standardWindowButton(button)?.isHidden = true
        }
        panel.level = .floating
        // Keeps clipboard contents out of classic screenshots and screen sharing. Since macOS 15,
        // ScreenCaptureKit-based recorders can still capture the window.
        panel.sharingType = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        panel.onKeyEquivalent = { [weak self] event in self?.handleKeyEquivalent(event) ?? false }
    }

    private func buildLayout() {
        let background = NSVisualEffectView()
        background.material = .popover
        background.blendingMode = .behindWindow
        background.state = .active
        panel.contentView = background
        background.widthAnchor.constraint(equalToConstant: 820).isActive = true
        background.heightAnchor.constraint(equalToConstant: 460).isActive = true

        search.placeholderString = "Zwischenablage durchsuchen …"
        search.setAccessibilityLabel("Zwischenablage durchsuchen")
        table.setAccessibilityLabel("Einträge der Zwischenablage")
        search.font = .systemFont(ofSize: 22, weight: .light)
        search.isBordered = false
        search.drawsBackground = false
        search.focusRingType = .none
        search.delegate = self
        search.cell?.isScrollable = true
        search.cell?.wraps = false

        let topSeparator = NSBox()
        topSeparator.boxType = .separator
        let sideSeparator = NSBox()
        sideSeparator.boxType = .separator

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("clip"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 32
        table.style = .inset
        table.backgroundColor = .clear
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.refusesFirstResponder = true
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(rowDoubleClicked)

        let tableScroll = NSScrollView()
        tableScroll.documentView = table
        tableScroll.hasVerticalScroller = true
        tableScroll.drawsBackground = false

        previewText.isEditable = false
        previewText.isSelectable = true
        previewText.drawsBackground = false
        previewText.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        previewText.textContainerInset = NSSize(width: 4, height: 6)
        previewTextScroll.drawsBackground = false
        previewTextScroll.hasVerticalScroller = true

        previewImage.imageScaling = .scaleProportionallyDown
        previewImage.imageAlignment = .alignCenter
        // An image view asks for its image's pixel size; without this, large images grow the whole panel.
        for orientation in [NSLayoutConstraint.Orientation.horizontal, .vertical] {
            previewImage.setContentCompressionResistancePriority(.defaultLow, for: orientation)
            previewImage.setContentHuggingPriority(.defaultLow, for: orientation)
        }

        infoLabel.font = .systemFont(ofSize: 11)
        infoLabel.textColor = .secondaryLabelColor
        infoLabel.lineBreakMode = .byTruncatingTail

        hintLabel.font = .systemFont(ofSize: 10)
        hintLabel.textColor = .secondaryLabelColor
        hintLabel.lineBreakMode = .byTruncatingTail

        emptyLabel.textColor = .tertiaryLabelColor
        emptyLabel.isHidden = true

        let views: [NSView] = [search, topSeparator, tableScroll, sideSeparator, previewTextScroll, previewImage, infoLabel, hintLabel, emptyLabel]
        for view in views {
            view.translatesAutoresizingMaskIntoConstraints = false
            background.addSubview(view)
        }

        NSLayoutConstraint.activate([
            search.topAnchor.constraint(equalTo: background.topAnchor, constant: 18),
            search.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 20),
            search.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -20),

            topSeparator.topAnchor.constraint(equalTo: search.bottomAnchor, constant: 12),
            topSeparator.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            topSeparator.trailingAnchor.constraint(equalTo: background.trailingAnchor),

            tableScroll.topAnchor.constraint(equalTo: topSeparator.bottomAnchor, constant: 4),
            tableScroll.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            tableScroll.bottomAnchor.constraint(equalTo: background.bottomAnchor, constant: -4),
            tableScroll.widthAnchor.constraint(equalToConstant: 380),

            emptyLabel.centerXAnchor.constraint(equalTo: tableScroll.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: tableScroll.centerYAnchor),

            sideSeparator.topAnchor.constraint(equalTo: topSeparator.bottomAnchor),
            sideSeparator.bottomAnchor.constraint(equalTo: background.bottomAnchor),
            sideSeparator.leadingAnchor.constraint(equalTo: tableScroll.trailingAnchor),

            previewTextScroll.topAnchor.constraint(equalTo: topSeparator.bottomAnchor, constant: 8),
            previewTextScroll.leadingAnchor.constraint(equalTo: sideSeparator.trailingAnchor, constant: 10),
            previewTextScroll.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -12),
            previewTextScroll.bottomAnchor.constraint(equalTo: infoLabel.topAnchor, constant: -8),

            previewImage.topAnchor.constraint(equalTo: previewTextScroll.topAnchor),
            previewImage.leadingAnchor.constraint(equalTo: previewTextScroll.leadingAnchor),
            previewImage.trailingAnchor.constraint(equalTo: previewTextScroll.trailingAnchor),
            previewImage.bottomAnchor.constraint(equalTo: previewTextScroll.bottomAnchor),

            infoLabel.leadingAnchor.constraint(equalTo: previewTextScroll.leadingAnchor, constant: 4),
            infoLabel.trailingAnchor.constraint(equalTo: previewTextScroll.trailingAnchor),
            infoLabel.bottomAnchor.constraint(equalTo: hintLabel.topAnchor, constant: -4),

            hintLabel.leadingAnchor.constraint(equalTo: infoLabel.leadingAnchor),
            hintLabel.trailingAnchor.constraint(equalTo: infoLabel.trailingAnchor),
            hintLabel.bottomAnchor.constraint(equalTo: background.bottomAnchor, constant: -10),
        ])
    }
}
