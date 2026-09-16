import Foundation

/// Heuristics for deciding whether a drawn stroke is a container shape.
///
/// This is what decides whether drawing a circle offers to make a node, so its
/// thresholds are load-bearing: too eager and every handwritten "o" becomes a
/// node, too strict and deliberate circles are ignored.
public enum ShapeDetection {

    /// Endpoints must land within this fraction of the stroke's own size for the
    /// stroke to count as closed.
    private static let closureThresholdRatio = 0.25

    /// Circles larger than this are never treated as letters.
    private static let maximumLetterSize = 60.0

    /// How far to look for similar-sized neighbours, as a multiple of stroke size.
    private static let neighbourSearchRadiusRatio = 3.0

    /// Similar-size band for deciding a neighbour is part of the same writing.
    private static let similarSizeRange = 0.5...2.0

    /// Number of similar-sized neighbours that mark a small circle as a letter.
    private static let lettersNeededNearby = 2

    /// Whether a stroke forms a closed shape suitable for becoming a node.
    ///
    /// - Parameters:
    ///   - stroke: the candidate stroke.
    ///   - otherStrokes: strokes already on the canvas, used to tell a deliberate
    ///     small circle apart from a letter inside handwriting.
    public static func isClosedShape(_ stroke: Stroke, among otherStrokes: [Stroke]) -> Bool {
        guard stroke.points.count > 5 else { return false }

        let start = stroke.points.first!.position
        let end = stroke.points.last!.position
        let distance = start.distance(to: end)

        guard let bounds = stroke.bounds else { return false }
        let size = max(bounds.max.x - bounds.min.x, bounds.max.y - bounds.min.y)

        // Endpoints close relative to the stroke's own size, so big loose circles
        // and small tight ones are judged on the same terms.
        guard distance < size * closureThresholdRatio else { return false }

        return !isLikelyLetter(stroke, size: size, among: otherStrokes)
    }

    /// Whether a small circle is probably a letter (o, O, 0) rather than a container.
    ///
    /// Judged by company: a lone small circle is taken at face value, but one
    /// sitting among similar-sized strokes is almost certainly handwriting.
    public static func isLikelyLetter(
        _ stroke: Stroke,
        size: Double,
        among otherStrokes: [Stroke]
    ) -> Bool {
        guard size < maximumLetterSize else { return false }
        guard let strokeBounds = stroke.bounds else { return false }

        let strokeCenter = center(of: strokeBounds)
        let searchRadius = size * neighbourSearchRadiusRatio
        var nearbyCount = 0

        for other in otherStrokes {
            guard other.id != stroke.id, let otherBounds = other.bounds else { continue }

            let distanceToOther = strokeCenter.distance(to: center(of: otherBounds))
            guard distanceToOther < searchRadius else { continue }

            let otherSize = max(
                otherBounds.max.x - otherBounds.min.x,
                otherBounds.max.y - otherBounds.min.y
            )
            guard size > 0, similarSizeRange.contains(otherSize / size) else { continue }

            nearbyCount += 1
            if nearbyCount >= lettersNeededNearby { return true }
        }

        return false
    }

    private static func center(of bounds: (min: Vec2, max: Vec2)) -> Vec2 {
        Vec2(
            bounds.min.x + (bounds.max.x - bounds.min.x) / 2,
            bounds.min.y + (bounds.max.y - bounds.min.y) / 2
        )
    }
}
