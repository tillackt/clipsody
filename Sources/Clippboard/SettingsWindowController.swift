import AppKit
import Carbon
import ClippboardCore
import ServiceManagement
import UniformTypeIdentifiers

final class SettingsWindowController: NSWindowController, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate {
    private var config: Config
    private let dataDirectory: URL
    private let onChange: (Config) -> Void

    private let hotKeyRecorder: HotKeyRecorder
    private let launchAtLogin = NSButton(checkboxWithTitle: "Beim Anmelden automatisch starten", target: nil, action: nil)
    private let accessibilityStatus = NSTextField(labelWithString: "")
    private let retentionField = NSTextField()
    private let retentionStepper = NSStepper()
    private let maxItemsField = NSTextField()
    private let maxItemsStepper = NSStepper()
    private let keepImages = NSButton(checkboxWithTitle: "Bilder speichern", target: nil, action: nil)
    private let ignoredTable = NSTableView()
    private let ignoredButtons = NSSegmentedControl()

    init(config: Config, dataDirectory: URL, onRecordingHotKey: @escaping (Bool) -> Void, onChange: @escaping (Config) -> Void) {
        self.config = config
        self.dataDirectory = dataDirectory
        self.onChange = onChange
        hotKeyRecorder = HotKeyRecorder(hotkey: config.hotkey)
        hotKeyRecorder.onRecordingChange = onRecordingHotKey

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 600),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Clippboard – Einstellungen"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        buildLayout()
        window.center()
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(with config: Config) {
        self.config = config
        refreshValues()
        NSApp.bringToFront()
        showWindow(nil)
        // Agent apps are often not activated in time; force the window to the front anyway.
        window?.orderFrontRegardless()
        window?.makeKeyAndOrderFront(nil)
    }

    // Permission and login item can change outside the app, e.g. in System Settings.
    // Leaving the window must not leave the global hotkey switched off mid-recording.
    func windowWillClose(_ notification: Notification) {
        hotKeyRecorder.cancelRecording()
    }

    func windowDidResignKey(_ notification: Notification) {
        hotKeyRecorder.cancelRecording()
    }

    func windowDidBecomeKey(_ notification: Notification) {
        refreshSystemState()
    }

    // MARK: - Values

    private func refreshValues() {
        hotKeyRecorder.hotkey = config.hotkey
        retentionField.integerValue = config.retentionDays
        retentionStepper.integerValue = config.retentionDays
        maxItemsField.integerValue = config.maxItems
        maxItemsStepper.integerValue = config.maxItems
        keepImages.state = config.keepImages ? .on : .off
        ignoredTable.reloadData()
        refreshSystemState()
    }

    private func refreshSystemState() {
        switch SMAppService.mainApp.status {
        case .enabled:
            launchAtLogin.state = .on
            launchAtLogin.title = "Beim Anmelden automatisch starten"
        case .requiresApproval:
            // Registered, but macOS waits for the user to allow it under Login Items.
            launchAtLogin.state = .off
            launchAtLogin.title = "Beim Anmelden starten (in Systemeinstellungen freigeben)"
        default:
            launchAtLogin.state = .off
            launchAtLogin.title = "Beim Anmelden automatisch starten"
        }
        if Paster.isTrusted(prompt: false) {
            accessibilityStatus.stringValue = "✓ Erlaubt"
            accessibilityStatus.textColor = .systemGreen
        } else {
            accessibilityStatus.stringValue = "✗ Nicht erlaubt"
            accessibilityStatus.textColor = .systemRed
        }
    }

    private func commit() {
        onChange(config)
    }

    /// The app could not register the recorded hotkey and keeps the previous one.
    func restoreHotkey(_ hotkey: String) {
        config.hotkey = hotkey
        hotKeyRecorder.hotkey = hotkey
    }

    // MARK: - Actions

    private func hotKeyChanged(_ hotkey: String) {
        config.hotkey = hotkey
        commit()
    }

