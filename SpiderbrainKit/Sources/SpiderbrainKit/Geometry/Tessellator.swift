import Foundation

/// One GPU vertex. Position is in view points; the vertex shader maps to NDC.
///
/// Colour is RGB only, with no per-vertex alpha. Alpha is applied once when the
/// offscreen ink layer is composited, which is what stops a stroke crossing itself
/// from blending twice and going blotchy. See `InkRenderer`.
public struct InkVertex: Equatable, Sendable {
    public var x: Float
    public var y: Float
    public var r: Float
    public var g: Float
    public var b: Float

    public init(x: Float, y: Float, r: Float, g: Float, b: Float) {
        self.x = x
        self.y = y
        self.r = r
        self.g = g
        self.b = b
    }
}

/// Converts a smoothed centreline into a triangle list.
///
/// A non-indexed triangle list is more vertices than a strip, but it lets caps and
/// body share one draw call and removes a whole class of winding bugs. At one live
/// stroke per frame the cost is irrelevant.
public enum Tessellator {

    /// Triangles per round cap. 8 is indistinguishable from a circle at pen widths.
    public static let capSegments = 8

    public static func tessellate(_ points: [ResampledPoint], style: InkStyle) -> [InkVertex] {
        guard !points.isEmpty else { return [] }

        let r = Float(style.red)
        let g = Float(style.green)
        let b = Float(style.blue)

        func vertex(_ p: Vec2) -> InkVertex {
            InkVertex(x: Float(p.x), y: Float(p.y), r: r, g: g, b: b)
        }

        // A single sample is a dot: just a filled circle.
        guard points.count > 1 else {
            let only = points[0]
            let radius = style.pressure.halfWidth(force: only.force, altitude: only.altitude)
            return disc(centre: only.position, radius: radius, vertex: vertex)
        }

        var vertices: [InkVertex] = []
        vertices.reserveCapacity(points.count * 6 + capSegments * 6)

        // Body: one quad per span, as two triangles.
        for i in 0..<(points.count - 1) {
            let a = points[i]
            let c = points[i + 1]

            let aHalf = style.pressure.halfWidth(force: a.force, altitude: a.altitude)
            let cHalf = style.pressure.halfWidth(force: c.force, altitude: c.altitude)

            let aNormal = a.tangent.perpendicular
            let cNormal = c.tangent.perpendicular

            let aLeft = a.position + aNormal * aHalf
            let aRight = a.position - aNormal * aHalf
            let cLeft = c.position + cNormal * cHalf
            let cRight = c.position - cNormal * cHalf

            vertices.append(vertex(aLeft))
            vertices.append(vertex(aRight))
            vertices.append(vertex(cLeft))

            vertices.append(vertex(cLeft))
            vertices.append(vertex(aRight))
            vertices.append(vertex(cRight))
        }

        // Round caps at both ends, so strokes don't look chopped off.
        if let first = points.first {
            let radius = style.pressure.halfWidth(force: first.force, altitude: first.altitude)
            vertices.append(contentsOf: disc(centre: first.position, radius: radius, vertex: vertex))
        }
        if let last = points.last {
            let radius = style.pressure.halfWidth(force: last.force, altitude: last.altitude)
            vertices.append(contentsOf: disc(centre: last.position, radius: radius, vertex: vertex))
        }

        return vertices
    }

    /// A filled circle as a triangle fan expanded into a list.
    private static func disc(
        centre: Vec2,
        radius: Double,
        vertex: (Vec2) -> InkVertex
    ) -> [InkVertex] {
        guard radius > 0 else { return [] }
        var vertices: [InkVertex] = []
        vertices.reserveCapacity(capSegments * 3)

        let step = (2 * Double.pi) / Double(capSegments)
        for i in 0..<capSegments {
            let a0 = Double(i) * step
            let a1 = Double(i + 1) * step
            let p0 = centre + Vec2(cos(a0), sin(a0)) * radius
            let p1 = centre + Vec2(cos(a1), sin(a1)) * radius
            vertices.append(vertex(centre))
            vertices.append(vertex(p0))
            vertices.append(vertex(p1))
        }
        return vertices
    }
}
