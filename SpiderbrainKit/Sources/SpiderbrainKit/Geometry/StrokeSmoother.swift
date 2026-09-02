import Foundation

/// A point on the smoothed centreline, ready to be turned into geometry.
public struct ResampledPoint: Equatable, Sendable {
    public var position: Vec2
    /// Unit tangent along the path.
    public var tangent: Vec2
    public var force: Double
    public var altitude: Double

    public init(position: Vec2, tangent: Vec2, force: Double, altitude: Double) {
        self.position = position
        self.tangent = tangent
        self.force = force
        self.altitude = altitude
    }
}

/// Turns raw digitizer samples into an evenly spaced, smoothed centreline.
///
/// Raw touch points are noisy and irregularly spaced — fast strokes give sparse
/// samples, slow ones give dense clusters. Interpolating with a centripetal
/// Catmull-Rom spline (alpha = 0.5) passes exactly through every sample, which
/// matters for ink, while avoiding the cusps and self-intersections that uniform
/// Catmull-Rom produces on sharp corners.
///
/// Resampling at constant arc length afterwards is what lets width vary smoothly:
/// width is applied per output point, so irregular input spacing would otherwise
/// show up as lumpy strokes.
public enum StrokeSmoother {

    /// Minimum distance between input samples. Closer points are dropped, since
    /// coincident points make tangents and the spline parameterisation degenerate.
    public static let minimumSampleDistance: Double = 0.05

    /// Substeps evaluated per spline segment before arc-length resampling.
    private static let substepsPerSegment = 16

    /// - Parameters:
    ///   - points: raw samples, in order.
    ///   - spacing: distance in points between output samples. Around 1.0 keeps
    ///     mitre artifacts invisible without generating excessive geometry.
    public static func resample(_ points: [InkPoint], spacing: Double = 1.0) -> [ResampledPoint] {
        let cleaned = dedupe(points)
        guard cleaned.count > 1 else {
            // A single tap is a dot: one point with an arbitrary tangent.
            if let only = cleaned.first {
                return [ResampledPoint(
                    position: only.position,
                    tangent: Vec2(1, 0),
                    force: only.force,
                    altitude: only.altitude
                )]
            }
            return []
        }

        let dense = densePolyline(cleaned)
        return walk(dense, spacing: max(spacing, 0.05))
    }

    // MARK: - Steps

    static func dedupe(_ points: [InkPoint]) -> [InkPoint] {
        var result: [InkPoint] = []
        for point in points {
            if let last = result.last,
               last.position.distance(to: point.position) < minimumSampleDistance {
                continue
            }
            result.append(point)
        }
        return result
    }

    /// Evaluate the spline into a fine polyline, carrying force and altitude along.
    private static func densePolyline(_ points: [InkPoint]) -> [ResampledPoint] {
        var output: [ResampledPoint] = []
        output.reserveCapacity(points.count * substepsPerSegment)

        for i in 0..<(points.count - 1) {
            // Duplicate the endpoints so the first and last segments are defined.
            let p0 = points[max(i - 1, 0)]
            let p1 = points[i]
            let p2 = points[i + 1]
            let p3 = points[min(i + 2, points.count - 1)]

            let steps = substepsPerSegment
            for step in 0..<steps {
                let t = Double(step) / Double(steps)
                let position = catmullRom(
                    p0.position, p1.position, p2.position, p3.position, t: t
                )
                output.append(ResampledPoint(
                    position: position,
                    tangent: Vec2(1, 0), // filled in during the walk
                    force: p1.force + (p2.force - p1.force) * t,
                    altitude: p1.altitude + (p2.altitude - p1.altitude) * t
                ))
            }
        }

        if let last = points.last {
            output.append(ResampledPoint(
                position: last.position,
                tangent: Vec2(1, 0),
                force: last.force,
                altitude: last.altitude
            ))
        }
        return output
    }

    /// Walk the polyline emitting a point every `spacing` units of arc length.
    private static func walk(_ dense: [ResampledPoint], spacing: Double) -> [ResampledPoint] {
        guard dense.count > 1 else { return dense }

        var output: [ResampledPoint] = []
        var carried = 0.0

        func tangent(at index: Int) -> Vec2 {
            let a = dense[max(index - 1, 0)].position
            let b = dense[min(index + 1, dense.count - 1)].position
            return (b - a).normalized ?? Vec2(1, 0)
        }

        var first = dense[0]
        first.tangent = tangent(at: 0)
        output.append(first)

        for i in 0..<(dense.count - 1) {
            let a = dense[i]
            let b = dense[i + 1]
            let segment = a.position.distance(to: b.position)
            guard segment > .ulpOfOne else { continue }

            var travelled = spacing - carried
            while travelled <= segment {
                let t = travelled / segment
                let position = a.position + (b.position - a.position) * t
                let direction = (b.position - a.position).normalized ?? tangent(at: i)
                output.append(ResampledPoint(
                    position: position,
                    tangent: direction,
                    force: a.force + (b.force - a.force) * t,
                    altitude: a.altitude + (b.altitude - a.altitude) * t
                ))
                travelled += spacing
            }
            carried = segment - (travelled - spacing)
        }

        // Always end exactly on the last sample so the stroke reaches the pen tip.
        var last = dense[dense.count - 1]
        last.tangent = tangent(at: dense.count - 1)
        if let tail = output.last, tail.position.distance(to: last.position) > spacing * 0.25 {
            output.append(last)
        } else if output.count == 1 {
            output.append(last)
        }
        return output
    }

    // MARK: - Centripetal Catmull-Rom

    /// Barry-Goldman evaluation with alpha = 0.5 (centripetal parameterisation).
    static func catmullRom(_ p0: Vec2, _ p1: Vec2, _ p2: Vec2, _ p3: Vec2, t: Double) -> Vec2 {
        let alpha = 0.5

        func knot(_ previous: Double, _ a: Vec2, _ b: Vec2) -> Double {
            let distance = a.distance(to: b)
            // Guard coincident points: a zero-length knot span divides by zero below.
            return previous + max(pow(distance, alpha), 1e-6)
        }

        let t0 = 0.0
        let t1 = knot(t0, p0, p1)
        let t2 = knot(t1, p1, p2)
        let t3 = knot(t2, p2, p3)

        let tt = t1 + (t2 - t1) * clamp(t, 0, 1)

        let a1 = p0 * ((t1 - tt) / (t1 - t0)) + p1 * ((tt - t0) / (t1 - t0))
        let a2 = p1 * ((t2 - tt) / (t2 - t1)) + p2 * ((tt - t1) / (t2 - t1))
        let a3 = p2 * ((t3 - tt) / (t3 - t2)) + p3 * ((tt - t2) / (t3 - t2))

        let b1 = a1 * ((t2 - tt) / (t2 - t0)) + a2 * ((tt - t0) / (t2 - t0))
        let b2 = a2 * ((t3 - tt) / (t3 - t1)) + a3 * ((tt - t1) / (t3 - t1))

        return b1 * ((t2 - tt) / (t2 - t1)) + b2 * ((tt - t1) / (t2 - t1))
    }
}
