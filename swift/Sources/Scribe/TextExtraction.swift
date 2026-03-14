import Foundation
import PDFKit
import CoreGraphics
import Vision
#if canImport(UIKit)
import UIKit
#endif

extension ScribeProcessor {

    // MARK: - Logical Page Extraction

    /// Extract logical pages from a PDF page. For two-column scanned books,
    /// returns two PageExtractions (one per column/book-page). For single-column
    /// pages, returns one PageExtraction.
    func extractLogicalPages(page: PDFPage, pageIndex: Int, seenHashes: inout Set<Int>) -> [PageExtraction] {
        let lines = extractTextLines(page: page)
        let pageRect = page.bounds(for: .cropBox)
        let images = extractPageImages(page: page, pageIndex: pageIndex, seenHashes: &seenHashes)

        // Detect two-column layout (two book pages per PDF page in scanned books)
        let isLandscape = pageRect.width > pageRect.height * 1.1

        // Try line-based column split first
        var columns = splitIntoColumns(lines: lines, pageWidth: pageRect.width, pageHeight: pageRect.height)

        // Fallback: if landscape page but line-based split failed (PDFKit merged
        // cross-column lines), use rect-based extraction to get each column independently
        if columns == nil && isLandscape && lines.count >= 6 {
            let midX = pageRect.width / 2
            let gutter: CGFloat = pageRect.width * 0.02 // 2% gutter
            let leftRect = CGRect(x: pageRect.origin.x, y: pageRect.origin.y,
                                  width: midX - gutter, height: pageRect.height)
            let rightRect = CGRect(x: midX + gutter, y: pageRect.origin.y,
                                   width: pageRect.width - midX - gutter, height: pageRect.height)

            let leftLines = extractTextLinesFromRect(page: page, rect: leftRect)
            let rightLines = extractTextLinesFromRect(page: page, rect: rightRect)

            if leftLines.count >= 3 && rightLines.count >= 3 {
                columns = [leftLines, rightLines]
                NSLog("[ScribeProcessor] Page %d: rect-based column split (%d left, %d right)", pageIndex, leftLines.count, rightLines.count)
            }
        }

        if let columns = columns {
            if columns[0].count >= 3 && columns[1].count >= 3 {
                NSLog("[ScribeProcessor] Page %d: two-column layout (%d left, %d right)", pageIndex, columns[0].count, columns[1].count)
            }
            var result: [PageExtraction] = []

            for (colIdx, column) in columns.enumerated() {
                if column.count <= 1 {
                    if let first = column.first {
                        let t = first.text.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !t.isEmpty {
                            result.append(PageExtraction(text: cleanOCRArtifacts(t, aggressive: bookProfile?.bookType == .scannedOCR), footnotes: [], images: [], pdfPageIndex: pageIndex))
                        }
                    }
                    continue
                }
                var columnLines = column
                stripPageNumberLines(&columnLines)
                let (bodyLines, footnotes, continuation) = separateFootnotes(lines: columnLines, page: page)

                if colIdx == 0 {
                    // Left column: continuation text is from the PREVIOUS PDF page's
                    // last footnote. Store it as footnoteContinuation on this extraction
                    // so appendFootnotesAsEndnotes can resolve it cross-page.
                    let bodyText = buildParagraphAwareText(lines: bodyLines)
                    if !bodyText.isEmpty {
                        result.append(PageExtraction(
                            text: cleanOCRArtifacts(bodyText, aggressive: bookProfile?.bookType == .scannedOCR),
                            footnotes: footnotes,
                            images: images,
                            pdfPageIndex: pageIndex,
                            footnoteContinuation: continuation
                        ))
                    }
                } else {
                    // Right column (or later): continuation text is from the LEFT
                    // column's last footnote — apply it within this page.
                    if let cont = continuation, !cont.isEmpty, !result.isEmpty {
                        var prev = result[result.count - 1]
                        if prev.footnotes.last != nil {
                            var updatedFootnotes = prev.footnotes
                            let last = updatedFootnotes[updatedFootnotes.count - 1]
                            updatedFootnotes[updatedFootnotes.count - 1] = Footnote(number: last.number, text: last.text + " " + cont)
                            prev = PageExtraction(text: prev.text, footnotes: updatedFootnotes, images: prev.images, pdfPageIndex: prev.pdfPageIndex, footnoteContinuation: prev.footnoteContinuation)
                            result[result.count - 1] = prev
                        }
                    }

                    let bodyText = buildParagraphAwareText(lines: bodyLines)
                    if !bodyText.isEmpty {
                        result.append(PageExtraction(
                            text: cleanOCRArtifacts(bodyText, aggressive: bookProfile?.bookType == .scannedOCR),
                            footnotes: footnotes,
                            images: [],
                            pdfPageIndex: pageIndex
                        ))
                    }
                }
            }

            return result.isEmpty ? [PageExtraction(text: "", footnotes: [], images: images, pdfPageIndex: pageIndex)] : result
        }

        // Single-column path
        if lines.count > 1 {
            var cleanedLines = lines
            stripPageNumberLines(&cleanedLines)
            let (bodyLines, footnotes, continuation) = separateFootnotes(lines: cleanedLines, page: page)
            let bodyText = buildParagraphAwareText(lines: bodyLines)
            return [PageExtraction(text: cleanOCRArtifacts(bodyText, aggressive: bookProfile?.bookType == .scannedOCR), footnotes: footnotes, images: images, pdfPageIndex: pageIndex, footnoteContinuation: continuation)]
        }

        // Fallback to raw string for single-line or failed extraction
        let pdfKitText = page.string ?? ""
        let trimmed = pdfKitText.trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmed.count > 20 {
            return [PageExtraction(text: trimmed, footnotes: [], images: images, pdfPageIndex: pageIndex)]
        }

        NSLog("[ScribeProcessor] Page %d has little text (%d chars), attempting Vision OCR", pageIndex, trimmed.count)
        let ocrText = extractTextWithVision(page: page)
        return [PageExtraction(text: ocrText.isEmpty ? trimmed : ocrText, footnotes: [], images: images, pdfPageIndex: pageIndex)]
    }

