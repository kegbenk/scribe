import Foundation
import PDFKit
import CoreGraphics

extension ScribeProcessor {

    // MARK: - Book Classification

    /// Classify a PDF by sampling pages to determine book type and content type.
    /// Runs once per processing invocation and stores the result in `bookProfile`.
    func classifyBook(pdfDoc: PDFDocument) -> BookProfile {
        let pageCount = pdfDoc.pageCount
        // Sample up to 10 evenly-spaced pages from the middle of the book
        let sampleCount = min(10, pageCount)
        let startPage = max(0, pageCount / 5)  // Skip front matter
        let stride = max(1, (pageCount - startPage) / sampleCount)

        var landscapeCount = 0
        var twoColumnCount = 0
        var illustratedPageCount = 0
        var citationLineCount = 0
        var totalSampledLines = 0
        var fontSizeVariances: [CGFloat] = []
        var globalFontBuckets: [Int: Int] = [:]  // font size bucket → count across all pages

        let citationRe = try! NSRegularExpression(
            pattern: #"([Ii]bid\.?|[Cc]f\.|op\.?\s*cit|supra|infra|[Pp]p?\.\s*\d|[Vv]ol\.\s*[IVX\d]|\(\d{4}\)|\bn\.\s*\d)"#
        )
        let noteNumRe = try! NSRegularExpression(pattern: #"^(\d{1,3})[.\s]"#)

        for s in 0..<sampleCount {
            let idx = min(startPage + s * stride, pageCount - 1)
            guard let page = pdfDoc.page(at: idx) else { continue }
            let rect = page.bounds(for: .cropBox)

            // Check landscape
            if rect.width > rect.height * 1.1 {
                landscapeCount += 1
            }

            // Extract lines and check for two-column layout
            let lines = extractTextLines(page: page)
            if let cols = splitIntoColumns(lines: lines, pageWidth: rect.width, pageHeight: rect.height) {
                if cols[0].count >= 3 && cols[1].count >= 3 {
                    twoColumnCount += 1
                }
            }

            // Check for citation content in bottom half of lines
            let bottomHalf = lines.count / 2
            for i in max(0, bottomHalf)..<lines.count {
                let text = lines[i].text.trimmingCharacters(in: .whitespacesAndNewlines)
                totalSampledLines += 1

                let hasNoteNum = noteNumRe.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
                let hasCitation = citationRe.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil

                if hasNoteNum && hasCitation {
                    citationLineCount += 1
                }
            }

            // Font size variance — high variance = real fonts, low variance = OCR-estimated
            let fontSizes = lines.filter { $0.fontSize > 3 }.map { $0.fontSize }
            if fontSizes.count >= 5 {
                let mean = fontSizes.reduce(0, +) / CGFloat(fontSizes.count)
                let variance = fontSizes.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / CGFloat(fontSizes.count)
                fontSizeVariances.append(variance)
            }

            // Accumulate global font buckets for body font estimation
            for fs in fontSizes {
                let bucket = Int(round(fs * 10))
                globalFontBuckets[bucket, default: 0] += 1
            }

            // Check for illustrated scan pages: has image XObjects but sparse text
            let totalTextChars = lines.reduce(0) { $0 + $1.text.count }
            if let cgPage = page.pageRef, let dict = cgPage.dictionary {
                var resourcesDict: CGPDFDictionaryRef?
                if CGPDFDictionaryGetDictionary(dict, "Resources", &resourcesDict),
                   let resources = resourcesDict {
                    var xObjectDict: CGPDFDictionaryRef?
                    if CGPDFDictionaryGetDictionary(resources, "XObject", &xObjectDict),
                       let _ = xObjectDict {
                        if totalTextChars < 200 {
                            illustratedPageCount += 1
                        }
                    }
                }
            }
        }

        // Determine book type
        let isTwoColumn = twoColumnCount >= sampleCount / 3
        let isLandscapeDominant = landscapeCount >= sampleCount / 2
        let avgFontVariance = fontSizeVariances.isEmpty ? CGFloat(10) :
            fontSizeVariances.reduce(0, +) / CGFloat(fontSizeVariances.count)
        let isIllustratedScan = illustratedPageCount > sampleCount / 5

        // Scanned OCR: landscape pages (two book pages per scan) OR very low font variance
        // (OCR estimates font size from bounding boxes → uniform sizes)
        // OR illustrated scan (image-heavy pages with sparse text)
        let bookType: BookType = (isLandscapeDominant || (isTwoColumn && avgFontVariance < 2.0) || isIllustratedScan)
            ? .scannedOCR : .digitalClean

        // Academic: ≥3 citation-format footnote lines found in sampled pages
        let contentType: ContentType = citationLineCount >= 3 ? .academic : .general

        // Global body font: most frequent font bucket across all sampled pages (mode, prefer larger)
        let globalBodyFont: CGFloat? = globalFontBuckets.max(by: { a, b in
            if a.value != b.value { return a.value < b.value }
            return a.key < b.key
        }).map { CGFloat($0.key) / 10.0 }

        let profile = BookProfile(
            bookType: bookType,
            contentType: contentType,
            isTwoColumn: isTwoColumn,
            globalBodyFont: globalBodyFont
        )

        NSLog("[ScribeProcessor] Book classified: type=%@, content=%@, twoColumn=%d, globalBodyFont=%.1f (sampled %d pages, %d citations, avgFontVar=%.1f)",
              bookType == .scannedOCR ? "scannedOCR" : "digitalClean",
              contentType == .academic ? "academic" : "general",
              isTwoColumn ? 1 : 0,
              globalBodyFont ?? 0,
              sampleCount, citationLineCount, avgFontVariance)

        return profile
    }
}
