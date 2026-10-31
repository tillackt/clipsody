import AppKit
import ClipsodyCore

/// The list of entries.
extension PanelController {
    func numberOfRows(in tableView: NSTableView) -> Int {
        items.count
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let id = NSUserInterfaceItemIdentifier("row")
        if let reused = tableView.makeView(withIdentifier: id, owner: nil) as? EmphasizedRowView { return reused }
        let rowView = EmphasizedRowView()
        rowView.identifier = id
        return rowView
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("clip")
        let cell = tableView.makeView(withIdentifier: id, owner: nil) as? ClipRowView ?? ClipRowView(identifier: id)
        let item = items[row]
        let text = ItemPresentation.title(for: item, query: query)
        cell.setTitle(text, highlights: query.ranges(in: text))
        cell.icon.image = icon(for: item)
        cell.pin.isHidden = !(item.pinned && list.section == .history)
        cell.shortcut.stringValue = row < 9 ? "⌘\(row + 1)" : ""
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        updatePreview()
    }

    /// Icon of the app the entry was copied from; for files the icon of the (first) file.
    func icon(for item: ClipItem) -> NSImage? {
        if item.kind == .files {
            guard let path = item.filePaths.first else { return nil }
            if let cached = iconCache.object(forKey: path as NSString) { return cached }
            // Checking a file on a disconnected network volume can block for seconds.
            let reachable = !path.hasPrefix("/Volumes/") && FileManager.default.fileExists(atPath: path)
            let icon = reachable ? NSWorkspace.shared.icon(forFile: path)
                                 : NSImage(systemSymbolName: "doc", accessibilityDescription: nil)!
            iconCache.setObject(icon, forKey: path as NSString)
            return icon
        }
        let key = item.appPath ?? ""
        if let cached = iconCache.object(forKey: (key + "#\(item.kind.rawValue)") as NSString) { return cached }

        let image: NSImage
        if let path = item.appPath, FileManager.default.fileExists(atPath: path) {
            image = NSWorkspace.shared.icon(forFile: path)
        } else {
            image = NSImage(systemSymbolName: item.kind == .image ? "photo" : "doc.text", accessibilityDescription: nil)!
        }
        // Cached either way, so a missing app is not looked up again for every row.
        iconCache.setObject(image, forKey: (key + "#\(item.kind.rawValue)") as NSString)
        return image
    }
}
