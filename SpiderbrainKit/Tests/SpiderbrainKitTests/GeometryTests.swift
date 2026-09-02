import XCTest
@testable import SpiderbrainKit

/// These cover the pure-geometry core only. It imports no UIKit and touches no GPU,
/// which is the whole point of keeping it in its own layer - `swift test` runs the
/// lot on a Mac with no simulator and no device.
final class PressureCurveTests: XCTestCase {

    func testWidthStaysWithinBounds() {
        let curve = PressureCurve.pen
        for force in stride(from: 0.0, through: 1.0, by: 0.05) {
            let width = curve.width(force: force)
            XCTAssertGreaterThanOrEqual(width, curve.minWidth - 1e-9)
            XCTAssertLessThanOrEqual(width, curve.maxWidth * (1 + curve.tiltBroadening) + 1e-9)
        }
    }

    func testWidthIsMonotonicInForce() {
        let curve = PressureCurve.pen
        var previous = curve.width(force: 0)
        for force in stride(from: 0.05, through: 1.0, by: 0.05) {
            let width = curve.width(force: force)
            XCTAssertGreaterThanOrEqual(width, previous - 1e-9, "width dipped at force \(force)")
            previous = width
        }
    }

    func testLightTouchStillLeavesAMark() {
        // A floor rather than zero, or feathered strokes disappear entirely.
        XCTAssertEqual(PressureCurve.pen.width(force: 0), PressureCurve.pen.minWidth, accuracy: 1e-9)
    }

    func testForceIsClampedOutsideUnitRange() {
        let curve = PressureCurve.pen
        XCTAssertEqual(curve.width(force: -5), curve.minWidth, accuracy: 1e-9)
        XCTAssertEqual(curve.width(force: 5), curve.width(force: 1), accuracy: 1e-9)
    }

    func testFlatPenBroadensTheMark() {
        let curve = PressureCurve.pen
        let perpendicular = curve.width(force: 0.5, altitude: .pi / 2)
        let flat = curve.width(force: 0.5, altitude: 0)
        XCTAssertGreaterThan(flat, perpendicular)
    }

    func testTiltCanBeDisabled() {
        let curve = PressureCurve(minWidth: 2, maxWidth: 8, exponent: 1, tiltBroadening: 0)
        XCTAssertEqual(
            curve.width(force: 0.5, altitude: 0),
            curve.width(force: 0.5, altitude: .pi / 2),
            accuracy: 1e-9
        )
    }
}

final class StrokeSmootherTests: XCTestCase {

    private func points(_ coordinates: [(Double, Double)], force: Double = 0.5) -> [InkPoint] {
        coordinates.map { InkPoint(position: Vec2($0.0, $0.1), force: force) }
    }

    func testEmptyInputProducesNoOutput() {
        XCTAssertTrue(StrokeSmoother.resample([]).isEmpty)
    }

