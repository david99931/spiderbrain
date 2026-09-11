import Foundation
import UIKit

/// A correction made by the user - stores the training data for ML
public struct CorrectionSample: Identifiable, Codable {
    public let id: UUID
    public let nodeId: UUID
    public let timestamp: Date

    // Recognition data
    public let visionResult: String
    public let visionConfidence: Float
    public let userCorrection: String

    // Training data - stored as PNG data for Codable compliance
    public let strokeImageData: Data
    public let strokeCount: Int
    public let boundsWidth: Double
    public let boundsHeight: Double

    // Metadata for training
    public var usedForTraining: Bool
    public var trainingModelVersion: Int?

    public init(
        id: UUID = UUID(),
        nodeId: UUID,
        timestamp: Date = Date(),
        visionResult: String,
        visionConfidence: Float,
        userCorrection: String,
        strokeImage: UIImage,
        strokeCount: Int,
        boundsWidth: Double,
        boundsHeight: Double,
        usedForTraining: Bool = false,
        trainingModelVersion: Int? = nil
    ) {
        self.id = id
        self.nodeId = nodeId
        self.timestamp = timestamp
        self.visionResult = visionResult
        self.visionConfidence = visionConfidence
        self.userCorrection = userCorrection
        self.strokeImageData = strokeImage.pngData() ?? Data()
        self.strokeCount = strokeCount
        self.boundsWidth = boundsWidth
        self.boundsHeight = boundsHeight
        self.usedForTraining = usedForTraining
        self.trainingModelVersion = trainingModelVersion
    }

    /// Decode stored image
    public var strokeImage: UIImage? {
        UIImage(data: strokeImageData)
    }
}
