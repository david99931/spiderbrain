import Foundation

/// A single announcement to send to peers.
///
/// Intents are the wire-level vocabulary, one step removed from effects: an effect
/// says what changed locally, an intent says what to tell everyone else. They are
/// separate because the two differ in both content and order — a local merge
/// produces its effects in whatever sequence is convenient, while peers require
/// nodes to arrive before the edges that reference them.
public enum SyncIntent: Equatable {
    case strokeAdded(Stroke)
    case strokeDeleted(id: UUID)

    case nodeCreated(Node)

    /// A node whose creation consumed canvas strokes, announced together so a peer
    /// never sees the strokes both loose and inside the node.
    case nodeCreatedConsumingStrokes(node: Node, deletedStrokeIds: [UUID])

    case nodeUpdated(Node)
    case nodeDeleted(id: UUID)

    case connectionCreated(Connection)
    case connectionDeleted(id: UUID)

    /// Wipe everything. Sent alone: no other announcement means anything once the
    /// canvas is gone.
    case canvasCleared
}
