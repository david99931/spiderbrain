import Foundation

/// The canvas operations, independent of any view.
///
/// Owns the executor and turns user-level actions — convert this stroke to a node,
/// absorb these strokes, finish this lasso — into commands. Returns the effects it
/// produced rather than announcing or drawing anything: the caller decides what to
/// broadcast and when to redraw.
///
/// Operations that need to know how the canvas is framed on screen take a
/// `ViewTransform`, so the controller stays free of UIKit while still being able to
/// interpret view-space input.
///
/// Selection is deliberately absent. Which node a person has highlighted is
/// per-device state that must never sync, so it stays with the view and is passed
/// in when an operation needs it.
public final class CanvasController {

    private let canvas: CanvasCommandExecutor

    public init(canvas: CanvasCommandExecutor = CanvasCommandExecutor()) {
        self.canvas = canvas
    }

    // MARK: - Reading

    public var strokes: [Stroke] { canvas.strokes }
    public var nodes: [Node] { canvas.nodes }
    public var connections: [Connection] { canvas.connections }

    public func node(withId id: UUID) -> Node? { canvas.node(withId: id) }

    public func outgoingConnections(from nodeId: UUID) -> [Connection] {
        canvas.outgoingConnections(from: nodeId)
    }

    public func incomingConnections(to nodeId: UUID) -> [Connection] {
        canvas.incomingConnections(to: nodeId)
    }

    // MARK: - Strokes

    public func addStroke(_ stroke: Stroke) -> [CanvasEffect] {
        canvas.execute(.addStroke(stroke), origin: .local)
    }

    public func undoLastStroke() -> [CanvasEffect] {
        canvas.execute(.removeLastStroke, origin: .local)
    }

    public func clear() -> [CanvasEffect] {
        canvas.execute(.clearCanvas, origin: .local)
    }

    /// Wipe the canvas because a peer did.
    public func applyReceivedClear() -> [CanvasEffect] {
        canvas.execute(.clearCanvas, origin: .remote)
    }

    // MARK: - Node creation

    /// Turn a closed stroke into an empty node, swallowing any strokes inside it.
    ///
    /// Returns no effects when the stroke is gone or was never a closed shape —
    /// the caller may have queued this across an interaction.
    public func convertStrokeToNode(strokeId: UUID) -> [CanvasEffect] {
        guard let boundary = canvas.stroke(withId: strokeId) else { return [] }
        guard ShapeDetection.isClosedShape(boundary, among: canvas.strokes) else { return [] }

        let polygon = boundary.points.map(\.position)
        let contained = canvas.strokes.filter {
            $0.id != strokeId && GeometryManager.isStrokeInsideLasso($0, lasso: polygon)
        }

        let bounds = Node.computeBounds(contained.isEmpty ? [boundary] : contained)
        guard let bounds else { return [] }

        let node = Node(
            strokes: contained,
            bounds: bounds,
            boundaryStroke: boundary
        )
        let consumed = [strokeId] + contained.map(\.id)
        return canvas.execute(.createNode(node, consumingStrokes: consumed), origin: .local)
    }

    /// Turn a closed stroke into a node that absorbs every node it encloses.
    public func convertStrokeToNodeWithAbsorb(strokeId: UUID) -> [CanvasEffect] {
        guard let boundary = canvas.stroke(withId: strokeId) else { return [] }

        let polygon = boundary.points.map(\.position)
        let containedStrokes = canvas.strokes.filter {
            $0.id != strokeId && GeometryManager.isStrokeInsideLasso($0, lasso: polygon)
        }
        let enclosedNodes = canvas.nodes.filter {
            GeometryManager.pointInPolygon($0.bounds.center, polygon: polygon)
        }

        var allStrokes = containedStrokes
        for node in enclosedNodes {
            allStrokes.append(contentsOf: node.strokes)
        }

        guard let bounds = Node.computeBounds(allStrokes.isEmpty ? [boundary] : allStrokes) else {
            return []
        }
        let merged = Node(strokes: allStrokes, bounds: bounds, boundaryStroke: boundary)
        let consumed = [strokeId] + containedStrokes.map(\.id)

        return canvas.execute(
            .mergeNodes(
                absorbing: enclosedNodes.map(\.id),
                into: merged,
                consumingStrokes: consumed
            ),
            origin: .local
        )
    }

