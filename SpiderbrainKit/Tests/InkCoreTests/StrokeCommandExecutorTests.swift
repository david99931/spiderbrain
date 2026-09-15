import XCTest
@testable import InkCore

final class StrokeCommandExecutorTests: XCTestCase {

    private func makeStroke(id: UUID = UUID()) -> Stroke {
        Stroke(
            id: id,
            points: [InkPoint(position: Vec2(0, 0), force: 0.5)],
            style: .pen
        )
    }

    // MARK: - add

    func testAddStoresStrokeAndReportsIt() {
        let executor = StrokeCommandExecutor()
        let stroke = makeStroke()

        let effects = executor.execute(.add(stroke), origin: .local)

        XCTAssertEqual(effects, [.added(stroke)])
        XCTAssertEqual(executor.count, 1)
    }

    /// Regression: a stroke arriving over several peer connections was appended once
    /// per connection, which later produced duplicate ids in deletion lists.
    func testAddIsIdempotentByStrokeId() {
        let executor = StrokeCommandExecutor()
        let stroke = makeStroke()

        _ = executor.execute(.add(stroke), origin: .local)
        let secondEffects = executor.execute(.add(stroke), origin: .remote)

        XCTAssertTrue(secondEffects.isEmpty, "duplicate add should be a no-op")
        XCTAssertEqual(executor.count, 1, "duplicate add must not append twice")
    }

    // MARK: - delete

    func testDeleteRemovesStroke() {
        let stroke = makeStroke()
        let executor = StrokeCommandExecutor(strokes: [stroke])

        let effects = executor.execute(.delete(id: stroke.id), origin: .local)

        XCTAssertEqual(effects, [.removed(ids: [stroke.id])])
        XCTAssertTrue(executor.isEmpty)
    }

    func testDeleteUnknownIdIsNoOp() {
        let executor = StrokeCommandExecutor(strokes: [makeStroke()])

        let effects = executor.execute(.delete(id: UUID()), origin: .local)

        XCTAssertTrue(effects.isEmpty, "deleting an absent stroke must not emit an effect")
        XCTAssertEqual(executor.count, 1)
    }

    // MARK: - deleteMany

    /// Regression: the merge path built a deletion list holding the same boundary
    /// stroke id three times, because duplicate copies existed in the collection.
    func testDeleteManyDeduplicatesRepeatedIds() {
        let stroke = makeStroke()
        let executor = StrokeCommandExecutor(strokes: [stroke])

        let effects = executor.execute(
            .deleteMany(ids: [stroke.id, stroke.id, stroke.id]),
            origin: .local
        )

        XCTAssertEqual(effects, [.removed(ids: [stroke.id])], "repeated ids collapse to one removal")
        XCTAssertTrue(executor.isEmpty)
    }

    func testDeleteManyReportsOnlyStrokesThatWerePresent() {
        let present = makeStroke()
        let absent = UUID()
        let executor = StrokeCommandExecutor(strokes: [present])

        let effects = executor.execute(.deleteMany(ids: [present.id, absent]), origin: .local)

        XCTAssertEqual(effects, [.removed(ids: [present.id])], "absent ids must not be reported as removed")
    }

    func testDeleteManyRemovesAllMatchingStrokes() {
        let a = makeStroke()
        let b = makeStroke()
        let c = makeStroke()
        let executor = StrokeCommandExecutor(strokes: [a, b, c])

        let effects = executor.execute(.deleteMany(ids: [a.id, c.id]), origin: .local)

        XCTAssertEqual(effects, [.removed(ids: [a.id, c.id])])
        XCTAssertEqual(executor.strokes.map(\.id), [b.id], "only unlisted strokes survive")
    }

    func testDeleteManyWithNoMatchesIsNoOp() {
        let executor = StrokeCommandExecutor(strokes: [makeStroke()])

        let effects = executor.execute(.deleteMany(ids: [UUID(), UUID()]), origin: .local)

        XCTAssertTrue(effects.isEmpty)
        XCTAssertEqual(executor.count, 1)
    }

    // MARK: - removeLast

    func testRemoveLastRemovesMostRecentStroke() {
        let first = makeStroke()
        let last = makeStroke()
        let executor = StrokeCommandExecutor(strokes: [first, last])

        let effects = executor.execute(.removeLast, origin: .local)

        XCTAssertEqual(effects, [.removed(ids: [last.id])])
        XCTAssertEqual(executor.strokes.map(\.id), [first.id])
    }

    func testRemoveLastOnEmptyIsNoOp() {
        let executor = StrokeCommandExecutor()

        let effects = executor.execute(.removeLast, origin: .local)

        XCTAssertTrue(effects.isEmpty)
    }

    // MARK: - clear

    func testClearRemovesEverything() {
        let executor = StrokeCommandExecutor(strokes: [makeStroke(), makeStroke()])

        let effects = executor.execute(.clear, origin: .local)

        XCTAssertEqual(effects, [.clearedAll])
        XCTAssertTrue(executor.isEmpty)
    }

    func testClearOnEmptyIsNoOp() {
        let executor = StrokeCommandExecutor()

        let effects = executor.execute(.clear, origin: .local)

        XCTAssertTrue(effects.isEmpty, "clearing an empty collection should not emit an effect")
    }

    // MARK: - ordering and bulk replace

    func testStrokesPreserveInsertionOrder() {
        let executor = StrokeCommandExecutor()
        let a = makeStroke()
        let b = makeStroke()
        let c = makeStroke()

        _ = executor.execute(.add(a), origin: .local)
        _ = executor.execute(.add(b), origin: .local)
        _ = executor.execute(.add(c), origin: .local)

        XCTAssertEqual(executor.strokes.map(\.id), [a.id, b.id, c.id])
    }

    func testReplaceAllSwapsContentsWithoutEffects() {
        let executor = StrokeCommandExecutor(strokes: [makeStroke()])
        let replacement = [makeStroke(), makeStroke()]

        executor.replaceAll(replacement)

        XCTAssertEqual(executor.strokes.map(\.id), replacement.map(\.id))
    }
}
