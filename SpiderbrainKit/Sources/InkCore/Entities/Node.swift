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

    /// M2 prototype: Outgoing connections to other nodes (this node → target nodes).
    /// Represents the DAG structure where this node points to its children/details.
    public var connections: [UUID]

    /// Recognized text from handwriting recognition (if available).
    public var recognizedText: RecognizedText?

    public init(id: UUID = UUID(), strokes: [Stroke], bounds: Rect, style: NodeStyle = .default, boundaryStroke: Stroke? = nil, connections: [UUID] = [], recognizedText: RecognizedText? = nil) {
        self.id = id
        self.strokes = strokes
        self.bounds = bounds
        self.style = style
        self.boundaryStroke = boundaryStroke
        self.connections = connections
        self.recognizedText = recognizedText
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
