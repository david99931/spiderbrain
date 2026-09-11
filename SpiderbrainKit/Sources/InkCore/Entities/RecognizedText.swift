import Foundation

/// Recognized text from handwriting recognition with metadata
public struct RecognizedText: Equatable, Codable {
    public let text: String
    public let confidence: Float
    public let source: RecognitionSourceData
    public let timestamp: Date

    public init(
        text: String,
        confidence: Float,
        source: RecognitionSourceData,
        timestamp: Date = Date()
    ) {
        self.text = text
        self.confidence = confidence
        self.source = source
        self.timestamp = timestamp
    }

    /// Source of the recognition result
    public enum RecognitionSourceData: Equatable, Codable {
        case vision(confidence: Float)
        case customModel(confidence: Float)
        case correctionHistory(matchConfidence: Float)
    }
}