    // MARK: - Node modification

    public func deleteNode(id nodeId: UUID) -> [CanvasEffect] {
        canvas.execute(.deleteNode(id: nodeId, returningStrokes: true), origin: .local)
    }

    /// Pull any loose strokes lying inside a node's bounds into that node.
    public func detectStrokesInNode(nodeId: UUID) -> [CanvasEffect] {
        guard var node = canvas.node(withId: nodeId) else { return [] }

        let inside = canvas.strokes.filter { mostlyInside($0, bounds: node.bounds) }
        guard !inside.isEmpty else { return [] }

        // Bounds deliberately unchanged: the node keeps the size it was drawn at.
        node.strokes.append(contentsOf: inside)

        var effects = canvas.execute(.updateNode(node), origin: .local)
        effects += canvas.execute(.deleteStrokes(ids: inside.map(\.id)), origin: .local)
        return effects
    }

    /// Scale a node proportionally about its centre, given a drag point in view space.
    ///
    /// - Parameters:
    ///   - startBounds: the node's bounds when the drag began, so the scale is
    ///     measured against a fixed origin rather than compounding each frame.
    ///   - startStrokes: likewise the strokes, so repeated scaling stays lossless.
    public func resizeNode(
        id nodeId: UUID,
        to endPoint: Vec2,
        startBounds: Rect,
        startStrokes: [Stroke],
        transform: ViewTransform
    ) -> [CanvasEffect] {
        guard var node = canvas.node(withId: nodeId) else { return [] }

        let center = startBounds.center
        let endWorld = transform.viewToWorld(endPoint)
        let delta = endWorld - center

        // Average the two axes so the node scales smoothly rather than snapping to
        // whichever axis the finger happens to favour.
        let scaleX = abs(delta.x) / (startBounds.width / 2.0)
        let scaleY = abs(delta.y) / (startBounds.height / 2.0)
        var scale = (scaleX + scaleY) / 2.0

        let minSizeWorld = transform.worldLength(fromViewPoints: 40.0)
        let minScale = minSizeWorld / min(startBounds.width, startBounds.height)
        scale = max(scale, minScale)

        let newWidth = startBounds.width * scale
        let newHeight = startBounds.height * scale
        node.bounds = Rect(
            x: center.x - newWidth / 2.0,
            y: center.y - newHeight / 2.0,
            width: newWidth,
            height: newHeight
        )

        node.strokes = startStrokes.map { stroke in
            var scaled = stroke
            scaled.points = stroke.points.map { point in
                var moved = point
                moved.position = center + (point.position - center) * scale
                return moved
            }
            return scaled
        }

        return canvas.execute(.updateNode(node), origin: .local)
    }

    /// Move a node by a world-space delta, taking its strokes with it.
    public func moveNode(id nodeId: UUID, by delta: Vec2) -> [CanvasEffect] {
        guard var node = canvas.node(withId: nodeId) else { return [] }

        node.bounds.x += delta.x
        node.bounds.y += delta.y
        node.strokes = node.strokes.map { stroke in
            var moved = stroke
            moved.points = stroke.points.map { point in
                var shifted = point
                shifted.position = point.position + delta
                return shifted
            }
            return moved
        }

        return canvas.execute(.updateNode(node), origin: .local)
    }

    /// Set the text a user typed into a node.
    ///
    /// - Parameter fittingBounds: a box large enough to hold the rendered text,
    ///   measured by the caller — text layout needs a font, which the domain has
    ///   no business knowing. The node grows to fit but never shrinks, so editing
    ///   a node down to a shorter string leaves the box where the user last had it.
    public func setText(
        _ text: String?,
        onNodeId nodeId: UUID,
        fittingBounds: Rect? = nil
    ) -> [CanvasEffect] {
        guard var node = canvas.node(withId: nodeId) else { return [] }

        node.text = text
        if let fittingBounds {
            node.bounds = Rect(
                x: node.bounds.x,
                y: node.bounds.y,
                width: max(node.bounds.width, fittingBounds.width),
                height: max(node.bounds.height, fittingBounds.height)
            )
        }

        return canvas.execute(.updateNode(node), origin: .local)
    }

