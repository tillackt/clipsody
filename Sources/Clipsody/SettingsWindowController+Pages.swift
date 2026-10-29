import AppKit
import ClipsodyCore

/// The four tabs of the settings window, one function each.
extension SettingsWindowController {
    func buildLayout() {
        let pages = [generalPage(), historyPage(), privacyPage(), infoPage()]
        // All tabs share the widest tab's width, so switching only changes the height.
        let width = pages.map(\.grid.fittingSize.width).max() ?? 0
        for page in pages {
            tabs.addTabViewItem(page.tabViewItem(width: width))
        }
        tabs.tabStyle = .toolbar
        tabs.selectedTabViewItemIndex = min(UserDefaults.standard.integer(forKey: Self.selectedTabKey), pages.count - 1)
        window?.contentViewController = tabs
        window?.toolbarStyle = .preference
    }

    private func generalPage() -> SettingsPage {
        let page = SettingsPage(String(localized: "General"), symbol: "gearshape")
        hotKeyRecorder.onChange = { [weak self] in self?.hotKeyChanged($0) }
        page.row(String(localized: "Shortcut:"), hotKeyRecorder, alignWith: hotKeyRecorder, help: String(localized: """
            Opens and closes the history from any app. To change it, click the field and press the new \
            combination, with ⌘ or ⌃ (macOS does not allow ⌥ alone). Esc cancels.
            """))

        configureLanguagePopUp()
        page.row(String(localized: "Language:"), languagePopUp, alignWith: languagePopUp, help: String(localized: """
            By default Clipsody uses the language of your Mac. A change takes effect after Clipsody restarts.
            """))

        launchAtLogin.target = self
        launchAtLogin.action = #selector(launchAtLoginChanged)
        page.row(String(localized: "Launch:"), launchAtLogin, alignWith: launchAtLogin, help: String(localized: """
            Starts Clipsody when you log in to your Mac. Copied content is only added to the history \
            while the app is running.
            """))

        let accessibilityButton = NSButton(title: String(localized: "Open System Settings…"), target: self,
                                           action: #selector(openAccessibilitySettings))
        let accessibilityStack = NSStackView(views: [accessibilityStatus, accessibilityButton])
        accessibilityStack.spacing = 12
        page.row(String(localized: "Paste directly:"), accessibilityStack, alignWith: accessibilityStatus,
                 help: String(localized: """
            For ⏎ to paste the entry straight into the active app, Clipsody needs the Accessibility \
            permission. Without it, the entry is only put on the clipboard and you press ⌘V yourself. \
            If the app was built without a fixed certificate (ad hoc), the permission must be granted again after \
            every rebuild (remove it and add it again).
            """))
        return page
    }

    private func configureLanguagePopUp() {
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
    }

    private func historyPage() -> SettingsPage {
        let page = SettingsPage(String(localized: "History"), symbol: "clock.arrow.circlepath")
        let retention = numberControl(retentionField, retentionStepper, range: Config.retentionRange, step: 1,
                                                   action: #selector(retentionChanged(_:)))
        let retentionLabel = page.row(String(localized: "Keep for (days):"), retention, alignWith: retentionField,
                                      help: String(localized: """
            Older entries are deleted automatically, at launch and every hour after that. If you lower the \
            value, older entries disappear right away. Pinned entries (⌘P) are never deleted automatically.
            """))

        let maxItems = numberControl(maxItemsField, maxItemsStepper, range: Config.maxItemsRange, step: 50,
                                                  action: #selector(maxItemsChanged(_:)))
        let maxItemsLabel = page.row(String(localized: "At most (entries):"), maxItems, alignWith: maxItemsField,
                                     help: String(localized: """
            Upper limit for the history. When there are more entries, the oldest are dropped, even if they \
            are newer than the retention period. Pinned entries do not count.
            """))

        retentionStepper.setAccessibilityTitleUIElement(retentionLabel)
        maxItemsStepper.setAccessibilityTitleUIElement(maxItemsLabel)

        keepImages.target = self
        keepImages.action = #selector(keepImagesChanged)
        page.row(String(localized: "Images:"), keepImages, alignWith: keepImages, help: String(localized: """
            Copied images such as screenshots are saved as PNG and can be pasted again. \
            When this is off, Clipsody only remembers text and file paths.
            """))
        return page
    }

    private func privacyPage() -> SettingsPage {
        let page = SettingsPage(String(localized: "Privacy"), symbol: "hand.raised")
        let content = NSStackView(views: [makeIgnoredAppsList(), SettingsPage.helpLabel(String(localized: """
            Anything copied in these apps never ends up in the history, e.g. from password managers. \
            Regardless of this list, Clipsody never saves content an app marks as confidential.
            """))])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 5
        page.row(String(localized: "Ignored apps:"), content: content)
        return page
    }

    private func infoPage() -> SettingsPage {
        let page = SettingsPage(String(localized: "Info"), symbol: "info.circle")
        let pathLabel = NSTextField(labelWithString: (dataDirectory.path as NSString).abbreviatingWithTildeInPath)
        pathLabel.lineBreakMode = .byTruncatingMiddle
        pathLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let revealButton = NSButton(title: String(localized: "Show in Finder"), target: self, action: #selector(revealData))
        let dataStack = NSStackView(views: [pathLabel, revealButton])
        dataStack.spacing = 12
        page.row(String(localized: "Location:"), dataStack, alignWith: pathLabel, help: String(localized: """
            The database, images and config.json are stored here. Everything stays on this Mac; nothing is \
            sent anywhere. You clear the history from the menu bar icon.
            """))

        let versionLabel = NSTextField(labelWithString: AppVersion.display)
        versionLabel.isSelectable = true
        page.row(String(localized: "Version:"), versionLabel, alignWith: versionLabel, help: String(localized: """
            The build number counts the changes to the source code, followed by the exact code version. \
            Please include it when reporting a problem.
            """))

        let uninstallButton = NSButton(title: String(localized: "Uninstall Clipsody…"), target: self,
                                       action: #selector(confirmUninstall))
        // Only an installed Clipsody.app can remove itself safely.
        uninstallButton.isEnabled = Uninstaller.bundleID != nil
        page.row(String(localized: "Uninstall:"), uninstallButton, alignWith: uninstallButton, help: String(localized: """
            Deletes the history, images and settings, removes the login item and the Accessibility \
            permission, and moves Clipsody to the Trash. If you drag the app to the Trash yourself, \
            this data stays behind.
            """))
        return page
    }

    /// A number field with a stepper. The unit is part of the row label: a word after the number would
    /// need plural forms (1 day, 2 days; Polish has four), which a catalog cannot give without the number.
    private func numberControl(_ field: NSTextField, _ stepper: NSStepper, range: ClosedRange<Int>, step: Int,
                               action: Selector) -> NSStackView {
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
        let stack = NSStackView(views: [field, stepper])
        stack.spacing = 4
        return stack
    }
}
