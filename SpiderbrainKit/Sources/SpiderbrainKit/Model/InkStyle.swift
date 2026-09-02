import Foundation

/// Colour and width behaviour for a stroke.
public struct InkStyle: Equatable, Sendable {
    public var red: Double
    public var green: Double
    public var blue: Double
    /// Applied once at composite time, not per vertex. See `InkRenderer` for why.
    public var alpha: Double
    public var pressure: PressureCurve

    public init(
        red: Double = 0.09,
        green: Double = 0.11,
        blue: Double = 0.13,
        alpha: Double = 1.0,
        pressure: PressureCurve = .pen
    ) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
        self.pressure = pressure
    }

    public static let pen = InkStyle()

    public static let highlighter = InkStyle(
        red: 0.98, green: 0.85, blue: 0.24, alpha: 0.35,
        pressure: PressureCurve(minWidth: 16, maxWidth: 22, exponent: 1.0, tiltBroadening: 0)
    )
}
