import XCTest
@testable import Scribe

/// Covers the word-anchored image placement contract: buildChapterImages must
/// anchor wordPosition to actual page word counts (no proportional smearing),
/// and textToHtml must insert figures by cumulative word count (not paragraph
/// count), including alongside a detected endnotes section.
final class ImagePlacementTests: XCTestCase {

    // MARK: - Helpers

    /// A single-line string of `count` space-separated words, first word `first`.
    private func words(_ count: Int, first: String = "w") -> String {
        guard count > 0 else { return "" }
        var parts = [first]
        for _ in 1..<max(1, count) { parts.append("w") }
        return parts.joined(separator: " ")
    }

    private func img(word: Int, src: String, width: Int) -> [String: Any] {
        return ["wordPosition": word, "src": src, "alt": "alt", "width": width, "height": width]
    }

    /// Byte offset of the first occurrence of `needle` in `haystack`.
    private func idx(_ needle: String, in haystack: String) -> Int {
        guard let r = haystack.range(of: needle) else {
            XCTFail("expected to find \(needle)")
            return -1
        }
        return haystack.distance(from: haystack.startIndex, to: r.lowerBound)
    }

    // MARK: - (a) buildChapterImages page-anchored wordPosition

    func testBuildChapterImagesPageAnchoredNoSmearing() {
        let processor = ScribeProcessor()

        let page1 = ScribeProcessor.PageExtraction(
            text: words(10), footnotes: [], images: [], pdfPageIndex: 0)
        let image = ScribeProcessor.ExtractedImage(
            dataURI: "data:image/jpeg;base64,AAAA", width: 100, height: 100,
            pageIndex: 1, yPosition: 0.5)
        let page2 = ScribeProcessor.PageExtraction(
            text: words(20), footnotes: [], images: [image], pdfPageIndex: 1)

        // chapterText tokenizes to more words than the summed pages — the old
        // ratio scaling would have moved the anchor; page anchoring must not.
        let result = processor.buildChapterImages(
            pages: [page1, page2], chapterText: words(50))

        XCTAssertEqual(result.count, 1)
        // page1 words (10) + round(0.5 × page2 words (20)) = 20, no scaling.
        XCTAssertEqual(result[0]["wordPosition"] as? Int, 20)
    }

    // MARK: - (b) textToHtml word-anchored insertion, uneven paragraphs

    func testTextToHtmlInsertsByWordCountNotParagraphCount() {
        let processor = ScribeProcessor()

        let p0 = "a b c d e"                               // 5 words
        let p1 = "MARKERP1 " + words(199)                  // 200 words
        let p2 = "f g h i j"                               // 5 words
        let text = [p0, p1, p2].joined(separator: "\n\n")

        // wordPosition 5 falls exactly at the p0/p1 boundary → insert before p1
        // (index 1). Old paragraph-count proportional math would place it at index 0.
        let html = processor.textToHtml(text, images: [img(word: 5, src: "data:x", width: 7)])

        XCTAssertLessThan(idx("d e</p>", in: html), idx("<figure", in: html))
        XCTAssertLessThan(idx("<figure", in: html), idx("MARKERP1", in: html))
    }

    // MARK: - (c) multiple images do not displace each other

    func testTextToHtmlMultipleImagesIndependent() {
        let processor = ScribeProcessor()

        let paras = (0..<4).map { "PARA\($0) " + words(9) }  // 10 words each
        let text = paras.joined(separator: "\n\n")

        // cumulative = [10, 20, 30, 40]; word 5 → before PARA0, word 25 → before PARA2.
        let images = [
            img(word: 5, src: "data:a", width: 111),
            img(word: 25, src: "data:b", width: 222),
        ]
        let html = processor.textToHtml(text, images: images)

        XCTAssertTrue(html.contains("width=\"111\""))
        XCTAssertTrue(html.contains("width=\"222\""))
        XCTAssertLessThan(idx("width=\"111\"", in: html), idx("PARA0", in: html))
        XCTAssertLessThan(idx("PARA1", in: html), idx("width=\"222\"", in: html))
        XCTAssertLessThan(idx("width=\"222\"", in: html), idx("PARA2", in: html))
    }

    // MARK: - (d) figure in body must not corrupt endnote section detection

    func testTextToHtmlImageWithEndnotesSection() {
        let processor = ScribeProcessor()

        let p0 = "BODYA one two three four five six seven"   // 8 words
        let p1 = "BODYB one two three four five"             // 6 words
        let notes = ["1 First endnote.", "2 Second endnote.", "3 Third.", "4 Fourth."]
        let text = ([p0, p1] + notes).joined(separator: "\n\n")

        // word 8 → p0/p1 boundary (body). endnoteStartIdx must track the insert.
        let html = processor.textToHtml(text, images: [img(word: 8, src: "data:x", width: 55)])

        XCTAssertTrue(html.contains("<section class=\"transposed-endnotes\">"))
        for n in 1...4 { XCTAssertTrue(html.contains("id=\"endnote-\(n)\"")) }
        // Figure sits in the body, between p0 and p1, before the notes section.
        XCTAssertLessThan(idx("BODYA", in: html), idx("<figure", in: html))
        XCTAssertLessThan(idx("<figure", in: html), idx("BODYB", in: html))
        XCTAssertLessThan(idx("<figure", in: html), idx("transposed-endnotes", in: html))
    }
}
