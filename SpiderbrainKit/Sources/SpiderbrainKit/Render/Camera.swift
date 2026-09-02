#if os(iOS)
import Foundation

/// Camera for the infinite canvas: tracks pan and zoom, transforms between view and world space.
///
/// Coordinate spaces:
/// - **View space**: UIKit screen coordinates (points). Origin at top-left.
/// - **World space**: Infinite canvas coordinates (points). Origin at (0, 0).
///
/// The camera defines what portion of the world is visible in the view.
public struct Camera {
    /// World-space position at the center of the view.
    public var offset: Vec2

    /// Zoom level. 1.0 = 100%, 2.0 = 200% (zoomed in), 0.5 = 50% (zoomed out).
    public var zoom: Float

    /// Minimum allowed zoom (maximum zoom out).
    public var minZoom: Float = 0.1

    /// Maximum allowed zoom (maximum zoom in).
    public var maxZoom: Float = 10.0

    public init(offset: Vec2 = .zero, zoom: Float = 1.0) {
        self.offset = offset
        self.zoom = max(minZoom, min(maxZoom, zoom))
    }

    // MARK: - Transform

    /// Convert a point from view space (screen pixels) to world space (canvas).
    ///
    /// - Parameters:
    ///   - viewPoint: Point in view coordinates.
    ///   - viewSize: Size of the view in points.
    /// - Returns: Point in world coordinates.
    public func viewToWorld(_ viewPoint: Vec2, viewSize: Vec2) -> Vec2 {
        let viewCenter = viewSize * 0.5
        return (viewPoint - viewCenter) / zoom + offset
    }

    /// Convert a point from world space (canvas) to view space (screen pixels).
    ///
    /// - Parameters:
    ///   - worldPoint: Point in world coordinates.
    ///   - viewSize: Size of the view in points.
    /// - Returns: Point in view coordinates.
    public func worldToView(_ worldPoint: Vec2, viewSize: Vec2) -> Vec2 {
        let viewCenter = viewSize * 0.5
        return (worldPoint - offset) * zoom + viewCenter
    }

    // MARK: - Manipulation

    /// Pan the camera by a delta in view space.
    ///
    /// - Parameter viewDelta: Movement in view coordinates (e.g., from a pan gesture).
    public mutating func pan(by viewDelta: Vec2) {
        // Moving right in view space means the camera offset moves left in world space
        offset = offset - (viewDelta / zoom)
    }

    /// Zoom the camera, keeping a specific view point fixed in world space.
    ///
    /// - Parameters:
    ///   - factor: Multiplier for zoom (e.g., 1.1 to zoom in 10%, 0.9 to zoom out 10%).
    ///   - anchor: The view-space point to keep fixed (typically the pinch center).
    ///   - viewSize: Size of the view in points.
    public mutating func zoom(by factor: Float, anchor: Vec2, viewSize: Vec2) {
        // Find the world point under the anchor before zooming
        let worldAnchor = viewToWorld(anchor, viewSize: viewSize)

        // Apply zoom with clamping
        let newZoom = max(minZoom, min(maxZoom, zoom * factor))
        zoom = newZoom

        // Adjust offset so the world point stays under the anchor after zooming
        offset = worldAnchor - (anchor - viewSize * 0.5) / zoom
    }
}
#endif
