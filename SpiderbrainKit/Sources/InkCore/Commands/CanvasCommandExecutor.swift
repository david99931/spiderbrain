import Foundation

/// Owns the canvas — strokes, nodes and connections — and is the only thing
/// permitted to mutate it.
///
/// One executor rather than three because the interesting operations span
/// collections. Merging nodes deletes strokes, deletes nodes, creates a node and
/// rewires connections; expressing that as separate per-type commands would let a
/// peer observe the canvas mid-merge. Here it is one command, one effect set, one
/// message.
///
/// Invariants that come for free:
///
/// - **No duplicates.** Adding a stroke, node or connection is idempotent by id.
/// - **No phantom removals.** Removal effects only name ids that were really there.
/// - **No dangling edges.** A connection cannot outlive either endpoint, and cannot
///   be created unless both endpoints exist.
///
/// Connections live in exactly one place: this executor's `connections`. A node
/// does not carry its own edge list, so the two cannot disagree.
public final class CanvasCommandExecutor {

    private var strokeStorage: [Stroke] = []
    private var nodeStorage: [Node] = []
    private var connectionStorage: [Connection] = []

    public init(
        strokes: [Stroke] = [],
        nodes: [Node] = [],
        connections: [Connection] = []
    ) {
        self.strokeStorage = strokes
        self.nodeStorage = nodes
        self.connectionStorage = connections
    }

    // MARK: - Reading

    public var strokes: [Stroke] { strokeStorage }
    public var nodes: [Node] { nodeStorage }
    public var connections: [Connection] { connectionStorage }

    public func stroke(withId id: UUID) -> Stroke? {
        strokeStorage.first { $0.id == id }
    }

    public func node(withId id: UUID) -> Node? {
        nodeStorage.first { $0.id == id }
    }

    public func connection(withId id: UUID) -> Connection? {
        connectionStorage.first { $0.id == id }
    }

    /// Edges leading out of a node.
    public func outgoingConnections(from nodeId: UUID) -> [Connection] {
        connectionStorage.filter { $0.from == nodeId }
    }

    /// Edges leading into a node.
    public func incomingConnections(to nodeId: UUID) -> [Connection] {
        connectionStorage.filter { $0.to == nodeId }
    }

    // MARK: - Executing

    /// Apply a command and report what changed.
    ///
    /// Returns an empty array when the command was a no-op.
    ///
    /// - Parameters:
    ///   - command: the mutation to apply.
    ///   - origin: whether this originated locally or arrived from a peer. Carried
    ///     with the command so callers can suppress echo without each call site
    ///     having to remember which path it is on.
    @discardableResult
    public func execute(_ command: CanvasCommand, origin: CommandOrigin) -> [CanvasEffect] {
        switch command {
        case .addStroke(let stroke):
            return addStroke(stroke)

        case .deleteStrokes(let ids):
            return removeStrokes(ids: ids)

        case .removeLastStroke:
            guard let last = strokeStorage.popLast() else { return [] }
            return [.strokesRemoved(ids: [last.id])]

        case .clearCanvas:
            guard !strokeStorage.isEmpty || !nodeStorage.isEmpty || !connectionStorage.isEmpty else {
                return []
            }
            strokeStorage.removeAll()
            nodeStorage.removeAll()
            connectionStorage.removeAll()
            return [.canvasCleared]

        case .createNode(let node, let consumedStrokeIds):
            return createNode(node, consumingStrokes: consumedStrokeIds)

        case .updateNode(let node):
            // No change-detection here: Node compares by id alone, so an equality
            // check would never see a moved or edited node.
            guard let index = nodeStorage.firstIndex(where: { $0.id == node.id }) else { return [] }
            nodeStorage[index] = node
            return [.nodeUpdated(node)]

        case .deleteNode(let id, let returningStrokes):
            return deleteNode(id: id, returningStrokes: returningStrokes)

        case .mergeNodes(let absorbedIds, let mergedNode, let consumedStrokeIds):
            return mergeNodes(
                absorbing: absorbedIds,
                into: mergedNode,
                consumingStrokes: consumedStrokeIds
            )

        case .connect(let sourceId, let targetId):
            return connect(from: sourceId, to: targetId)

        case .disconnect(let id):
            return removeConnections(ids: [id])
        }
    }

    /// Replace everything without emitting effects, for bulk load and full sync.
    public func replaceAll(strokes: [Stroke], nodes: [Node], connections: [Connection]) {
        strokeStorage = strokes
        nodeStorage = nodes
        // Drop any edge whose endpoints aren't present, so a malformed payload
        // can't seed dangling connections.
        let ids = Set(nodes.map(\.id))
        connectionStorage = connections.filter { ids.contains($0.from) && ids.contains($0.to) }
    }

    /// Replace only the strokes, without emitting effects.
    public func replaceStrokes(_ strokes: [Stroke]) {
        strokeStorage = strokes
    }

    // MARK: - Stroke operations

    private func addStroke(_ stroke: Stroke) -> [CanvasEffect] {
        guard !strokeStorage.contains(where: { $0.id == stroke.id }) else { return [] }
        strokeStorage.append(stroke)
        return [.strokeAdded(stroke)]
    }

