import Foundation
import PencilKit

/// Helpers for syncing PKDrawing data
public extension PKDrawing {
    /// Convert PKDrawing to data for transmission
    func toSyncData() -> Data {
        return self.dataRepresentation()
    }

    /// Create PKDrawing from sync data
    static func fromSyncData(_ data: Data) throws -> PKDrawing {
        return try PKDrawing(data: data)
    }
}

/// Simplified sync message for PKDrawing
/// Instead of individual strokes, we'll sync the entire drawing for now
public struct DrawingSyncMessage: Codable {
    public let drawingData: Data
    public let timestamp: Date

    public init(drawing: PKDrawing) {
        self.drawingData = drawing.dataRepresentation()
        self.timestamp = Date()
    }

    public func toDrawing() throws -> PKDrawing {
        return try PKDrawing(data: drawingData)
    }
}