    @objc private func launchAtLoginChanged() {
        if SMAppService.mainApp.status == .requiresApproval {
            SMAppService.openSystemSettingsLoginItems()
            refreshSystemState()
            return
        }
        do {
            if launchAtLogin.state == .on {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            let alert = NSAlert(error: error)
            alert.beginSheetModal(for: window!)
        }
        refreshSystemState()
    }

    @objc private func openAccessibilitySettings() {
        _ = Paster.isTrusted(prompt: true)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func retentionChanged(_ sender: NSControl) {
        config.retentionDays = Config.clamp(sender.integerValue, to: Config.retentionRange)
        retentionField.integerValue = config.retentionDays
        retentionStepper.integerValue = config.retentionDays
        commit()
    }

    @objc private func maxItemsChanged(_ sender: NSControl) {
        config.maxItems = Config.clamp(sender.integerValue, to: Config.maxItemsRange)
        maxItemsField.integerValue = config.maxItems
        maxItemsStepper.integerValue = config.maxItems
        commit()
    }

    @objc private func keepImagesChanged() {
        config.keepImages = keepImages.state == .on
        commit()
    }

    @objc private func ignoredButtonClicked() {
        if ignoredButtons.selectedSegment == 0 {
            addIgnoredApp()
        } else {
            let row = ignoredTable.selectedRow
            guard config.ignoredApps.indices.contains(row) else { return }
            config.ignoredApps.remove(at: row)
            ignoredTable.reloadData()
            commit()
        }
    }

    private func addIgnoredApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = "Ignorieren"
        panel.message = "App auswählen, deren Kopien nicht gespeichert werden sollen"
        panel.beginSheetModal(for: window!) { [weak self] response in
            guard let self, response == .OK, let url = panel.url,
                  let bundleId = Bundle(url: url)?.bundleIdentifier,
                  !config.ignoredApps.contains(bundleId) else { return }
            config.ignoredApps.append(bundleId)
            ignoredTable.reloadData()
            commit()
        }
    }

    @objc private func revealData() {
        NSWorkspace.shared.activateFileViewerSelecting([dataDirectory])
    }

    // MARK: - Ignored apps table

    // Names for the default entries, shown when the app is not installed.
    private static let knownAppNames = [
        "com.1password.1password": "1Password 8",
        "com.agilebits.onepassword7": "1Password 7",
        "com.apple.keychainaccess": "Schlüsselbundverwaltung",
        "com.apple.Passwords": "Passwörter",
        "com.bitwarden.desktop": "Bitwarden",
    ]

    func numberOfRows(in tableView: NSTableView) -> Int {
        config.ignoredApps.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let bundleId = config.ignoredApps[row]
        let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId)
        let name = appURL.map { FileManager.default.displayName(atPath: $0.path) }
            ?? Self.knownAppNames[bundleId]
            ?? bundleId

        let id = NSUserInterfaceItemIdentifier("app")
        let cell = tableView.makeView(withIdentifier: id, owner: nil) as? IgnoredAppCell ?? IgnoredAppCell(identifier: id)
        cell.icon.image = appURL.map { NSWorkspace.shared.icon(forFile: $0.path) }
            ?? NSImage(systemSymbolName: "app.dashed", accessibilityDescription: nil)
        cell.title.stringValue = name
        cell.detail.stringValue = appURL == nil ? "nicht installiert" : bundleId
        return cell
    }

    // MARK: - Layout

