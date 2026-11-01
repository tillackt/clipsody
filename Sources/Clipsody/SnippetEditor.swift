import AppKit
import ClipsodyCore

/// Edits one snippet in the panel's right half: its name and its fields (optional label, text).
/// Every change is reported right away; the panel saves it.
@MainActor
final class SnippetEditor: NSView, NSTextFieldDelegate {
    var onChange: (Snippet) -> Void = { _ in }
    var onUse: () -> Void = {}
    var onDelete: () -> Void = {}
    /// Back to the search field (after the field with the focus went away).
    var onLeave: () -> Void = {}
    /// Esc in a field: the panel closes, as it does from the search field.
    var onEscape: () -> Void = {}

    private(set) var snippet = Snippet()
    private let nameField = NSTextField()
    private let rowsStack = NSStackView()
    private let useButton = NSButton()
    private var labelFields: [NSTextField] = []
    private var textFields: [NSTextField] = []

    override init(frame: NSRect) {
        super.init(frame: frame)
        build()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func show(_ snippet: Snippet) {
        let sameSnippet = snippet.id == self.snippet.id
        // Another snippet while a field of this one is edited: the field goes, so the focus goes back
        // to the search field instead of staying nowhere.
        let wasEditing = (window?.firstResponder as? NSView)?.isDescendant(of: self) == true
        self.snippet = snippet
        nameField.stringValue = snippet.name
        // Rebuilding the rows while the user types in one would take the cursor away.
        if !sameSnippet || labelFields.count != snippet.fields.count {
            rebuildRows()
            if wasEditing { onLeave() }
        }
        updateUseButton()
    }

    func focusName() {
        window?.makeFirstResponder(nameField)
    }

    // MARK: - Layout

    private func build() {
        nameField.placeholderString = String(localized: "Name, e.g. My address")
        nameField.font = .systemFont(ofSize: 15, weight: .medium)
        nameField.delegate = self
        nameField.setAccessibilityLabel(String(localized: "Snippet name"))

        let labelHeader = header(String(localized: "Label (optional)"))
        labelHeader.widthAnchor.constraint(equalToConstant: 110).isActive = true
        let headers = NSStackView(views: [labelHeader, header(String(localized: "Text"))])
        headers.spacing = 6

        rowsStack.orientation = .vertical
        rowsStack.alignment = .leading
        rowsStack.spacing = 6
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        rowsStack.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(rowsStack)
        scroll.documentView = document

        let addButton = NSButton(title: String(localized: "Add Field"), target: self, action: #selector(addField))
        addButton.image = NSImage(systemSymbolName: "plus", accessibilityDescription: nil)
        addButton.imagePosition = .imageLeading
        addButton.bezelStyle = .inline
        let deleteButton = NSButton(title: String(localized: "Delete…"), target: self, action: #selector(deleteClicked))
        useButton.target = self
        useButton.action = #selector(useClicked)
        useButton.keyEquivalent = ""
        let footer = NSStackView(views: [addButton, NSView(), deleteButton, useButton])
        footer.spacing = 8

        let stack = NSStackView(views: [nameField, headers, scroll, footer])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            nameField.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            footer.widthAnchor.constraint(equalTo: stack.widthAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            rowsStack.topAnchor.constraint(equalTo: document.topAnchor),
            rowsStack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            rowsStack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            rowsStack.bottomAnchor.constraint(equalTo: document.bottomAnchor),
        ])
        scroll.setContentHuggingPriority(.defaultLow, for: .vertical)
    }

    private func header(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        return label
    }

    private func rebuildRows() {
        rowsStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        labelFields = []
        textFields = []
        for (index, field) in snippet.fields.enumerated() {
            let row = row(for: field, at: index)
            rowsStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: rowsStack.widthAnchor).isActive = true
        }
    }

    private func row(for field: Snippet.Field, at index: Int) -> NSView {
        let label = NSTextField(string: field.label)
        label.placeholderString = String(localized: "e.g. Postcode")
        label.delegate = self
        label.widthAnchor.constraint(equalToConstant: 110).isActive = true
        label.setAccessibilityLabel(String(localized: "Label of field \(index + 1)"))
        let text = NSTextField(string: field.text)
        text.placeholderString = String(localized: "Text")
        text.delegate = self
        text.usesSingleLineMode = false
        text.cell?.wraps = true
        text.cell?.isScrollable = false
        text.maximumNumberOfLines = 4
        text.setAccessibilityLabel(String(localized: "Text of field \(index + 1)"))
        text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        labelFields.append(label)
        textFields.append(text)

        let up = iconButton("chevron.up", String(localized: "Move Up"), #selector(moveFieldUp(_:)), index, enabled: index > 0)
        let down = iconButton("chevron.down", String(localized: "Move Down"), #selector(moveFieldDown(_:)), index,
                              enabled: index < snippet.fields.count - 1)
        let remove = iconButton("xmark", String(localized: "Remove Field"), #selector(removeField(_:)), index,
                                enabled: snippet.fields.count > 1)
        let row = NSStackView(views: [label, text, up, down, remove])
        row.spacing = 6
        row.alignment = .top
        row.translatesAutoresizingMaskIntoConstraints = false
        return row
    }

    private func iconButton(_ symbol: String, _ label: String, _ action: Selector, _ index: Int, enabled: Bool) -> NSButton {
        let button = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: label)!, target: self, action: action)
        button.isBordered = false
        button.tag = index
        button.isEnabled = enabled
        button.toolTip = label
        return button
    }

