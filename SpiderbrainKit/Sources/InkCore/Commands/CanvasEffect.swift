import Foundation

/// What actually changed when a command was applied.
///
/// The executor reports effects rather than performing side effects, so it stays
/// free of rendering and networking. Callers interpret: the view rebuilds geometry,
/// the sync layer broadcasts. Effects are only emitted for real changes, so a no-op
/// command yields none and callers can skip redundant work.
public enum CanvasEffect: Equatable {

    // MARK: - Strokes

    case strokeAdded(Stroke)
    case strokesRemoved(ids: [UUID])

    // MARK: - Nodes

    case nodeCreated(Node)
    case nodeUpdated(Node)
    case nodesRemoved(ids: [UUID])

    // MARK: - Connections

    case connectionAdded(Connection)
    case connectionsRemoved(ids: [UUID])

    // MARK: - Wholesale

    /// Everything was cleared; incremental updates don't apply.
    case canvasCleared
}
