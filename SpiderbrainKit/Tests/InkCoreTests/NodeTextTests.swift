import XCTest
@testable import InkCore

final class NodeTextTests: XCTestCase {

    private func node(
        text: String? = nil,
        recognized: String? = nil,
        size: Double = 100
    ) -> Node {
        Node(
            strokes: [],
            bounds: Rect(x: 0, y: 0, width: size, height: size),
            recognizedText: recognized.map {
                RecognizedText(text: $0, confidence: 0.9, source: .vision(confidence: 0.9))
            },
            text: text
        )
    }

    // MARK: - promptText precedence

    func testTypedTextIsUsedWhenPresent() {
        XCTAssertEqual(node(text: "typed").promptText, "typed")
    }

    func testRecognizedTextIsUsedWhenNothingWasTyped() {
        XCTAssertEqual(node(recognized: "written").promptText, "written")
    }

    /// Recognition is a guess; typing is not. Typed text wins.
    func testTypedTextWinsOverRecognition() {
        XCTAssertEqual(node(text: "typed", recognized: "written").promptText, "typed")
    }

    func testEmptyNodeHasNoPromptText() {
        XCTAssertNil(node().promptText)
    }

    /// Whitespace-only text is not content, so it falls through to recognition.
    func testBlankTypedTextFallsBackToRecognition() {
        XCTAssertEqual(node(text: "   \n ", recognized: "written").promptText, "written")
    }

    func testBlankTextEverywhereIsNoPrompt() {
        XCTAssertNil(node(text: "  ", recognized: "\n").promptText)
    }

    func testPromptTextIsTrimmed() {
        XCTAssertEqual(node(text: "  hello  ").promptText, "hello")
    }

    // MARK: - setText

    func testSetTextStoresTheText() {
        let target = node()
        let controller = CanvasController(canvas: CanvasCommandExecutor(nodes: [target]))

        let effects = controller.setText("hello", onNodeId: target.id)

        XCTAssertFalse(effects.isEmpty)
        XCTAssertEqual(controller.node(withId: target.id)?.text, "hello")
    }

    func testSetTextOnMissingNodeIsANoOp() {
        let controller = CanvasController()

        XCTAssertTrue(controller.setText("hello", onNodeId: UUID()).isEmpty)
    }

    func testSetTextLeavesRecognitionAlone() {
        let target = node(recognized: "written")
        let controller = CanvasController(canvas: CanvasCommandExecutor(nodes: [target]))

        _ = controller.setText("typed", onNodeId: target.id)

        let updated = controller.node(withId: target.id)
        XCTAssertEqual(updated?.recognizedText?.text, "written", "a later typing pass must not erase recognition")
        XCTAssertEqual(updated?.promptText, "typed")
    }

    // MARK: - grow-only sizing

    func testNodeGrowsToFitLongerText() {
        let target = node(size: 100)
        let controller = CanvasController(canvas: CanvasCommandExecutor(nodes: [target]))

        _ = controller.setText(
            "a long line of text",
            onNodeId: target.id,
            fittingBounds: Rect(x: 0, y: 0, width: 300, height: 140)
        )

        let grown = controller.node(withId: target.id)!
        XCTAssertEqual(grown.bounds.width, 300, accuracy: 0.001)
        XCTAssertEqual(grown.bounds.height, 140, accuracy: 0.001)
    }

    /// Grow-only: deleting text must not snap the box smaller than the user left it.
    func testNodeDoesNotShrinkWhenTextGetsShorter() {
        let target = node(size: 300)
        let controller = CanvasController(canvas: CanvasCommandExecutor(nodes: [target]))

        _ = controller.setText(
            "hi",
            onNodeId: target.id,
            fittingBounds: Rect(x: 0, y: 0, width: 40, height: 20)
        )

        let unchanged = controller.node(withId: target.id)!
        XCTAssertEqual(unchanged.bounds.width, 300, accuracy: 0.001)
        XCTAssertEqual(unchanged.bounds.height, 300, accuracy: 0.001)
    }

    /// Growth happens on whichever axis needs it, independently.
    func testNodeGrowsOnOneAxisOnly() {
        let target = node(size: 100)
        let controller = CanvasController(canvas: CanvasCommandExecutor(nodes: [target]))

        _ = controller.setText(
            "wide",
            onNodeId: target.id,
            fittingBounds: Rect(x: 0, y: 0, width: 250, height: 30)
        )

        let grown = controller.node(withId: target.id)!
        XCTAssertEqual(grown.bounds.width, 250, accuracy: 0.001)
        XCTAssertEqual(grown.bounds.height, 100, accuracy: 0.001, "height was already sufficient")
    }

    func testGrowthKeepsTheNodesOrigin() {
        let target = Node(
            strokes: [],
            bounds: Rect(x: 75, y: 40, width: 100, height: 100)
        )
        let controller = CanvasController(canvas: CanvasCommandExecutor(nodes: [target]))

        _ = controller.setText(
            "text",
            onNodeId: target.id,
            fittingBounds: Rect(x: 0, y: 0, width: 200, height: 200)
        )

        let grown = controller.node(withId: target.id)!
        XCTAssertEqual(grown.bounds.x, 75, accuracy: 0.001, "the box grows from where it sits")
        XCTAssertEqual(grown.bounds.y, 40, accuracy: 0.001)
    }

    func testSetTextWithoutMeasurementLeavesBoundsAlone() {
        let target = node(size: 100)
        let controller = CanvasController(canvas: CanvasCommandExecutor(nodes: [target]))

        _ = controller.setText("hello", onNodeId: target.id)

        XCTAssertEqual(controller.node(withId: target.id)?.bounds.width, 100)
    }
}
