import Vision
import UIKit
import Foundation

/// Service for recognizing handwritten text from strokes using Vision Framework
public class TextRecognitionService {

    /// Result of text recognition
    public enum RecognitionResult {
        case success(text: String, confidence: Float, source: RecognitionSource)
        case failure(Error)
    }

    /// Source of the recognition result
    public enum RecognitionSource: Equatable {
        case vision(confidence: Float)
        case customModel(confidence: Float)
        case correctionHistory(matchConfidence: Float)
    }

    /// Errors that can occur during recognition
    public enum RecognitionError: Error {
        case noTextFound
        case imageCreationFailed
        case visionRequestFailed
    }

    private let correctionStorage = CorrectionStorageManager()

    public init() {}

    /// Recognize text from a node's strokes using Apple's Vision Framework
    /// - Parameter node: The node containing strokes to recognize
    /// - Returns: Recognition result with text, confidence, and source
    public func recognizeText(from node: Node) async -> RecognitionResult {
        // Convert strokes to image
        let image = StrokeImageRenderer.render(
            strokes: node.strokes,
            bounds: node.bounds
        )

        // Run Vision recognition
        guard let visionResult = await runVisionRecognition(image) else {
            return .failure(RecognitionError.noTextFound)
        }

        // Check if this Vision result has been corrected before
        if let correction = correctionStorage.findCorrection(for: visionResult.text) {
            // User has corrected this before - use their correction
            return .success(
                text: correction,
                confidence: 1.0, // User correction is 100% confident
                source: .correctionHistory(matchConfidence: 1.0)
            )
        }

        // No correction history - return Vision result
        return .success(
            text: visionResult.text,
            confidence: visionResult.confidence,
            source: .vision(confidence: visionResult.confidence)
        )
    }

    /// Run Vision Framework text recognition on an image
    /// - Parameter image: The image to recognize text from
    /// - Returns: Tuple of recognized text and confidence, or nil if no text found
    private func runVisionRecognition(_ image: UIImage) async -> (text: String, confidence: Float)? {
        guard let cgImage = image.cgImage else {
            return nil
        }

        // Create text recognition request
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate  // Use accurate mode for handwriting
        request.usesLanguageCorrection = true  // Enable language correction
        request.recognitionLanguages = ["en-US"]  // Start with English

        // Create request handler
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])

        do {
            // Perform request
            try handler.perform([request])

            // Get results
            guard let observations = request.results,
                  !observations.isEmpty else {
                return nil
            }

            // Collect all recognized text from all observations
            var allText: [String] = []
            var confidences: [Float] = []

            for observation in observations {
                guard let topCandidate = observation.topCandidates(1).first else {
                    continue
                }

                allText.append(topCandidate.string)
                confidences.append(topCandidate.confidence)
            }

            guard !allText.isEmpty else { return nil }

            // Combine all text with spaces
            let combinedText = allText.joined(separator: " ")

            // Average confidence across all observations
            let averageConfidence = confidences.reduce(0, +) / Float(confidences.count)

            return (text: combinedText, confidence: averageConfidence)

        } catch {
            print("Vision recognition failed: \(error)")
            return nil
        }
    }
}
