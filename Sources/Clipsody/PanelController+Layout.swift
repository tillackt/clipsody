import AppKit

/// Builds the panel window and its views.
extension PanelController {
    func configurePanel() {
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

    func buildLayout() {
        let background = NSVisualEffectView()
        background.material = .popover
        background.blendingMode = .behindWindow
        background.state = .active
        panel.contentView = background
        background.widthAnchor.constraint(equalToConstant: 820).isActive = true
        background.heightAnchor.constraint(equalToConstant: 460).isActive = true

        configureSearch()
        configureSections()
        let tableScroll = makeTable()
        configurePreview()
        let topSeparator = NSBox()
        topSeparator.boxType = .separator
        let sideSeparator = NSBox()
        sideSeparator.boxType = .separator

        let views: [NSView] = [search, sections, topSeparator, tableScroll, sideSeparator, previewTextScroll, previewImage,
                               infoLabel, hintLabel, emptyLabel]
        for view in views {
            view.translatesAutoresizingMaskIntoConstraints = false
            background.addSubview(view)
        }
        constrain(in: background, topSeparator: topSeparator, tableScroll: tableScroll, sideSeparator: sideSeparator)
    }

    private func configureSearch() {
        search.placeholderString = String(localized: "Search clipboard…")
        search.setAccessibilityLabel(String(localized: "Search clipboard"))
        search.font = .systemFont(ofSize: 22, weight: .light)
        search.isBordered = false
        search.drawsBackground = false
        search.focusRingType = .none
        search.delegate = self
        search.cell?.isScrollable = true
        search.cell?.wraps = false
    }

    private func configureSections() {
        sections.segmentCount = 2
        sections.trackingMode = .selectOne
        sections.segmentStyle = .automatic
        sections.controlSize = .small
        sections.selectedSegment = 0
        // The search field keeps the keyboard focus; the arrows and ⇥ switch from there.
        sections.refusesFirstResponder = true
        sections.target = self
        sections.action = #selector(sectionClicked)
        sections.setAccessibilityLabel(String(localized: "List"))
        sections.toolTip = String(localized: "Switch with → and ← or ⇥")
    }

    /// Tab titles with the number of pinned entries, the hint line, and what an empty list says.
    func updateSectionLabels() {
        let pinnedCount = list.count(in: .pinned)
        sections.setLabel(String(localized: "History"), forSegment: 0)
        sections.setLabel(pinnedCount > 0 ? String(localized: "Pinned · \(pinnedCount)") : String(localized: "Pinned"),
                          forSegment: 1)
        sections.selectedSegment = list.section == .pinned ? 1 : 0
        hintLabel.stringValue = list.section == .pinned
            ? String(localized: "⏎ paste   ⌥⏎ without formatting   ⌘P unpin   ⌘⌫ delete")
            : String(localized: "⏎ paste   ⌥⏎ without formatting   ⌘P pin   ⌘⌫ delete")
        emptyLabel.isHidden = !items.isEmpty
        guard items.isEmpty else { return }
        let elsewhere = query.isEmpty ? 0 : list.matchCount(in: list.section.other)
        switch (list.section, elsewhere > 0) {
        case (.history, true): emptyLabel.stringValue = String(localized: "No matches here – \(elsewhere) in Pinned (→)")
        case (.pinned, true): emptyLabel.stringValue = String(localized: "No matches here – \(elsewhere) in History (←)")
        case (.pinned, false) where query.isEmpty:
            emptyLabel.stringValue = String(localized: "Nothing pinned yet. Pin entries in the history with ⌘P.")
        default: emptyLabel.stringValue = String(localized: "No entries")
        }
    }

    /// The list of entries, inside the scroll view that is returned.
    private func makeTable() -> NSScrollView {
        table.setAccessibilityLabel(String(localized: "Clipboard entries"))
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
        // Secondary rather than tertiary: the text may say where the hits are.
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.alignment = .center
        emptyLabel.maximumNumberOfLines = 3
        emptyLabel.lineBreakMode = .byWordWrapping
        emptyLabel.preferredMaxLayoutWidth = 300
        emptyLabel.isHidden = true
        return tableScroll
    }

    private func configurePreview() {
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
    }

    private func constrain(in background: NSView, topSeparator: NSView, tableScroll: NSView, sideSeparator: NSView) {
        NSLayoutConstraint.activate([
            search.topAnchor.constraint(equalTo: background.topAnchor, constant: 18),
            search.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 20),
            search.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -20),

            sections.topAnchor.constraint(equalTo: search.bottomAnchor, constant: 10),
            sections.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 18),

            topSeparator.topAnchor.constraint(equalTo: sections.bottomAnchor, constant: 8),
            topSeparator.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            topSeparator.trailingAnchor.constraint(equalTo: background.trailingAnchor),

            tableScroll.topAnchor.constraint(equalTo: topSeparator.bottomAnchor, constant: 4),
            tableScroll.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            tableScroll.bottomAnchor.constraint(equalTo: background.bottomAnchor, constant: -4),
            tableScroll.widthAnchor.constraint(equalToConstant: 380),

            emptyLabel.centerXAnchor.constraint(equalTo: tableScroll.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: tableScroll.centerYAnchor),
            emptyLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 300),

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
