import AppKit
import ApplicationServices
import ClipsodyCore

/// What has the keyboard focus in the app in front, asked through the Accessibility API.
enum FocusedField {
    case editable, notEditable, unknown

    /// Roles that take typed text; anything clearly not editable (a label, a button, a link) is
    /// refused. Apps that report nothing useful get the benefit of the doubt.
    static func current() -> FocusedField {
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else { return .unknown }
        let app = AXUIElementCreateApplication(pid)
        // A hanging app must not freeze Clipsody for the default 6 seconds.
        AXUIElementSetMessagingTimeout(app, 0.3)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return .unknown }
        // CFGetTypeID checked above.
        // swiftlint:disable:next force_cast
        let element = focused as! AXUIElement
        AXUIElementSetMessagingTimeout(element, 0.3)
        var settable = DarwinBoolean(false)
        if AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable) == .success, settable.boolValue {
            return .editable
        }
        var role: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role) == .success,
              let role = role as? String else { return .unknown }
        if editableRoles.contains(role) { return .editable }
        return notEditableRoles.contains(role) ? .notEditable : .unknown
    }

    private static let editableRoles: Set = ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"]
    /// Only elements that are clearly something else. Windows, groups and web areas are not refused:
    /// browsers often report a focused form field as one of those.
    private static let notEditableRoles: Set = [
        "AXStaticText", "AXButton", "AXLink", "AXImage", "AXCheckBox", "AXRadioButton", "AXPopUpButton",
        "AXMenuButton", "AXHeading",
    ]
}

/// A button that reacts to the first click, although the bar never becomes the key window.
private class FirstClickButton: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// A value of the fill bar: a click pastes it into the focused field, dragging drops it into any field.
private final class ValueButton: FirstClickButton, NSDraggingSource {
    var text = ""
    var onDropped: () -> Void = {}

    /// NSButton's own tracking would swallow the drag, so the mouse is followed here: released in
    /// place it is a click, moved a few points it becomes a drag.
    override func mouseDown(with event: NSEvent) {
        let start = event.locationInWindow
        highlight(true)
        defer { highlight(false) }
        while let next = window?.nextEvent(matching: [.leftMouseUp, .leftMouseDragged]) {
            if next.type == .leftMouseUp {
                if bounds.contains(convert(next.locationInWindow, from: nil)) { sendAction(action, to: target) }
                return
            }
            if hypot(next.locationInWindow.x - start.x, next.locationInWindow.y - start.y) > 4 {
                let item = NSDraggingItem(pasteboardWriter: text as NSString)
                item.setDraggingFrame(bounds, contents: snapshot())
                // The bar may close during the drag; the source must outlive it.
                Self.dragging = self
                beginDraggingSession(with: [item], event: next, source: self)
                return
            }
        }
    }

    private static var dragging: ValueButton?

    private func snapshot() -> NSImage? {
        guard let rep = bitmapImageRepForCachingDisplay(in: bounds) else { return nil }
        cacheDisplay(in: bounds, to: rep)
        let image = NSImage(size: bounds.size)
        image.addRepresentation(rep)
        return image
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .outsideApplication ? .copy : []
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        if !operation.isEmpty { onDropped() }
        Self.dragging = nil
    }
}

/// Never becomes key: the app in front keeps its focused field, and ⌘V goes there.
private final class FillBarPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// The fill bar of a snippet with several fields: floats at the top of the screen without taking
/// the focus. The user clicks into a form field, then on a value (or presses ⌥⌘V for the next one);
/// the value is pasted there, unless no text field has the focus.
@MainActor
final class FillBar {
    /// Pastes a text into the app in front; true if it was pasted.
    private let onPaste: (String) -> Bool
    private var panel: FillBarPanel?
    private var snippet: Snippet?
    private var used: Set<Int> = []
    private var buttons: [NSButton] = []
    private let status = NSTextField(labelWithString: "")
    private var nextKey: HotKey?
    /// Counts openings and closings; a delayed paste or close of an earlier one is dropped.
    private var generation = 0
    /// ⌥⌘V is waiting for the keys to be released; a second press meanwhile is ignored.
    private var nextPending = false
    /// Watches for Esc in any app while the bar is open; the key still reaches that app.
    private var escapeMonitor: Any?

    init(onPaste: @escaping (String) -> Bool) {
        self.onPaste = onPaste
    }

    var isVisible: Bool { panel?.isVisible == true }

