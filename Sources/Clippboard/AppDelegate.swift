import AppKit
import ClippboardCore
import ClippboardServices

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var store: Store!
    private var config = Config()
    private var monitor: ClipboardMonitor!
    private var panel: PanelController!
    private let decoder = DecoderClient()
    private lazy var paster = Paster(decoder: decoder)
    private var hotKey: HotKey?
    private var statusItem: NSStatusItem!
    private var openItem: NSMenuItem!
    private var settings: SettingsWindowController?
    private var pruneTimer: Timer?
    private var images: ImageQueue!
    private var recognition: TextRecognitionQueue!

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            store = try Store()
        } catch {
            fail("\(error)")
            return
        }
        config = Config.load(from: store.directory) { [unowned self] backup in
            alert("""
                Die Einstellungen (config.json) waren beschädigt und wurden durch die Standardwerte ersetzt. \
                Die alte Datei liegt als \(backup.lastPathComponent) im Datenordner.
                """)
        }

        prune()

        recognition = TextRecognitionQueue(store: store) { [decoder] png in
            await decoder.recognizeText(inPNG: png)
        } onRecognized: { [unowned self] file in
            // The open panel searches its own copy of the entries.
            panel.refreshRecognizedText(forImageFile: file)
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
        registerHotKey(config.hotkey)

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

    /// Registers `hotkey` in place of the current one. On failure nothing is registered and the
    /// caller decides what to restore; the alert explains why.
    @discardableResult
    private func registerHotKey(_ hotkey: String) -> Bool {
        guard let spec = HotKeySpec(hotkey) else {
            alert("Ungültiger Hotkey „\(hotkey)“ in config.json. Beispiel: \"cmd+option+c\"")
            return false
        }
        let label = KeyLabel.display(spec)
        // Release the old one first, otherwise re-registering the same combination counts as taken.
        hotKey = nil
        do {
            hotKey = try HotKey(spec: spec) { [weak self] in self?.panel.toggle() }
        } catch let error as HotKeyError where error.isAlreadyTaken {
            alert("Der Hotkey \(label) ist bereits von einer anderen App belegt (z. B. Alfred).")
            return false
        } catch {
            alert("macOS hat den Hotkey \(label) abgelehnt (\(error)). Bitte eine Kombination mit ⌘ oder ⌃ wählen.")
            return false
        }
        openItem?.title = "Historie öffnen (\(label))"
        return true
    }

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
                // The registered hotkey would swallow the keystroke while recording a new one.
                onRecordingHotKey: { [unowned self] recording in
                    if recording { hotKey = nil } else { registerHotKey(config.hotkey) }
                },
                onChange: { [unowned self] newConfig in applySettings(newConfig) }
            )
        }
        settings?.show(with: config)
    }

    private func applySettings(_ newConfig: Config) {
        var newConfig = newConfig
        // A rejected hotkey must not be saved: the old one stays registered and in the settings.
        if newConfig.hotkey != config.hotkey, !registerHotKey(newConfig.hotkey) {
            registerHotKey(config.hotkey)
            newConfig.hotkey = config.hotkey
            settings?.restoreHotkey(config.hotkey)
        }
        config = newConfig
        config.save(to: store.directory)
        prune()
    }

    @objc private func clearHistory() {
        let alert = NSAlert()
        alert.messageText = "Gesamte Historie löschen?"
        alert.informativeText = "Angepinnte Einträge bleiben erhalten."
        alert.addButton(withTitle: "Löschen")
        alert.addButton(withTitle: "Abbrechen")
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
        statusItem.button?.image = NSImage(systemSymbolName: "list.clipboard", accessibilityDescription: "Clippboard")

        let menu = NSMenu()
        // Items are enabled explicitly; otherwise isEnabled would be ignored.
        menu.autoenablesItems = false
        openItem = menu.addItem(withTitle: "Historie öffnen", action: #selector(openPanel), keyEquivalent: "")
        menu.addItem(withTitle: "Einstellungen …", action: #selector(openSettings), keyEquivalent: ",")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Historie löschen …", action: #selector(clearHistory), keyEquivalent: "")
        menu.addItem(.separator())
        // Informational only, no action: disabled items show greyed out.
        let versionItem = menu.addItem(withTitle: "Clippboard – \(AppVersion.display)", action: nil, keyEquivalent: "")
        versionItem.isEnabled = false
        menu.addItem(withTitle: "Beenden", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
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
        appItem.submenu?.addItem(withTitle: "Beenden", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        mainMenu.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Bearbeiten")
        edit.addItem(withTitle: "Widerrufen", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Wiederholen", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(withTitle: "Ausschneiden", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Kopieren", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Einsetzen", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Alles auswählen", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        mainMenu.addItem(editItem)
        NSApp.mainMenu = mainMenu
    }

    // MARK: - Alerts

    private func alert(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Clippboard"
        alert.informativeText = message
        NSApp.bringToFront()
        alert.runModal()
    }

    private func fail(_ message: String) {
        alert(message)
        NSApp.terminate(nil)
    }
}
