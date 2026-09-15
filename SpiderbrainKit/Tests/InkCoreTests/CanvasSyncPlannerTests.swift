import XCTest
@testable import InkCore

final class CanvasSyncPlannerTests: XCTestCase {

    private func makeStroke(id: UUID = UUID()) -> Stroke {
        Stroke(id: id, points: [InkPoint(position: Vec2(0, 0), force: 0.5)], style: .pen)
    }

    private func makeNode(id: UUID = UUID()) -> Node {
        Node(id: id, strokes: [], bounds: Rect(x: 0, y: 0, width: 10, height: 10))
    }

    /// Index of the first intent satisfying a predicate, for order assertions.
    private func firstIndex(
        in intents: [SyncIntent],
        where predicate: (SyncIntent) -> Bool
    ) -> Int? {
        intents.firstIndex(where: predicate)
    }

    // MARK: - The regression this type exists for

    /// A merge rewires an absorbed node's edge onto the merged node. If the edge is
    /// announced first, the peer rejects it (the endpoint doesn't exist yet) and
    /// never retries — the arrow vanishes on the receiving device while looking
    /// correct on the sender.
    func testMergedNodeIsAnnouncedBeforeEdgesReferencingIt() {
        let merged = makeNode()
        let external = makeNode()
        let rewired = Connection(from: merged.id, to: external.id)

        // Effects in the order the executor happens to produce them: the edge
        // addition can precede the node creation.
        let effects: [CanvasEffect] = [
            .connectionAdded(rewired),
            .nodeCreated(merged)
        ]

        let intents = CanvasSyncPlanner.plan(for: effects)

        let nodeIndex = firstIndex(in: intents) {
            if case .nodeCreated(let n) = $0 { return n.id == merged.id }
            if case .nodeCreatedConsumingStrokes(let n, _) = $0 { return n.id == merged.id }
            return false
        }
        let edgeIndex = firstIndex(in: intents) {
            if case .connectionCreated(let c) = $0 { return c.id == rewired.id }
            return false
        }

        XCTAssertNotNil(nodeIndex)
        XCTAssertNotNil(edgeIndex)
        XCTAssertLessThan(
            nodeIndex!, edgeIndex!,
            "the node must be announced before any edge that names it"
        )
    }

    func testEveryEdgeFollowsEveryNodeAnnouncement() {
        let a = makeNode()
        let b = makeNode()
        let effects: [CanvasEffect] = [
            .connectionAdded(Connection(from: a.id, to: b.id)),
            .nodeCreated(a),
            .connectionAdded(Connection(from: b.id, to: a.id)),
            .nodeCreated(b)
        ]

        let intents = CanvasSyncPlanner.plan(for: effects)

        let lastNode = intents.lastIndex {
            if case .nodeCreated = $0 { return true }
            if case .nodeCreatedConsumingStrokes = $0 { return true }
            if case .nodeUpdated = $0 { return true }
            return false
        }
        let firstEdge = firstIndex(in: intents) {
            if case .connectionCreated = $0 { return true }
            return false
        }

        XCTAssertNotNil(lastNode)
        XCTAssertNotNil(firstEdge)
        XCTAssertLessThan(lastNode!, firstEdge!, "no edge may precede any node announcement")
    }

    func testUpdatedNodeAlsoPrecedesEdges() {
        let survivor = makeNode()
        let external = makeNode()
        let effects: [CanvasEffect] = [
            .connectionAdded(Connection(from: survivor.id, to: external.id)),
            .nodeUpdated(survivor)
        ]

        let intents = CanvasSyncPlanner.plan(for: effects)

        let nodeIndex = firstIndex(in: intents) {
            if case .nodeUpdated = $0 { return true }
            return false
        }
        let edgeIndex = firstIndex(in: intents) {
            if case .connectionCreated = $0 { return true }
            return false
        }

        XCTAssertLessThan(nodeIndex!, edgeIndex!)
    }

    // MARK: - Removals first

    /// Deleting before creating keeps a peer from briefly holding both the absorbed
    /// nodes and the node that replaced them.
    func testRemovalsPrecedeCreations() {
        let absorbed = makeNode()
        let merged = makeNode()
        let effects: [CanvasEffect] = [
            .nodeCreated(merged),
            .nodesRemoved(ids: [absorbed.id])
        ]

        let intents = CanvasSyncPlanner.plan(for: effects)

        let removalIndex = firstIndex(in: intents) {
            if case .nodeDeleted = $0 { return true }
            return false
        }
        let creationIndex = firstIndex(in: intents) {
            if case .nodeCreated = $0 { return true }
            if case .nodeCreatedConsumingStrokes = $0 { return true }
            return false
        }

        XCTAssertLessThan(removalIndex!, creationIndex!)
    }

