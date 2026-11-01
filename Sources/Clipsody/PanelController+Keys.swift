import AppKit
import Carbon

/// The panel's keyboard: the search field keeps the focus, so arrows, ⏎, ⇥ and the ⌘ shortcuts
/// arrive here.
extension PanelController {
    /// → at the end of the search text opens the next tab, ← at its start the previous one;
    /// anywhere else the arrows move the cursor as usual.
    func switchSection(by key: Selector, in textView: NSTextView) -> Bool {
        // A pending dead key or input method composition gets the arrows, not the tabs.
        let cursor = textView.selectedRange()
        guard cursor.length == 0, !textView.hasMarkedText() else { return false }
        if key == #selector(NSResponder.moveRight(_:)), cursor.location == textView.string.utf16.count,
           let next = tab.next {
            show(next)
            return true
        }
        if key == #selector(NSResponder.moveLeft(_:)), cursor.location == 0, let previous = tab.previous {
            show(previous)
            return true
        }
        return false
    }

    func handleKeyEquivalent(_ event: NSEvent) -> Bool {
        // Only the four modifier keys count, so Caps Lock does not break the shortcuts.
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        guard flags == .command else { return false }
        // ⌘N creates a snippet from any tab
        if event.keyCode == UInt16(kVK_ANSI_N) {
            newSnippet()
            return true
        }
        // While a snippet is edited, ⌘⌫, ⌘P and ⌘1 … ⌘9 belong to the text field.
        guard !isEditingSnippet else { return false }
        // ⌘⌫ deletes the selected entry
        if event.keyCode == UInt16(kVK_Delete) {
            deleteSelected()
            return true
        }
        // ⌘P pins or unpins the selected entry
        if event.keyCode == UInt16(kVK_ANSI_P) {
            togglePinSelected()
            return true
        }
        // ⌘1 … ⌘9 paste the n-th visible entry
        if let chars = event.charactersIgnoringModifiers, let digit = Int(chars), (1...9).contains(digit) {
            guard tab != .snippets || digit <= snippetRows.count else {
                NSSound.beep()
                return true
            }
            paste(at: digit - 1)
            return true
        }
        return false
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveLeft(_:)), #selector(NSResponder.moveRight(_:)):
            return switchSection(by: selector, in: textView)
        case #selector(NSResponder.insertTab(_:)): show(tab.next ?? .history)
        case #selector(NSResponder.insertBacktab(_:)): show(tab.previous ?? .snippets)
        case #selector(NSResponder.moveUp(_:)): move(by: -1)
        case #selector(NSResponder.moveDown(_:)): move(by: 1)
        case #selector(NSResponder.scrollPageUp(_:)), #selector(NSResponder.pageUp(_:)): move(by: -10)
        case #selector(NSResponder.scrollPageDown(_:)), #selector(NSResponder.pageDown(_:)): move(by: 10)
        case #selector(NSResponder.insertNewline(_:)): pasteSelected()
        // ⌥⏎ arrives as "insert newline ignoring field editor" and pastes plain text
        case #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)): pasteSelected(withFormatting: false)
        case #selector(NSResponder.cancelOperation(_:)): hide()
        default: return false
        }
        return true
    }

}
