import Foundation

/// A camera paired with the size of the view it is looking through.
///
/// The two always travel together — every view/world conversion needs both — so
/// they are one value rather than two parameters threaded side by side through
/// every hit test and vertex builder.
public struct ViewTransform: Equatable {
    public var camera: Camera
    public var viewSize: Vec2

    public init(camera: Camera, viewSize: Vec2) {
        self.camera = camera
        self.viewSize = viewSize
    }

    /// Current zoom level. 1.0 = 100%.
    public var zoom: Float { camera.zoom }

    public func viewToWorld(_ viewPoint: Vec2) -> Vec2 {
        camera.viewToWorld(viewPoint, viewSize: viewSize)
    }

    public func worldToView(_ worldPoint: Vec2) -> Vec2 {
        camera.worldToView(worldPoint, viewSize: viewSize)
    }

    /// Convert a length in view points to the equivalent length in world space.
    ///
    /// Hit areas and handle sizes are specified in view points so they stay a
    /// constant size on screen; this is what turns them into world distances.
    public func worldLength(fromViewPoints points: Double) -> Double {
        points / Double(camera.zoom)
    }
}