    /// Put a reply on the canvas as its own node, pointed at by the node that
    /// asked the question.
    ///
    /// - Parameters:
    ///   - text: the reply.
    ///   - sourceId: the node whose contents were the prompt.
    ///   - size: how big the reply's box needs to be, measured by the caller —
    ///     text layout needs a font, which the domain has no business knowing.
    /// - Returns: the effects, empty if the source node has since been deleted.
    public func addReply(
        _ text: String,
        answering sourceId: UUID,
        size: Vec2
    ) -> [CanvasEffect] {
        guard let source = canvas.node(withId: sourceId) else { return [] }

        // Sit to the right of the question, top-aligned, with a gap wide enough
        // that the arrow between them is visible.
        let gap = 60.0
        let reply = Node(
            strokes: [],
            bounds: Rect(
                x: source.bounds.maxX + gap,
                y: source.bounds.y,
                width: size.x,
                height: size.y
            ),
            text: text
        )

        return canvas.execute(.createNodeLinked(reply, from: sourceId), origin: .local)
    }

    /// Record recognized handwriting on a node.
    ///
    /// The recognition itself runs on the platform side; only the result lands here.
    public func applyRecognizedText(
        _ recognized: RecognizedText,
        toNodeId nodeId: UUID
    ) -> [CanvasEffect] {
        guard var node = canvas.node(withId: nodeId) else { return [] }
        node.recognizedText = recognized
        return canvas.execute(.updateNode(node), origin: .local)
    }

    // MARK: - Connections

    @discardableResult
    public func connect(from sourceId: UUID, to targetId: UUID) -> [CanvasEffect] {
        canvas.execute(.connect(from: sourceId, to: targetId), origin: .local)
    }

    public func disconnect(id: UUID) -> [CanvasEffect] {
        canvas.execute(.disconnect(id: id), origin: .local)
    }

    // MARK: - Applying peer changes
    //
    // Everything below arrives from another device. It is applied with
    // `.remote` origin so it is never echoed back.

    public func applyReceivedStroke(_ stroke: Stroke) -> [CanvasEffect] {
        canvas.execute(.addStroke(stroke), origin: .remote)
    }

    public func applyReceivedStrokeDeletion(id: UUID) -> [CanvasEffect] {
        canvas.execute(.deleteStrokes(ids: [id]), origin: .remote)
    }

    public func applyReceivedNode(_ node: Node) -> [CanvasEffect] {
        canvas.execute(.createNode(node, consumingStrokes: []), origin: .remote)
    }

    public func applyReceivedNodeUpdate(_ node: Node) -> [CanvasEffect] {
        canvas.execute(.updateNode(node), origin: .remote)
    }

    public func applyReceivedNodeDeletion(id: UUID) -> [CanvasEffect] {
        canvas.execute(.deleteNode(id: id, returningStrokes: false), origin: .remote)
    }

    public func applyReceivedConnection(_ connection: Connection) -> [CanvasEffect] {
        canvas.execute(.connect(from: connection.from, to: connection.to), origin: .remote)
    }

    public func applyReceivedConnectionDeletion(id: UUID) -> [CanvasEffect] {
        canvas.execute(.disconnect(id: id), origin: .remote)
    }

    // MARK: - Helpers

    /// Whether most of a stroke lies within some bounds, by sampling.
    private func mostlyInside(_ stroke: Stroke, bounds: Rect) -> Bool {
        let sampleCount = min(stroke.points.count, 10)
        guard sampleCount > 0 else { return false }

        let step = max(1, stroke.points.count / sampleCount)
        var insideCount = 0
        for i in stride(from: 0, to: stroke.points.count, by: step) {
            if bounds.contains(stroke.points[i].position) { insideCount += 1 }
        }
        return insideCount > sampleCount / 2
    }
}