    private func buildLayout() {
        let grid = NSGridView()
        grid.columnSpacing = 14
        grid.rowSpacing = 10

        func section(_ title: String) {
            let label = NSTextField(labelWithString: title)
            label.font = .boldSystemFont(ofSize: 13)
            let row = grid.addRow(with: [label, NSGridCell.emptyContentView])
            row.mergeCells(in: NSRange(location: 0, length: 2))
            row.cell(at: 0).xPlacement = .leading
            if grid.numberOfRows > 1 { row.topPadding = 8 }
        }

        func row(_ title: String, _ control: NSView, alignWith anchor: NSView, help: String) {
            let label = NSTextField(labelWithString: title)
            let helpLabel = NSTextField(wrappingLabelWithString: help)
            helpLabel.font = .systemFont(ofSize: 11)
            helpLabel.textColor = .secondaryLabelColor
            helpLabel.preferredMaxLayoutWidth = 520
            let stack = NSStackView(views: [control, helpLabel])
            stack.orientation = .vertical
            stack.alignment = .leading
            stack.spacing = 5
            let gridRow = grid.addRow(with: [label, stack])
            gridRow.yPlacement = .top
            label.firstBaselineAnchor.constraint(equalTo: anchor.firstBaselineAnchor).isActive = true
        }

        func numberControl(_ field: NSTextField, _ stepper: NSStepper, unit: String, range: ClosedRange<Int>, step: Int, action: Selector) -> NSStackView {
            let formatter = NumberFormatter()
            formatter.minimum = NSNumber(value: range.lowerBound)
            formatter.maximum = NSNumber(value: range.upperBound)
            formatter.allowsFloats = false
            field.formatter = formatter
            field.alignment = .right
            field.target = self
            field.action = action
            field.cell?.sendsActionOnEndEditing = true
            field.widthAnchor.constraint(equalToConstant: 64).isActive = true
            stepper.minValue = Double(range.lowerBound)
            stepper.maxValue = Double(range.upperBound)
            stepper.increment = Double(step)
            stepper.valueWraps = false
            stepper.target = self
            stepper.action = action
            let stack = NSStackView(views: [field, stepper, NSTextField(labelWithString: unit)])
            stack.spacing = 4
            return stack
        }

        // General
        section("Allgemein")
        hotKeyRecorder.onChange = { [weak self] in self?.hotKeyChanged($0) }
        row("Tastenkürzel:", hotKeyRecorder, alignWith: hotKeyRecorder, help: """
            Öffnet und schließt die Historie aus jeder App heraus. Zum Ändern auf das Feld klicken und die neue \
            Kombination drücken, mit ⌘ oder ⌃ (macOS lässt ⌥ allein nicht zu). Esc bricht ab.
            """)

        launchAtLogin.target = self
        launchAtLogin.action = #selector(launchAtLoginChanged)
        row("Autostart:", launchAtLogin, alignWith: launchAtLogin, help: """
            Startet Clippboard nach dem Anmelden am Mac. Nur solange die App läuft, wird kopierter Inhalt \
            in die Historie aufgenommen.
            """)

        let accessibilityButton = NSButton(title: "Systemeinstellungen öffnen …", target: self, action: #selector(openAccessibilitySettings))
        let accessibilityStack = NSStackView(views: [accessibilityStatus, accessibilityButton])
        accessibilityStack.spacing = 12
        row("Direkt einfügen:", accessibilityStack, alignWith: accessibilityStatus, help: """
            Damit ⏎ den Eintrag sofort in die aktive App einfügt, braucht Clippboard die Berechtigung \
            „Bedienungshilfen“. Ohne sie landet der Eintrag nur in der Zwischenablage und du drückst selbst ⌘V. \
            Wurde die App ohne festes Zertifikat gebaut (ad hoc), muss die Berechtigung nach jedem Neubau neu gesetzt \
            werden (entfernen und wieder hinzufügen).
            """)

        // History
        section("Historie")
        let retention = numberControl(retentionField, retentionStepper, unit: "Tage", range: Config.retentionRange, step: 1,
                                      action: #selector(retentionChanged(_:)))
        row("Aufbewahren:", retention, alignWith: retentionField, help: """
            Ältere Einträge werden automatisch gelöscht, beim Start und danach stündlich. Wird der Wert \
            verkleinert, verschwinden ältere Einträge sofort. Angepinnte Einträge (⌘P) werden nie automatisch gelöscht.
            """)

        let maxItems = numberControl(maxItemsField, maxItemsStepper, unit: "Einträge", range: Config.maxItemsRange, step: 50,
                                     action: #selector(maxItemsChanged(_:)))
        row("Höchstens:", maxItems, alignWith: maxItemsField, help: """
            Obergrenze für die Historie. Kommen mehr Einträge zusammen, fallen die ältesten weg, auch wenn \
            sie jünger als die Aufbewahrungszeit sind. Angepinnte Einträge zählen nicht mit.
            """)

        keepImages.target = self
        keepImages.action = #selector(keepImagesChanged)
        row("Bilder:", keepImages, alignWith: keepImages, help: """
            Kopierte Bilder wie Screenshots werden als PNG gespeichert und lassen sich wieder einfügen. \
            Ist das aus, merkt sich Clippboard nur Texte und Dateipfade.
            """)

        // Privacy
        section("Datenschutz")
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
        tableScroll.widthAnchor.constraint(equalToConstant: 520).isActive = true
        tableScroll.heightAnchor.constraint(equalToConstant: 100).isActive = true

        ignoredButtons.segmentStyle = .smallSquare
        ignoredButtons.trackingMode = .momentary
        ignoredButtons.segmentCount = 2
        ignoredButtons.setImage(NSImage(named: NSImage.addTemplateName), forSegment: 0)
        ignoredButtons.setImage(NSImage(named: NSImage.removeTemplateName), forSegment: 1)
        ignoredButtons.setToolTip("App hinzufügen", forSegment: 0)
        ignoredButtons.setToolTip("Ausgewählte App entfernen", forSegment: 1)
        ignoredButtons.target = self
        ignoredButtons.action = #selector(ignoredButtonClicked)

        let ignoredStack = NSStackView(views: [tableScroll, ignoredButtons])
        ignoredStack.orientation = .vertical
        ignoredStack.alignment = .leading
        ignoredStack.spacing = 0
        let ignoredTitle = NSTextField(labelWithString: "Ignorierte Apps:")
        let ignoredHelp = NSTextField(wrappingLabelWithString: """
            Was in diesen Apps kopiert wird, landet nie in der Historie, z. B. aus Passwort-Managern. \
            Unabhängig davon speichert Clippboard nie Inhalte, die eine App als vertraulich markiert.
            """)
        ignoredHelp.font = .systemFont(ofSize: 11)
        ignoredHelp.textColor = .secondaryLabelColor
        ignoredHelp.preferredMaxLayoutWidth = 520
        let ignoredContent = NSStackView(views: [ignoredStack, ignoredHelp])
        ignoredContent.orientation = .vertical
        ignoredContent.alignment = .leading
        ignoredContent.spacing = 5
        grid.addRow(with: [ignoredTitle, ignoredContent]).yPlacement = .top

        // Data
        section("Daten")
        let pathLabel = NSTextField(labelWithString: (dataDirectory.path as NSString).abbreviatingWithTildeInPath)
        pathLabel.lineBreakMode = .byTruncatingMiddle
        pathLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let revealButton = NSButton(title: "Im Finder zeigen", target: self, action: #selector(revealData))
        let dataStack = NSStackView(views: [pathLabel, revealButton])
        dataStack.spacing = 12
        row("Speicherort:", dataStack, alignWith: pathLabel, help: """
            Hier liegen Datenbank, Bilder und config.json. Alles bleibt lokal auf diesem Mac, nichts wird \
            übertragen. Den Verlauf löschst du über das Menüleisten-Symbol.
            """)

        let versionLabel = NSTextField(labelWithString: AppVersion.display)
        versionLabel.isSelectable = true
        row("Version:", versionLabel, alignWith: versionLabel, help: """
            Die Build-Nummer zählt die Änderungen am Quellcode, dahinter steht die genaue Code-Version. \
            Bei Fehlermeldungen bitte mit angeben.
            """)

        // Columns only exist once rows were added.
        grid.column(at: 0).xPlacement = .trailing

        let content = FlippedView()
        grid.translatesAutoresizingMaskIntoConstraints = false
        content.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            grid.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            grid.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            grid.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
        ])

        // Scrolls on small screens instead of growing past the bottom edge.
        let scroll = NSScrollView()
        scroll.documentView = content
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            content.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            content.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
        ])
        window?.contentView = scroll

        let fitting = content.fittingSize
        let maxHeight = (NSScreen.main?.visibleFrame.height ?? 800) - 80
        window?.setContentSize(NSSize(width: fitting.width, height: min(fitting.height, maxHeight)))
    }
}

/// Top-left origin so the settings start at the top of the scroll view.
private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
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

    required init?(coder: NSCoder) { fatalError() }
}
