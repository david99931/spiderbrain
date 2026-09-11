import Foundation

/// A rectangle in world space.
public struct Rect: Equatable, Codable {
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