    /// Removes the strokes that are actually present, deduplicating the request.
    /// A caller passing an id twice cannot produce two removals.
    private func removeStrokes(ids: [UUID]) -> [CanvasEffect] {
        let present = Set(strokeStorage.map(\.id))
        let removable = orderedUnique(ids).filter { present.contains($0) }
        guard !removable.isEmpty else { return [] }

        let removalSet = Set(removable)
        strokeStorage.removeAll { removalSet.contains($0.id) }
        return [.strokesRemoved(ids: removable)]
    }

    // MARK: - Node operations

    private func createNode(_ node: Node, consumingStrokes ids: [UUID]) -> [CanvasEffect] {
        guard !nodeStorage.contains(where: { $0.id == node.id }) else { return [] }

        var effects: [CanvasEffect] = []
        effects.append(contentsOf: removeStrokes(ids: ids))

        nodeStorage.append(node)
        effects.append(.nodeCreated(node))
        return effects
    }

    private func deleteNode(id: UUID, returningStrokes: Bool) -> [CanvasEffect] {
        guard let index = nodeStorage.firstIndex(where: { $0.id == id }) else { return [] }

        var effects: [CanvasEffect] = []
        let node = nodeStorage[index]
        nodeStorage.remove(at: index)
        effects.append(.nodesRemoved(ids: [id]))

        // An edge to a node that no longer exists cannot be drawn, so it goes too.
        effects.append(contentsOf: removeConnectionsTouching(nodeIds: [id]))

        if returningStrokes {
            for stroke in node.strokes {
                effects.append(contentsOf: addStroke(stroke))
            }
        }

        return effects
    }

    /// Absorb nodes into a merged node, re-pointing their external edges at it.
    ///
    /// Edges between two absorbed nodes are dropped: both endpoints are gone, and
    /// the merged node cannot connect to itself.
    private func mergeNodes(
        absorbing absorbedIds: [UUID],
        into mergedNode: Node,
        consumingStrokes strokeIds: [UUID]
    ) -> [CanvasEffect] {
        let absorbed = Set(absorbedIds.filter { id in nodeStorage.contains { $0.id == id } })
        guard !absorbed.isEmpty || !strokeIds.isEmpty else { return [] }
        guard !nodeStorage.contains(where: { $0.id == mergedNode.id }) else { return [] }

        var effects: [CanvasEffect] = []

        // Work out the surviving edges before anything is removed.
        var rewired: [Connection] = []
        for connection in connectionStorage {
            let fromAbsorbed = absorbed.contains(connection.from)
            let toAbsorbed = absorbed.contains(connection.to)

            switch (fromAbsorbed, toAbsorbed) {
            case (false, false):
                continue                       // untouched by the merge
            case (true, true):
                continue                       // wholly interior; disappears
            case (true, false):
                rewired.append(Connection(from: mergedNode.id, to: connection.to))
            case (false, true):
                rewired.append(Connection(from: connection.from, to: mergedNode.id))
            }
        }

        effects.append(contentsOf: removeStrokes(ids: strokeIds))
        effects.append(contentsOf: removeConnectionsTouching(nodeIds: absorbed))

        let removedNodeIds = nodeStorage.filter { absorbed.contains($0.id) }.map(\.id)
        nodeStorage.removeAll { absorbed.contains($0.id) }
        if !removedNodeIds.isEmpty {
            effects.append(.nodesRemoved(ids: removedNodeIds))
        }

        nodeStorage.append(mergedNode)
        effects.append(.nodeCreated(mergedNode))

        // Re-add the rewired edges, skipping duplicates that collapsed onto the
        // same pair when several absorbed nodes pointed at one external node.
        for connection in rewired {
            guard connection.from != connection.to else { continue }
            guard !connectionStorage.contains(where: {
                $0.from == connection.from && $0.to == connection.to
            }) else { continue }
            connectionStorage.append(connection)
            effects.append(.connectionAdded(connection))
        }

        return effects
    }

    // MARK: - Connection operations

    private func connect(from sourceId: UUID, to targetId: UUID) -> [CanvasEffect] {
        guard sourceId != targetId else { return [] }
        guard nodeStorage.contains(where: { $0.id == sourceId }),
              nodeStorage.contains(where: { $0.id == targetId }) else { return [] }
        guard !connectionStorage.contains(where: { $0.from == sourceId && $0.to == targetId })
        else { return [] }

        let connection = Connection(from: sourceId, to: targetId)
        connectionStorage.append(connection)
        return [.connectionAdded(connection)]
    }

    private func removeConnections(ids: [UUID]) -> [CanvasEffect] {
        let present = Set(connectionStorage.map(\.id))
        let removable = orderedUnique(ids).filter { present.contains($0) }
        guard !removable.isEmpty else { return [] }

        let removalSet = Set(removable)
        connectionStorage.removeAll { removalSet.contains($0.id) }
        return [.connectionsRemoved(ids: removable)]
    }

    private func removeConnectionsTouching(nodeIds: Set<UUID>) -> [CanvasEffect] {
        let doomed = connectionStorage
            .filter { nodeIds.contains($0.from) || nodeIds.contains($0.to) }
            .map(\.id)
        return removeConnections(ids: doomed)
    }

    // MARK: - Helpers

    /// Deduplicate while preserving first-seen order, so effects stay predictable.
    private func orderedUnique(_ ids: [UUID]) -> [UUID] {
        var seen = Set<UUID>()
        return ids.filter { seen.insert($0).inserted }
    }
}
