import AppKit
import Carbon
import ClippboardCore
import ServiceManagement
import UniformTypeIdentifiers

final class SettingsWindowController: NSWindowController, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate {
    private var config: Config
    private let dataDirectory: URL
    private let onChange: (Config) -> Void
    private let onUninstall: () -> Void

    private let hotKeyRecorder: HotKeyRecorder
    private let languagePopUp = NSPopUpButton()
    private let launchAtLogin = NSButton(checkboxWithTitle: String(localized: "Start automatically at login"), target: nil, action: nil)
    private let accessibilityStatus = NSTextField(labelWithString: "")
    private let retentionField = NSTextField()
    private let retentionStepper = NSStepper()
    private let maxItemsField = NSTextField()
    private let maxItemsStepper = NSStepper()
    private let keepImages = NSButton(checkboxWithTitle: String(localized: "Save images"), target: nil, action: nil)
    private let ignoredTable = NSTableView()
    private let ignoredButtons = NSSegmentedControl()
    private let tabs = NSTabViewController()
    private static let selectedTabKey = "SettingsSelectedTab"

    init(config: Config, dataDirectory: URL, onRecordingHotKey: @escaping (Bool) -> Void,
         onChange: @escaping (Config) -> Void, onUninstall: @escaping () -> Void) {
        self.config = config
        self.dataDirectory = dataDirectory
        self.onChange = onChange
        self.onUninstall = onUninstall
        hotKeyRecorder = HotKeyRecorder(hotkey: config.hotkey)
        hotKeyRecorder.onRecordingChange = onRecordingHotKey

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 600),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
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
        // Opens centred on the active screen each time, instead of wherever it was last closed;
        // an already open window stays where the user moved it. Not center(): it places windows
        // in the upper third.
        // The screen under the mouse: an inactive agent app's NSScreen.main can be the other display.
        let mouse = NSEvent.mouseLocation
        let activeScreen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        if let window, !window.isVisible, let screen = activeScreen?.visibleFrame {
            window.setFrameOrigin(NSPoint(x: screen.midX - window.frame.width / 2,
                                          y: screen.midY - window.frame.height / 2))
        }
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
        UserDefaults.standard.set(tabs.selectedTabViewItemIndex, forKey: Self.selectedTabKey)
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
            launchAtLogin.title = String(localized: "Start automatically at login")
        case .requiresApproval:
            // Registered, but macOS waits for the user to allow it under Login Items.
            launchAtLogin.state = .off
            launchAtLogin.title = String(localized: "Start at login (allow in System Settings)")
        default:
            launchAtLogin.state = .off
            launchAtLogin.title = String(localized: "Start automatically at login")
        }
        if Paster.isTrusted(prompt: false) {
            accessibilityStatus.stringValue = String(localized: "✓ Allowed")
            accessibilityStatus.textColor = .systemGreen
        } else {
            accessibilityStatus.stringValue = String(localized: "✗ Not allowed")
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

    @objc private func languageChanged() {
        let language = languagePopUp.selectedItem?.representedObject as? String
        AppLanguage.select(language)
        // Nothing to restart for if the effective language stays the one on screen.
        guard (language ?? AppLanguage.systemLanguage) != Bundle.main.preferredLocalizations.first else { return }
        let alert = NSAlert()
        alert.messageText = String(localized: "Clippboard needs to restart to switch the language.")
        alert.addButton(withTitle: String(localized: "Restart Now"))
        alert.addButton(withTitle: String(localized: "Later"))
        alert.beginSheetModal(for: window!) { response in
            if response == .alertFirstButtonReturn { AppLanguage.relaunch() }
        }
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
        panel.prompt = String(localized: "Ignore")
        panel.message = String(localized: "Choose an app whose copies should not be saved")
        panel.beginSheetModal(for: window!) { [weak self] response in
            guard let self, response == .OK, let url = panel.url,
                  let bundleId = Bundle(url: url)?.bundleIdentifier,
                  !config.ignoredApps.contains(bundleId) else { return }
            config.ignoredApps.append(bundleId)
            ignoredTable.reloadData()
            commit()
        }
    }

    @objc private func confirmUninstall() {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = String(localized: "Uninstall Clippboard?")
        alert.informativeText = String(localized: """
            The history including pinned entries, all images and the settings are deleted for good, \
            and Clippboard moves to the Trash. This cannot be undone.
            """)
        alert.addButton(withTitle: String(localized: "Uninstall"))
        alert.buttons.first?.hasDestructiveAction = true
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.beginSheetModal(for: window!) { [weak self] response in
            if response == .alertFirstButtonReturn { self?.onUninstall() }
        }
    }

    @objc private func revealData() {
        NSWorkspace.shared.activateFileViewerSelecting([dataDirectory])
    }

    // MARK: - Ignored apps table

    // Names for the default entries, shown when the app is not installed.
    func numberOfRows(in tableView: NSTableView) -> Int {
        config.ignoredApps.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let bundleId = config.ignoredApps[row]
        let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId)
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

    // MARK: - Layout

    private func buildLayout() {
        // One grid per tab; the helpers below add rows to the current one.
        var grid = NSGridView()
        var pages: [(title: String, symbol: String, grid: NSGridView)] = []

        func page(_ title: String, symbol: String) {
            grid = NSGridView()
            grid.columnSpacing = 14
            grid.rowSpacing = 16
            pages.append((title, symbol, grid))
        }

        @discardableResult
        func row(_ title: String, _ control: NSView, alignWith anchor: NSView, help: String) -> NSTextField {
            let label = NSTextField(labelWithString: title)
            // VoiceOver names the control after its label and reads the explanation as help.
            anchor.setAccessibilityTitleUIElement(label)
            anchor.setAccessibilityHelp(help)
            let helpLabel = NSTextField(wrappingLabelWithString: help)
            helpLabel.font = .systemFont(ofSize: 11)
            helpLabel.textColor = .secondaryLabelColor
            helpLabel.preferredMaxLayoutWidth = 480
            let stack = NSStackView(views: [control, helpLabel])
            stack.orientation = .vertical
            stack.alignment = .leading
            stack.spacing = 5
            let gridRow = grid.addRow(with: [label, stack])
            gridRow.yPlacement = .top
            label.firstBaselineAnchor.constraint(equalTo: anchor.firstBaselineAnchor).isActive = true
            return label
        }

        func numberControl(_ field: NSTextField, _ stepper: NSStepper, range: ClosedRange<Int>, step: Int, action: Selector) -> NSStackView {
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
            // The unit is part of the row label: a word after the number would need plural forms
            // (1 day, 2 days; Polish has four), which a catalog cannot give without the number.
            let stack = NSStackView(views: [field, stepper])
            stack.spacing = 4
            return stack
        }

        // General
        page(String(localized: "General"), symbol: "gearshape")
        hotKeyRecorder.onChange = { [weak self] in self?.hotKeyChanged($0) }
        row(String(localized: "Shortcut:"), hotKeyRecorder, alignWith: hotKeyRecorder, help: String(localized: """
            Opens and closes the history from any app. To change it, click the field and press the new \
            combination, with ⌘ or ⌃ (macOS does not allow ⌥ alone). Esc cancels.
            """))

        let systemName = AppLanguage.displayName(AppLanguage.systemLanguage)
        languagePopUp.addItem(withTitle: String(localized: "System (\(systemName))"))
        languagePopUp.menu?.addItem(.separator())
        for language in AppLanguage.available {
            languagePopUp.addItem(withTitle: AppLanguage.displayName(language))
            languagePopUp.lastItem?.representedObject = language
        }
        let selectedIndex = AppLanguage.selected.map { languagePopUp.indexOfItem(withRepresentedObject: $0) } ?? -1
        languagePopUp.selectItem(at: max(selectedIndex, 0))
        languagePopUp.target = self
        languagePopUp.action = #selector(languageChanged)
        row(String(localized: "Language:"), languagePopUp, alignWith: languagePopUp, help: String(localized: """
            By default Clippboard uses the language of your Mac. A change takes effect after Clippboard restarts.
            """))

        launchAtLogin.target = self
        launchAtLogin.action = #selector(launchAtLoginChanged)
        row(String(localized: "Launch:"), launchAtLogin, alignWith: launchAtLogin, help: String(localized: """
            Starts Clippboard when you log in to your Mac. Copied content is only added to the history \
            while the app is running.
            """))

        let accessibilityButton = NSButton(title: String(localized: "Open System Settings…"), target: self, action: #selector(openAccessibilitySettings))
        let accessibilityStack = NSStackView(views: [accessibilityStatus, accessibilityButton])
        accessibilityStack.spacing = 12
        row(String(localized: "Paste directly:"), accessibilityStack, alignWith: accessibilityStatus, help: String(localized: """
            For ⏎ to paste the entry straight into the active app, Clippboard needs the Accessibility \
            permission. Without it, the entry is only put on the clipboard and you press ⌘V yourself. \
            If the app was built without a fixed certificate (ad hoc), the permission must be granted again after \
            every rebuild (remove it and add it again).
            """))

        // History
        page(String(localized: "History"), symbol: "clock.arrow.circlepath")
        let retention = numberControl(retentionField, retentionStepper, range: Config.retentionRange, step: 1,
                                      action: #selector(retentionChanged(_:)))
        let retentionLabel = row(String(localized: "Keep for (days):"), retention, alignWith: retentionField, help: String(localized: """
            Older entries are deleted automatically, at launch and every hour after that. If you lower the \
            value, older entries disappear right away. Pinned entries (⌘P) are never deleted automatically.
            """))

        let maxItems = numberControl(maxItemsField, maxItemsStepper, range: Config.maxItemsRange, step: 50,
                                     action: #selector(maxItemsChanged(_:)))
        let maxItemsLabel = row(String(localized: "At most (entries):"), maxItems, alignWith: maxItemsField, help: String(localized: """
            Upper limit for the history. When there are more entries, the oldest are dropped, even if they \
            are newer than the retention period. Pinned entries do not count.
            """))

        retentionStepper.setAccessibilityTitleUIElement(retentionLabel)
        maxItemsStepper.setAccessibilityTitleUIElement(maxItemsLabel)

        keepImages.target = self
        keepImages.action = #selector(keepImagesChanged)
        row(String(localized: "Images:"), keepImages, alignWith: keepImages, help: String(localized: """
            Copied images such as screenshots are saved as PNG and can be pasted again. \
            When this is off, Clippboard only remembers text and file paths.
            """))

        // Privacy
        page(String(localized: "Privacy"), symbol: "hand.raised")
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

        let ignoredStack = NSStackView(views: [tableScroll, ignoredButtons])
        ignoredStack.orientation = .vertical
        ignoredStack.alignment = .leading
        ignoredStack.spacing = 0
        let ignoredTitle = NSTextField(labelWithString: String(localized: "Ignored apps:"))
        let ignoredHelp = NSTextField(wrappingLabelWithString: String(localized: """
            Anything copied in these apps never ends up in the history, e.g. from password managers. \
            Regardless of this list, Clippboard never saves content an app marks as confidential.
            """))
        ignoredHelp.font = .systemFont(ofSize: 11)
        ignoredHelp.textColor = .secondaryLabelColor
        ignoredHelp.preferredMaxLayoutWidth = 480
        let ignoredContent = NSStackView(views: [ignoredStack, ignoredHelp])
        ignoredContent.orientation = .vertical
        ignoredContent.alignment = .leading
        ignoredContent.spacing = 5
        grid.addRow(with: [ignoredTitle, ignoredContent]).yPlacement = .top

        // Info
        page(String(localized: "Info"), symbol: "info.circle")
        let pathLabel = NSTextField(labelWithString: (dataDirectory.path as NSString).abbreviatingWithTildeInPath)
        pathLabel.lineBreakMode = .byTruncatingMiddle
        pathLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let revealButton = NSButton(title: String(localized: "Show in Finder"), target: self, action: #selector(revealData))
        let dataStack = NSStackView(views: [pathLabel, revealButton])
        dataStack.spacing = 12
        row(String(localized: "Location:"), dataStack, alignWith: pathLabel, help: String(localized: """
            The database, images and config.json are stored here. Everything stays on this Mac; nothing is \
            sent anywhere. You clear the history from the menu bar icon.
            """))

        let versionLabel = NSTextField(labelWithString: AppVersion.display)
        versionLabel.isSelectable = true
        row(String(localized: "Version:"), versionLabel, alignWith: versionLabel, help: String(localized: """
            The build number counts the changes to the source code, followed by the exact code version. \
            Please include it when reporting a problem.
            """))

        let uninstallButton = NSButton(title: String(localized: "Uninstall Clippboard…"), target: self, action: #selector(confirmUninstall))
        // Only an installed Clippboard.app can remove itself safely.
        uninstallButton.isEnabled = Uninstaller.bundleID != nil
        row(String(localized: "Uninstall:"), uninstallButton, alignWith: uninstallButton, help: String(localized: """
            Deletes the history, images and settings, removes the login item and the Accessibility \
            permission, and moves Clippboard to the Trash. If you drag the app to the Trash yourself, \
            this data stays behind.
            """))

        // All tabs share the widest tab's width, so switching only changes the height.
        let width = pages.map { $0.grid.fittingSize.width }.max() ?? 0
        for page in pages {
            // Columns only exist once rows were added.
            page.grid.column(at: 0).xPlacement = .trailing
            page.grid.translatesAutoresizingMaskIntoConstraints = false
            let view = NSView()
            view.addSubview(page.grid)
            NSLayoutConstraint.activate([
                page.grid.topAnchor.constraint(equalTo: view.topAnchor, constant: 20),
                page.grid.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
                page.grid.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -20),
                view.widthAnchor.constraint(equalToConstant: width + 48),
            ])
            let controller = NSViewController()
            controller.view = view
            controller.title = page.title
            controller.preferredContentSize = view.fittingSize
            let item = NSTabViewItem(viewController: controller)
            item.label = page.title
            item.image = NSImage(systemSymbolName: page.symbol, accessibilityDescription: nil)
            tabs.addTabViewItem(item)
        }
        tabs.tabStyle = .toolbar
        tabs.selectedTabViewItemIndex = min(UserDefaults.standard.integer(forKey: Self.selectedTabKey), pages.count - 1)
        window?.contentViewController = tabs
        window?.toolbarStyle = .preference
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

    required init?(coder: NSCoder) { fatalError() }
}