    func testSingleSampleBecomesADot() {
        let result = StrokeSmoother.resample(points([(10, 10)]))
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].position, Vec2(10, 10))
    }

    func testCoincidentSamplesAreDeduped() {
        // Repeated identical points make the spline parameterisation degenerate.
        let input = points([(5, 5), (5, 5), (5, 5)])
        XCTAssertEqual(StrokeSmoother.dedupe(input).count, 1)
    }

    func testResamplingIsEvenlySpaced() {
        let input = points([(0, 0), (50, 0), (100, 0)])
        let result = StrokeSmoother.resample(input, spacing: 2.0)
        XCTAssertGreaterThan(result.count, 10)

        // Ignore the final point, which snaps to the true stroke end.
        for i in 1..<(result.count - 2) {
            let gap = result[i].position.distance(to: result[i + 1].position)
            XCTAssertEqual(gap, 2.0, accuracy: 0.35, "uneven gap at index \(i)")
        }
    }

    func testStrokePassesThroughItsEndpoints() {
        // Centripetal Catmull-Rom interpolates its control points; ink must land
        // exactly where the pen did, especially at the tip.
        let input = points([(0, 0), (30, 40), (90, 10)])
        let result = StrokeSmoother.resample(input, spacing: 1.0)
        XCTAssertEqual(result.first!.position.distance(to: Vec2(0, 0)), 0, accuracy: 0.01)
        XCTAssertLessThan(result.last!.position.distance(to: Vec2(90, 10)), 0.6)
    }

    func testTangentsAreUnitLength() {
        let input = points([(0, 0), (20, 25), (60, 5), (100, 60)])
        for point in StrokeSmoother.resample(input) {
            XCTAssertEqual(point.tangent.length, 1.0, accuracy: 1e-6)
        }
    }

    func testForceIsInterpolatedAlongTheStroke() {
        let input = [
            InkPoint(position: Vec2(0, 0), force: 0.0),
            InkPoint(position: Vec2(100, 0), force: 1.0)
        ]
        let result = StrokeSmoother.resample(input, spacing: 5)
        XCTAssertLessThan(result.first!.force, 0.1)
        XCTAssertGreaterThan(result.last!.force, 0.9)
    }

    func testSharpReversalDoesNotExplode() {
        // A hard 180 is where uniform Catmull-Rom overshoots badly. Centripetal
        // should stay inside a sane neighbourhood of the input.
        let input = points([(0, 0), (50, 0), (0, 1)])
        let result = StrokeSmoother.resample(input, spacing: 1)
        for point in result {
            XCTAssertLessThan(point.position.x, 70)
            XCTAssertGreaterThan(point.position.x, -20)
        }
    }
}

final class TessellatorTests: XCTestCase {

    private func line(_ count: Int) -> [ResampledPoint] {
        (0..<count).map { i in
            ResampledPoint(
                position: Vec2(Double(i) * 2, 0),
                tangent: Vec2(1, 0),
                force: 0.5,
                altitude: .pi / 2
            )
        }
    }

    func testEmptyInputProducesNoGeometry() {
        XCTAssertTrue(Tessellator.tessellate([], style: .pen).isEmpty)
    }

    func testVertexCountIsAMultipleOfThree() {
        // Non-indexed triangle list: anything else means a malformed primitive.
        for count in [1, 2, 5, 40] {
            let vertices = Tessellator.tessellate(line(count), style: .pen)
            XCTAssertEqual(vertices.count % 3, 0, "count \(count) produced \(vertices.count)")
        }
    }

    func testSingleSampleProducesADisc() {
        let vertices = Tessellator.tessellate(line(1), style: .pen)
        XCTAssertEqual(vertices.count, Tessellator.capSegments * 3)
    }

    func testRibbonWidthMatchesThePressureCurve() {
        let style = InkStyle.pen
        let vertices = Tessellator.tessellate(line(4), style: style)
        let expectedHalf = style.pressure.halfWidth(force: 0.5, altitude: .pi / 2)

        // First two vertices are the left and right edge of the opening quad.
        let left = vertices[0]
        let right = vertices[1]
        let spread = abs(Double(left.y) - Double(right.y))
        XCTAssertEqual(spread, expectedHalf * 2, accuracy: 1e-4)
    }

    func testStyleColourReachesEveryVertex() {
        let style = InkStyle(red: 0.2, green: 0.4, blue: 0.6)
        for vertex in Tessellator.tessellate(line(6), style: style) {
            XCTAssertEqual(Double(vertex.r), 0.2, accuracy: 1e-6)
            XCTAssertEqual(Double(vertex.g), 0.4, accuracy: 1e-6)
            XCTAssertEqual(Double(vertex.b), 0.6, accuracy: 1e-6)
        }
    }
}

final class Vec2Tests: XCTestCase {

    func testNormalizedRejectsDegenerateVectors() {
        XCTAssertNil(Vec2.zero.normalized)
        XCTAssertNotNil(Vec2(3, 4).normalized)
    }

    func testNormalizedHasUnitLength() {
        XCTAssertEqual(Vec2(3, 4).normalized!.length, 1.0, accuracy: 1e-12)
    }

    func testPerpendicularIsOrthogonal() {
        let v = Vec2(3, 4)
        let p = v.perpendicular
        XCTAssertEqual(v.x * p.x + v.y * p.y, 0, accuracy: 1e-12)
    }
}
