import AppKit

/// The menu bar icon; with a dot when a newer version is available.
enum StatusIcon {
    static func image(badged: Bool) -> NSImage? {
        guard let symbol = NSImage(systemSymbolName: "list.clipboard", accessibilityDescription: "Clipsody") else { return nil }
        guard badged else { return symbol }
        // Drawn on demand, so the symbol takes the menu bar's current appearance (light, dark, tinted).
        let image = NSImage(size: symbol.size, flipped: false) { rect in
            symbol.draw(in: rect)
            NSColor.labelColor.set()
            rect.fill(using: .sourceAtop)
            let diameter = rect.width * 0.4
            NSColor.systemRed.setFill()
            NSBezierPath(ovalIn: NSRect(x: rect.maxX - diameter, y: rect.maxY - diameter,
                                        width: diameter, height: diameter)).fill()
            return true
        }
        image.accessibilityDescription = String(localized: "Clipsody, update available")
        return image
    }
}
