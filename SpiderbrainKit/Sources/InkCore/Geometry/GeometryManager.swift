import Foundation

/// Handles geometric calculations and spatial queries
public class GeometryManager {

    /// Check if a stroke is inside a lasso polygon
    /// Uses sampling to check if most points are inside
    public static func isStrokeInsideLasso(_ stroke: Stroke, lasso: [Vec2]) -> Bool {
        // Simple heuristic: check if most sample points are inside the lasso
        let sampleCount = min(stroke.points.count, 10)
        let step = max(1, stroke.points.count / sampleCount)
        var insideCount = 0

        for i in stride(from: 0, to: stroke.points.count, by: step) {
            if pointInPolygon(stroke.points[i].position, polygon: lasso) {
                insideCount += 1
            }
        }

        // If more than half the samples are inside, consider the stroke selected
        return insideCount > sampleCount / 2
    }

    /// Point-in-polygon test using ray casting algorithm
    public static func pointInPolygon(_ point: Vec2, polygon: [Vec2]) -> Bool {
        guard polygon.count > 2 else { return false }

        var inside = false
        var j = polygon.count - 1

        for i in 0..<polygon.count {
            let pi = polygon[i]
            let pj = polygon[j]

            if ((pi.y > point.y) != (pj.y > point.y)) &&
               (point.x < (pj.x - pi.x) * (point.y - pi.y) / (pj.y - pi.y) + pi.x) {
                inside.toggle()
            }
            j = i
        }

        return inside
    }
}
