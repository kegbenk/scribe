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
        // cover (image-only) + ch1 + ch2 split at its #sec2 fragment anchor;
        // the nav doc is not in the spine
        XCTAssertEqual(result.chapters.count, 4)

        let titles = result.chapters.map { $0["title"] as? String }
        XCTAssertEqual(titles[1], "Chapter One")
        XCTAssertEqual(titles[2], "Chapter Two")
        XCTAssertEqual(titles[3], "A Nested Section")

        let levels = result.chapters.map { $0["level"] as? Int }
        XCTAssertEqual(levels, [0, 0, 0, 1])

        for chapter in result.chapters {
            XCTAssertEqual(chapter["sourceType"] as? String, "epub")
        }

        let sectionText = try XCTUnwrap(result.chapters[3]["plainText"] as? String)
        XCTAssertTrue(sectionText.contains("Sections nest"))
        let ch2Text = try XCTUnwrap(result.chapters[2]["plainText"] as? String)
        XCTAssertFalse(ch2Text.contains("Sections nest"), "fragment content must not remain in the parent chapter")
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
        XCTAssertEqual(coverImages.count, 1, "image-only cover page should be kept for its image")

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
