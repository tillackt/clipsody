import AppKit
import ClipsodyCore
import ClipsodyServices

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var store: Store!
    private var config = Config()
    private var monitor: ClipboardMonitor!
    private var panel: PanelController!
    private let decoder = DecoderClient()
    private lazy var paster = Paster(decoder: decoder)
    private lazy var hotKeys = HotKeyController(
        onPress: { [unowned self] in panel.toggle() },
        onRegister: { [unowned self] label in openItem?.title = String(localized: "Open History (\(label))") },
        onError: { [unowned self] message in alert(message) }
    )
    private var statusItem: NSStatusItem!
    private var openItem: NSMenuItem!
    private var settings: SettingsWindowController?
    private var pruneTimer: Timer?
    private var images: ImageQueue!
    private var recognition: TextRecognitionQueue!

    func applicationDidFinishLaunching(_ notification: Notification) {
        LegacyMigration.run()
        do {
            store = try Store()
        } catch {
            fail("\(error)")
            return
        }
        config = Config.load(from: store.directory) { [unowned self] backup in
            alert(String(localized: """
                The settings (config.json) were damaged and have been replaced with the defaults. \
                The old file is in the data folder as \(backup.lastPathComponent).
                """))
        }

        prune()

        recognition = TextRecognitionQueue(store: store) { [decoder] png in
            await decoder.recognizeText(inPNG: png)
        } onRecognized: { [unowned self] file, text in
            // The open panel searches its own copy of the entries.
            panel.refreshRecognizedText(text, forImageFile: file)
        }
        images = ImageQueue(store: store, accepts: { [unowned self] appBundleID in
            config.keepImages && !(appBundleID.map(config.ignoredApps.contains) ?? false)
        }) { [decoder] data in
            await decoder.prepareImage(data)
        } onStored: { [unowned self] in
            panel.reloadIfVisible()
            recognition.start()
        }
        monitor = ClipboardMonitor(store: store, images: images) { [unowned self] in config }
        panel = PanelController(store: store, decoder: decoder) { [unowned self] item, target, formatted in
            paste(item, into: target, withFormatting: formatted)
        }
        monitor.onChange = { [unowned self] in
            panel.reloadIfVisible()
        }
        monitor.start()
        recognition.start()

        buildMainMenu()
        buildStatusItem()
        hotKeys.register(config.hotkey)

        pruneTimer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.prune() }
        }
        pruneTimer?.tolerance = 60

        // No prompt at launch, or users without the permission would see it on every start; the
        // first paste attempt asks. Without it entries are only copied, not pasted.
        if !Paster.isTrusted(prompt: false) {
            logger.notice("No Accessibility permission yet; asked on the first paste")
        }

        if CommandLine.arguments.contains("--settings") {
            openSettings()
        }
    }

    /// Launching the app again (Spotlight, Finder, `open`) shows the history.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // nil if the store could not be opened at launch
        panel?.show()
        return false
    }

    // Opts into secure state restoration; without it macOS 14+ logs a warning at launch.
    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }

    // MARK: - Paste

    func applicationWillTerminate(_ notification: Notification) {
        store?.flushDeletions()
        paster.prepareForTermination()
    }

    private func paste(_ item: ClipItem, into target: NSRunningApplication?, withFormatting: Bool) {
        var item = item
        // The list holds only the beginning of long texts.
        if item.kind == .text, item.textByteCount > item.text.utf8.count {
            // Only the beginning is in the list; pasting that silently would be wrong.
            guard let text = store.fullText(for: item) else {
                logger.error("Paste: full text could not be loaded")
                NSSound.beep()
                return
            }
            item.text = text
        }
        let rich = withFormatting ? store.richText(for: item) : nil
        guard paster.paste(item, imageURL: store.imageURL(for: item), rich: rich, into: target) else {
            logger.error("Paste: content no longer available (file moved or deleted)")
            NSSound.beep()
            return
        }
        monitor.ignoreCurrentContents()
        store.touch(item)
    }

    // MARK: - Settings

    private func prune() {
        store.prune(retentionDays: config.retentionDays, maxItems: config.maxItems)
        // An open panel must not keep showing (and pasting) entries that are gone.
        panel?.reloadIfVisible()
    }

    @objc private func openPanel() {
        panel.show()
    }

    @objc private func openSettings() {
        if settings == nil {
            settings = SettingsWindowController(
                config: config,
                dataDirectory: store.directory,
                onRecordingHotKey: { [unowned self] recording in
                    if recording { hotKeys.suspend() } else { hotKeys.resume() }
                },
                onChange: { [unowned self] newConfig in applySettings(newConfig) },
                onUninstall: { [unowned self] in uninstall() }
            )
        }
        settings?.show(with: config)
    }

    private func applySettings(_ newConfig: Config) {
        var newConfig = newConfig
        // Also for an unchanged hotkey: a recording that ends on the same key must resume it.
        // A rejected hotkey must not be saved: the old one stays registered and in the settings.
        if !hotKeys.replace(with: newConfig.hotkey) {
            newConfig.hotkey = config.hotkey
            settings?.restoreHotkey(config.hotkey)
        }
        config = newConfig
        config.save(to: store.directory)
        prune()
    }

    private func uninstall() {
        // Nothing may write into the data folder, or show the deleted history, while and after it
        // is deleted: tccutil and the failure alert both let the run loop go on.
        monitor.stop()
        pruneTimer?.invalidate()
        images.discardPending()
        recognition.stop()
        hotKeys.suspend()
        panel.hide()
        let failed = Uninstaller.run(dataDirectory: store.directory)
        if !failed.isEmpty {
            alert(String(localized: "Clipsody could not remove these items; please delete them yourself:") + "\n\n"
                + failed.joined(separator: "\n"))
        }
        // An image pasted last still owes the clipboard its TIFF version.
        paster.prepareForTermination()
        // Not terminate(): quitting normally would flush the database and save window state again.
        exit(0)
    }

    @objc private func clearHistory() {
        let alert = NSAlert()
        alert.messageText = String(localized: "Clear the entire history?")
        alert.informativeText = String(localized: "Pinned entries are kept.")
        alert.addButton(withTitle: String(localized: "Clear"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        NSApp.bringToFront()
        if alert.runModal() == .alertFirstButtonReturn {
            images.discardPending()
            store.clear()
            panel.reloadIfVisible()
        }
    }

    // MARK: - Menus

    private func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "list.clipboard", accessibilityDescription: "Clipsody")

        let menu = NSMenu()
        // Items are enabled explicitly; otherwise isEnabled would be ignored.
        menu.autoenablesItems = false
        openItem = menu.addItem(withTitle: String(localized: "Open History"), action: #selector(openPanel), keyEquivalent: "")
        menu.addItem(withTitle: String(localized: "Settings…"), action: #selector(openSettings), keyEquivalent: ",")
        menu.addItem(.separator())
        menu.addItem(withTitle: String(localized: "Clear History…"), action: #selector(clearHistory), keyEquivalent: "")
        menu.addItem(.separator())
        // Informational only, no action: disabled items show greyed out.
        let versionItem = menu.addItem(withTitle: "Clipsody – \(AppVersion.display)", action: nil, keyEquivalent: "")
        versionItem.isEnabled = false
        menu.addItem(withTitle: String(localized: "Quit"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        for item in menu.items where item.action != nil && item.action != #selector(NSApplication.terminate(_:)) {
            item.target = self
        }
        statusItem.menu = menu
    }

    /// Agent apps have no visible menu bar, but text fields need the Edit actions for ⌘C/⌘V/⌘A.
    private func buildMainMenu() {
        let mainMenu = NSMenu()
        let appItem = NSMenuItem()
        appItem.submenu = NSMenu()
        appItem.submenu?.addItem(withTitle: String(localized: "Quit"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        mainMenu.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: String(localized: "Edit"))
        edit.addItem(withTitle: String(localized: "Undo"), action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: String(localized: "Redo"), action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(withTitle: String(localized: "Cut"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: String(localized: "Copy"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: String(localized: "Paste"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: String(localized: "Select All"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        mainMenu.addItem(editItem)
        NSApp.mainMenu = mainMenu
    }

    // MARK: - Alerts

    private func alert(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Clipsody"
        alert.informativeText = message
        NSApp.bringToFront()
        alert.runModal()
    }

    private func fail(_ message: String) {
        alert(message)
        NSApp.terminate(nil)
    }
}
