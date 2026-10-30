// Renders the website's social preview images (1200×630) and the Apple touch icon from the logo.
// Run after changing the logo or the texts: swift .github/scripts/website-images.swift
import AppKit

let assets = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("website/assets")

guard let logo = NSImage(contentsOf: assets.appendingPathComponent("logo.svg")) else {
    fatalError("logo.svg could not be loaded")
}

func png(width: Int, height: Int, draw: (NSRect) -> Void) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    draw(NSRect(x: 0, y: 0, width: width, height: height))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

func text(_ string: String, size: CGFloat, weight: NSFont.Weight, color: NSColor, in rect: NSRect) {
    let style = NSMutableParagraphStyle()
    style.lineHeightMultiple = 1.05
    let attributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color, .paragraphStyle: style,
    ]
    NSAttributedString(string: string, attributes: attributes)
        .draw(with: rect, options: [.usesLineFragmentOrigin, .usesFontLeading])
}

func preview(title: String, subtitle: String, footer: String) -> Data {
    png(width: 1200, height: 630) { rect in
        NSGradient(starting: NSColor(srgbRed: 0.97, green: 0.98, blue: 1, alpha: 1),
                   ending: NSColor(srgbRed: 0.86, green: 0.91, blue: 1, alpha: 1))!.draw(in: rect, angle: -60)
        logo.draw(in: NSRect(x: 80, y: 410, width: 140, height: 140))
        text("Clipsody", size: 44, weight: .semibold, color: NSColor(srgbRed: 0.04, green: 0.35, blue: 0.82, alpha: 1),
             in: NSRect(x: 245, y: 445, width: 800, height: 70))
        text(title, size: 66, weight: .bold, color: NSColor(srgbRed: 0.11, green: 0.11, blue: 0.12, alpha: 1),
             in: NSRect(x: 80, y: 175, width: 1040, height: 210))
        text(subtitle, size: 30, weight: .regular, color: NSColor(srgbRed: 0.37, green: 0.39, blue: 0.41, alpha: 1),
             in: NSRect(x: 80, y: 95, width: 1040, height: 80))
        text(footer, size: 24, weight: .medium, color: NSColor(srgbRed: 0.04, green: 0.35, blue: 0.82, alpha: 1),
             in: NSRect(x: 80, y: 40, width: 1040, height: 40))
    }
}

let images: [(String, Data)] = [
    ("og-de.png", preview(title: "Die Zwischenablage mit Gedächtnis für deinen Mac",
                          subtitle: "Alle kopierten Texte, Bilder und Dateien – durchsuchbar, per ⌥⌘C.",
                          footer: "Kostenlos · Open Source · alles bleibt auf deinem Mac")),
    ("og-en.png", preview(title: "The clipboard with a memory for your Mac",
                          subtitle: "Every text, image and file you copy – searchable, with ⌥⌘C.",
                          footer: "Free · Open source · everything stays on your Mac")),
    ("icon-180.png", png(width: 180, height: 180) { rect in
        NSColor.white.setFill()
        rect.fill()
        logo.draw(in: rect)
    }),
]
for (name, data) in images {
    try data.write(to: assets.appendingPathComponent(name))
    print("wrote website/assets/\(name) (\(data.count / 1024) KB)")
}
