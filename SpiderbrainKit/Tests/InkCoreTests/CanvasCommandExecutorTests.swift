import XCTest
@testable import InkCore

final class CanvasCommandExecutorTests: XCTestCase {

    private func makeStroke(id: UUID = UUID()) -> Stroke {
        Stroke(id: id, points: [InkPoint(position: Vec2(0, 0), force: 0.5)], style: .pen)
    }

    private func makeNode(id: UUID = UUID()) -> Node {
        Node(id: id, strokes: [], bounds: Rect(x: 0, y: 0, width: 10, height: 10))
    }

    // MARK: - Node creation consuming strokes

    /// Creating a node from a drawn boundary must consume the strokes in the same
    /// step, so a peer never sees them both loose and inside the node.
    func testCreateNodeConsumesStrokesAtomically() {
        let boundary = makeStroke()
        let inside = makeStroke()
        let executor = CanvasCommandExecutor(strokes: [boundary, inside])
        let node = makeNode()

        let effects = executor.execute(
            .createNode(node, consumingStrokes: [boundary.id, inside.id]),
            origin: .local
        )

        XCTAssertEqual(effects, [
            .strokesRemoved(ids: [boundary.id, inside.id]),
            .nodeCreated(node)
        ])
        XCTAssertTrue(executor.strokes.isEmpty)
        XCTAssertEqual(executor.nodes.map(\.id), [node.id])
    }

    func testCreateNodeIsIdempotentById() {
        let node = makeNode()
        let executor = CanvasCommandExecutor(nodes: [node])

        let effects = executor.execute(.createNode(node, consumingStrokes: []), origin: .remote)

        XCTAssertTrue(effects.isEmpty)
        XCTAssertEqual(executor.nodes.count, 1)
    }

    // MARK: - Node update

    func testUpdateNodeReplacesStoredNode() {
        var node = makeNode()
        let executor = CanvasCommandExecutor(nodes: [node])
        node.bounds = Rect(x: 99, y: 99, width: 10, height: 10)

        let effects = executor.execute(.updateNode(node), origin: .local)

        XCTAssertEqual(effects, [.nodeUpdated(node)])
        XCTAssertEqual(executor.node(withId: node.id)?.bounds.x, 99, "moved node must be stored")
    }

    func testUpdateUnknownNodeIsNoOp() {
        let executor = CanvasCommandExecutor()

        let effects = executor.execute(.updateNode(makeNode()), origin: .local)

        XCTAssertTrue(effects.isEmpty)
    }

    // MARK: - Node deletion

    func testDeleteNodeRemovesItsConnections() {
        let a = makeNode()
        let b = makeNode()
        let executor = CanvasCommandExecutor(nodes: [a, b])
        _ = executor.execute(.connect(from: a.id, to: b.id), origin: .local)

        let effects = executor.execute(.deleteNode(id: a.id, returningStrokes: false), origin: .local)

        XCTAssertTrue(executor.connections.isEmpty, "an edge cannot outlive its endpoint")
        XCTAssertTrue(effects.contains(.nodesRemoved(ids: [a.id])))
    }

    func testDeleteNodeCanReturnStrokesToCanvas() {
        let held = makeStroke()
        let node = Node(strokes: [held], bounds: Rect(x: 0, y: 0, width: 10, height: 10))
        let executor = CanvasCommandExecutor(nodes: [node])

        _ = executor.execute(.deleteNode(id: node.id, returningStrokes: true), origin: .local)

        XCTAssertEqual(executor.strokes.map(\.id), [held.id])
    }

    func testDeleteNodeCanDiscardStrokes() {
        let held = makeStroke()
        let node = Node(strokes: [held], bounds: Rect(x: 0, y: 0, width: 10, height: 10))
        let executor = CanvasCommandExecutor(nodes: [node])

        _ = executor.execute(.deleteNode(id: node.id, returningStrokes: false), origin: .local)

        XCTAssertTrue(executor.strokes.isEmpty)
    }

    // MARK: - Connections

    func testConnectRejectsSelfLoops() {
        let node = makeNode()
        let executor = CanvasCommandExecutor(nodes: [node])

        let effects = executor.execute(.connect(from: node.id, to: node.id), origin: .local)

        XCTAssertTrue(effects.isEmpty)
    }

    func testConnectRejectsDuplicates() {
        let a = makeNode()
        let b = makeNode()
        let executor = CanvasCommandExecutor(nodes: [a, b])
        _ = executor.execute(.connect(from: a.id, to: b.id), origin: .local)

        let effects = executor.execute(.connect(from: a.id, to: b.id), origin: .local)

        XCTAssertTrue(effects.isEmpty)
        XCTAssertEqual(executor.connections.count, 1)
    }

    func testConnectRequiresBothEndpointsToExist() {
        let a = makeNode()
        let executor = CanvasCommandExecutor(nodes: [a])

        let effects = executor.execute(.connect(from: a.id, to: UUID()), origin: .local)

        XCTAssertTrue(effects.isEmpty, "cannot connect to a node that does not exist")
    }

    // MARK: - Merge

