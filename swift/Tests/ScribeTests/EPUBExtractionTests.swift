import CoreGraphics
import XCTest
@testable import Scribe

final class EPUBExtractionTests: XCTestCase {

    private var fixtureURL: URL {
        guard let url = Bundle.module.url(forResource: "sample", withExtension: "epub", subdirectory: "Fixtures") else {
            fatalError("sample.epub fixture missing from test bundle")
        }
        return url
    }

    func testIsEPUBDetection() {
        XCTAssertTrue(EPUBProcessor.isEPUB(url: fixtureURL))
        XCTAssertFalse(EPUBProcessor.isEPUB(url: URL(fileURLWithPath: "/tmp/book.pdf")))
    }

    func testExtractsChaptersWithStructure() throws {
        let result = try XCTUnwrap(ScribeProcessor.processForTest(url: fixtureURL))
        XCTAssertTrue(result.hasStructure)
        // Front Matter (cover title page, before the first toc anchor) + ch1 +
        // ch2 split at its #sec2 fragment anchor + ch3 (Chapter Three anchors
        // mid-file at #c3). The nav doc is not in the spine.
        XCTAssertEqual(result.chapters.count, 5)

        let titles = result.chapters.map { $0["title"] as? String }
        XCTAssertEqual(titles[0], "Front Matter")
        XCTAssertEqual(titles[1], "Chapter One")
        XCTAssertEqual(titles[2], "Chapter Two")
        XCTAssertEqual(titles[3], "A Nested Section")
        XCTAssertEqual(titles[4], "Chapter Three")

        let levels = result.chapters.map { $0["level"] as? Int }
        XCTAssertEqual(levels, [0, 0, 0, 1, 0])

        for chapter in result.chapters {
            XCTAssertEqual(chapter["sourceType"] as? String, "epub")
        }

        let sectionText = try XCTUnwrap(result.chapters[3]["plainText"] as? String)
        XCTAssertTrue(sectionText.contains("Sections nest"))
        let ch2Text = try XCTUnwrap(result.chapters[2]["plainText"] as? String)
        XCTAssertFalse(ch2Text.contains("Sections nest"), "fragment content must not remain in the parent chapter")
    }

    /// The regression this whole rewrite targets: a chapter whose text spills
    /// across a spine-file boundary must stay with the chapter it belongs to,
    /// not leak into the next file's first chapter. "A Nested Section" begins in
    /// ch2 and continues into ch3 (before ch3's own #c3 anchor); "Chapter Three"
    /// must contain only what follows #c3.
    func testCrossFileChapterBoundaries() throws {
        let result = try XCTUnwrap(ScribeProcessor.processForTest(url: fixtureURL))

        let sectionText = try XCTUnwrap(result.chapters[3]["plainText"] as? String)
        XCTAssertTrue(sectionText.contains("Sections nest"), "nested section keeps its own opening text")
        XCTAssertTrue(sectionText.contains("flowing past the file split"),
                      "cross-file continuation must stay with the section it belongs to")

        let ch3Text = try XCTUnwrap(result.chapters[4]["plainText"] as? String)
        XCTAssertTrue(ch3Text.contains("Chapter three body begins"))
        XCTAssertFalse(ch3Text.contains("flowing past the file split"),
                       "the previous chapter's tail must not leak into Chapter Three")

        // startPage is the spine ordinal of the file the chapter's ANCHOR lives
        // in: the nested section anchors in ch2 (ordinal 3) even though its text
        // runs into ch3; Chapter Three anchors in ch3 (ordinal 4).
        XCTAssertEqual(result.chapters[3]["startPage"] as? Int, 3)
        XCTAssertEqual(result.chapters[4]["startPage"] as? Int, 4)
    }

