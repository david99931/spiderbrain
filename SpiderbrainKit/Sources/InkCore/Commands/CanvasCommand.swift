import Foundation

/// A requested mutation to the canvas.
///
/// One command per *logical* operation, not per collection touched. Merging nodes
/// deletes strokes, deletes nodes, creates a node and rewires connections — that is
/// one `mergeNodes`, applied atomically, rather than a burst of smaller commands a
/// peer could observe half-finished.
///
/// Commands are data: loggable, replayable, and testable without a view, a GPU, or
/// a network.
public enum CanvasCommand: Equatable {

    // MARK: - Strokes

    /// Add a stroke. Ignored if a stroke with the same id is already present.
    case addStroke(Stroke)

    /// Delete strokes by id. Ids that aren't present are ignored.
    case deleteStrokes(ids: [UUID])

    /// Remove the most recently added stroke. No-op when there are none.
    case removeLastStroke

    /// Remove every stroke, node and connection.
    case clearCanvas

    // MARK: - Nodes

    /// Create a node, optionally consuming canvas strokes it now contains.
    ///
    /// The strokes move into the node in one step, so a peer never sees them
    /// both loose on the canvas and inside the node.
    case createNode(Node, consumingStrokes: [UUID])

    /// Replace a node wholesale: drag, resize, absorbed strokes, recognized text.
    /// Ignored if no node with that id exists.
    case updateNode(Node)

    /// Delete a node.
    ///
    /// - Parameter returningStrokes: when true the node's strokes are returned to
    ///   the canvas rather than discarded. Connections touching the node are always
    ///   removed, since an edge to a missing node cannot be drawn.
    case deleteNode(id: UUID, returningStrokes: Bool)

    /// Absorb several nodes into a new merged node, consuming canvas strokes.
    ///
    /// Connections are rewired by the executor: edges that pointed into or out of
    /// an absorbed node are re-pointed at the merged node, and edges between two
    /// absorbed nodes disappear along with them.
    case mergeNodes(absorbing: [UUID], into: Node, consumingStrokes: [UUID])

    // MARK: - Connections

    /// Connect one node to another. Rejects self-loops and duplicates, and
    /// requires both endpoints to exist.
    case connect(from: UUID, to: UUID)

    /// Remove a connection by id. Ignored if not present.
    case disconnect(id: UUID)
}
