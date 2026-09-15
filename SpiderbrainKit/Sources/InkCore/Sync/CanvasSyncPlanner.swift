import Foundation

/// Turns local effects into an ordered list of announcements for peers.
///
/// Exists because ordering is a protocol rule, not a rendering detail. A peer
/// applies a connection only when both endpoints already exist, and nothing
/// retries a rejected edge — so any announcement naming a node must follow that
/// node's own announcement. Getting this wrong drops arrows silently on the
/// receiving device while the sending device looks perfectly correct, which is
/// exactly the failure this type exists to prevent.
///
/// Pure and Foundation-only, so the ordering rule can be tested without a view,
/// a GPU, or a network.
public enum CanvasSyncPlanner {

    /// Produce the announcements for a set of effects, in an order any peer can
    /// apply top to bottom without dropping anything.
    ///
    /// The ordering contract, in three parts:
    ///
    /// 1. **Removals first.** Deleting before creating keeps a peer from briefly
    ///    holding both an absorbed node and the node that replaced it.
    /// 2. **Nodes before edges.** An edge naming a node the peer has not seen is
    ///    rejected on arrival and never retried.
    /// 3. **Stroke consumption travels with its node**, so strokes are never
    ///    visible both loose and inside a node.
    public static func plan(for effects: [CanvasEffect]) -> [SyncIntent] {
        // A cleared canvas makes every other announcement meaningless.
        if effects.contains(.canvasCleared) {
            return []
        }

        var removals: [SyncIntent] = []
        var nodeAnnouncements: [SyncIntent] = []
        var edgeAnnouncements: [SyncIntent] = []
        var strokeAdditions: [SyncIntent] = []

        // Strokes consumed by a node creation travel with that node rather than as
        // standalone deletions. Scanned in two independent passes: the executor is
        // free to emit the removal before or after the creation, so a single
        // ordered walk would miss the pairing depending on which came first.
        let createdNodes = effects.compactMap { effect -> Node? in
            if case .nodeCreated(let node) = effect { return node }
            return nil
        }
        let removedStrokeIds = effects.flatMap { effect -> [UUID] in
            if case .strokesRemoved(let ids) = effect { return ids }
            return []
        }
        let foldsStrokesIntoNode = createdNodes.count == 1 && !removedStrokeIds.isEmpty
        let consumedStrokeIds = foldsStrokesIntoNode ? removedStrokeIds : []

        for effect in effects {
            switch effect {
            case .strokeAdded(let stroke):
                strokeAdditions.append(.strokeAdded(stroke))

            case .strokesRemoved(let ids):
                // Folded into the node announcement when a node consumed them.
                guard !foldsStrokesIntoNode else { continue }
                removals.append(contentsOf: ids.map { .strokeDeleted(id: $0) })

            case .nodesRemoved(let ids):
                removals.append(contentsOf: ids.map { .nodeDeleted(id: $0) })

            case .connectionsRemoved(let ids):
                removals.append(contentsOf: ids.map { .connectionDeleted(id: $0) })

            case .nodeCreated(let node):
                if foldsStrokesIntoNode {
                    nodeAnnouncements.append(
                        .nodeCreatedConsumingStrokes(node: node, deletedStrokeIds: consumedStrokeIds)
                    )
                } else {
                    nodeAnnouncements.append(.nodeCreated(node))
                }

            case .nodeUpdated(let node):
                nodeAnnouncements.append(.nodeUpdated(node))

            case .connectionAdded(let connection):
                edgeAnnouncements.append(.connectionCreated(connection))

            case .canvasCleared:
                continue  // handled above
            }
        }

        // Removals, then strokes and nodes, then the edges that reference them.
        return removals + strokeAdditions + nodeAnnouncements + edgeAnnouncements
    }
}
