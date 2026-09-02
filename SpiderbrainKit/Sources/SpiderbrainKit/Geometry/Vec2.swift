import Foundation

/// A 2D point in world coordinates.
///
/// Deliberately `Double`, not `Float`. World coordinates are kept in Float64 on the
/// CPU and rebased against the camera origin before upload, so shaders always work
/// with small numbers near zero. See the architecture plan, "Coordinate precision".
public struct Vec2: Equatable, Sendable {
    public var x: Double
    public var y: Double

    public init(_ x: Double, _ y: Double) {
        self.x = x
        self.y = y
    }

    public static let zero = Vec2(0, 0)

    public static func + (a: Vec2, b: Vec2) -> Vec2 { Vec2(a.x + b.x, a.y + b.y) }
    public static func - (a: Vec2, b: Vec2) -> Vec2 { Vec2(a.x - b.x, a.y - b.y) }
    public static func * (v: Vec2, s: Double) -> Vec2 { Vec2(v.x * s, v.y * s) }
    public static func * (s: Double, v: Vec2) -> Vec2 { v * s }

    public var length: Double { (x * x + y * y).squareRoot() }

    public func distance(to other: Vec2) -> Double { (self - other).length }

    /// Unit vector, or `nil` when the vector is degenerate.
    public var normalized: Vec2? {
        let len = length
        guard len > .ulpOfOne else { return nil }
        return Vec2(x / len, y / len)
    }

    /// Left-hand perpendicular. Used to offset ribbon edges from the path.
    public var perpendicular: Vec2 { Vec2(-y, x) }
}

@inlinable
public func clamp(_ value: Double, _ low: Double, _ high: Double) -> Double {
    min(max(value, low), high)
}
