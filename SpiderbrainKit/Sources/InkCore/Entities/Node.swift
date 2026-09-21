import Foundation

/// A graph node containing handwritten strokes.
///
/// M2 prototype: nodes are created by lasso selection or auto-detection of closed shapes.
/// Each node captures a region of ink and can be moved, resized, and connected to other nodes.
public struct Node: Identifiable, Equatable, Codable {
    public let id: UUID

    /// The strokes contained in this node, in world coordinates.
    public var strokes: [Stroke]

    /// Bounding box in world coordinates.
    public var bounds: Rect

    /// Visual style for the node container.
    public var style: NodeStyle

    /// The boundary stroke that created this node (the blue circle).
    /// Stored so we can remove it when the node is absorbed.
    public var boundaryStroke: Stroke?

    /// Recognized text from handwriting recognition (if available).
    public var recognizedText: RecognizedText?

    /// Text the user typed, as opposed to wrote.
    ///
    /// Kept separate from `recognizedText` because the two differ in kind: this is
    /// authored and exact, recognition is a guess at what the ink says. They are
    /// used together — see `promptText` — but a node can have either, both, or
    /// neither, and typed text is never overwritten by a later recognition pass.
    public var text: String?

    public init(
        id: UUID = UUID(),
        strokes: [Stroke],
        bounds: Rect,
        style: NodeStyle = .default,
        boundaryStroke: Stroke? = nil,
        recognizedText: RecognizedText? = nil,
        text: String? = nil
    ) {
        self.id = id
        self.strokes = strokes
        self.bounds = bounds
        self.style = style
        self.boundaryStroke = boundaryStroke
        self.recognizedText = recognizedText
        self.text = text
    }

    /// Everything this node says, as a prompt.
    ///
    /// Typed text wins over recognition when both are present, since recognition
    /// is lossy and typing is not.
    ///
    /// Deliberately a computed composition rather than a stored field: a node's
    /// meaning is going to grow beyond a single string — ink that underlines a
    /// word is emphasis the model should see — and this is where that folds in
    /// without touching the callers.
    public var promptText: String? {
        let typed = text?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let typed, !typed.isEmpty { return typed }

        let recognized = recognizedText?.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let recognized, !recognized.isEmpty { return recognized }

        return nil
    }

    public static func == (lhs: Node, rhs: Node) -> Bool {
        return lhs.id == rhs.id
    }

    /// Compute the bounding box that contains all strokes.
    public static func computeBounds(_ strokes: [Stroke]) -> Rect? {
        guard !strokes.isEmpty else { return nil }

        var minX = Double.infinity
        var minY = Double.infinity
        var maxX = -Double.infinity
        var maxY = -Double.infinity

        for stroke in strokes {
            for point in stroke.points {
                minX = min(minX, point.position.x)
                minY = min(minY, point.position.y)
                maxX = max(maxX, point.position.x)
                maxY = max(maxY, point.position.y)
            }
        }

        // Add padding around the strokes
        let padding = 20.0
        return Rect(
            x: minX - padding,
            y: minY - padding,
            width: maxX - minX + padding * 2,
            height: maxY - minY + padding * 2
        )
    }

    /// Check if a point in world space is inside this node's bounds.
    public func contains(_ point: Vec2) -> Bool {
        return bounds.contains(point)
    }
}
