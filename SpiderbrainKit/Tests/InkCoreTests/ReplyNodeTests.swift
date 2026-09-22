import XCTest
@testable import InkCore

final class ReplyNodeTests: XCTestCase {

    private func node(at center: Vec2 = Vec2(100, 100), size: Double = 80) -> Node {
        Node(
            strokes: [],
            bounds: Rect(
                x: center.x - size / 2,
                y: center.y - size / 2,
                width: size,
                height: size
            )
        )
    }

    // MARK: - The command

    func testCreateNodeLinkedAddsBothNodeAndEdge() {
        let source = node()
        let executor = CanvasCommandExecutor(nodes: [source])
        let reply = node(at: Vec2(400, 100))

        let effects = executor.execute(.createNodeLinked(reply, from: source.id), origin: .local)

        XCTAssertEqual(executor.nodes.count, 2)
        XCTAssertEqual(executor.connections.count, 1)
        XCTAssertEqual(executor.connections[0].from, source.id)
        XCTAssertEqual(executor.connections[0].to, reply.id)
        XCTAssertTrue(effects.contains(.nodeCreated(reply)))
    }

    /// A reply that has lost its question is worse than no reply, so the whole
    /// command refuses rather than leaving an orphan behind.
    func testCreateNodeLinkedRefusesWhenTheSourceIsGone() {
        let executor = CanvasCommandExecutor()

        let effects = executor.execute(
            .createNodeLinked(node(), from: UUID()),
            origin: .local
        )

        XCTAssertTrue(effects.isEmpty)
        XCTAssertTrue(executor.nodes.isEmpty, "no orphan node is left behind")
        XCTAssertTrue(executor.connections.isEmpty)
    }

    func testCreateNodeLinkedIsIdempotentByNodeId() {
        let source = node()
        let reply = node(at: Vec2(400, 100))
        let executor = CanvasCommandExecutor(nodes: [source, reply])

        let effects = executor.execute(.createNodeLinked(reply, from: source.id), origin: .local)

        XCTAssertTrue(effects.isEmpty)
        XCTAssertEqual(executor.nodes.count, 2)
    }

    // MARK: - Ordering over the wire

    /// The node must be announced before the edge that names it: a peer drops an
    /// edge whose endpoints it has not seen, and nothing retries.
    func testReplyNodeIsAnnouncedBeforeItsEdge() {
        let source = node()
        let executor = CanvasCommandExecutor(nodes: [source])
        let reply = node(at: Vec2(400, 100))

        let effects = executor.execute(.createNodeLinked(reply, from: source.id), origin: .local)
        let intents = CanvasSyncPlanner.plan(for: effects)

        let nodeIndex = intents.firstIndex {
            if case .nodeCreated(let n) = $0 { return n.id == reply.id }
            if case .nodeCreatedConsumingStrokes(let n, _) = $0 { return n.id == reply.id }
            return false
        }
        let edgeIndex = intents.firstIndex {
            if case .connectionCreated = $0 { return true }
            return false
        }

        XCTAssertNotNil(nodeIndex)
        XCTAssertNotNil(edgeIndex)
        XCTAssertLessThan(nodeIndex!, edgeIndex!)
    }

    // MARK: - addReply

    func testAddReplyStoresTheTextInANewNode() {
        let source = node()
        let controller = CanvasController(canvas: CanvasCommandExecutor(nodes: [source]))

        _ = controller.addReply("the answer", answering: source.id, size: Vec2(200, 100))

        let reply = controller.nodes.first { $0.id != source.id }
        XCTAssertEqual(reply?.text, "the answer")
        XCTAssertEqual(reply?.promptText, "the answer")
    }

    func testAddReplyLinksBackToTheQuestion() {
        let source = node()
        let controller = CanvasController(canvas: CanvasCommandExecutor(nodes: [source]))

        _ = controller.addReply("answer", answering: source.id, size: Vec2(200, 100))

        XCTAssertEqual(controller.connections.count, 1)
        XCTAssertEqual(controller.connections[0].from, source.id, "the question points at the reply")
    }

    func testAddReplySitsToTheRightOfTheQuestion() {
        let source = node(at: Vec2(100, 100), size: 80)
        let controller = CanvasController(canvas: CanvasCommandExecutor(nodes: [source]))

        _ = controller.addReply("answer", answering: source.id, size: Vec2(200, 100))

        let reply = controller.nodes.first { $0.id != source.id }!
        XCTAssertGreaterThan(reply.bounds.x, source.bounds.maxX, "clear of the question, not overlapping")
        XCTAssertEqual(reply.bounds.y, source.bounds.y, accuracy: 0.001, "top-aligned with it")
    }

    func testAddReplyUsesTheMeasuredSize() {
        let source = node()
        let controller = CanvasController(canvas: CanvasCommandExecutor(nodes: [source]))

        _ = controller.addReply("answer", answering: source.id, size: Vec2(250, 130))

        let reply = controller.nodes.first { $0.id != source.id }!
        XCTAssertEqual(reply.bounds.width, 250, accuracy: 0.001)
        XCTAssertEqual(reply.bounds.height, 130, accuracy: 0.001)
    }

    func testAddReplyToAMissingNodeIsANoOp() {
        let controller = CanvasController()

        let effects = controller.addReply("answer", answering: UUID(), size: Vec2(200, 100))

        XCTAssertTrue(effects.isEmpty)
        XCTAssertTrue(controller.nodes.isEmpty)
    }

    /// Asking the same node twice gives two replies, both pointing back at it.
    func testAskingTwiceGivesTwoReplies() {
        let source = node()
        let controller = CanvasController(canvas: CanvasCommandExecutor(nodes: [source]))

        _ = controller.addReply("first", answering: source.id, size: Vec2(200, 100))
        _ = controller.addReply("second", answering: source.id, size: Vec2(200, 100))

        XCTAssertEqual(controller.nodes.count, 3)
        XCTAssertEqual(controller.outgoingConnections(from: source.id).count, 2)
    }

    /// Deleting the question takes its replies' edges with it, but leaves the
    /// replies themselves on the canvas.
    func testDeletingTheQuestionLeavesTheReplyButDropsTheEdge() {
        let source = node()
        let controller = CanvasController(canvas: CanvasCommandExecutor(nodes: [source]))
        _ = controller.addReply("answer", answering: source.id, size: Vec2(200, 100))

        _ = controller.deleteNode(id: source.id)

        XCTAssertEqual(controller.nodes.count, 1, "the reply outlives the question")
        XCTAssertTrue(controller.connections.isEmpty, "its edge does not")
    }
}
