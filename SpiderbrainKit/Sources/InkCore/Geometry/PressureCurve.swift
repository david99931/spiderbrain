import Foundation

/// Maps pen force and tilt to stroke width.
///
/// Linear pressure feels wrong — it makes light strokes vanish and heavy strokes
/// blobby. A smoothstep with an exponent gives contrast in the middle of the range
/// where handwriting actually lives, and `minWidth` guarantees a light stroke still
/// leaves a mark.
public struct PressureCurve: Equatable, Sendable, Codable {
    /// Width in points at zero force.
    public var minWidth: Double
    /// Width in points at full force.
    public var maxWidth: Double
    /// Above 1 pushes contrast toward heavier pressure. 1 is plain smoothstep.
    public var exponent: Double
    /// How much a flat pen broadens the mark. 0 disables tilt entirely.
    public var tiltBroadening: Double

    public init(minWidth: Double, maxWidth: Double, exponent: Double, tiltBroadening: Double) {
        self.minWidth = minWidth
        self.maxWidth = maxWidth
        self.exponent = exponent
        self.tiltBroadening = tiltBroadening
    }

    public static let pen = PressureCurve(
        minWidth: 1.4, maxWidth: 6.0, exponent: 1.25, tiltBroadening: 0.35
    )

    public static let marker = PressureCurve(
        minWidth: 6.0, maxWidth: 14.0, exponent: 1.0, tiltBroadening: 0.6
    )

    /// Full stroke width in points for a given normalised force and altitude.
    public func width(force: Double, altitude: Double = .pi / 2) -> Double {
        let f = clamp(force, 0, 1)
        let smooth = f * f * (3 - 2 * f)
        let shaped = exponent == 1 ? smooth : pow(smooth, exponent)
        var w = minWidth + (maxWidth - minWidth) * shaped

        if tiltBroadening > 0 {
            // altitude pi/2 = perpendicular = no broadening; 0 = flat = full broadening
            let perpendicular = Double.pi / 2
            let tilt = clamp((perpendicular - altitude) / perpendicular, 0, 1)
            w *= 1 + tiltBroadening * tilt
        }
        return w
    }

    public func halfWidth(force: Double, altitude: Double = .pi / 2) -> Double {
        width(force: force, altitude: altitude) / 2
    }
}
