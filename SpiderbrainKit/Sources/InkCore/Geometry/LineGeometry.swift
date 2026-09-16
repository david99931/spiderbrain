import Foundation

/// Distance and projection helpers for line segments.
public enum LineGeometry {

    /// Shortest distance from a point to a line segment.
    ///
    /// Clamped to the segment rather than the infinite line, so a point beyond an
    /// endpoint measures to that endpoint — which is what makes tapping near the
    /// end of a connection arrow behave the way you would expect.
    public static func distance(from point: Vec2, toSegmentFrom start: Vec2, to end: Vec2) -> Double {
        let lineVec = end - start
        let pointVec = point - start
        let lineLength = lineVec.length

        guard lineLength > 0 else { return point.distance(to: start) }

        let projectionRatio = (pointVec.x * lineVec.x + pointVec.y * lineVec.y) / (lineLength * lineLength)
        let clamped = max(0, min(1, projectionRatio))
        let projection = start + lineVec * clamped

        return point.distance(to: projection)
    }
}