    func testTextAndEntityHandling() throws {
        let result = try XCTUnwrap(ScribeProcessor.processForTest(url: fixtureURL))
        let ch1Text = try XCTUnwrap(result.chapters[1]["plainText"] as? String)
        XCTAssertTrue(ch1Text.contains("curious world\u{2014}one"), "mdash entity should be decoded")
        XCTAssertTrue(ch1Text.contains("close reading"))
        XCTAssertFalse(ch1Text.contains("margin: 0"), "style content must not leak into text")
        XCTAssertFalse(ch1Text.contains("&mdash;"))
    }

    func testWordBoundariesAreContiguous() throws {
        let result = try XCTUnwrap(ScribeProcessor.processForTest(url: fixtureURL))
        var expectedStart = 0
        for chapter in result.chapters {
            XCTAssertEqual(chapter["startWordIndex"] as? Int, expectedStart)
            let wordCount = try XCTUnwrap(chapter["wordCount"] as? Int)
            XCTAssertEqual(chapter["endWordIndex"] as? Int, expectedStart + wordCount)
            expectedStart += wordCount
        }
        XCTAssertGreaterThan(expectedStart, 20, "fixture should tokenize to a meaningful word count")
    }

    func testImagesBecomeDataURIsWithWordPositions() throws {
        let result = try XCTUnwrap(ScribeProcessor.processForTest(url: fixtureURL))

        let coverImages = try XCTUnwrap(result.chapters[0]["images"] as? [[String: Any]])
        XCTAssertEqual(coverImages.count, 1, "cover art on the front-matter page should be kept")

        let ch1Images = try XCTUnwrap(result.chapters[1]["images"] as? [[String: Any]])
        XCTAssertEqual(ch1Images.count, 1)
        let src = try XCTUnwrap(ch1Images[0]["src"] as? String)
        XCTAssertTrue(src.hasPrefix("data:image/png;base64,"))
        XCTAssertEqual(ch1Images[0]["alt"] as? String, "A small figure")
        let wordPosition = try XCTUnwrap(ch1Images[0]["wordPosition"] as? Int)
        XCTAssertGreaterThan(wordPosition, 0, "figure sits after two paragraphs of text")

        let htmlContent = try XCTUnwrap(result.chapters[1]["htmlContent"] as? String)
        XCTAssertTrue(htmlContent.contains("<img"), "images should be embedded in htmlContent")
    }

    func testNestedTocLevelsParsed() throws {
        let navXHTML = """
        <html xmlns:epub="http://www.idpf.org/2007/ops"><body><nav epub:type="toc"><ol>
        <li><a href="a.xhtml">Top</a>
          <ol><li><a href="a.xhtml#s1">Sub</a>
            <ol><li><a href="a.xhtml#s1a">SubSub</a></li></ol>
          </li></ol>
        </li>
        </ol></nav></body></html>
        """
        let entries = NavParser.parse(Data(navXHTML.utf8))
        XCTAssertEqual(entries.map(\.title), ["Top", "Sub", "SubSub"])
        XCTAssertEqual(entries.map(\.level), [0, 1, 2])
    }

    func testNCXParsing() {
        let ncx = """
        <?xml version="1.0"?>
        <ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">
        <navMap>
          <navPoint id="n1"><navLabel><text>One</text></navLabel><content src="a.html"/></navPoint>
          <navPoint id="n2"><navLabel><text>Two</text></navLabel><content src="b.html"/>
            <navPoint id="n3"><navLabel><text>Two-Sub</text></navLabel><content src="b.html#s"/></navPoint>
          </navPoint>
        </navMap>
        </ncx>
        """
        let entries = NCXParser.parse(Data(ncx.utf8))
        XCTAssertEqual(entries.map(\.title), ["One", "Two", "Two-Sub"])
        XCTAssertEqual(entries.map(\.level), [0, 0, 1])
    }

