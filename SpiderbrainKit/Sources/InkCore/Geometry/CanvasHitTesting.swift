import Foundation

/// Finding what the user tapped.
///
/// Hit areas are expressed in view points and converted to world distances, so a
/// small node stays equally tappable at any zoom level.
public enum CanvasHitTesting {

    /// Minimum tappable size for a node, in view points.
    private static let minimumNodeHitSize = 80.0

    /// How close a tap must land to a connection arrow, in view points.
    private static let connectionTapThreshold = 20.0

    /// Hit radius of a node's resize handle, in view points.
    private static let resizeHandleHitRadius = 20.0

    /// The topmost node at a view point, or nil.
    ///
    /// Small nodes get an expanded hit area so they remain tappable; nodes are
    /// searched front to back so the one drawn on top wins.
    public static func node(
        at viewPoint: Vec2,
        in nodes: [Node],
        transform: ViewTransform
    ) -> Node? {
        let worldPoint = transform.viewToWorld(viewPoint)
        let minHitSize = transform.worldLength(fromViewPoints: minimumNodeHitSize)

        for node in nodes.reversed() {
            if hitBounds(for: node, minimumSize: minHitSize).contains(worldPoint) {
                return node
            }
        }
        return nil
    }

    /// A node's bounds, expanded if it is smaller than the minimum hit size.
    public static func hitBounds(for node: Node, minimumSize: Double) -> Rect {
        let bounds = node.bounds
        guard bounds.width < minimumSize || bounds.height < minimumSize else { return bounds }

        let expandX = max(0, (minimumSize - bounds.width) / 2)
        let expandY = max(0, (minimumSize - bounds.height) / 2)
        return Rect(
            x: bounds.x - expandX,
            y: bounds.y - expandY,
            width: bounds.width + expandX * 2,
            height: bounds.height + expandY * 2
        )
    }

    /// The connection whose arrow passes near a view point, or nil.
    ///
    /// Connections whose endpoints are missing are skipped rather than treated as
    /// hits — there is no arrow drawn for them.
    public static func connection(
        at viewPoint: Vec2,
        in connections: [Connection],
        nodes: [Node],
        transform: ViewTransform
    ) -> Connection? {
        let worldPoint = transform.viewToWorld(viewPoint)
        let threshold = transform.worldLength(fromViewPoints: connectionTapThreshold)

        for connection in connections {
            guard let source = nodes.first(where: { $0.id == connection.from }),
                  let target = nodes.first(where: { $0.id == connection.to }) else { continue }

            let distance = LineGeometry.distance(
                from: worldPoint,
                toSegmentFrom: source.bounds.center,
                to: target.bounds.center
            )
            if distance < threshold { return connection }
        }
        return nil
    }

    /// Where a node's resize handle sits, in view space.
    public static func resizeHandlePosition(for node: Node, transform: ViewTransform) -> Vec2 {
        transform.worldToView(Vec2(node.bounds.maxX, node.bounds.maxY))
    }

    /// Whether a view point lands on a node's resize handle.
    public static func isNearResizeHandle(
        viewPoint: Vec2,
        node: Node,
        transform: ViewTransform
    ) -> Bool {
        let handle = resizeHandlePosition(for: node, transform: transform)
        return viewPoint.distance(to: handle) <= resizeHandleHitRadius
    }
}
