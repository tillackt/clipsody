import CoreGraphics
import Foundation
import ImageIO
import SQLite3
import UniformTypeIdentifiers

/// A fresh temporary directory per test, removed when the value goes away.
final class TemporaryDirectory {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("ClippboardTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }
}

/// Runs raw SQL against a database file, for building fixtures such as old schemas.
func sqlite(_ path: String, _ sql: String) {
    var db: OpaquePointer?
    sqlite3_open(path, &db)
    defer { sqlite3_close(db) }
    var error: UnsafeMutablePointer<CChar>?
    if sqlite3_exec(db, sql, nil, nil, &error) != SQLITE_OK {
        fatalError("Fixture SQL failed: \(String(cString: error!))")
    }
}

/// A small RGBA test image with distinct pixels, encoded as `type` with the given DPI.
func makeImage(width: Int = 12, height: Int = 7, type: UTType = .tiff, dpi: Double = 144) -> Data {
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    for x in 0..<width {
        for y in 0..<height {
            context.setFillColor(red: CGFloat(x) / CGFloat(width), green: CGFloat(y) / CGFloat(height), blue: 0.5, alpha: 1)
            context.fill(CGRect(x: x, y: y, width: 1, height: 1))
        }
    }
    let output = NSMutableData()
    let destination = CGImageDestinationCreateWithData(output, type.identifier as CFString, 1, nil)!
    let properties = [kCGImagePropertyDPIWidth: dpi, kCGImagePropertyDPIHeight: dpi] as CFDictionary
    CGImageDestinationAddImage(destination, context.makeImage()!, properties)
    CGImageDestinationFinalize(destination)
    return output as Data
}

/// Pixels of an encoded image, redrawn into 8-bit sRGB so different file formats compare equal.
func pixels(of data: Data) -> [UInt8] {
    let source = CGImageSourceCreateWithData(data as CFData, nil)!
    let image = CGImageSourceCreateImageAtIndex(source, 0, nil)!
    var buffer = [UInt8](repeating: 0, count: image.width * image.height * 4)
    let context = CGContext(data: &buffer, width: image.width, height: image.height, bitsPerComponent: 8,
                            bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    return buffer
}

func imageProperties(of data: Data) -> [CFString: Any] {
    let source = CGImageSourceCreateWithData(data as CFData, nil)!
    return CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as! [CFString: Any]
}
