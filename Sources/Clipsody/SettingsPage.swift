import AppKit

/// One tab of the settings window: a grid of label + control rows, each with an explanation below.
@MainActor
final class SettingsPage {
    let title: String
    let symbol: String
    let grid = NSGridView()

    init(_ title: String, symbol: String) {
        self.title = title
        self.symbol = symbol
        grid.columnSpacing = 14
        grid.rowSpacing = 16
    }

    /// Adds a row; `anchor` is the control the label's baseline lines up with. Returns the label.
    @discardableResult
    func row(_ title: String, _ control: NSView, alignWith anchor: NSView, help: String) -> NSTextField {
        let label = NSTextField(labelWithString: title)
        // VoiceOver names the control after its label and reads the explanation as help.
        anchor.setAccessibilityTitleUIElement(label)
        anchor.setAccessibilityHelp(help)
        let stack = NSStackView(views: [control, Self.helpLabel(help)])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 5
        let gridRow = grid.addRow(with: [label, stack])
        gridRow.yPlacement = .top
        label.firstBaselineAnchor.constraint(equalTo: anchor.firstBaselineAnchor).isActive = true
        return label
    }

    /// A row whose content is not one control (e.g. a list with buttons); the label sits at the top.
    func row(_ title: String, content: NSView) {
        grid.addRow(with: [NSTextField(labelWithString: title), content]).yPlacement = .top
    }

    static func helpLabel(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        label.preferredMaxLayoutWidth = 480
        return label
    }

    /// The tab's content: the grid with margins, `width` wide, as tall as the rows need.
    func tabViewItem(width: CGFloat) -> NSTabViewItem {
        // Columns only exist once rows were added.
        grid.column(at: 0).xPlacement = .trailing
        grid.translatesAutoresizingMaskIntoConstraints = false
        let view = NSView()
        view.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: view.topAnchor, constant: 20),
            grid.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            grid.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -20),
            view.widthAnchor.constraint(equalToConstant: width + 48),
        ])
        let controller = NSViewController()
        controller.view = view
        controller.title = title
        controller.preferredContentSize = view.fittingSize
        let item = NSTabViewItem(viewController: controller)
        item.label = title
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        return item
    }
}
