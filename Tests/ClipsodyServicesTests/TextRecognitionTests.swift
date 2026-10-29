import Foundation
import Testing
@testable import ClipsodyDecoderKit

/// Vision itself, without XPC in between: if recognition fails, the test reports Vision's error,
/// which the service only logs (e.g. when a new macOS changes the text recognition).
@Suite struct TextRecognitionTests {
    @Test func visionReadsTextInProcess() throws {
        let png = try #require(ImageCodec.prepare(makeImage(text: "Clipsody 4711", width: 700, height: 120))).png
        do {
            let lines = try ClipsodyDecoderKit.Decoder.recognizedLines(inPNG: png)
            #expect(lines.joined(separator: " ").contains("4711"), "recognised: \(lines)")
        } catch {
            Issue.record("Vision failed: \(String(describing: error))")
        }
    }
}
