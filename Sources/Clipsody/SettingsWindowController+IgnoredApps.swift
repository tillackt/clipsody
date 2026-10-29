import AppKit
import ClipsodyCore

/// The list of ignored apps on the Privacy tab, with its add and remove buttons.
extension SettingsWindowController {
    /// The table with the +/- buttons below it.
    func makeIgnoredAppsList() -> NSView {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("app"))
        column.resizingMask = .autoresizingMask
        ignoredTable.addTableColumn(column)
        ignoredTable.headerView = nil
        ignoredTable.rowHeight = 24
        ignoredTable.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        ignoredTable.dataSource = self
        ignoredTable.delegate = self
        let tableScroll = NSScrollView()
        tableScroll.documentView = ignoredTable
        tableScroll.hasVerticalScroller = true
        tableScroll.borderType = .bezelBorder
        tableScroll.translatesAutoresizingMaskIntoConstraints = false
        tableScroll.widthAnchor.constraint(equalToConstant: 480).isActive = true
        // The tab has room for the whole default list without scrolling.
        tableScroll.heightAnchor.constraint(equalToConstant: 200).isActive = true

        ignoredButtons.segmentStyle = .smallSquare
        ignoredButtons.trackingMode = .momentary
        ignoredButtons.segmentCount = 2
        // Image-only segments: the descriptions are what VoiceOver reads.
        let addImage = NSImage(named: NSImage.addTemplateName)
        addImage?.accessibilityDescription = String(localized: "Add app")
        let removeImage = NSImage(named: NSImage.removeTemplateName)
        removeImage?.accessibilityDescription = String(localized: "Remove selected app")
        ignoredButtons.setImage(addImage, forSegment: 0)
        ignoredButtons.setImage(removeImage, forSegment: 1)
        ignoredButtons.setToolTip(String(localized: "Add app"), forSegment: 0)
        ignoredButtons.setToolTip(String(localized: "Remove selected app"), forSegment: 1)
        ignoredButtons.target = self
        ignoredButtons.action = #selector(ignoredButtonClicked)

        let stack = NSStackView(views: [tableScroll, ignoredButtons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        return stack
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        config.ignoredApps.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let bundleId = config.ignoredApps[row]
        let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId)
        // Names for the default entries, shown when the app is not installed.
        let name = appURL.map { FileManager.default.displayName(atPath: $0.path) }
            ?? Config.defaultIgnoredAppNames[bundleId]
            ?? bundleId

        let id = NSUserInterfaceItemIdentifier("app")
        let cell = tableView.makeView(withIdentifier: id, owner: nil) as? IgnoredAppCell ?? IgnoredAppCell(identifier: id)
        cell.icon.image = appURL.map { NSWorkspace.shared.icon(forFile: $0.path) }
            ?? NSImage(systemSymbolName: "app.dashed", accessibilityDescription: nil)
        cell.title.stringValue = name
        cell.detail.stringValue = appURL == nil ? String(localized: "not installed") : bundleId
        return cell
    }
}

/// Row of the ignored-apps list; reused by the table instead of being rebuilt per call.
private final class IgnoredAppCell: NSTableCellView {
    let icon = NSImageView()
    let title = NSTextField(labelWithString: "")
    let detail = NSTextField(labelWithString: "")

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        imageView = icon
        textField = title
        detail.textColor = .secondaryLabelColor
        detail.font = .systemFont(ofSize: 11)
        detail.lineBreakMode = .byTruncatingTail
        let stack = NSStackView(views: [icon, title, detail])
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 18),
            icon.heightAnchor.constraint(equalToConstant: 18),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -4),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}
