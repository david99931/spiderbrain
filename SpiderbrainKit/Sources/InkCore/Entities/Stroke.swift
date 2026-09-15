import Foundation

/// A committed stroke. Immutable once the pen lifts, which is what makes the
/// document an append-only log and the CRDT merge trivial.
public struct Stroke: Identifiable, Equatable, Sendable, Codable {
    public let id: UUID
    public var points: [InkPoint]
    public var style: InkStyle

    public init(id: UUID = UUID(), points: [InkPoint], style: InkStyle) {
        self.id = id
        self.points = points
        self.style = style
    }

    /// Axis-aligned bounds, ignoring stroke width. Cheap; good enough for culling.
    public var bounds: (min: Vec2, max: Vec2)? {
        guard let first = points.first else { return nil }
        var lo = first.position
        var hi = first.position
        for point in points.dropFirst() {
            lo = Vec2(Swift.min(lo.x, point.position.x), Swift.min(lo.y, point.position.y))
            hi = Vec2(Swift.max(hi.x, point.position.x), Swift.max(hi.y, point.position.y))
        }
        return (lo, hi)
    }
}