    /// Legacy single-result extraction — combines columns into one text block.
    /// Used by tests that call extractPageText directly.
    func extractPageText(page: PDFPage, pageIndex: Int) -> (text: String, footnotes: [Footnote]) {
        var seenHashes = Set<Int>()
        let logicalPages = extractLogicalPages(page: page, pageIndex: pageIndex, seenHashes: &seenHashes)
        let combinedText = logicalPages.map { $0.text }.joined(separator: "\n\n")
        let combinedFootnotes = logicalPages.flatMap { $0.footnotes }
        return (combinedText, combinedFootnotes)
    }

    // MARK: - Page Number Stripping

    /// Strip standalone page number lines from top and bottom of a column.
    /// Page numbers are short lines containing only digits or Roman numerals.
    func stripPageNumberLines(_ lines: inout [TextLine]) {
        guard lines.count > 3 else { return }

        // Strip leading page numbers
        while lines.count > 3 {
            let text = lines[0].text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard text.count <= 6 else { break }
            let isNumber = text.range(of: #"^[\divxlcdmIVXLCDM]+$"#, options: .regularExpression) != nil
            guard isNumber else { break }
            lines.removeFirst()
        }

        // Strip trailing page numbers
        while lines.count > 3 {
            let text = lines.last!.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard text.count <= 6 else { break }
            let isNumber = text.range(of: #"^[\divxlcdmIVXLCDM]+$"#, options: .regularExpression) != nil
            guard isNumber else { break }
            lines.removeLast()
        }
    }

    // MARK: - Column Detection

    /// Detect two-column layout (e.g., two book pages per PDF page in scanned books).
    /// Returns [leftLines, rightLines] if two columns detected, nil otherwise.
    func splitIntoColumns(lines: [TextLine], pageWidth: CGFloat, pageHeight: CGFloat) -> [[TextLine]]? {
        // Only consider landscape pages with enough lines
        guard pageWidth > pageHeight * 1.1 else { return nil }
        guard lines.count >= 6 else { return nil }

        let midX = pageWidth / 2
        let tolerance = pageWidth * 0.05 // 5% dead zone around midpoint

        var leftLines: [TextLine] = []
        var rightLines: [TextLine] = []
        var ambiguous = 0

        for line in lines {
            let center = (line.minX + line.maxX) / 2
            if center < midX - tolerance {
                leftLines.append(line)
            } else if center > midX + tolerance {
                rightLines.append(line)
            } else {
                ambiguous += 1
            }
        }

        // Both columns need significant content; few lines should span the middle
        guard leftLines.count >= 3 && rightLines.count >= 3 else { return nil }
        guard ambiguous <= max(2, lines.count / 10) else { return nil }

        return [leftLines, rightLines]
    }

    // MARK: - Rect-Based Text Extraction

    /// Extract text lines from a specific rectangular region of a page.
    /// Used to extract left and right column text independently for two-column PDFs
    /// where PDFKit's selectionsByLine() merges text across columns.
    func extractTextLinesFromRect(page: PDFPage, rect: CGRect) -> [TextLine] {
        guard let selection = page.selection(for: rect) else { return [] }
        let lineSelections = selection.selectionsByLine()
        let pageRect = page.bounds(for: .cropBox)

        var lines: [TextLine] = []
        for sel in lineSelections {
            let text = sel.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if text.isEmpty { continue }

            let bounds = sel.bounds(for: page)
            let topDownY = pageRect.height - bounds.origin.y - bounds.height
            let fontSize = max(1, bounds.height * 0.75)

            // Merge with previous if same Y (within tolerance) and small gap
            let yTolerance: CGFloat = 2.0
            if let last = lines.last, abs(last.y - topDownY) <= yTolerance {
                let gap = bounds.origin.x - last.maxX
                if gap <= rect.width * 0.15 {
                    let mergedText = last.text + text
                    lines[lines.count - 1] = TextLine(
                        text: mergedText,
                        y: last.y,
                        minX: min(last.minX, bounds.origin.x),
                        maxX: max(last.maxX, bounds.origin.x + bounds.width),
                        width: max(last.maxX, bounds.origin.x + bounds.width) - min(last.minX, bounds.origin.x),
                        fontSize: max(last.fontSize, fontSize)
                    )
                    continue
                }
            }

            lines.append(TextLine(
                text: text,
                y: topDownY,
                minX: bounds.origin.x,
                maxX: bounds.origin.x + bounds.width,
                width: bounds.width,
                fontSize: fontSize
            ))
        }

        return lines
    }

    // MARK: - Line Extraction

    /// Extract positioned text lines from a PDF page using PDFKit selections.
    func extractTextLines(page: PDFPage) -> [TextLine] {
        guard let fullText = page.string, !fullText.isEmpty else { return [] }
        let pageRect = page.bounds(for: .cropBox)

        // Get a selection covering the full page text
        guard let fullSelection = page.selection(for: pageRect) else { return [] }
        let lineSelections = fullSelection.selectionsByLine()

        var rawLines: [TextLine] = []
        for sel in lineSelections {
            let text = sel.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if text.isEmpty { continue }

            let bounds = sel.bounds(for: page)
            // PDFKit uses bottom-left origin; convert to top-down Y
            let topDownY = pageRect.height - bounds.origin.y - bounds.height
            let fontSize = max(1, bounds.height * 0.75) // Approximate from line height

            rawLines.append(TextLine(
                text: text,
                y: topDownY,
                minX: bounds.origin.x,
                maxX: bounds.origin.x + bounds.width,
                width: bounds.width,
                fontSize: fontSize
            ))
        }

        // Sort top-to-bottom, then left-to-right within same Y
        rawLines.sort { $0.y != $1.y ? $0.y < $1.y : $0.minX < $1.minX }

        // Recover superscript footnote reference digits.
        // PDFKit's selectionsByLine() often places superscript numbers (smaller font,
        // raised baseline) as separate tiny selections at a slightly different Y position.
        // These become standalone 1-3 digit TextLines that get lost during processing.
        // Strategy: find short all-digit lines positioned slightly ABOVE a body text line
        // and horizontally adjacent to it, then merge them into the body line.
        let superscriptPattern = try! NSRegularExpression(pattern: #"^\d{1,3}$"#)
        var superscriptIndices = Set<Int>()
        for (i, line) in rawLines.enumerated() {
            let text = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard text.count <= 3 else { continue }
            guard superscriptPattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil else { continue }
            // This is a short all-digit line — check if a body line is just below it
            // (within 6pt Y) and horizontally overlapping
            for (j, bodyLine) in rawLines.enumerated() {
                guard j != i else { continue }
                guard bodyLine.text.count > 10 else { continue } // Must be a real body line
                let yDiff = bodyLine.y - line.y // Body line should be below (larger Y)
                guard yDiff > 0 && yDiff < 6.0 else { continue }
                // Superscript should be near the horizontal extent of the body line
                guard line.minX >= bodyLine.minX - 2 && line.minX <= bodyLine.maxX + 5 else { continue }
                // Merge: append as "!<digits>" to the body line at the appropriate position
                // If superscript is near the end of the body line, append
                // If near the start, prepend
                let midX = (line.minX + line.maxX) / 2
                let bodyMidX = (bodyLine.minX + bodyLine.maxX) / 2
                if midX > bodyMidX {
                    // Superscript is in the right half of the body line — append
                    rawLines[j] = TextLine(
                        text: bodyLine.text + "!" + text,
                        y: bodyLine.y,
                        minX: bodyLine.minX,
                        maxX: max(bodyLine.maxX, line.maxX),
                        width: max(bodyLine.maxX, line.maxX) - bodyLine.minX,
                        fontSize: bodyLine.fontSize
                    )
                } else {
                    // Superscript is in the left half — prepend
                    rawLines[j] = TextLine(
                        text: "!" + text + " " + bodyLine.text,
                        y: bodyLine.y,
                        minX: min(bodyLine.minX, line.minX),
                        maxX: bodyLine.maxX,
                        width: bodyLine.maxX - min(bodyLine.minX, line.minX),
                        fontSize: bodyLine.fontSize
                    )
                }
                superscriptIndices.insert(i)
                break
            }
        }
        // Remove consumed superscript lines
        if !superscriptIndices.isEmpty {
            rawLines = rawLines.enumerated().filter { !superscriptIndices.contains($0.offset) }.map { $0.element }
        }

        // Merge selections that share the same Y position (within tolerance).
        // PDFKit selectionsByLine() sometimes splits a visual line at punctuation
        // boundaries (e.g., closing quote as separate selection). Merge these so
        // paragraph heuristics see complete lines.
        // BUT: do NOT merge across a large horizontal gap — that indicates two
        // separate columns in a scanned two-column PDF.
        let yTolerance: CGFloat = 2.0
        let columnGapThreshold: CGFloat = pageRect.width * 0.08 // 8% of page width
        var lines: [TextLine] = []
        for raw in rawLines {
            if let last = lines.last, abs(last.y - raw.y) <= yTolerance {
                // Check horizontal gap between end of previous and start of current
                let gap = raw.minX - last.maxX
                if gap > columnGapThreshold {
                    // Large gap — these are from different columns, keep separate
                    lines.append(raw)
                } else {
                    // Small gap — merge with previous line
                    let mergedText = last.text + raw.text
                    let mergedMinX = min(last.minX, raw.minX)
                    let mergedMaxX = max(last.maxX, raw.maxX)
                    let mergedFontSize = max(last.fontSize, raw.fontSize)
                    lines[lines.count - 1] = TextLine(
                        text: mergedText,
                        y: last.y,
                        minX: mergedMinX,
                        maxX: mergedMaxX,
                        width: mergedMaxX - mergedMinX,
                        fontSize: mergedFontSize
                    )
                }
            } else {
                lines.append(raw)
            }
        }

        return lines
    }

    // MARK: - Footnote Reference Stripping

    /// Strip inline footnote reference numbers from body text.
    /// PDFKit extracts superscript reference numbers as plain digits
    /// embedded in the text (e.g. "outcast,8 is" or "analysis 15 nothing").
    /// Uses the known footnote numbers to target only real references.
    func stripFootnoteReferences(text: String, footnotes: [Footnote]) -> String {
        guard !footnotes.isEmpty else { return text }
        let fnNumbers = Set(footnotes.map { $0.number })
        let maxFn = fnNumbers.max() ?? 0
        // Match standalone 1-3 digit numbers that look like footnote references:
        //   - preceded by a word char, punctuation, or closing quote
        //   - optionally with whitespace between
        //   - the number itself (1-3 digits)
        //   - followed by whitespace then a letter
        // Only strip if the number is in our known footnote set or <= maxFn
        let pattern = #"(?<=[a-zA-Z\p{L},;:.!?"')\]])(\s?)\d{1,3}(?=\s+[a-zA-Z\p{L}])"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let nsText = text as NSString
        var result = text
        // Find all matches and filter to only strip actual footnote references
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: nsText.length))
        // Process in reverse order to preserve indices
        for match in matches.reversed() {
            let fullRange = match.range
            let matchStr = nsText.substring(with: fullRange)
            // Extract just the digits
            let digits = matchStr.trimmingCharacters(in: .whitespaces)
            guard let num = Int(digits) else { continue }
            // Only strip if it's a plausible footnote reference
            if num >= 1 && num <= maxFn + 5 {
                let swiftRange = Range(fullRange, in: result)!
                // Preserve leading space if the match had one before the digits
                result.replaceSubrange(swiftRange, with: "")
            }
        }
        return result
    }

    // MARK: - Paragraph-Aware Text Building

    /// Build paragraph-aware text from positioned lines.
    /// Ports the heuristics from the JS `extractParagraphAwarePageText`.
    func buildParagraphAwareText(lines: [TextLine]) -> String {
        guard !lines.isEmpty else { return "" }
        if lines.count == 1 { return lines[0].text }

        // Calculate vertical gaps between consecutive lines
        var verticalGaps: [CGFloat] = []
        for i in 0..<lines.count - 1 {
            let gap = abs(lines[i + 1].y - lines[i].y)
            if gap > 0.5 && gap < 180 { verticalGaps.append(gap) }
        }

        let rawMedianGap = median(verticalGaps) ?? 12
        let inlierGaps = verticalGaps.filter { $0 <= rawMedianGap * 1.35 }
        let typicalLineGap = max(8, median(inlierGaps.isEmpty ? verticalGaps : inlierGaps) ?? 12)
        let paragraphGapThreshold = typicalLineGap * 1.6
        let hardParagraphGapThreshold = typicalLineGap * 2.8

        let leftXValues = lines.map { $0.minX }
        let baselineLeftX = median(leftXValues) ?? 0
        let lineWidths = lines.map { $0.width }
        let medianLineWidth = max(1, median(lineWidths) ?? 1)
        let fontSizes = lines.map { $0.fontSize }
        let medianFontSize = max(1, median(fontSizes) ?? 12)
        let indentThreshold = max(8, medianFontSize * 0.9)

        var paragraphs: [String] = []
        var current = lines[0].text

        for i in 1..<lines.count {
            let prev = lines[i - 1]
            let next = lines[i]
            let gap = abs(next.y - prev.y)

            let gapBreak = gap >= paragraphGapThreshold
            let hardGapBreak = gap >= hardParagraphGapThreshold

            let indentedStartBreak = (next.minX - baselineLeftX) >= indentThreshold
                && looksLikeSentenceStart(next.text)
                && looksLikeSentenceEnd(prev.text)

            let raggedLineBreak = prev.width <= medianLineWidth * 0.72
                && looksLikeSentenceEnd(prev.text)
                && looksLikeSentenceStart(next.text)

            let headingBreak = looksLikeHeadingLine(prev, medianFontSize: medianFontSize, medianLineWidth: medianLineWidth)
                && looksLikeSentenceStart(next.text)
                && next.width >= medianLineWidth * 0.65

            let likelyContinuation = !looksLikeSentenceEnd(prev.text) || looksLikeContinuationEnd(prev.text)

            let paragraphBreak = (gapBreak && (!likelyContinuation || hardGapBreak))
                || indentedStartBreak
                || raggedLineBreak
                || headingBreak

            if paragraphBreak {
                let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { paragraphs.append(trimmed) }
                current = next.text
                continue
            }

            // Join with previous line, handling hyphenation
            if current.hasSuffix("-") && !current.hasSuffix(" -") {
                current = String(current.dropLast()) + next.text
            } else {
                current = current + " " + next.text
            }
        }

        let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { paragraphs.append(trimmed) }

        return paragraphs.joined(separator: "\n\n")
    }

    // MARK: - Paragraph Detection Helpers

    func looksLikeSentenceStart(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = t.first else { return false }
        return first.isUppercase || first.isNumber || "\"\u{201C}\u{2018}'".contains(first)
    }

    /// Character-level similarity (Dice coefficient on bigrams).
    static func charSimilarity(_ a: String, _ b: String) -> Double {
        let la = a.lowercased()
        let lb = b.lowercased()
        if la == lb { return 1.0 }
        guard max(la.count, lb.count) > 0 else { return 1.0 }
        func bigrams(_ s: String) -> [String] {
            let chars: [Character] = Array(s)
            guard chars.count >= 2 else { return [s] }
            var result: [String] = []
            for i in 0..<(chars.count - 1) {
                let bg: String = String(chars[i]) + String(chars[i + 1])
                result.append(bg)
            }
            return result
        }
        let ba = bigrams(la), bb = bigrams(lb)
        let setA = NSCountedSet(array: ba), setB = NSCountedSet(array: bb)
        var intersection = 0
        for bigram in setA { intersection += min(setA.count(for: bigram), setB.count(for: bigram)) }
        let total = ba.count + bb.count
        return total == 0 ? 1.0 : Double(2 * intersection) / Double(total)
    }

    func looksLikeSentenceEnd(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let pattern = #"[.!?]["'"'\)\]]?$"#
        return t.range(of: pattern, options: .regularExpression) != nil
    }

    func looksLikeContinuationEnd(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let pattern = #"[,;:\u{2014}\-]["'"'\)\]]?$"#
        return t.range(of: pattern, options: .regularExpression) != nil
    }

    func looksLikeHeadingLine(_ line: TextLine, medianFontSize: CGFloat, medianLineWidth: CGFloat) -> Bool {
        let text = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty || text.count > 90 { return false }
        if text.contains("/") || text.contains(",") || text.contains(";") { return false }
        let words = text.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
        if words.isEmpty || words.count > 10 { return false }
        let widerFont = line.fontSize >= medianFontSize * 1.05
        let narrowLine = line.width <= medianLineWidth * 0.68
        return widerFont || narrowLine
    }

    // MARK: - Vision OCR (fallback for scanned pages)

    func extractTextWithVision(page: PDFPage) -> String {
        #if !canImport(UIKit)
        return "" // Vision OCR requires UIKit (iOS only)
        #else
        let pageRect = page.bounds(for: .mediaBox)
        let scale: CGFloat = 2.0
        let imageWidth = Int(pageRect.width * scale)
        let imageHeight = Int(pageRect.height * scale)

        guard imageWidth > 0, imageHeight > 0 else { return "" }

        UIGraphicsBeginImageContextWithOptions(
            CGSize(width: CGFloat(imageWidth), height: CGFloat(imageHeight)),
            true, 1.0
        )
        guard let context = UIGraphicsGetCurrentContext() else {
            UIGraphicsEndImageContext()
            return ""
        }

        context.setFillColor(UIColor.white.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: imageWidth, height: imageHeight))
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: 0, y: pageRect.height)
        context.scaleBy(x: 1.0, y: -1.0)
        page.draw(with: .mediaBox, to: context)

