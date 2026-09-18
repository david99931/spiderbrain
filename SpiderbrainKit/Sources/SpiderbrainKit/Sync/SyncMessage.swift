import Foundation

/// Messages sent between peers for synchronization
public enum SyncMessage: Codable {
    case strokeAdded(Stroke)
    case strokeDeleted(id: UUID)

    case nodeCreated(Node)
    case nodeCreatedWithStrokeDeletions(node: Node, deletedStrokeIds: [UUID])
    case nodeUpdated(Node)
    case nodeDeleted(id: UUID)

    case connectionCreated(Connection)
    case connectionDeleted(id: UUID)

    /// Wipe the whole canvas. One message rather than hundreds of individual
    /// deletions, so a peer can never end up half-cleared.
    case canvasCleared

    case correctionApplied(CorrectionData)

    case fullSync([Stroke])
    case requestFullSync
}

/// Serialized node data for transmission
public struct NodeData: Codable {
    public let id: UUID
    public let position: CGPoint
    public let content: String
    public let timestamp: Date

    public init(id: UUID, position: CGPoint, content: String, timestamp: Date) {
        self.id = id
        self.position = position
        self.content = content
        self.timestamp = timestamp
    }
}

/// Correction data from ML model
public struct CorrectionData: Codable {
    public let strokeId: UUID
    public let correctedText: String
    public let confidence: Double
    public let timestamp: Date

    public init(strokeId: UUID, correctedText: String, confidence: Double, timestamp: Date) {
        self.strokeId = strokeId
        self.correctedText = correctedText
        self.confidence = confidence
        self.timestamp = timestamp
    }
}

/// Full canvas state for initial sync
public struct CanvasState: Codable {
    public let strokes: [Stroke]
    public let nodes: [NodeData]
    public let corrections: [UUID: String] // strokeId -> correctedText

    public init(strokes: [Stroke], nodes: [NodeData], corrections: [UUID: String]) {
        self.strokes = strokes
        self.nodes = nodes
        self.corrections = corrections
    }
}

/// Helper for encoding/decoding sync messages
public extension SyncMessage {
    func encode() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }

    static func decode(from data: Data) throws -> SyncMessage {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(SyncMessage.self, from: data)
    }
}
