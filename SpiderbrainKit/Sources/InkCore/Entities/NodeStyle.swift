import Foundation

/// Visual styling for a node container.
public struct NodeStyle: Equatable, Codable {
    public var borderColor: (Double, Double, Double) // RGB
    public var borderWidth: Double
    public var fillColor: (Double, Double, Double, Double) // RGBA
    public var cornerRadius: Double

    public init(borderColor: (Double, Double, Double), borderWidth: Double, fillColor: (Double, Double, Double, Double), cornerRadius: Double) {
        self.borderColor = borderColor
        self.borderWidth = borderWidth
        self.fillColor = fillColor
        self.cornerRadius = cornerRadius
    }

    public static let `default` = NodeStyle(
        borderColor: (0.2, 0.4, 0.8),  // Blue
        borderWidth: 3.0,
        fillColor: (0.9, 0.95, 1.0, 0.1),  // Light blue tint
        cornerRadius: 12.0
    )

    public static func == (lhs: NodeStyle, rhs: NodeStyle) -> Bool {
        return lhs.borderColor == rhs.borderColor &&
               lhs.borderWidth == rhs.borderWidth &&
               lhs.fillColor == rhs.fillColor &&
               lhs.cornerRadius == rhs.cornerRadius
    }

    // Custom Codable implementation for tuples
    private enum CodingKeys: String, CodingKey {
        case borderColorR, borderColorG, borderColorB
        case borderWidth
        case fillColorR, fillColorG, fillColorB, fillColorA
        case cornerRadius
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let bcR = try container.decode(Double.self, forKey: .borderColorR)
        let bcG = try container.decode(Double.self, forKey: .borderColorG)
        let bcB = try container.decode(Double.self, forKey: .borderColorB)
        borderColor = (bcR, bcG, bcB)
        borderWidth = try container.decode(Double.self, forKey: .borderWidth)
        let fcR = try container.decode(Double.self, forKey: .fillColorR)
        let fcG = try container.decode(Double.self, forKey: .fillColorG)
        let fcB = try container.decode(Double.self, forKey: .fillColorB)
        let fcA = try container.decode(Double.self, forKey: .fillColorA)
        fillColor = (fcR, fcG, fcB, fcA)
        cornerRadius = try container.decode(Double.self, forKey: .cornerRadius)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(borderColor.0, forKey: .borderColorR)
        try container.encode(borderColor.1, forKey: .borderColorG)
        try container.encode(borderColor.2, forKey: .borderColorB)
        try container.encode(borderWidth, forKey: .borderWidth)
        try container.encode(fillColor.0, forKey: .fillColorR)
        try container.encode(fillColor.1, forKey: .fillColorG)
        try container.encode(fillColor.2, forKey: .fillColorB)
        try container.encode(fillColor.3, forKey: .fillColorA)
        try container.encode(cornerRadius, forKey: .cornerRadius)
    }
}
