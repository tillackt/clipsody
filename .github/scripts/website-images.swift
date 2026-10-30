// Renders the website's images: the social preview image per language (1200×630 JPEG, texts from
// site/content/<lang>.json), the Apple touch icon, and the hero photo (cropped to the 2:1 box it is
// shown in, as AVIF plus a JPEG fallback). Run after changing the logo, the photo or the texts:
//     swift .github/scripts/website-images.swift
import AppKit
import ImageIO
import UniformTypeIdentifiers

let root = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
let assets = root.appendingPathComponent("website/assets")
let content = root.appendingPathComponent("site/content")

guard let logo = NSImage(contentsOf: assets.appendingPathComponent("logo.svg")) else {
    fatalError("logo.svg could not be loaded")
}

func bitmap(width: Int, height: Int, draw: (NSRect) -> Void) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    draw(NSRect(x: 0, y: 0, width: width, height: height))
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

/// Encodes with ImageIO, which (unlike NSBitmapImageRep) also writes AVIF with a quality setting.
func encode(_ image: CGImage, as type: UTType, quality: Double) -> Data {
    let data = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else {
        fatalError("cannot write \(type.identifier)")
    }
    CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
    guard CGImageDestinationFinalize(destination) else { fatalError("encoding \(type.identifier) failed") }
    return data as Data
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

let blue = NSColor(srgbRed: 0.04, green: 0.35, blue: 0.82, alpha: 1)

func preview(title: String, footer: String) -> CGImage {
    bitmap(width: 1200, height: 630) { rect in
        NSGradient(starting: NSColor(srgbRed: 0.97, green: 0.98, blue: 1, alpha: 1),
                   ending: NSColor(srgbRed: 0.86, green: 0.91, blue: 1, alpha: 1))!.draw(in: rect, angle: -60)
        logo.draw(in: NSRect(x: 80, y: 420, width: 130, height: 130))
        text("Clipsody", size: 44, weight: .semibold, color: blue, in: NSRect(x: 235, y: 452, width: 800, height: 70))
        text(title, size: 60, weight: .bold, color: NSColor(srgbRed: 0.11, green: 0.11, blue: 0.12, alpha: 1),
             in: NSRect(x: 80, y: 110, width: 1040, height: 280))
        text(footer, size: 26, weight: .medium, color: blue, in: NSRect(x: 80, y: 44, width: 1040, height: 44))
    }.cgImage!
}

// One preview image per language: the home page's H1 and its badges.
let languages = try FileManager.default.contentsOfDirectory(at: content, includingPropertiesForKeys: nil)
    .filter { $0.pathExtension == "json" }
for file in languages.sorted(by: { $0.path < $1.path }) {
    guard let json = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any],
          let code = json["lang"] as? String, let home = json["home"] as? [String: Any],
          let title = home["h1"] as? String, let badges = home["badges"] as? [String] else {
        fatalError("\(file.lastPathComponent): lang, home.h1 or home.badges missing")
    }
    let name = "og-\(code.lowercased()).jpg"
    try encode(preview(title: title, footer: badges.joined(separator: " · ")), as: .jpeg, quality: 0.82)
        .write(to: assets.appendingPathComponent(name))
    print("wrote website/assets/\(name)")
}

let icon = bitmap(width: 180, height: 180) { rect in
    NSColor.white.setFill()
    rect.fill()
    logo.draw(in: rect)
}
try icon.representation(using: .png, properties: [:])!.write(to: assets.appendingPathComponent("icon-180.png"))
print("wrote website/assets/icon-180.png")

// The hero photo is shown at most about 470×240 CSS pixels: crop it to 2:1 and keep 2× for Retina.
guard let source = NSImage(contentsOf: root.appendingPathComponent("site/images/hero-photo-source.jpg"))?
    .cgImage(forProposedRect: nil, context: nil, hints: nil) else { fatalError("hero photo missing") }
let cropHeight = source.width / 2
let crop = source.cropping(to: CGRect(x: 0, y: (source.height - cropHeight) / 2, width: source.width, height: cropHeight))!
let photo = bitmap(width: 940, height: 470) { rect in
    NSGraphicsContext.current?.imageInterpolation = .high
    NSGraphicsContext.current?.cgContext.draw(crop, in: rect)
}.cgImage!
try encode(photo, as: UTType("public.avif")!, quality: 0.55).write(to: assets.appendingPathComponent("sample-photo.avif"))
try encode(photo, as: .jpeg, quality: 0.72).write(to: assets.appendingPathComponent("sample-photo.jpg"))
print("wrote website/assets/sample-photo.avif and sample-photo.jpg")