        let image = UIGraphicsGetImageFromCurrentImageContext()
        UIGraphicsEndImageContext()

        guard let cgImage = image?.cgImage else { return "" }

        let semaphore = DispatchSemaphore(value: 0)
        var recognizedText = ""

        let request = VNRecognizeTextRequest { request, error in
            defer { semaphore.signal() }
            guard error == nil,
                  let observations = request.results as? [VNRecognizedTextObservation] else {
                return
            }

            let sorted = observations.sorted { a, b in
                let ay = 1.0 - a.boundingBox.origin.y
                let by = 1.0 - b.boundingBox.origin.y
                if abs(ay - by) > 0.01 {
                    return ay < by
                }
                return a.boundingBox.origin.x < b.boundingBox.origin.x
            }

            let lines = sorted.compactMap { observation -> String? in
                observation.topCandidates(1).first?.string
            }
            recognizedText = lines.joined(separator: "\n")
        }

        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do {
            try handler.perform([request])
            semaphore.wait()
        } catch {
            NSLog("[ScribeProcessor] Vision OCR failed: %@", error.localizedDescription)
        }

        return recognizedText
        #endif
    }

    // MARK: - OCR Cleanup

    /// Fix common OCR artifacts from PDFKit text extraction on scanned PDFs.
    /// When `aggressive` is true (scanned book types), applies additional passes
    /// to strip stray symbols, garbage fragments, and clean up paragraphs.
    func cleanOCRArtifacts(_ text: String, aggressive: Bool = false) -> String {
        var result = text

        // Fix single-letter word fragments surrounded by longer words:
        // "composed o f several" → "composed of several"
        // Only when both neighbors are 3+ chars to avoid false positives
        let splitWords: [(split: String, joined: String)] = [
            ("o f", "of"), ("i n", "in"), ("i t", "it"), ("o n", "on"),
            ("i s", "is"), ("a t", "at"), ("a s", "as"), ("b e", "be"),
            ("b y", "by"), ("t o", "to"), ("o r", "or"), ("a n", "an"),
        ]
        for (split, joined) in splitWords {
            let escaped = NSRegularExpression.escapedPattern(for: split)
            // Match when both neighbors are 2+ chars
            let pattern2 = "(\\w{2,}) \(escaped) (\\w{2,})"
            if let regex = try? NSRegularExpression(pattern: pattern2) {
                result = regex.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result), withTemplate: "$1 \(joined) $2")
            }
            // Also match when one neighbor is 1 char but the other is 3+ chars
            // (handles cases where OCR broke multiple words: "direction o f a Com")
            let patternL = "(\\w{3,}) \(escaped) (\\w)"
            if let regex = try? NSRegularExpression(pattern: patternL) {
                result = regex.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result), withTemplate: "$1 \(joined) $2")
            }
            let patternR = "(\\w) \(escaped) (\\w{3,})"
            if let regex = try? NSRegularExpression(pattern: patternR) {
                result = regex.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result), withTemplate: "$1 \(joined) $2")
            }
        }

        // Fix "micro scopic" → "microscopic" style breaks where first part ends
        // with a common prefix and second part is a known suffix
        let knownJoins: [(String, String)] = [
            ("micro scopic", "microscopic"), ("strat egy", "strategy"),
            ("philos ophy", "philosophy"), ("philos opher", "philosopher"),
            ("knowl edge", "knowledge"), ("al chemy", "alchemy"),
            ("al chemical", "alchemical"), ("al chemist", "alchemist"),
            ("ex periment", "experiment"), ("ex perimental", "experimental"),
            ("in terpret", "interpret"), ("inter pretation", "interpretation"),
            ("mech anical", "mechanical"), ("mech anism", "mechanism"),
            ("math ematical", "mathematical"), ("math ematics", "mathematics"),
            ("dem onstration", "demonstration"), ("cor respondence", "correspondence"),
            ("phenom ena", "phenomena"), ("grav itation", "gravitation"),
        ]
        for (split, joined) in knownJoins {
            result = result.replacingOccurrences(of: split, with: joined, options: .caseInsensitive)
        }

        if aggressive {
            // Strip stray symbol tokens: 1-4 chars of pure punctuation/symbols
            // at word boundaries (start of line, between spaces, end of line).
            // Catches: "(^", "&", "<$", "J*", "/*" etc.
            if let strayRe = try? NSRegularExpression(pattern: #"(?:^|\s)[^\w\s]{1,4}(?=\s|$)"#, options: .anchorsMatchLines) {
                result = strayRe.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result), withTemplate: " ")
            }

            // Strip symbol prefixes/suffixes fused to words: "<$past" → "past", "cenJ*" → "cen"
            if let prefixRe = try? NSRegularExpression(pattern: #"(?:^|\s)[^\w\s]{1,3}(\w{3,})"#, options: .anchorsMatchLines) {
                result = prefixRe.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result), withTemplate: " $1")
            }
            if let suffixRe = try? NSRegularExpression(pattern: #"(\w{2,})[^\w\s]{1,3}(?=\s|$)"#) {
                result = suffixRe.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result), withTemplate: "$1")
            }

            // Common OCR misreads in scanned fiction
            result = result.replacingOccurrences(of: "'11 ", with: "'ll ")  // it '11 → it'll
            result = result.replacingOccurrences(of: "'11\n", with: "'ll\n")

            // Collapse multiple spaces left by stripping
            if let multiSpaceRe = try? NSRegularExpression(pattern: #" {2,}"#) {
                result = multiSpaceRe.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result), withTemplate: " ")
            }

            // Filter garbage paragraphs: pure symbols, standalone &, >50% non-alpha
            let paragraphs = result.components(separatedBy: "\n\n")
            var cleanedParagraphs: [String] = []
            for para in paragraphs {
                let trimmed = para.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                // Remove paragraphs that are just 1-3 chars of symbols/punctuation
                if trimmed.count <= 3 && trimmed.allSatisfy({ !$0.isLetter && !$0.isNumber }) { continue }
                // Remove paragraphs that are >50% non-alphanumeric
                let alphaNumCount = trimmed.filter { $0.isLetter || $0.isNumber || $0.isWhitespace }.count
                if trimmed.count < 100 && alphaNumCount < trimmed.count / 2 { continue }
                cleanedParagraphs.append(trimmed)
            }
            result = cleanedParagraphs.joined(separator: "\n\n")
        }

        return result
    }
}