    func testFootnoteSeparation() throws {
        let result = try XCTUnwrap(ScribeProcessor.processForTest(url: fixtureURL))

        // ch1: numbered <aside epub:type="footnote">
        let ch1Notes = try XCTUnwrap(result.chapters[1]["footnotes"] as? [[String: Any]])
        XCTAssertEqual(ch1Notes.count, 1)
        XCTAssertEqual(ch1Notes[0]["number"] as? Int, 1)
        XCTAssertEqual(ch1Notes[0]["text"] as? String, "Close reading was, at the time, considered a radical act.")

        // Footnote text must not leak into body text
        let ch1Text = try XCTUnwrap(result.chapters[1]["plainText"] as? String)
        XCTAssertFalse(ch1Text.contains("radical act"))
        // The inline noteref marker stays in the body
        XCTAssertTrue(ch1Text.contains("close reading.1") || ch1Text.contains("close reading. 1"))

        // ch2's unnumbered role="doc-footnote" sits after the #sec2 anchor,
        // so it belongs to the nested-section chapter and gets number 1
        let sectionNotes = try XCTUnwrap(result.chapters[3]["footnotes"] as? [[String: Any]])
        XCTAssertEqual(sectionNotes.count, 1)
        XCTAssertEqual(sectionNotes[0]["number"] as? Int, 1)
        XCTAssertEqual(sectionNotes[0]["text"] as? String, "Unnumbered note attached to the nested section.")
        let ch2Notes = try XCTUnwrap(result.chapters[2]["footnotes"] as? [[String: Any]])
        XCTAssertTrue(ch2Notes.isEmpty)
        let sectionText = try XCTUnwrap(result.chapters[3]["plainText"] as? String)
        XCTAssertFalse(sectionText.contains("Unnumbered note"))
    }

    func testCoverImagePresentForEPUBAndAbsentForPDF() throws {
        // EPUB: the manifest's properties="cover-image" item surfaces as a
        // PNG data URI on the extractContent result dict.
        let epub = try XCTUnwrap(ScribeProcessor.extractContent(from: fixtureURL))
        let cover = try XCTUnwrap(epub["coverImage"] as? String, "EPUB cover should be surfaced")
        XCTAssertTrue(cover.hasPrefix("data:image/png;base64,"),
                      "cover should be a base64 PNG data URI, got: \(cover.prefix(32))")

        // PDF: cover extraction is deliberately not attempted; the field is absent.
        let pdfURL = try makeBlankPDF()
        defer { try? FileManager.default.removeItem(at: pdfURL) }
        let pdf = try XCTUnwrap(ScribeProcessor.extractContent(from: pdfURL))
        XCTAssertNil(pdf["coverImage"], "PDF path must not emit a coverImage")
    }

    /// Write a minimal one-page PDF to a temp file (no dependency on corpus
    /// sources, which aren't present in CI).
    private func makeBlankPDF() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("scribe-cover-\(UUID().uuidString).pdf")
        var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        let ctx = try XCTUnwrap(CGContext(url as CFURL, mediaBox: &mediaBox, nil),
                                "failed to create PDF context")
        ctx.beginPDFPage(nil)
        ctx.endPDFPage()
        ctx.closePDF()
        return url
    }

    func testZipReaderRoundTrip() throws {
        let zip = try XCTUnwrap(ZipReader(url: fixtureURL))
        let mimetype = try XCTUnwrap(zip.contents(of: "mimetype"))
        XCTAssertEqual(String(data: mimetype, encoding: .utf8), "application/epub+zip")
        // Deflated entry
        let opf = try XCTUnwrap(zip.contents(of: "OEBPS/content.opf"))
        XCTAssertTrue(try XCTUnwrap(String(data: opf, encoding: .utf8)).contains("<spine"))
        // Stored binary entry
        let png = try XCTUnwrap(zip.contents(of: "OEBPS/images/fig1.png"))
        XCTAssertEqual(png.prefix(4), Data([0x89, 0x50, 0x4E, 0x47]))
        XCTAssertNil(zip.contents(of: "no/such/entry"))
    }
}
