import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var store: Store!
    private var config = Config()
    private var monitor: ClipboardMonitor!
    private var panel: PanelController!
    private var hotKey: HotKey?
    private var hotKeySpec: HotKeySpec?
    private var statusItem: NSStatusItem!
    private var openItem: NSMenuItem!
    private var settings: SettingsWindowController?
    private var pruneTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            store = try Store()
        } catch {
            fail("Die Datenbank konnte nicht geöffnet werden: \(error)")
            return
        }
        config = Config.load(from: store.directory)

        let imported = AlfredImporter.importIfNeeded(into: store, force: CommandLine.arguments.contains("--import-alfred"))
        if imported > 0 { NSLog("Clippboard: imported %d entries from Alfred", imported) }
        prune()

        monitor = ClipboardMonitor(store: store) { [unowned self] in config }
        panel = PanelController(store: store, maxItems: { [unowned self] in config.maxItems }) { [unowned self] item, target in
            paste(item, into: target)
        }
        monitor.onChange = { [unowned self] in panel.reloadIfVisible() }
        monitor.start()

        buildMainMenu()
        buildStatusItem()
        registerHotKey()

        pruneTimer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in self?.prune() }

        // Asks once for Accessibility permission; without it entries are only copied, not pasted.
        _ = Paster.isTrusted(prompt: true)

        if CommandLine.arguments.contains("--settings") {
            openSettings()
        }
    }

    /// Launching the app again (Spotlight, Finder, `open`) shows the history.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        panel.show()
        return false
    }

    // MARK: - Paste

    private func paste(_ item: ClipItem, into target: NSRunningApplication?) {
        Paster.write(item, store: store)
        monitor.ignoreCurrentContents()
        store.touch(item)

        guard Paster.isTrusted(prompt: false) else {
            NSLog("Clippboard paste: no Accessibility permission, item only copied")
            NSSound.beep()
            _ = Paster.isTrusted(prompt: true)
            return
        }

        // If Clippboard itself is active (e.g. the settings window was used), ⌘V would land here.
        if let target, !target.isActive {
            if #available(macOS 14.0, *) { NSApp.yieldActivation(to: target) }
            target.activate(options: [])
        }
        whenFrontmost(target, attemptsLeft: 20) {
            NSLog("Clippboard paste: sending ⌘V to %@ (frontmost: %@)",
                  target?.localizedName ?? "-",
                  NSWorkspace.shared.frontmostApplication?.localizedName ?? "-")
            Paster.sendPasteKeystroke()
        }
    }

    /// Waits up to ~0.5 s for the target app to be frontmost, then lets its window regain focus.
    private func whenFrontmost(_ target: NSRunningApplication?, attemptsLeft: Int, then action: @escaping () -> Void) {
        let frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier
        if target == nil || frontmost == target?.processIdentifier || attemptsLeft == 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: action)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.025) { [weak self] in
            self?.whenFrontmost(target, attemptsLeft: attemptsLeft - 1, then: action)
        }
    }

    // MARK: - Settings

    private func registerHotKey() {
        hotKey = nil
        guard let spec = HotKeySpec(config.hotkey) else {
            alert("Ungültiger Hotkey „\(config.hotkey)“ in config.json. Beispiel: \"cmd+option+c\"")
            return
        }
        hotKeySpec = spec
        hotKey = HotKey(spec: spec) { [weak self] in self?.panel.toggle() }
        if hotKey == nil {
            alert("Der Hotkey \(spec.display) ist bereits von einer anderen App belegt (z. B. Alfred).")
        }
        openItem?.title = "Historie öffnen (\(spec.display))"
    }

    private func prune() {
        store.prune(retentionDays: config.retentionDays, maxItems: config.maxItems)
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
                    if recording { hotKey = nil } else { registerHotKey() }
                },
                onChange: { [unowned self] newConfig in applySettings(newConfig) }
            )
        }
        settings?.show(with: config)
    }

    private func applySettings(_ newConfig: Config) {
        let hotkeyChanged = newConfig.hotkey != config.hotkey
        config = newConfig
        config.save(to: store.directory)
        if hotkeyChanged { registerHotKey() }
        prune()
    }

    @objc private func clearHistory() {
        let alert = NSAlert()
        alert.messageText = "Gesamte Historie löschen?"
        alert.addButton(withTitle: "Löschen")
        alert.addButton(withTitle: "Abbrechen")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            store.clear()
        }
    }

    // MARK: - Menus

    private func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "list.clipboard", accessibilityDescription: "Clippboard")

        let menu = NSMenu()
        openItem = menu.addItem(withTitle: "Historie öffnen", action: #selector(openPanel), keyEquivalent: "")
        menu.addItem(withTitle: "Einstellungen …", action: #selector(openSettings), keyEquivalent: ",")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Historie löschen …", action: #selector(clearHistory), keyEquivalent: "")
        menu.addItem(withTitle: "Beenden", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        for item in menu.items where item.action != #selector(NSApplication.terminate(_:)) {
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
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    private func fail(_ message: String) {
        alert(message)
        NSApp.terminate(nil)
    }
}
