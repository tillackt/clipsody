import AppKit
import ClipsodyCore
import ClipsodyServices

/// The preview of the selected entry: text, image and the info line, and VoiceOver announcements.
extension PanelController {
    func updatePreview() {
        let row = table.selectedRow
        guard items.indices.contains(row) else {
            previewTextScroll.isHidden = true
            previewImage.isHidden = true
            infoLabel.stringValue = ""
            previewedItem = nil
            return
        }
        let item = items[row]
        guard item != previewedItem || query.terms != previewedTerms else { return }
        previewedItem = item
        previewedTerms = query.terms
        announceForVoiceOver(item)
        var info = [item.app ?? String(localized: "Unknown app"), dateFormatter.localizedString(for: item.date, relativeTo: Date())]
        if item.pinned { info.insert(String(localized: "Pinned"), at: 0) }
        switch item.kind {
        case .text:
            showPreviewText(item.text)
            let bytes = item.textByteCount
            if bytes > ItemPresentation.searchablePrefix {
                // Counting characters and lines of a multi-MB text would stall arrowing through the list.
                info.append(AppLocale.fileSize(Int64(bytes)))
            } else {
                let lines = item.text.split(whereSeparator: \.isNewline).count
                // Separate parts, joined by " · " like the rest of the line: no language-specific comma.
                info.append(String(localized: "\(item.text.count) characters"))
                if lines > 1 { info.append(String(localized: "\(lines) lines")) }
            }
            if item.hasRichText { info.append(String(localized: "with formatting")) }
        case .files:
            let paths = item.filePaths
            showPreviewText(paths.joined(separator: "\n"))
            // Paths on network volumes are not checked: a disconnected server blocks for seconds.
            let missing = paths.filter { !$0.hasPrefix("/Volumes/") && !FileManager.default.fileExists(atPath: $0) }.count
            info.append(String(localized: "\(paths.count) files"))
            if missing > 0 { info.append(String(localized: "\(missing) no longer available")) }
        case .image:
            previewTextScroll.isHidden = true
            previewImage.isHidden = false
            showPreviewImage(for: item)
            info.append(ItemPresentation.imageLabel(for: item))
            if let text = item.recognizedText, !text.isEmpty { info.append(String(localized: "Text recognized")) }
        }
        infoLabel.stringValue = info.joined(separator: " · ")
    }

    /// Shows a downscaled image, made by the decoder service as raw pixels (the app never decodes
    /// image formats) and cached, so holding ↓ over screenshots does not decode full-size images.
    private func showPreviewImage(for item: ClipItem) {
        previewTask?.cancel()
        // The small preview stored with large images; older entries fall back to the full image.
        guard let url = store.previewURL(for: item) ?? store.imageURL(for: item) else {
            previewImage.image = nil
            return
        }
        let key = url.lastPathComponent as NSString
        if let cached = previewCache.object(forKey: key) {
            previewImage.image = cached
            return
        }
        previewImage.image = nil
        let scale = panel.backingScaleFactor
        let maxPixelSize = Int(max(previewImage.bounds.width, previewImage.bounds.height, 400) * scale)
        previewTask = Task { [weak self, decoder] in
            // Holding ↓ over screenshots: only the image the selection rests on is decoded.
            try? await Task.sleep(for: .milliseconds(100))
            guard !Task.isCancelled else { return }
            // Reading a multi-MB file must not block the main thread.
            let png = await Task.detached(priority: .userInitiated) { try? Data(contentsOf: url) }.value
            guard let png, !Task.isCancelled,
                  let result = await decoder.thumbnail(ofPNG: png, maxPixelSize: maxPixelSize),
                  let self, !Task.isCancelled else { return }
            let thumbnail = NSImage(cgImage: result.image, size: result.pointSize)
            previewCache.setObject(thumbnail, forKey: key, cost: result.image.bytesPerRow * result.image.height)
            previewImage.image = thumbnail
        }
    }

    /// Focus stays in the search field, so VoiceOver would not notice the selection moving.
    private func announceForVoiceOver(_ item: ClipItem) {
        guard NSWorkspace.shared.isVoiceOverEnabled else { return }
        var parts = [ItemPresentation.title(for: item, query: query)]
        if item.pinned { parts.append(String(localized: "pinned")) }
        NSAccessibility.post(element: panel, notification: .announcementRequested, userInfo: [
            .announcement: parts.joined(separator: ", "),
            .priority: NSAccessibilityPriorityLevel.high.rawValue,
        ])
    }

    private func showPreviewText(_ text: String) {
        previewTextScroll.isHidden = false
        previewImage.isHidden = true
        let shown = String(text.prefix(ItemPresentation.searchablePrefix))
        let string = NSMutableAttributedString(string: shown, attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular), .foregroundColor: NSColor.labelColor,
        ])
        for range in query.ranges(in: shown) {
            string.addAttributes([.backgroundColor: NSColor.findHighlightColor, .foregroundColor: NSColor.black], range: range)
        }
        previewText.textStorage?.setAttributedString(string)
        if let first = query.ranges(in: shown).first {
            previewText.scrollRangeToVisible(first)
        } else {
            previewText.scrollToBeginningOfDocument(nil)
        }
    }
}
