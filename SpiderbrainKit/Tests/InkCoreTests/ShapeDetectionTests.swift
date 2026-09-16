import XCTest
@testable import InkCore

final class ShapeDetectionTests: XCTestCase {

    /// A closed loop of the given size, centred where asked.
    private func circle(
        center: Vec2 = Vec2(0, 0),
        radius: Double,
        points: Int = 32,
        gap: Double = 0
    ) -> Stroke {
        var samples: [InkPoint] = []
        for i in 0...points {
            // `gap` shortens the sweep so the ends stop short of meeting.
            let fraction = Double(i) / Double(points)
            let angle = fraction * (2 * .pi - gap)
            samples.append(InkPoint(
                position: Vec2(center.x + radius * cos(angle), center.y + radius * sin(angle)),
                force: 0.5
            ))
        }
        return Stroke(points: samples, style: .pen)
    }

    private func line(from start: Vec2, to end: Vec2, points: Int = 20) -> Stroke {
        var samples: [InkPoint] = []
        for i in 0...points {
            let t = Double(i) / Double(points)
            samples.append(InkPoint(
                position: Vec2(start.x + (end.x - start.x) * t, start.y + (end.y - start.y) * t),
                force: 0.5
            ))
        }
        return Stroke(points: samples, style: .pen)
    }

    // MARK: - Closure

    func testLargeCircleIsAClosedShape() {
        let stroke = circle(radius: 100)

        XCTAssertTrue(ShapeDetection.isClosedShape(stroke, among: []))
    }

    func testStraightLineIsNotAClosedShape() {
        let stroke = line(from: Vec2(0, 0), to: Vec2(200, 0))

        XCTAssertFalse(ShapeDetection.isClosedShape(stroke, among: []))
    }

    /// A circle with a large gap between its endpoints is not closed.
    func testOpenArcIsNotAClosedShape() {
        let stroke = circle(radius: 100, gap: .pi)

        XCTAssertFalse(ShapeDetection.isClosedShape(stroke, among: []))
    }

    func testVeryShortStrokeIsNotAClosedShape() {
        let stroke = Stroke(
            points: (0..<4).map { InkPoint(position: Vec2(Double($0), 0), force: 0.5) },
            style: .pen
        )

        XCTAssertFalse(ShapeDetection.isClosedShape(stroke, among: []))
    }

    // MARK: - Letter rejection

    /// A small circle alone on the canvas is taken at face value as a container.
    func testSmallCircleAloneIsAClosedShape() {
        let stroke = circle(radius: 15)

        XCTAssertTrue(
            ShapeDetection.isClosedShape(stroke, among: []),
            "a lone small circle is a deliberate shape, not a letter"
        )
    }

    /// The same small circle surrounded by similar-sized strokes reads as an "o"
    /// inside handwriting, so it must not offer to become a node.
    func testSmallCircleAmongSimilarStrokesIsRejectedAsALetter() {
        let stroke = circle(center: Vec2(0, 0), radius: 15)
        let neighbours = [
            circle(center: Vec2(40, 0), radius: 14),
            circle(center: Vec2(80, 0), radius: 16)
        ]

        XCTAssertFalse(
            ShapeDetection.isClosedShape(stroke, among: neighbours),
            "a small circle among similar-sized strokes is handwriting"
        )
    }

    /// One neighbour is not enough company to call it handwriting.
    func testSmallCircleWithASingleNeighbourIsStillAShape() {
        let stroke = circle(center: Vec2(0, 0), radius: 15)
        let neighbours = [circle(center: Vec2(40, 0), radius: 14)]

        XCTAssertTrue(ShapeDetection.isClosedShape(stroke, among: neighbours))
    }

    /// Big circles are never letters, however much company they keep.
    func testLargeCircleAmongNeighboursIsStillAShape() {
        let stroke = circle(center: Vec2(0, 0), radius: 100)
        let neighbours = [
            circle(center: Vec2(250, 0), radius: 95),
            circle(center: Vec2(500, 0), radius: 105)
        ]

        XCTAssertTrue(ShapeDetection.isClosedShape(stroke, among: neighbours))
    }

    /// Neighbours of a very different size are not evidence of handwriting.
    func testSmallCircleAmongMuchLargerStrokesIsStillAShape() {
        let stroke = circle(center: Vec2(0, 0), radius: 15)
        let neighbours = [
            circle(center: Vec2(40, 0), radius: 200),
            circle(center: Vec2(60, 0), radius: 250)
        ]

        XCTAssertTrue(ShapeDetection.isClosedShape(stroke, among: neighbours))
    }

    /// Distant strokes are not company, however similar their size.
    func testSmallCircleWithOnlyDistantNeighboursIsStillAShape() {
        let stroke = circle(center: Vec2(0, 0), radius: 15)
        let neighbours = [
            circle(center: Vec2(5000, 0), radius: 15),
            circle(center: Vec2(6000, 0), radius: 15)
        ]

        XCTAssertTrue(ShapeDetection.isClosedShape(stroke, among: neighbours))
    }

    /// The candidate must not count itself when it is already on the canvas.
    func testStrokeDoesNotCountItselfAsANeighbour() {
        let stroke = circle(center: Vec2(0, 0), radius: 15)
        let onCanvas = [stroke, circle(center: Vec2(40, 0), radius: 15)]

        XCTAssertTrue(
            ShapeDetection.isClosedShape(stroke, among: onCanvas),
            "only one genuine neighbour, so this is still a shape"
        )
    }
}
