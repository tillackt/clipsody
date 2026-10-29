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
    let shortcut = NSTextField(labelWithString: "")

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

        for view in [icon, title, shortcut] {
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
            shortcut.leadingAnchor.constraint(greaterThanOrEqualTo: title.trailingAnchor, constant: 8),
            shortcut.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            shortcut.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet {
            shortcut.textColor = backgroundStyle == .emphasized ? .alternateSelectedControlTextColor : .secondaryLabelColor
        }
    }
}

final class PanelController: NSObject, NSWindowDelegate, NSTextFieldDelegate, NSTableViewDataSource, NSTableViewDelegate {
    private let store: Store
    private let maxItems: () -> Int
    private let onPaste: (ClipItem, NSRunningApplication?) -> Void
    /// The app that was frontmost when the panel opened; the paste goes there.
    private var targetApp: NSRunningApplication?

    private let panel: KeyPanel
    private let search = NSTextField()
    private let table = NSTableView()
    private let previewTextScroll = NSTextView.scrollableTextView()
    private var previewText: NSTextView { previewTextScroll.documentView as! NSTextView }
    private let previewImage = NSImageView()
    private let infoLabel = NSTextField(labelWithString: "")
    private let emptyLabel = NSTextField(labelWithString: "Keine Einträge")

    private var allItems: [ClipItem] = []
    private var items: [ClipItem] = []
    private let iconCache = NSCache<NSString, NSImage>()
    private let dateFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "de_DE")
        return formatter
    }()

    var isVisible: Bool { panel.isVisible }

    init(store: Store, maxItems: @escaping () -> Int, onPaste: @escaping (ClipItem, NSRunningApplication?) -> Void) {
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

    private func pasteSelected() {
        paste(at: table.selectedRow)
    }

    private func paste(at row: Int) {
        guard items.indices.contains(row) else { return }
        let item = items[row]
        hide()
        onPaste(item, targetApp)
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
        // ⌘1 … ⌘9 paste the n-th visible entry
        if let chars = event.charactersIgnoringModifiers, let digit = Int(chars), (1...9).contains(digit) {
            paste(at: digit - 1)
            return true
        }
        return false
    }

    // MARK: - Filtering

    private func applyFilter() {
        let terms = search.stringValue.split(whereSeparator: \.isWhitespace).map(String.init)
        if terms.isEmpty {
            items = allItems
        } else {
            items = allItems.filter { item in
                let haystack = item.text + " " + (item.app ?? "")
                return terms.allSatisfy { haystack.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
            }
        }
        table.reloadData()
        emptyLabel.isHidden = !items.isEmpty
        select(0)
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
        cell.title.stringValue = title(for: item)
        cell.icon.image = icon(for: item)
        cell.shortcut.stringValue = row < 9 ? "⌘\(row + 1)" : ""
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        updatePreview()
    }

    private func title(for item: ClipItem) -> String {
        let collapsed = item.text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ⏎ ")
        return String(collapsed.prefix(300))
    }

    private func icon(for item: ClipItem) -> NSImage? {
        let key: String
        switch item.kind {
        case .image: key = item.imageFile ?? ""
        case .text: key = item.appPath ?? ""
        }
        if let cached = iconCache.object(forKey: key as NSString) { return cached }

        var image: NSImage?
        if item.kind == .image, let url = store.imageURL(for: item) {
            image = NSImage(contentsOf: url)
        } else if let path = item.appPath, FileManager.default.fileExists(atPath: path) {
            image = NSWorkspace.shared.icon(forFile: path)
        }
        image = image ?? NSImage(systemSymbolName: "doc.text", accessibilityDescription: nil)
        if let image, !key.isEmpty { iconCache.setObject(image, forKey: key as NSString) }
        return image
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
        switch item.kind {
        case .text:
            previewTextScroll.isHidden = false
            previewImage.isHidden = true
            previewText.string = String(item.text.prefix(100_000))
            previewText.scrollToBeginningOfDocument(nil)
            let lines = item.text.split(whereSeparator: \.isNewline).count
            info.append("\(item.text.count) Zeichen" + (lines > 1 ? ", \(lines) Zeilen" : ""))
        case .image:
            previewTextScroll.isHidden = true
            previewImage.isHidden = false
            previewImage.image = store.imageURL(for: item).flatMap(NSImage.init(contentsOf:))
            info.append(item.text)
        }
        infoLabel.stringValue = info.joined(separator: " · ")
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

        emptyLabel.textColor = .tertiaryLabelColor
        emptyLabel.isHidden = true

        let views: [NSView] = [search, topSeparator, tableScroll, sideSeparator, previewTextScroll, previewImage, infoLabel, emptyLabel]
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
            infoLabel.bottomAnchor.constraint(equalTo: background.bottomAnchor, constant: -12),
        ])
    }
}
