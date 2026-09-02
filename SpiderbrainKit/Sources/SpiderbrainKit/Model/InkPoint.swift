import Foundation

/// One sample from the digitizer.
///
/// Apple Pencil delivers `force`, `altitude` and `azimuth` as *estimates* first and
/// corrects them milliseconds later. `estimationIndex` is how a correction finds its
/// way back to the right sample — see `StrokeInputCollector.applyEstimatedUpdate`.
public struct InkPoint: Equatable, Sendable {
    /// Position in view coordinates (points, y-down).
    public var position: Vec2
    /// Normalised 0...1. Fingers report 0 on devices without force, so the pressure
    /// curve has a floor rather than treating 0 as "no ink".
    public var force: Double
    /// Radians. 0 = pen flat against the glass, pi/2 = perpendicular.
    public var altitude: Double
    /// Radians, direction the pen is pointing.
    public var azimuth: Double
    public var timestamp: TimeInterval

    /// Set when any property above is still an estimate awaiting correction.
    public var estimationIndex: Int?
    /// True while at least one property is expected to be updated.
    public var expectsUpdates: Bool

    public init(
        position: Vec2,
        force: Double,
        altitude: Double = .pi / 2,
        azimuth: Double = 0,
        timestamp: TimeInterval = 0,
        estimationIndex: Int? = nil,
        expectsUpdates: Bool = false
    ) {
        self.position = position
        self.force = force
        self.altitude = altitude
        self.azimuth = azimuth
        self.timestamp = timestamp
        self.estimationIndex = estimationIndex
        self.expectsUpdates = expectsUpdates
    }
}
