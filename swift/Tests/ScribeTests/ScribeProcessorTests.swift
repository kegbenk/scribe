import XCTest
@testable import Scribe

final class ScribeProcessorTests: XCTestCase {

    func testTokenizerEmpty() {
        XCTAssertEqual(ScribeTokenizer.parseText(nil), [])
        XCTAssertEqual(ScribeTokenizer.parseText(""), [])
    }

    func testTokenizerSingleLine() {
        let result = ScribeTokenizer.parseText("Hello world")
        XCTAssertEqual(result, ["Hello", "world"])
    }

    func testTokenizerMultiLine() {
        let result = ScribeTokenizer.parseText("Hello world\nSecond line")
        XCTAssertEqual(result, ["Hello", "world", "\n", "\u{27E9}Second", "line"])
    }

    func testTokenizerSkipsBlankLines() {
        let result = ScribeTokenizer.parseText("First\n\n\nSecond")
        XCTAssertEqual(result, ["First", "\n", "\u{27E9}Second"])
    }
}
