import Foundation
import Vision

/// On-device text recognition for screenshots (Vision). Nothing leaves the device until the person
/// taps Check.
public enum TextRecognizer {
    public static func recognize(imageData: Data) async throws -> String {
        var request = RecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        let observations = try await request.perform(on: imageData)
        return observations
            .compactMap { $0.topCandidates(1).first?.string }
            .joined(separator: "\n")
    }
}
