// Renders the app icon (Resources/AppIcon.icns) from website/assets/logo.svg and the background of
// the disk image (Resources/dmg/background.png, 1x and 2x in one TIFF would need Finder tricks; a
// 2x PNG with 144 dpi is shown at the right size). Run after changing the logo:
//   swift .github/scripts/app-artwork.swift
import AppKit

let root = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
guard let logo = NSImage(contentsOf: root.appendingPathComponent("website/assets/logo.svg")) else {
    fatalError("website/assets/logo.svg could not be loaded")
}

func render(width: Int, height: Int, scale: CGFloat = 1, draw: (NSRect) -> Void) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: CGFloat(width) / scale, height: CGFloat(height) / scale)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    draw(NSRect(origin: .zero, size: rep.size))
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

// App icon: the logo's rounded square (56 of 64 units) fills Apple's 824 of 1024 icon grid, with the
// soft shadow macOS icons have.
func icon(pixels: Int) -> NSBitmapImageRep {
    render(width: pixels, height: pixels) { rect in
        let unit = rect.width / 1024
        let side = 824 * unit * 64 / 56
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
        shadow.shadowBlurRadius = 18 * unit
        shadow.shadowOffset = NSSize(width: 0, height: -8 * unit)
        shadow.set()
        logo.draw(in: NSRect(x: (rect.width - side) / 2, y: (rect.height - side) / 2 + 6 * unit, width: side, height: side))
    }
}

let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon-\(UUID().uuidString).iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
        try icon(pixels: points * scale).representation(using: .png, properties: [:])!
            .write(to: iconset.appendingPathComponent(name))
    }
}
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", root.appendingPathComponent("Resources/AppIcon.icns").path]
try iconutil.run()
iconutil.waitUntilExit()
try? FileManager.default.removeItem(at: iconset)
guard iconutil.terminationStatus == 0 else { fatalError("iconutil failed") }
print("wrote Resources/AppIcon.icns")

// Disk image window, 600 × 380 points: app on the left, Applications on the right (positions in
// .github/scripts/dmg-layout.sh), an arrow between them and one line of text.
let background = render(width: 1200, height: 760, scale: 2) { rect in
    NSColor(calibratedRed: 0.965, green: 0.972, blue: 0.985, alpha: 1).setFill()
    rect.fill()
    let arrow = NSBezierPath()
    let centerY: CGFloat = rect.height - 175
    arrow.move(to: NSPoint(x: 245, y: centerY))
    arrow.line(to: NSPoint(x: 345, y: centerY))
    arrow.lineWidth = 6
    arrow.lineCapStyle = .round
    let head = NSBezierPath()
    head.move(to: NSPoint(x: 330, y: centerY + 16))
    head.line(to: NSPoint(x: 352, y: centerY))
    head.line(to: NSPoint(x: 330, y: centerY - 16))
    head.lineWidth = 6
    head.lineCapStyle = .round
    head.lineJoinStyle = .round
    NSColor(calibratedRed: 0.04, green: 0.35, blue: 0.82, alpha: 1).setStroke()
    arrow.stroke()
    head.stroke()
    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = .center
    let text = NSAttributedString(string: "Drag Clipsody to Applications", attributes: [
        .font: NSFont.systemFont(ofSize: 15, weight: .medium),
        .foregroundColor: NSColor(calibratedWhite: 0.25, alpha: 1),
        .paragraphStyle: paragraph,
    ])
    text.draw(in: NSRect(x: 0, y: 78, width: rect.width, height: 24))
    // Finder cannot replace an app that is running; updates from Clipsody 1.4 on install themselves.
    let hint = NSAttributedString(string: "Updating? Quit Clipsody first (menu bar icon → Quit).", attributes: [
        .font: NSFont.systemFont(ofSize: 12),
        .foregroundColor: NSColor(calibratedWhite: 0.45, alpha: 1),
        .paragraphStyle: paragraph,
    ])
    hint.draw(in: NSRect(x: 0, y: 54, width: rect.width, height: 20))
}
let dmgFolder = root.appendingPathComponent("Resources/dmg")
try FileManager.default.createDirectory(at: dmgFolder, withIntermediateDirectories: true)
try background.representation(using: .png, properties: [:])!.write(to: dmgFolder.appendingPathComponent("background.png"))
print("wrote Resources/dmg/background.png")