    /// Regression: merging two nodes used to drop A→C when A was absorbed, because
    /// every edge touching an absorbed node was deleted rather than re-pointed.
    func testMergeRewiresOutgoingEdgeToMergedNode() {
        let a = makeNode()
        let b = makeNode()
        let external = makeNode()
        let executor = CanvasCommandExecutor(nodes: [a, b, external])
        _ = executor.execute(.connect(from: a.id, to: external.id), origin: .local)

        let merged = makeNode()
        _ = executor.execute(
            .mergeNodes(absorbing: [a.id, b.id], into: merged, consumingStrokes: []),
            origin: .local
        )

        XCTAssertEqual(executor.connections.count, 1)
        let edge = executor.connections[0]
        XCTAssertEqual(edge.from, merged.id, "edge should now start at the merged node")
        XCTAssertEqual(edge.to, external.id)
    }

    func testMergeRewiresIncomingEdgeToMergedNode() {
        let a = makeNode()
        let external = makeNode()
        let executor = CanvasCommandExecutor(nodes: [a, external])
        _ = executor.execute(.connect(from: external.id, to: a.id), origin: .local)

        let merged = makeNode()
        _ = executor.execute(
            .mergeNodes(absorbing: [a.id], into: merged, consumingStrokes: []),
            origin: .local
        )

        XCTAssertEqual(executor.connections.count, 1)
        XCTAssertEqual(executor.connections[0].from, external.id)
        XCTAssertEqual(executor.connections[0].to, merged.id)
    }

    /// An edge between two absorbed nodes has nowhere to go — both endpoints
    /// collapse into the merged node, and a node cannot point at itself.
    func testMergeDropsEdgesBetweenAbsorbedNodes() {
        let a = makeNode()
        let b = makeNode()
        let executor = CanvasCommandExecutor(nodes: [a, b])
        _ = executor.execute(.connect(from: a.id, to: b.id), origin: .local)

        let merged = makeNode()
        _ = executor.execute(
            .mergeNodes(absorbing: [a.id, b.id], into: merged, consumingStrokes: []),
            origin: .local
        )

        XCTAssertTrue(executor.connections.isEmpty, "interior edge must not become a self-loop")
    }

    /// Two absorbed nodes both pointing at the same external node collapse to one
    /// edge, not two duplicates.
    func testMergeCollapsesDuplicateRewiredEdges() {
        let a = makeNode()
        let b = makeNode()
        let external = makeNode()
        let executor = CanvasCommandExecutor(nodes: [a, b, external])
        _ = executor.execute(.connect(from: a.id, to: external.id), origin: .local)
        _ = executor.execute(.connect(from: b.id, to: external.id), origin: .local)

        let merged = makeNode()
        _ = executor.execute(
            .mergeNodes(absorbing: [a.id, b.id], into: merged, consumingStrokes: []),
            origin: .local
        )

        XCTAssertEqual(executor.connections.count, 1, "duplicate rewired edges collapse")
    }

    func testMergeLeavesUnrelatedEdgesAlone() {
        let a = makeNode()
        let x = makeNode()
        let y = makeNode()
        let executor = CanvasCommandExecutor(nodes: [a, x, y])
        _ = executor.execute(.connect(from: x.id, to: y.id), origin: .local)

        let merged = makeNode()
        _ = executor.execute(
            .mergeNodes(absorbing: [a.id], into: merged, consumingStrokes: []),
            origin: .local
        )

        XCTAssertEqual(executor.connections.count, 1)
        XCTAssertEqual(executor.connections[0].from, x.id)
        XCTAssertEqual(executor.connections[0].to, y.id)
    }

    func testMergeConsumesStrokes() {
        let boundary = makeStroke()
        let a = makeNode()
        let executor = CanvasCommandExecutor(strokes: [boundary], nodes: [a])

        let merged = makeNode()
        _ = executor.execute(
            .mergeNodes(absorbing: [a.id], into: merged, consumingStrokes: [boundary.id]),
            origin: .local
        )

        XCTAssertTrue(executor.strokes.isEmpty, "the boundary stroke is consumed by the merge")
    }

    /// The whole point of one command: a peer applies the merge or none of it.
    func testMergeRemovesAbsorbedNodesAndAddsMergedNode() {
        let a = makeNode()
        let b = makeNode()
        let executor = CanvasCommandExecutor(nodes: [a, b])

        let merged = makeNode()
        _ = executor.execute(
            .mergeNodes(absorbing: [a.id, b.id], into: merged, consumingStrokes: []),
            origin: .local
        )

        XCTAssertEqual(executor.nodes.map(\.id), [merged.id])
    }

    // MARK: - Clear

    func testClearRemovesEverything() {
        let node = makeNode()
        let other = makeNode()
        let executor = CanvasCommandExecutor(strokes: [makeStroke()], nodes: [node, other])
        _ = executor.execute(.connect(from: node.id, to: other.id), origin: .local)

        let effects = executor.execute(.clearCanvas, origin: .local)

        XCTAssertEqual(effects, [.canvasCleared])
        XCTAssertTrue(executor.strokes.isEmpty)
        XCTAssertTrue(executor.nodes.isEmpty)
        XCTAssertTrue(executor.connections.isEmpty)
    }

    func testClearOnEmptyCanvasIsNoOp() {
        let executor = CanvasCommandExecutor()

        XCTAssertTrue(executor.execute(.clearCanvas, origin: .local).isEmpty)
    }

    // MARK: - Bulk replace

    func testReplaceAllDropsDanglingConnections() {
        let a = makeNode()
        let executor = CanvasCommandExecutor()

        executor.replaceAll(
            strokes: [],
            nodes: [a],
            connections: [Connection(from: a.id, to: UUID())]
        )

        XCTAssertTrue(executor.connections.isEmpty, "edges to absent nodes are discarded")
    }
}
