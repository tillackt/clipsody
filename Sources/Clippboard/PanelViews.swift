import AppKit

/// Borderless panel that can take keyboard focus without activating the app,
/// so the app the user is working in stays frontmost (like Spotlight/Alfred).
final class KeyPanel: NSPanel {
    var onKeyEquivalent: ((NSEvent) -> Bool)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if onKeyEquivalent?(event) == true { return true }
        return super.performKeyEquivalent(with: event)
    }
}

/// Keeps rows in the accent colour although the table never becomes first responder.
final class EmphasizedRowView: NSTableRowView {
    override var isEmphasized: Bool {
        get { true }
        set {}
    }
}

final class ClipRowView: NSTableCellView {
    let icon = NSImageView()
    let title = NSTextField(labelWithString: "")
    let pin = NSImageView(image: NSImage(systemSymbolName: "pin.fill", accessibilityDescription: "Angepinnt")!)
    let shortcut = NSTextField(labelWithString: "")
    private var plainTitle = ""
    private var highlights: [NSRange] = []

    /// Title with search matches marked; colours follow the row's selection state.
    func setTitle(_ text: String, highlights: [NSRange]) {
        plainTitle = text
        self.highlights = highlights
        renderTitle()
    }

    private func renderTitle() {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        let base: NSColor = backgroundStyle == .emphasized ? .alternateSelectedControlTextColor : .labelColor
        let string = NSMutableAttributedString(string: plainTitle, attributes: [
            .font: NSFont.systemFont(ofSize: 14), .foregroundColor: base, .paragraphStyle: paragraph,
        ])
        for range in highlights {
            string.addAttributes([.backgroundColor: NSColor.findHighlightColor, .foregroundColor: NSColor.black], range: range)
        }
        title.attributedStringValue = string
    }

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        imageView = icon
        textField = title

        icon.imageScaling = .scaleProportionallyUpOrDown
        title.lineBreakMode = .byTruncatingTail
        title.font = .systemFont(ofSize: 14)
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        shortcut.font = .systemFont(ofSize: 12)
        shortcut.textColor = .secondaryLabelColor
        shortcut.setContentHuggingPriority(.required, for: .horizontal)
        pin.contentTintColor = .secondaryLabelColor
        pin.symbolConfiguration = .init(pointSize: 11, weight: .regular)
        pin.setContentHuggingPriority(.required, for: .horizontal)

        for view in [icon, title, pin, shortcut] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 22),
            icon.heightAnchor.constraint(equalToConstant: 22),
            title.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
            title.centerYAnchor.constraint(equalTo: centerYAnchor),
            pin.leadingAnchor.constraint(greaterThanOrEqualTo: title.trailingAnchor, constant: 6),
            pin.centerYAnchor.constraint(equalTo: centerYAnchor),
            shortcut.leadingAnchor.constraint(equalTo: pin.trailingAnchor, constant: 6),
            shortcut.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            shortcut.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet {
            let emphasized = backgroundStyle == .emphasized
            shortcut.textColor = emphasized ? .alternateSelectedControlTextColor : .secondaryLabelColor
            pin.contentTintColor = emphasized ? .alternateSelectedControlTextColor : .secondaryLabelColor
            renderTitle()
        }
    }
}
