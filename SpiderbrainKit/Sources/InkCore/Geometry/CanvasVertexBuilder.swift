import Foundation

/// Turns canvas contents into GPU vertices.
///
/// Pure geometry: takes what to draw and how the camera is framed, returns
/// triangles. Knows nothing about Metal, the view, or when to redraw — which is
/// what lets it be tested without any of them.
public enum CanvasVertexBuilder {

    /// Visual state that changes how things are drawn but is not part of the data.
    public struct Highlight: Equatable {
        public var selectedNodeId: UUID?
        public var selectedConnectionId: UUID?

        public init(selectedNodeId: UUID? = nil, selectedConnectionId: UUID? = nil) {
            self.selectedNodeId = selectedNodeId
            self.selectedConnectionId = selectedConnectionId
        }

        public static let none = Highlight()
    }

    private static let selectedColor = (0.9, 0.6, 0.2)
    private static let connectionColor = (0.5, 0.5, 0.5)
    private static let handleColor = (0.9, 0.9, 1.0)
    private static let lassoColor = (0.2, 0.5, 1.0)

    /// Every vertex for the committed canvas, in draw order.
    ///
    /// Arrows are emitted before nodes so they pass underneath rather than over.
    public static func committedGeometry(
        strokes: [Stroke],
        nodes: [Node],
        connections: [Connection],
        highlight: Highlight,
        transform: ViewTransform
    ) -> [InkVertex] {
        var vertices = strokes.flatMap { tessellate($0) }

        for connection in connections {
            vertices += connectionArrow(connection, nodes: nodes, highlight: highlight)
        }

        for node in nodes {
            vertices += nodeOutline(node, highlight: highlight)
            vertices += node.strokes.flatMap { tessellate($0) }

            if node.id == highlight.selectedNodeId {
                vertices += resizeHandle(for: node, transform: transform)
            }
        }

        return vertices
    }

    /// The in-progress lasso path, given points in view space.
    public static func lassoPath(
        viewPoints: [Vec2],
        transform: ViewTransform
    ) -> [InkVertex] {
        guard viewPoints.count > 1 else { return [] }

        let points = viewPoints.map { flatPoint(at: transform.viewToWorld($0)) }
        return tessellate(points, color: lassoColor, alpha: 0.7, width: 2)
    }

    /// A node's bounding outline. Selected nodes are drawn brighter and thicker.
    public static func nodeOutline(_ node: Node, highlight: Highlight) -> [InkVertex] {
        let bounds = node.bounds
        let isSelected = node.id == highlight.selectedNodeId
        let color = isSelected ? selectedColor : node.style.borderColor
        let width = isSelected ? node.style.borderWidth * 2.0 : node.style.borderWidth

        let corners = [
            Vec2(bounds.x, bounds.y),
            Vec2(bounds.maxX, bounds.y),
            Vec2(bounds.maxX, bounds.maxY),
            Vec2(bounds.x, bounds.maxY),
            Vec2(bounds.x, bounds.y)  // close the loop
        ]

        return tessellate(corners.map(flatPoint(at:)), color: color, alpha: 1.0, width: width)
    }

    /// The drag-to-resize handle at a node's bottom-right corner.
    ///
    /// Sized in view points and converted to world space, so it stays the same size
    /// on screen at any zoom.
    public static func resizeHandle(for node: Node, transform: ViewTransform) -> [InkVertex] {
        let radius = transform.worldLength(fromViewPoints: 10.0)
        let center = Vec2(node.bounds.maxX, node.bounds.maxY)

        let segments = 16
        let circle = (0...segments).map { i -> InkPoint in
            let angle = Double(i) * 2.0 * .pi / Double(segments)
            return flatPoint(at: Vec2(
                center.x + radius * cos(angle),
                center.y + radius * sin(angle)
            ))
        }

        return tessellate(circle, color: handleColor, alpha: 1.0, width: 3.0)
    }

    /// An arrow from one node's centre to another's.
    ///
    /// Returns nothing when either endpoint is missing — there is no line to draw
    /// between a node and a node that isn't there.
    public static func connectionArrow(
        _ connection: Connection,
        nodes: [Node],
        highlight: Highlight
    ) -> [InkVertex] {
        guard let source = nodes.first(where: { $0.id == connection.from }),
              let target = nodes.first(where: { $0.id == connection.to }) else { return [] }

        let start = source.bounds.center
        let end = target.bounds.center
        guard let direction = (end - start).normalized else { return [] }

        let isSelected = connection.id == highlight.selectedConnectionId
        let color = isSelected ? selectedColor : connectionColor
        let shaftWidth = isSelected ? 4.0 : 2.0
        let headLength = 20.0
        let headWidth = isSelected ? 16.0 : 12.0

        // The shaft stops short so the head, not the line, reaches the target.
        let headBase = end - direction * headLength
        var vertices = tessellate(
            [flatPoint(at: start), flatPoint(at: headBase)],
            color: color,
            alpha: 1.0,
            width: shaftWidth
        )

        // The head is a bare triangle rather than a tessellated stroke.
        let perpendicular = direction.perpendicular
        let r = Float(color.0), g = Float(color.1), b = Float(color.2)
        for corner in [
            headBase + perpendicular * (headWidth / 2),
            headBase - perpendicular * (headWidth / 2),
            end
        ] {
            vertices.append(InkVertex(x: Float(corner.x), y: Float(corner.y), r: r, g: g, b: b))
        }

        return vertices
    }

    // MARK: - Helpers

    /// A sample with no pressure or tilt, for geometry that isn't handwriting.
    private static func flatPoint(at position: Vec2) -> InkPoint {
        InkPoint(position: position, force: 0.5, altitude: .pi / 2, azimuth: 0, timestamp: 0)
    }

    private static func tessellate(_ stroke: Stroke) -> [InkVertex] {
        Tessellator.tessellate(StrokeSmoother.resample(stroke.points), style: stroke.style)
    }

    /// Tessellate at a uniform width, for outlines and other non-ink geometry.
    private static func tessellate(
        _ points: [InkPoint],
        color: (Double, Double, Double),
        alpha: Double,
        width: Double
    ) -> [InkVertex] {
        let style = InkStyle(
            red: color.0,
            green: color.1,
            blue: color.2,
            alpha: alpha,
            pressure: PressureCurve(
                minWidth: width,
                maxWidth: width,
                exponent: 1.0,
                tiltBroadening: 0
            )
        )
        return Tessellator.tessellate(StrokeSmoother.resample(points), style: style)
    }
}
