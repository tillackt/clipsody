import AppKit

/// Borderless panel that can take keyboard focus without activating the app,
/// so the app the user is working in stays frontmost (like Spotlight/Alfred).
final class KeyPanel: NSPanel {
    var onKeyEquivalent: ((NSEvent) -> Bool)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if onKeyEquivalent?(event) == true { return true }
        return super.performKeyEquivalent(with: event)
    }
}

/// Keeps rows in the accent colour although the table never becomes first responder.
private final class EmphasizedRowView: NSTableRowView {
    override var isEmphasized: Bool {
        get { true }
        set {}
    }
}

private final class ClipRowView: NSTableCellView {
    let icon = NSImageView()
    let title = NSTextField(labelWithString: "")
    let pin = NSImageView(image: NSImage(systemSymbolName: "pin.fill", accessibilityDescription: "Angepinnt")!)
    let shortcut = NSTextField(labelWithString: "")
    private var plainTitle = ""
    private var highlights: [NSRange] = []

    /// Title with search matches marked; colours follow the row's selection state.
    func setTitle(_ text: String, highlights: [NSRange]) {
        plainTitle = text
        self.highlights = highlights
        renderTitle()
    }

    private func renderTitle() {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        let base: NSColor = backgroundStyle == .emphasized ? .alternateSelectedControlTextColor : .labelColor
        let string = NSMutableAttributedString(string: plainTitle, attributes: [
            .font: NSFont.systemFont(ofSize: 14), .foregroundColor: base, .paragraphStyle: paragraph,
        ])
        for range in highlights {
            string.addAttributes([.backgroundColor: NSColor.findHighlightColor, .foregroundColor: NSColor.black], range: range)
        }
        title.attributedStringValue = string
    }

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        imageView = icon
        textField = title

        icon.imageScaling = .scaleProportionallyUpOrDown
        title.lineBreakMode = .byTruncatingTail
        title.font = .systemFont(ofSize: 14)
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        shortcut.font = .systemFont(ofSize: 12)
        shortcut.textColor = .secondaryLabelColor
        shortcut.setContentHuggingPriority(.required, for: .horizontal)
        pin.contentTintColor = .secondaryLabelColor
        pin.symbolConfiguration = .init(pointSize: 11, weight: .regular)
        pin.setContentHuggingPriority(.required, for: .horizontal)

        for view in [icon, title, pin, shortcut] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 22),
            icon.heightAnchor.constraint(equalToConstant: 22),
            title.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
            title.centerYAnchor.constraint(equalTo: centerYAnchor),
            pin.leadingAnchor.constraint(greaterThanOrEqualTo: title.trailingAnchor, constant: 6),
            pin.centerYAnchor.constraint(equalTo: centerYAnchor),
            shortcut.leadingAnchor.constraint(equalTo: pin.trailingAnchor, constant: 6),
            shortcut.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            shortcut.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet {
            let emphasized = backgroundStyle == .emphasized
            shortcut.textColor = emphasized ? .alternateSelectedControlTextColor : .secondaryLabelColor
            pin.contentTintColor = emphasized ? .alternateSelectedControlTextColor : .secondaryLabelColor
            renderTitle()
        }
    }
}

final class PanelController: NSObject, NSWindowDelegate, NSTextFieldDelegate, NSTableViewDataSource, NSTableViewDelegate {
    private let store: Store
    private let maxItems: () -> Int
    /// Item, target app, and whether to paste with formatting (⌥⏎).
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
    private let hintLabel = NSTextField(labelWithString: "⏎ einfügen   ⌥⏎ mit Formatierung   ⌘P anpinnen   ⌘⌫ löschen")
    private let emptyLabel = NSTextField(labelWithString: "Keine Einträge")

