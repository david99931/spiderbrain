import XCTest
@testable import InkCore

final class CanvasControllerTests: XCTestCase {

    private func transform(zoom: Float = 1.0) -> ViewTransform {
        ViewTransform(
            camera: Camera(offset: .zero, zoom: zoom),
            viewSize: Vec2(1000, 1000)
        )
    }

    /// A stroke tracing a closed loop, large enough not to read as a letter.
    private func circleStroke(center: Vec2 = Vec2(500, 500), radius: Double = 100) -> Stroke {
        let samples = (0...32).map { i -> InkPoint in
            let angle = Double(i) / 32.0 * 2 * .pi
            return InkPoint(
                position: Vec2(center.x + radius * cos(angle), center.y + radius * sin(angle)),
                force: 0.5
            )
        }
        return Stroke(points: samples, style: .pen)
    }

    /// A short stroke sitting at a given point.
    private func dot(at position: Vec2) -> Stroke {
        Stroke(
            points: (0..<6).map {
                InkPoint(position: Vec2(position.x + Double($0), position.y), force: 0.5)
            },
            style: .pen
        )
    }

    private func node(at center: Vec2, size: Double = 100, strokes: [Stroke] = []) -> Node {
        Node(
            strokes: strokes,
            bounds: Rect(
                x: center.x - size / 2,
                y: center.y - size / 2,
                width: size,
                height: size
            )
        )
    }

    // MARK: - Converting strokes to nodes

    func testConvertStrokeToNodeConsumesTheBoundary() {
        let boundary = circleStroke()
        let controller = CanvasController(canvas: CanvasCommandExecutor(strokes: [boundary]))

        let effects = controller.convertStrokeToNode(strokeId: boundary.id)

        XCTAssertFalse(effects.isEmpty)
        XCTAssertTrue(controller.strokes.isEmpty, "the boundary stroke becomes the node")
        XCTAssertEqual(controller.nodes.count, 1)
    }

    func testConvertStrokeToNodeSwallowsStrokesInside() {
        let boundary = circleStroke(center: Vec2(500, 500), radius: 150)
        let inside = dot(at: Vec2(500, 500))
        let outside = dot(at: Vec2(50, 50))
        let controller = CanvasController(
            canvas: CanvasCommandExecutor(strokes: [boundary, inside, outside])
        )

        _ = controller.convertStrokeToNode(strokeId: boundary.id)

        XCTAssertEqual(controller.strokes.map(\.id), [outside.id], "only the outside stroke remains")
        XCTAssertEqual(controller.nodes.first?.strokes.count, 1)
    }

    /// The caller may queue a conversion across an interaction, during which the
    /// stroke can be deleted. That must be a quiet no-op, not a crash.
    func testConvertStrokeToNodeIgnoresAMissingStroke() {
        let controller = CanvasController()

        XCTAssertTrue(controller.convertStrokeToNode(strokeId: UUID()).isEmpty)
    }

    func testConvertStrokeToNodeRejectsAnOpenStroke() {
        let line = Stroke(
            points: (0...20).map { InkPoint(position: Vec2(Double($0) * 10, 0), force: 0.5) },
            style: .pen
        )
        let controller = CanvasController(canvas: CanvasCommandExecutor(strokes: [line]))

        XCTAssertTrue(
            controller.convertStrokeToNode(strokeId: line.id).isEmpty,
            "a line is not a container"
        )
    }

    // MARK: - Merging

    func testConvertWithAbsorbSwallowsEnclosedNodes() {
        let boundary = circleStroke(center: Vec2(500, 500), radius: 200)
        let inner = node(at: Vec2(500, 500), size: 50)
        let outer = node(at: Vec2(50, 50), size: 50)
        let controller = CanvasController(
            canvas: CanvasCommandExecutor(strokes: [boundary], nodes: [inner, outer])
        )

        _ = controller.convertStrokeToNodeWithAbsorb(strokeId: boundary.id)

        let remaining = Set(controller.nodes.map(\.id))
        XCTAssertFalse(remaining.contains(inner.id), "the enclosed node is absorbed")
        XCTAssertTrue(remaining.contains(outer.id), "the distant node is untouched")
        XCTAssertEqual(controller.nodes.count, 2, "the outer node plus the merged one")
    }

