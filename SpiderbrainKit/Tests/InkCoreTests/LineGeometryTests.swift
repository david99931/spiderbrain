import XCTest
@testable import InkCore

final class LineGeometryTests: XCTestCase {

    func testPerpendicularDistanceToSegmentInterior() {
        let distance = LineGeometry.distance(
            from: Vec2(5, 3),
            toSegmentFrom: Vec2(0, 0),
            to: Vec2(10, 0)
        )

        XCTAssertEqual(distance, 3, accuracy: 0.0001)
    }

    func testPointOnSegmentHasZeroDistance() {
        let distance = LineGeometry.distance(
            from: Vec2(5, 0),
            toSegmentFrom: Vec2(0, 0),
            to: Vec2(10, 0)
        )

        XCTAssertEqual(distance, 0, accuracy: 0.0001)
    }

    /// Clamped to the segment, not the infinite line: a point past the end measures
    /// to the endpoint. This is what makes tapping near an arrow's tip behave.
    func testPointBeyondEndClampsToEndpoint() {
        let distance = LineGeometry.distance(
            from: Vec2(20, 0),
            toSegmentFrom: Vec2(0, 0),
            to: Vec2(10, 0)
        )

        XCTAssertEqual(distance, 10, accuracy: 0.0001)
    }

    func testPointBeforeStartClampsToStart() {
        let distance = LineGeometry.distance(
            from: Vec2(-5, 0),
            toSegmentFrom: Vec2(0, 0),
            to: Vec2(10, 0)
        )

        XCTAssertEqual(distance, 5, accuracy: 0.0001)
    }

    /// A zero-length segment is a point; distance falls back to that point.
    func testDegenerateSegmentMeasuresToThePoint() {
        let distance = LineGeometry.distance(
            from: Vec2(3, 4),
            toSegmentFrom: Vec2(0, 0),
            to: Vec2(0, 0)
        )

        XCTAssertEqual(distance, 5, accuracy: 0.0001)
    }

    func testDiagonalSegment() {
        let distance = LineGeometry.distance(
            from: Vec2(0, 10),
            toSegmentFrom: Vec2(0, 0),
            to: Vec2(10, 10)
        )

        XCTAssertEqual(distance, (50.0).squareRoot(), accuracy: 0.0001)
    }
}