    // MARK: - Stroke consumption folds into the node

    /// Strokes swallowed by a new node travel with it, so a peer never sees them
    /// both loose on the canvas and inside the node.
    func testStrokesConsumedByNodeCreationTravelWithTheNode() {
        let boundary = makeStroke()
        let node = makeNode()
        let effects: [CanvasEffect] = [
            .strokesRemoved(ids: [boundary.id]),
            .nodeCreated(node)
        ]

        let intents = CanvasSyncPlanner.plan(for: effects)

        XCTAssertEqual(intents, [
            .nodeCreatedConsumingStrokes(node: node, deletedStrokeIds: [boundary.id])
        ])
        XCTAssertFalse(
            intents.contains { if case .strokeDeleted = $0 { return true }; return false },
            "consumed strokes must not also be announced as standalone deletions"
        )
    }

    /// Stroke removals unrelated to a node creation stay standalone.
    func testStrokeRemovalWithoutNodeCreationIsStandalone() {
        let stroke = makeStroke()

        let intents = CanvasSyncPlanner.plan(for: [.strokesRemoved(ids: [stroke.id])])

        XCTAssertEqual(intents, [.strokeDeleted(id: stroke.id)])
    }

    /// Deleting a node returns its strokes to the canvas. Those additions must not
    /// be mistaken for strokes being consumed.
    func testStrokesReturnedByNodeDeletionAreAnnouncedAsAdditions() {
        let returned = makeStroke()
        let node = makeNode()
        let effects: [CanvasEffect] = [
            .nodesRemoved(ids: [node.id]),
            .strokeAdded(returned)
        ]

        let intents = CanvasSyncPlanner.plan(for: effects)

        XCTAssertEqual(intents, [
            .nodeDeleted(id: node.id),
            .strokeAdded(returned)
        ])
    }

    // MARK: - Simple passthroughs

    func testStrokeAddition() {
        let stroke = makeStroke()

        XCTAssertEqual(
            CanvasSyncPlanner.plan(for: [.strokeAdded(stroke)]),
            [.strokeAdded(stroke)]
        )
    }

    func testConnectionRemoval() {
        let connection = Connection(from: UUID(), to: UUID())

        XCTAssertEqual(
            CanvasSyncPlanner.plan(for: [.connectionsRemoved(ids: [connection.id])]),
            [.connectionDeleted(id: connection.id)]
        )
    }

    func testNoEffectsProduceNoIntents() {
        XCTAssertTrue(CanvasSyncPlanner.plan(for: []).isEmpty)
    }

    /// A cleared canvas makes every other announcement redundant. Clear is not yet
    /// synced at all, so this documents that the planner emits nothing rather than
    /// a burst of individual deletions.
    func testClearedCanvasProducesNoIntents() {
        let node = makeNode()
        let effects: [CanvasEffect] = [
            .canvasCleared,
            .nodesRemoved(ids: [node.id])
        ]

        XCTAssertTrue(CanvasSyncPlanner.plan(for: effects).isEmpty)
    }

    // MARK: - End-to-end against the executor

    /// The real shape of the bug: drive an actual merge through the executor and
    /// check the plan the planner derives from its effects.
    func testPlanFromRealMergeKeepsRewiredEdgeAfterMergedNode() {
        let a = makeNode()
        let b = makeNode()
        let external = makeNode()
        let executor = CanvasCommandExecutor(nodes: [a, b, external])
        _ = executor.execute(.connect(from: a.id, to: external.id), origin: .local)

        let merged = makeNode()
        let effects = executor.execute(
            .mergeNodes(absorbing: [a.id, b.id], into: merged, consumingStrokes: []),
            origin: .local
        )

        let intents = CanvasSyncPlanner.plan(for: effects)

        let nodeIndex = firstIndex(in: intents) {
            if case .nodeCreated(let n) = $0 { return n.id == merged.id }
            if case .nodeCreatedConsumingStrokes(let n, _) = $0 { return n.id == merged.id }
            return false
        }
        let edgeIndex = firstIndex(in: intents) {
            if case .connectionCreated(let c) = $0 { return c.from == merged.id }
            return false
        }

        XCTAssertNotNil(nodeIndex, "merged node must be announced")
        XCTAssertNotNil(edgeIndex, "rewired edge must be announced")
        XCTAssertLessThan(nodeIndex!, edgeIndex!)
    }
}