    private func updateUseButton() {
        useButton.title = snippet.isSet ? String(localized: "Fill In ⏎") : String(localized: "Paste ⏎")
    }

    // MARK: - Changes

    func controlTextDidChange(_ notification: Notification) {
        // A text field grows with its lines while it is edited, not only afterwards.
        (notification.object as? NSTextField)?.invalidateIntrinsicContentSize()
        snippet.name = nameField.stringValue
        for index in snippet.fields.indices where index < labelFields.count {
            snippet.fields[index] = Snippet.Field(label: labelFields[index].stringValue, text: textFields[index].stringValue)
        }
        updateUseButton()
        onChange(snippet)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.cancelOperation(_:)):
            onEscape()
            return true
        case #selector(NSResponder.insertTab(_:)), #selector(NSResponder.insertBacktab(_:)):
            let order = [nameField] + zip(labelFields, textFields).flatMap { [$0, $1] }
            guard let index = order.firstIndex(where: { $0 === control }) else { return false }
            let step = selector == #selector(NSResponder.insertTab(_:)) ? 1 : -1
            window?.makeFirstResponder(order[(index + step + order.count) % order.count])
            return true
        // ⏎ in a text starts a new line (signatures, addresses); in a name or label it moves on.
        case #selector(NSResponder.insertNewline(_:)) where textFields.contains(where: { $0 === control }):
            textView.insertNewlineIgnoringFieldEditor(nil)
            return true
        default:
            return false
        }
    }

    /// `focus`: the field index that gets the keyboard afterwards (a rebuild removes the old fields,
    /// and without this the window itself would keep the focus and typing would only beep).
    private func changeFields(focus: Int? = nil, _ change: (inout [Snippet.Field]) -> Void) {
        change(&snippet.fields)
        rebuildRows()
        updateUseButton()
        onChange(snippet)
        if let focus, textFields.indices.contains(focus) {
            window?.makeFirstResponder(textFields[focus])
        } else {
            onLeave()
        }
    }

    @objc private func addField() {
        changeFields(focus: snippet.fields.count) { $0.append(Snippet.Field()) }
    }

    @objc private func removeField(_ sender: NSButton) {
        guard snippet.fields.count > 1 else { return }
        changeFields(focus: max(0, sender.tag - 1)) { $0.remove(at: sender.tag) }
    }

    @objc private func moveFieldUp(_ sender: NSButton) {
        guard sender.tag > 0 else { return }
        changeFields(focus: sender.tag - 1) { $0.swapAt(sender.tag, sender.tag - 1) }
    }

    @objc private func moveFieldDown(_ sender: NSButton) {
        guard sender.tag < snippet.fields.count - 1 else { return }
        changeFields(focus: sender.tag + 1) { $0.swapAt(sender.tag, sender.tag + 1) }
    }

    @objc private func useClicked() {
        onUse()
    }

    @objc private func deleteClicked() {
        onDelete()
    }
}

/// Lays out the field rows from the top.
private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