    private var allItems: [ClipItem] = []
    private var items: [ClipItem] = []
    private var searchTerms: [String] = []
    private let iconCache = NSCache<NSString, NSImage>()
    private var fileSizes: [String: String] = [:]
    private let dateFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "de_DE")
        return formatter
    }()

    var isVisible: Bool { panel.isVisible }

    init(store: Store, maxItems: @escaping () -> Int, onPaste: @escaping (ClipItem, NSRunningApplication?, Bool) -> Void) {
        self.store = store
        self.maxItems = maxItems
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
        let frontmost = NSWorkspace.shared.frontmostApplication
        if frontmost?.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            targetApp = frontmost
        }
        allItems = store.items(limit: maxItems())
        search.stringValue = ""
        applyFilter()
        positionOnActiveScreen()
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(search)
    }

    func hide() {
        panel.orderOut(nil)
    }

    /// Refreshes the list when the clipboard changes while the panel is open.
    func reloadIfVisible() {
        guard isVisible else { return }
        allItems = store.items(limit: maxItems())
        applyFilter()
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

    private func pasteSelected(withFormatting: Bool = false) {
        paste(at: table.selectedRow, withFormatting: withFormatting)
    }

    private func paste(at row: Int, withFormatting: Bool = false) {
        guard items.indices.contains(row) else { return }
        let item = items[row]
        hide()
        onPaste(item, targetApp, withFormatting)
    }

    private func togglePinSelected() {
        let row = table.selectedRow
        guard items.indices.contains(row) else { return }
        let item = items[row]
        store.setPinned(!item.pinned, for: item)
        allItems = store.items(limit: maxItems())
        applyFilter(selecting: item.id)
    }

    private func deleteSelected() {
        let row = table.selectedRow
        guard items.indices.contains(row) else { return }
        let item = items[row]
        store.delete(item)
        allItems.removeAll { $0.id == item.id }
        items.remove(at: row)
        table.reloadData()
        select(min(row, items.count - 1))
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
        guard items.indices.contains(row) else {
            updatePreview()
            return
        }
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        table.scrollRowToVisible(row)
    }

    private func handleKeyEquivalent(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags == .command else { return false }
        // ⌘⌫ deletes the selected entry
        if event.keyCode == 51 {
            deleteSelected()
            return true
        }
        // ⌘P pins or unpins the selected entry
        if event.keyCode == 35 {
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

    private static let matchOptions: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]

    private func applyFilter(selecting id: Int64? = nil) {
        searchTerms = search.stringValue.split(whereSeparator: \.isWhitespace).map(String.init)
        if searchTerms.isEmpty {
            items = allItems
        } else {
            items = allItems.filter { item in
                let haystack = [item.text, item.app ?? "", item.recognizedText ?? ""].joined(separator: " ")
                return searchTerms.allSatisfy { haystack.range(of: $0, options: Self.matchOptions) != nil }
            }
        }
        table.reloadData()
        emptyLabel.isHidden = !items.isEmpty
        select(id.flatMap { id in items.firstIndex { $0.id == id } } ?? 0)
    }

    /// Ranges of all search terms in `string`, for highlighting.
    private func matchRanges(in string: String) -> [NSRange] {
        var ranges: [NSRange] = []
        for term in searchTerms {
            var remaining = string.startIndex..<string.endIndex
            while let found = string.range(of: term, options: Self.matchOptions, range: remaining) {
                ranges.append(NSRange(found, in: string))
                remaining = found.upperBound..<string.endIndex
            }
        }
        return ranges
    }

    func controlTextDidChange(_ notification: Notification) {
        applyFilter()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveUp(_:)): move(by: -1)
        case #selector(NSResponder.moveDown(_:)): move(by: 1)
        case #selector(NSResponder.scrollPageUp(_:)), #selector(NSResponder.pageUp(_:)): move(by: -10)
        case #selector(NSResponder.scrollPageDown(_:)), #selector(NSResponder.pageDown(_:)): move(by: 10)
        case #selector(NSResponder.insertNewline(_:)): pasteSelected()
        // ⌥⏎ arrives as "insert newline ignoring field editor"
        case #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)): pasteSelected(withFormatting: true)
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
        EmphasizedRowView()
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("clip")
        let cell = tableView.makeView(withIdentifier: id, owner: nil) as? ClipRowView ?? ClipRowView(identifier: id)
        let item = items[row]
        let text = title(for: item)
        cell.setTitle(text, highlights: matchRanges(in: text))
        cell.icon.image = icon(for: item)
        cell.pin.isHidden = !item.pinned
        cell.shortcut.stringValue = row < 9 ? "⌘\(row + 1)" : ""
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        updatePreview()
    }

    private func title(for item: ClipItem) -> String {
        switch item.kind {
        case .image:
            // Like Alfred: "Bild 478×406 (762 KB)", plus the matching line when found via recognised text
            let base = fileSize(of: item).map { "\(item.text) (\($0))" } ?? item.text
            return recognizedSnippet(for: item).map { "\(base) – „\($0)“" } ?? base
        case .files:
            let names = item.filePaths.map { ($0 as NSString).lastPathComponent }
            return names.count == 1 ? names[0] : "\(names.count) Dateien: " + names.joined(separator: ", ")
        case .text:
            break
        }
        let collapsed = item.text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ⏎ ")
        return String(collapsed.prefix(300))
    }

    /// First recognised line containing a search term, shortened around the match.
    private func recognizedSnippet(for item: ClipItem) -> String? {
        guard let text = item.recognizedText, !searchTerms.isEmpty else { return nil }
        for line in text.split(whereSeparator: \.isNewline) {
            let line = String(line)
            guard let match = searchTerms.lazy.compactMap({ line.range(of: $0, options: Self.matchOptions) }).first else { continue }
            let start = line.index(match.lowerBound, offsetBy: -25, limitedBy: line.startIndex) ?? line.startIndex
            let end = line.index(match.upperBound, offsetBy: 40, limitedBy: line.endIndex) ?? line.endIndex
            return (start > line.startIndex ? "…" : "") + line[start..<end] + (end < line.endIndex ? "…" : "")
        }
        return nil
    }

    private func fileSize(of item: ClipItem) -> String? {
        guard let file = item.imageFile else { return nil }
        if let cached = fileSizes[file] { return cached }
        guard let url = store.imageURL(for: item),
              let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int64 else { return nil }
        let formatted = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
        fileSizes[file] = formatted
        return formatted
    }

    /// Icon of the app the entry was copied from; for files the icon of the (first) file.
    private func icon(for item: ClipItem) -> NSImage? {
        if item.kind == .files {
            guard let path = item.filePaths.first, FileManager.default.fileExists(atPath: path) else {
                return NSImage(systemSymbolName: "doc", accessibilityDescription: nil)
            }
            return NSWorkspace.shared.icon(forFile: path)
        }
        let key = item.appPath ?? ""
        if let cached = iconCache.object(forKey: key as NSString) { return cached }

        var image: NSImage?
        if let path = item.appPath, FileManager.default.fileExists(atPath: path) {
            image = NSWorkspace.shared.icon(forFile: path)
            iconCache.setObject(image!, forKey: key as NSString)
        }
        return image ?? NSImage(systemSymbolName: item.kind == .image ? "photo" : "doc.text", accessibilityDescription: nil)
    }

    private func updatePreview() {
        let row = table.selectedRow
        guard items.indices.contains(row) else {
            previewTextScroll.isHidden = true
            previewImage.isHidden = true
            infoLabel.stringValue = ""
            return
        }
        let item = items[row]
        var info = [item.app ?? "Unbekannte App", dateFormatter.localizedString(for: item.date, relativeTo: Date())]
        if item.pinned { info.insert("Angepinnt", at: 0) }
        switch item.kind {
        case .text:
            showPreviewText(item.text)
            let lines = item.text.split(whereSeparator: \.isNewline).count
            info.append("\(item.text.count) Zeichen" + (lines > 1 ? ", \(lines) Zeilen" : ""))
            if item.hasRichText { info.append("mit Formatierung") }
        case .files:
            let paths = item.filePaths
            showPreviewText(paths.joined(separator: "\n"))
            let missing = paths.filter { !FileManager.default.fileExists(atPath: $0) }.count
            info.append(paths.count == 1 ? "1 Datei" : "\(paths.count) Dateien")
            if missing > 0 { info.append("\(missing) nicht mehr vorhanden") }
        case .image:
            previewTextScroll.isHidden = true
            previewImage.isHidden = false
            previewImage.image = store.imageURL(for: item).flatMap(NSImage.init(contentsOf:))
            info.append(item.text)
            if let text = item.recognizedText, !text.isEmpty { info.append("Text erkannt") }
        }
        infoLabel.stringValue = info.joined(separator: " · ")
    }

    private func showPreviewText(_ text: String) {
        previewTextScroll.isHidden = false
        previewImage.isHidden = true
        let shown = String(text.prefix(100_000))
        let string = NSMutableAttributedString(string: shown, attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular), .foregroundColor: NSColor.labelColor,
        ])
        for range in matchRanges(in: shown) {
            string.addAttributes([.backgroundColor: NSColor.findHighlightColor, .foregroundColor: NSColor.black], range: range)
        }
        previewText.textStorage?.setAttributedString(string)
        if let first = matchRanges(in: shown).first {
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
        hintLabel.textColor = .tertiaryLabelColor
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
