import AppKit
import ClipsodyCore
import ServiceManagement
import UniformTypeIdentifiers

/// The settings window. Its tabs are built in SettingsWindowController+Pages.swift, the list of
/// ignored apps in SettingsWindowController+IgnoredApps.swift.
final class SettingsWindowController: NSWindowController, NSWindowDelegate,
    NSTableViewDataSource, NSTableViewDelegate {
    var config: Config
    let dataDirectory: URL
    let onChange: (Config) -> Void
    let onUninstall: () -> Void

    let hotKeyRecorder: HotKeyRecorder
    let languagePopUp = NSPopUpButton()
    let launchAtLogin = NSButton(checkboxWithTitle: String(localized: "Start automatically at login"), target: nil, action: nil)
    let accessibilityStatus = NSTextField(labelWithString: "")
    let retentionField = NSTextField()
    let retentionStepper = NSStepper()
    let maxItemsField = NSTextField()
    let maxItemsStepper = NSStepper()
    let keepImages = NSButton(checkboxWithTitle: String(localized: "Save images"), target: nil, action: nil)
    let ignoredTable = NSTableView()
    let ignoredButtons = NSSegmentedControl()
    let tabs = NSTabViewController()
    static let selectedTabKey = "SettingsSelectedTab"

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

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

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

    func refreshValues() {
        hotKeyRecorder.hotkey = config.hotkey
        retentionField.integerValue = config.retentionDays
        retentionStepper.integerValue = config.retentionDays
        maxItemsField.integerValue = config.maxItems
        maxItemsStepper.integerValue = config.maxItems
        keepImages.state = config.keepImages ? .on : .off
        ignoredTable.reloadData()
        refreshSystemState()
    }

    func refreshSystemState() {
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

    func commit() {
        onChange(config)
    }

    /// The app could not register the recorded hotkey and keeps the previous one.
    func restoreHotkey(_ hotkey: String) {
        config.hotkey = hotkey
        hotKeyRecorder.hotkey = hotkey
    }

    // MARK: - Actions

    func hotKeyChanged(_ hotkey: String) {
        config.hotkey = hotkey
        commit()
    }

    @objc func launchAtLoginChanged() {
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

    @objc func languageChanged() {
        let language = languagePopUp.selectedItem?.representedObject as? String
        AppLanguage.select(language)
        // Nothing to restart for if the effective language stays the one on screen.
        guard (language ?? AppLanguage.systemLanguage) != Bundle.main.preferredLocalizations.first else { return }
        let alert = NSAlert()
        alert.messageText = String(localized: "Clipsody needs to restart to switch the language.")
        alert.addButton(withTitle: String(localized: "Restart Now"))
        alert.addButton(withTitle: String(localized: "Later"))
        alert.beginSheetModal(for: window!) { response in
            if response == .alertFirstButtonReturn { AppLanguage.relaunch() }
        }
    }

    @objc func openAccessibilitySettings() {
        _ = Paster.isTrusted(prompt: true)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc func retentionChanged(_ sender: NSControl) {
        config.retentionDays = Config.clamp(sender.integerValue, to: Config.retentionRange)
        retentionField.integerValue = config.retentionDays
        retentionStepper.integerValue = config.retentionDays
        commit()
    }

    @objc func maxItemsChanged(_ sender: NSControl) {
        config.maxItems = Config.clamp(sender.integerValue, to: Config.maxItemsRange)
        maxItemsField.integerValue = config.maxItems
        maxItemsStepper.integerValue = config.maxItems
        commit()
    }

    @objc func keepImagesChanged() {
        config.keepImages = keepImages.state == .on
        commit()
    }

    @objc func ignoredButtonClicked() {
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

    func addIgnoredApp() {
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

    @objc func confirmUninstall() {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = String(localized: "Uninstall Clipsody?")
        alert.informativeText = String(localized: """
            The history including pinned entries, all images and the settings are deleted for good, \
            and Clipsody moves to the Trash. This cannot be undone.
            """)
        alert.addButton(withTitle: String(localized: "Uninstall"))
        alert.buttons.first?.hasDestructiveAction = true
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.beginSheetModal(for: window!) { [weak self] response in
            if response == .alertFirstButtonReturn { self?.onUninstall() }
        }
    }

    @objc func revealData() {
        NSWorkspace.shared.activateFileViewerSelecting([dataDirectory])
    }
}
