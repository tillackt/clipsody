import Foundation
import Vision

/// On-device text recognition (Vision) so screenshots can be found by the words they contain.
enum TextRecognizer {
    /// Recognised lines joined by newlines; nil if the image could not be read.
    static func recognize(imageAt url: URL) async -> String? {
        await Task.detached(priority: .utility) {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.recognitionLanguages = ["de-DE", "en-US"]
            request.usesLanguageCorrection = true
            do {
                try VNImageRequestHandler(url: url).perform([request])
            } catch {
                return nil
            }
            let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
            return lines.joined(separator: "\n")
        }.value
    }
}
