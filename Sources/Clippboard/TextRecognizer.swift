import Foundation
import Vision

/// On-device text recognition (Vision) so screenshots can be found by the words they contain.
enum TextRecognizer {
    static func recognize(imageAt url: URL, completion: @escaping (String) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.recognitionLanguages = ["de-DE", "en-US"]
            request.usesLanguageCorrection = true
            try? VNImageRequestHandler(url: url).perform([request])
            let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
            let text = lines.joined(separator: "\n")
            DispatchQueue.main.async { completion(text) }
        }
    }
}