    /// The regression that kept recurring: an absorbed node's edge to an outside
    /// node must survive, re-pointed at the merged node.
    func testMergeKeepsEdgesToNodesOutsideTheBoundary() {
        let boundary = circleStroke(center: Vec2(500, 500), radius: 200)
        let inner = node(at: Vec2(500, 500), size: 50)
        let external = node(at: Vec2(50, 50), size: 50)
        let controller = CanvasController(
            canvas: CanvasCommandExecutor(strokes: [boundary], nodes: [inner, external])
        )
        _ = controller.connect(from: inner.id, to: external.id)

        _ = controller.convertStrokeToNodeWithAbsorb(strokeId: boundary.id)

        XCTAssertEqual(controller.connections.count, 1, "the edge survives the merge")
        XCTAssertEqual(controller.connections[0].to, external.id)
        XCTAssertNotEqual(
            controller.connections[0].from, inner.id,
            "the edge now starts at the merged node, not the absorbed one"
        )
    }

    // MARK: - Moving and resizing

    func testMoveNodeShiftsBoundsAndStrokesTogether() {
        let stroke = dot(at: Vec2(500, 500))
        let target = node(at: Vec2(500, 500), strokes: [stroke])
        let controller = CanvasController(canvas: CanvasCommandExecutor(nodes: [target]))
        let originalX = target.bounds.x
        let originalStrokeX = stroke.points[0].position.x

        _ = controller.moveNode(id: target.id, by: Vec2(100, 0))

        let moved = controller.node(withId: target.id)!
        XCTAssertEqual(moved.bounds.x, originalX + 100, accuracy: 0.0001)
        XCTAssertEqual(
            moved.strokes[0].points[0].position.x, originalStrokeX + 100, accuracy: 0.0001,
            "strokes travel with the node"
        )
    }

    /// Resizing measures against the bounds captured when the drag began, so
    /// dragging out and back returns to the original size rather than drifting.
    func testResizeScalesFromTheStartingBounds() {
        let target = node(at: Vec2(500, 500), size: 100)
        let controller = CanvasController(canvas: CanvasCommandExecutor(nodes: [target]))

        _ = controller.resizeNode(
            id: target.id,
            to: Vec2(600, 600),
            startBounds: target.bounds,
            startStrokes: [],
            transform: transform()
        )

        let resized = controller.node(withId: target.id)!
        XCTAssertEqual(resized.bounds.center.x, 500, accuracy: 0.001, "centre stays put")
        XCTAssertEqual(resized.bounds.center.y, 500, accuracy: 0.001)
        XCTAssertGreaterThan(resized.bounds.width, 100, "dragging outward grows the node")
    }

    func testResizeEnforcesAMinimumSize() {
        let target = node(at: Vec2(500, 500), size: 100)
        let controller = CanvasController(canvas: CanvasCommandExecutor(nodes: [target]))

        _ = controller.resizeNode(
            id: target.id,
            to: Vec2(500, 500),  // dragged onto the centre
            startBounds: target.bounds,
            startStrokes: [],
            transform: transform()
        )

        let resized = controller.node(withId: target.id)!
        XCTAssertGreaterThanOrEqual(resized.bounds.width, 39.9, "cannot shrink to nothing")
    }

    // MARK: - Recognized text

    func testApplyRecognizedTextStoresItOnTheNode() {
        let target = node(at: Vec2(500, 500))
        let controller = CanvasController(canvas: CanvasCommandExecutor(nodes: [target]))
        let recognized = RecognizedText(
            text: "hello",
            confidence: 0.9,
            source: .vision(confidence: 0.9)
        )

        _ = controller.applyRecognizedText(recognized, toNodeId: target.id)

        XCTAssertEqual(controller.node(withId: target.id)?.recognizedText?.text, "hello")
    }

    // MARK: - Peer changes

    func testReceivedStrokeIsStoredOnce() {
        let controller = CanvasController()
        let stroke = dot(at: Vec2(0, 0))

        _ = controller.applyReceivedStroke(stroke)
        let second = controller.applyReceivedStroke(stroke)

        XCTAssertTrue(second.isEmpty, "a stroke arriving twice lands once")
        XCTAssertEqual(controller.strokes.count, 1)
    }

    func testReceivedNodeDeletionDropsItsEdges() {
        let a = node(at: Vec2(100, 100))
        let b = node(at: Vec2(300, 300))
        let controller = CanvasController(canvas: CanvasCommandExecutor(nodes: [a, b]))
        _ = controller.connect(from: a.id, to: b.id)

        _ = controller.applyReceivedNodeDeletion(id: a.id)

        XCTAssertTrue(controller.connections.isEmpty)
    }

    /// An edge whose endpoints have not arrived yet cannot be drawn, so it is
    /// dropped rather than stored dangling.
    func testReceivedConnectionNeedsBothEndpoints() {
        let a = node(at: Vec2(100, 100))
        let controller = CanvasController(canvas: CanvasCommandExecutor(nodes: [a]))

        let effects = controller.applyReceivedConnection(Connection(from: a.id, to: UUID()))

        XCTAssertTrue(effects.isEmpty)
        XCTAssertTrue(controller.connections.isEmpty)
    }
}
