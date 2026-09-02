import Foundation

/// A graph node containing handwritten strokes.
///
/// M2 prototype: nodes are created by lasso selection or auto-detection of closed shapes.
/// Each node captures a region of ink and can be moved, resized, and connected to other nodes.
public struct Node: Identifiable, Equatable {
    public let id: UUID

    /// The strokes contained in this node, in world coordinates.
    public var strokes: [Stroke]

    /// Bounding box in world coordinates.
    public var bounds: Rect

    /// Visual style for the node container.
    public var style: NodeStyle

    public init(id: UUID = UUID(), strokes: [Stroke], bounds: Rect, style: NodeStyle = .default) {
        self.id = id
        self.strokes = strokes
        self.bounds = bounds
        self.style = style
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

/// Visual styling for a node container.
public struct NodeStyle: Equatable {
    public var borderColor: (Double, Double, Double) // RGB
    public var borderWidth: Double
    public var fillColor: (Double, Double, Double, Double) // RGBA
    public var cornerRadius: Double

    public static let `default` = NodeStyle(
        borderColor: (0.2, 0.4, 0.8),  // Blue
        borderWidth: 3.0,
        fillColor: (0.9, 0.95, 1.0, 0.1),  // Light blue tint
        cornerRadius: 12.0
    )

    public static func == (lhs: NodeStyle, rhs: NodeStyle) -> Bool {
        return lhs.borderColor == rhs.borderColor &&
               lhs.borderWidth == rhs.borderWidth &&
               lhs.fillColor == rhs.fillColor &&
               lhs.cornerRadius == rhs.cornerRadius
    }
}

/// A rectangle in world space.
public struct Rect: Equatable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var center: Vec2 {
        Vec2(x + width / 2, y + height / 2)
    }

    public var minX: Double { x }
    public var minY: Double { y }
    public var maxX: Double { x + width }
    public var maxY: Double { y + height }

    /// Check if a point is inside this rectangle.
    public func contains(_ point: Vec2) -> Bool {
        return point.x >= minX && point.x <= maxX &&
               point.y >= minY && point.y <= maxY
    }

    /// Check if this rectangle intersects another.
    public func intersects(_ other: Rect) -> Bool {
        return !(maxX < other.minX || minX > other.maxX ||
                 maxY < other.minY || minY > other.maxY)
    }
}