    func show(_ snippet: Snippet) {
        close()
        generation += 1
        self.snippet = Snippet(id: snippet.id, name: snippet.name, fields: snippet.filledFields)
        used = []
        let panel = FillBarPanel(contentRect: .zero, styleMask: [.nonactivatingPanel, .borderless],
                                 backing: .buffered, defer: false)
        panel.level = .floating
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        // Like the panel: kept out of classic screenshots and screen sharing.
        panel.sharingType = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.contentView = makeContent()
        panel.setContentSize(panel.contentView?.fittingSize ?? .zero)
        position(panel)
        panel.orderFrontRegardless()
        self.panel = panel
        // ⌥⌘V: the next value not used yet. Taken by another app: the bar still works by clicking.
        if let spec = HotKeySpec("cmd+option+v") {
            nextKey = try? HotKey(spec: spec, id: .fillNext) { [weak self] in self?.pasteNext() }
        }
        // Key events of other apps need the Accessibility permission, which pasting needs anyway.
        escapeMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return }
            MainActor.assumeIsolated { self?.close() }
        }
        showHint()
    }

    func close() {
        generation += 1
        nextPending = false
        nextKey = nil
        if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }
        escapeMonitor = nil
        panel?.orderOut(nil)
        panel = nil
        snippet = nil
        buttons = []
    }

    private func makeContent() -> NSView {
        let background = NSVisualEffectView()
        background.material = .popover
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 12

        let title = NSTextField(labelWithString: snippet?.name.isEmpty == false ? snippet!.name : String(localized: "Snippet"))
        title.font = .systemFont(ofSize: 12, weight: .semibold)
        title.textColor = .secondaryLabelColor
        title.lineBreakMode = .byTruncatingTail
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        buttons = (snippet?.fields ?? []).enumerated().map { valueButton(for: $1, at: $0) }
        let close = FirstClickButton(image: NSImage(systemSymbolName: "xmark", accessibilityDescription: String(localized: "Close"))!,
                                     target: self, action: #selector(closeClicked))
        close.isBordered = false

        status.font = .systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor

        // At most four values per row, so long snippets stay within the screen.
        var rows: [NSView] = []
        for start in stride(from: 0, to: buttons.count, by: 4) {
            let row = NSStackView(views: Array(buttons[start..<min(start + 4, buttons.count)]))
            row.spacing = 6
            rows.append(row)
        }
        let header = NSStackView(views: [title, NSView(), close])
        header.spacing = 8
        let stack = NSStackView(views: [header] + rows + [status])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 10)
        stack.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: background.topAnchor),
            stack.bottomAnchor.constraint(equalTo: background.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            header.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -22),
        ])
        return background
    }

    private func valueButton(for field: Snippet.Field, at index: Int) -> NSButton {
        let firstLine = field.text.split(whereSeparator: \.isNewline).first.map(String.init) ?? field.text
        let caption = field.label.isEmpty ? firstLine : "\(field.label): \(firstLine)"
        let button = ValueButton(title: caption, target: self, action: #selector(valueClicked(_:)))
        button.tag = index
        button.text = field.text
        button.onDropped = { [weak self] in self?.markUsed(index) }
        button.bezelStyle = .rounded
        button.lineBreakMode = .byTruncatingTail
        button.toolTip = field.text
        button.widthAnchor.constraint(lessThanOrEqualToConstant: 240).isActive = true
        return button
    }

    /// Top centre of the screen with the mouse, below the menu bar.
    private func position(_ panel: NSPanel) {
        let mouse = NSEvent.mouseLocation
        guard let visible = (NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main)?.visibleFrame
        else { return }
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: visible.midX - size.width / 2, y: visible.maxY - size.height - 12))
    }

    @objc private func valueClicked(_ sender: NSButton) {
        paste(sender.tag)
    }

    @objc private func closeClicked() {
        close()
    }

    /// ⌥⌘V: the next value, once ⌥ and ⌘ are released. While they are still held, the app would
    /// receive ⌥⌘V instead of the ⌘V Clipsody sends, and paste nothing.
    private func pasteNext() {
        guard snippet != nil, !nextPending else { return }
        nextPending = true
        let opening = generation
        Task { @MainActor [weak self] in
            for _ in 0..<30 where !NSEvent.modifierFlags.isDisjoint(with: [.option, .command, .control, .shift]) {
                try? await Task.sleep(for: .milliseconds(50))
            }
            guard let self, generation == opening else { return }
            nextPending = false
            guard NSEvent.modifierFlags.isDisjoint(with: [.option, .command, .control, .shift]) else {
                NSSound.beep()
                status.stringValue = String(localized: "Release ⌥ and ⌘ to paste the next value.")
                status.textColor = .systemOrange
                resize()
                return
            }
            // Chosen only now: a click meanwhile may have used the value that was next before.
            if let next = snippet?.fields.indices.first(where: { !used.contains($0) }) { paste(next) }
        }
    }

    private func paste(_ index: Int) {
        guard let snippet, snippet.fields.indices.contains(index) else { return }
        guard FocusedField.current() != .notEditable else {
            NSSound.beep()
            status.stringValue = String(localized: "No text field selected – nothing was pasted. Click into a field first.")
            status.textColor = .systemRed
            resize()
            return
        }
        guard onPaste(snippet.fields[index].text) else {
            status.stringValue = String(localized: """
                Only copied, not pasted: Clipsody needs the Accessibility permission, or no app is in front. Press ⌘V.
                """)
            status.textColor = .systemOrange
            resize()
            return
        }
        markUsed(index)
    }

    private func markUsed(_ index: Int) {
        guard let snippet, buttons.indices.contains(index) else { return }
        used.insert(index)
        buttons[index].image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: String(localized: "Pasted"))
        buttons[index].imagePosition = .imageLeading
        if used.count == snippet.fields.count {
            // Everything is filled in; the bar goes away by itself.
            status.stringValue = String(localized: "All fields pasted.")
            status.textColor = .secondaryLabelColor
            let opening = generation
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(1.2))
                if self?.generation == opening { self?.close() }
            }
        } else {
            showHint()
        }
        resize()
    }

    private func showHint() {
        status.stringValue = nextKey == nil
            ? String(localized: "Click into a field, then on the value, or drag the value into the field.")
            : String(localized: "Click into a field, then on the value (or ⌥⌘V for the next one), or drag the value into the field.")
        status.textColor = .secondaryLabelColor
    }

    private func resize() {
        guard let panel, let content = panel.contentView else { return }
        let top = panel.frame.maxY
        panel.setContentSize(content.fittingSize)
        panel.setFrameTopLeftPoint(NSPoint(x: panel.frame.minX, y: top))
    }
}
