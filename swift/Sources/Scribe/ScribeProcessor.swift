import CoreGraphics
import Foundation
import PDFKit
import Vision

public class ScribeProcessor {

    // MARK: - Public API

    /// Extract content from a PDF file.
    /// Returns a dictionary with "text", "chapters", "hasStructure" keys.
    public static func extractContent(from url: URL) -> [String: Any]? {
        let processor = ScribeProcessor()
        guard let result = processor.processFileForResult(url: url) else { return nil }
        return [
            "text": result.text,
            "chapters": result.chapters,
            "hasStructure": result.hasStructure
        ]
    }

    // MARK: - Types

    /// Book type based on PDF source characteristics.
    enum BookType {
        case digitalClean       // Clean digital PDF with embedded fonts (e.g. healing-dream)
        case scannedOCR         // Scanned pages with OCR text layer (e.g. janus-faces)
    }

    /// Content type based on textual patterns.
    enum ContentType {
        case academic           // Footnotes, citations, bibliography
        case general            // Fiction, non-fiction without heavy citations
    }

    /// Book profile determined by sampling pages at processing start.
    /// Drives adaptive strategy selection in separateFootnotes and other heuristics.
    struct BookProfile {
        let bookType: BookType
        let contentType: ContentType
        let isTwoColumn: Bool
        /// Global body font size computed from sampled pages. Used as override when
        /// per-column font bucketing picks the wrong font (footnote font > body font count).
        let globalBodyFont: CGFloat?

        /// True when footnote detection should prioritize content-based strategies
        /// (citation patterns) over layout-based strategies (font size, gaps).
        var preferContentStrategies: Bool {
            return bookType == .scannedOCR && contentType == .academic
        }
    }

    // MARK: - Data Structures

    struct Footnote {
        let number: Int
        let text: String
    }

    struct PageExtraction {
        let text: String
        let footnotes: [Footnote]
        let images: [ExtractedImage]
        let pdfPageIndex: Int  // Source PDF page index (for PDFKit lookups)
        var footnoteContinuation: String? = nil  // Text continuing a footnote from a previous page/column
    }

    struct ExtractedImage {
        let dataURI: String
        let width: Int
        let height: Int
        let pageIndex: Int
        let yPosition: CGFloat // 0=top, 1=bottom (normalized)
    }

    /// Represents a visual line of text with its position on the page.
    struct TextLine {
        let text: String
        let y: CGFloat      // top-down Y position (higher = further down the page)
        let minX: CGFloat
        let maxX: CGFloat
        let width: CGFloat
        let fontSize: CGFloat
    }

    /// Stored book profile, computed once per processing run.
    var bookProfile: BookProfile?

    // MARK: - Test Entry Point

    /// Process a PDF file and return structured results. Used by unit tests.
    public static func processForTest(url: URL) -> (text: String, chapters: [[String: Any]], hasStructure: Bool)? {
        let processor = ScribeProcessor()
        return processor.processFileForResult(url: url)
    }

    func processFileForResult(url: URL) -> (text: String, chapters: [[String: Any]], hasStructure: Bool)? {
        guard let pdfDoc = PDFDocument(url: url) else { return nil }
        let pageCount = pdfDoc.pageCount
        guard pageCount > 0 else { return nil }

        NSLog("[ScribeProcessor] Processing %d pages from %@", pageCount, url.lastPathComponent)

        // Classify the book before extraction — drives adaptive strategy selection
        self.bookProfile = classifyBook(pdfDoc: pdfDoc)

        // Extract logical pages: each PDF page may produce 1 or 2 logical pages
        // (2 for two-column scanned books where each PDF page = 2 book pages)
        var pageExtractions: [PageExtraction] = []
        var seenImageHashes = Set<Int>()
        for i in 0..<pageCount {
            guard let page = pdfDoc.page(at: i) else {
                pageExtractions.append(PageExtraction(text: "", footnotes: [], images: [], pdfPageIndex: i))
                continue
            }
            let logicalPages = extractLogicalPages(page: page, pageIndex: i, seenHashes: &seenImageHashes)
            pageExtractions.append(contentsOf: logicalPages)
        }

        NSLog("[ScribeProcessor] %d PDF pages → %d logical pages", pageCount, pageExtractions.count)

        // Detect chapter structure BEFORE stripping running headers,
        // since chapter titles on title pages are the same text as running headers
        let outline = extractOutline(pdfDoc: pdfDoc)
        var chapterOutline: [(title: String, pageIndex: Int)]
        var hasStructure = false

        if !outline.isEmpty {
            // Outline gives PDF page indices, but pageExtractions uses logical indices
            // (two-column pages produce 2 logical pages per PDF page). Map accordingly.
            chapterOutline = outline.map { item in
                let logicalIndex = pageExtractions.firstIndex(where: { $0.pdfPageIndex == item.pageIndex }) ?? item.pageIndex
                return (title: item.title, pageIndex: logicalIndex)
            }
            hasStructure = true
        } else {
            chapterOutline = parseChaptersFromContentsPage(pageExtractions: pageExtractions, pageCount: pageExtractions.count, pdfDoc: pdfDoc)
            if !chapterOutline.isEmpty {
                NSLog("[ScribeProcessor] Parsed %d chapters from Contents page text", chapterOutline.count)
                hasStructure = true
            }
        }

        // Detect back-matter sections BEFORE stripping running headers,
        // because headers like "Bibliography" get detected as running headers
        // and would be stripped, preventing back-matter detection.
        var backMatterStartIndex = chapterOutline.count  // Track where back matter begins
        if hasStructure && chapterOutline.count >= 2 {
            let lastEntry = chapterOutline.last!
            let lastStartPage = lastEntry.pageIndex
            if lastStartPage < pageExtractions.count {
                let backMatterPages = Array(pageExtractions[lastStartPage..<pageExtractions.count])
                let backMatterHeaders = detectBackMatterSections(pages: backMatterPages, startOffset: lastStartPage)
                if !backMatterHeaders.isEmpty {
                    NSLog("[ScribeProcessor] Pre-strip: detected %d back-matter sections after '%@'", backMatterHeaders.count, lastEntry.title)
                    backMatterStartIndex = chapterOutline.count
                    chapterOutline.append(contentsOf: backMatterHeaders)
                }
            }
        }

        // NOW strip running headers (after chapter boundaries are determined)
        detectAndStripRunningHeaders(pageExtractions: &pageExtractions)

        let pageTexts = pageExtractions.map { $0.text }
        var chapters: [[String: Any]]

        if hasStructure {
            chapters = buildChaptersFromOutline(outline: chapterOutline, pageExtractions: pageExtractions, pageCount: pageExtractions.count, backMatterStartIndex: backMatterStartIndex)
        } else {
            chapters = buildPageBasedChapters(pageExtractions: pageExtractions, fileName: url.lastPathComponent)
        }

        chapters = calculateWordBoundaries(chapters: chapters)
        let fullText = pageTexts.joined(separator: "\n")
        return (text: fullText, chapters: chapters, hasStructure: hasStructure)
    }
}
