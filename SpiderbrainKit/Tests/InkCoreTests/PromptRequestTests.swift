import XCTest
@testable import InkCore

final class PromptRequestTests: XCTestCase {

    func testWholeNodeRequestHasNoFocus() {
        let request = PromptRequest(context: "some note")

        XCTAssertNil(request.focus)
        XCTAssertFalse(request.isFocused)
        XCTAssertEqual(request.context, "some note")
    }

    func testFocusedRequestKeepsBoth() {
        let request = PromptRequest(context: "a, b, and c", focus: "b")

        XCTAssertEqual(request.context, "a, b, and c")
        XCTAssertEqual(request.focus, "b")
        XCTAssertTrue(request.isFocused)
    }

    func testFocusIsTrimmed() {
        let request = PromptRequest(context: "a, b, and c", focus: "  b \n")

        XCTAssertEqual(request.focus, "b")
    }

    func testBlankFocusIsNoFocus() {
        XCTAssertNil(PromptRequest(context: "note", focus: "   ").focus)
        XCTAssertNil(PromptRequest(context: "note", focus: "").focus)
        XCTAssertNil(PromptRequest(context: "note", focus: nil).focus)
    }

    /// Selecting the whole of a node is the same question as asking about the
    /// node, so there is nothing to narrow down to.
    func testFocusMatchingTheWholeContextIsNoFocus() {
        let request = PromptRequest(context: "the whole note", focus: "the whole note")

        XCTAssertNil(request.focus)
        XCTAssertFalse(request.isFocused)
    }

    func testFocusMatchingContextApartFromWhitespaceIsNoFocus() {
        let request = PromptRequest(context: "  the whole note  ", focus: "the whole note")

        XCTAssertNil(request.focus)
    }
}
