import Foundation
import PDFKit
import CoreGraphics

extension ScribeProcessor {

    /// Separate footnote lines from body text lines.
    /// Footnotes are detected at the bottom of the page by:
    ///   - smaller line height than the body median
    ///   - starting with a digit (footnote number)
    ///   - located in the bottom portion of the page
    func separateFootnotes(lines: [TextLine], page: PDFPage) -> (body: [TextLine], footnotes: [Footnote], continuationText: String?) {
        guard lines.count > 3 else { return (lines, [], nil) }

        let pageHeight = page.bounds(for: .cropBox).height
        let pageIndex = page.document?.index(for: page) ?? -1

        let noteStartPattern = try! NSRegularExpression(pattern: #"^(\d{1,3})[.\s]"#)
        // Academic citation markers — used by Strategy 6 for content-based detection
        let citationPattern = try! NSRegularExpression(
            pattern: #"([Ii]bid\.?|[Cc]f\.|op\.?\s*cit|supra|infra|[Pp]p?\.\s*\d|[Vv]ol\.\s*[IVX\d]|\(\d{4}\)|\bn\.\s*\d)"#
        )

        // Find the body font size by bucketing all font sizes and selecting the
        // MOST FREQUENT bucket (mode). Among equally-frequent buckets, prefer the
        // larger font (body text is larger than footnotes). This avoids: (a) chapter
        // titles (1-2 lines at a large font) and (b) rare fonts from headers/captions.
        let allFontSizes = lines.filter { $0.fontSize > 3 }.map { $0.fontSize }
        var fontBuckets: [Int: Int] = [:] // rounded font size → count
        for fs in allFontSizes {
            let bucket = Int(round(fs * 10)) // 0.1pt precision
            fontBuckets[bucket, default: 0] += 1
        }
        // Most frequent bucket = body text; break ties by preferring larger font
        let bodyFontBucket = fontBuckets.max(by: { a, b in
            if a.value != b.value { return a.value < b.value }
            return a.key < b.key
        })
        var medianBodyFontSize = bodyFontBucket.map { CGFloat($0.key) / 10.0 } ?? 10

        // For scanned OCR academic books: if per-column bucketing picked a font significantly
        // smaller than the global body font, the column likely has more footnote lines than
        // body lines (footnote font won the mode). Override with the global body font.
        if let globalFont = bookProfile?.globalBodyFont, bookProfile?.preferContentStrategies ?? false {
            if medianBodyFontSize < globalFont * 0.95 {
                medianBodyFontSize = globalFont
            }
        }

        // Calculate typical body gap from lines matching the body font size
        // Use the (possibly overridden) medianBodyFontSize to determine which lines are body
        let bodyBucketKey = Int(round(medianBodyFontSize * 10))
        var bodyGaps: [CGFloat] = []
        for i in 1..<lines.count {
            let prevFs = Int(round(lines[i-1].fontSize * 10))
            let currFs = Int(round(lines[i].fontSize * 10))
            guard prevFs == bodyBucketKey && currFs == bodyBucketKey else { continue }
            let gap = abs(lines[i].y - lines[i-1].y)
            if gap > 0.5 && gap < 50 { bodyGaps.append(gap) }
        }
        let typicalBodyGap = median(bodyGaps) ?? 12
        var footnoteStartIdx: Int? = nil

        for i in 1..<lines.count {
            let line = lines[i]
            let gap = abs(line.y - lines[i-1].y)

            let text = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let hasNoteNum = noteStartPattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil

            // Strategy 1: Numbered line after a significant gap
            if hasNoteNum && gap >= typicalBodyGap * 1.2 {
                footnoteStartIdx = i
                break
            }

            // Strategy 2: Numbered line with noticeably smaller font than body
            if hasNoteNum && line.fontSize < medianBodyFontSize * 0.92 {
                footnoteStartIdx = i
                break
            }

            // Strategy 3: Gap + font-size drop WITHOUT requiring a numbered line.
            // In scanned books, the first line after the body-footnote separator is often
            // continuation text (no number) or has an OCR-mangled number ("I." instead of "1.").
            // A gap >= 1.5x body gap with a clear font-size drop indicates the boundary.
            if gap >= typicalBodyGap * 1.5 && line.fontSize < medianBodyFontSize * 0.92 {
                footnoteStartIdx = i
                break
            }

            // Strategy 4: Font-size drop alone in the bottom 30% of the page.
            // Catches cases where the body-footnote gap is small (< 1.2x) but
            // the font clearly changes. Only trigger in the lower portion of the
            // page to avoid false positives from mid-page font-size variation.
            if line.y > pageHeight * 0.65 && line.fontSize < medianBodyFontSize * 0.88 {
                // Require at least one numbered note in the remaining lines
                var hasNumberedNote = false
                for j in i..<lines.count {
                    let t = lines[j].text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if noteStartPattern.firstMatch(in: t, range: NSRange(t.startIndex..., in: t)) != nil {
                        hasNumberedNote = true
                        break
                    }
                }
                if hasNumberedNote {
                    footnoteStartIdx = i
                    break
                }
            }
        }

        // Strategy 5: Bottom-of-page numbered-line cluster.
        // For PDFs where footnotes have the SAME font size as body text and
        // minimal gap (e.g., healing-dream with garbled glyph encoding), the
        // gap/font heuristics all fail. Instead, scan from the bottom of the
        // page upward looking for a cluster of ≥2 consecutive lines starting
        // with sequential numbers — a strong footnote signal regardless of
        // font or spacing.
        // For scanned OCR academic books, search a larger region (bottom 50%)
        // and accept single footnotes backed by citation content.
        if footnoteStartIdx == nil {
            let prefersContent = bookProfile?.preferContentStrategies ?? false
            let searchFraction = prefersContent ? 0.5 : 0.4
            var numberedLineIndices: [Int] = []
            let bottomHalf = Int(Double(lines.count) * searchFraction)
            for i in max(1, bottomHalf)..<lines.count {
                let t = lines[i].text.trimmingCharacters(in: .whitespacesAndNewlines)
                if noteStartPattern.firstMatch(in: t, range: NSRange(t.startIndex..., in: t)) != nil {
                    numberedLineIndices.append(i)
                }
            }

            // For academic scanned OCR: accept single numbered line if it has citation content
            let minClusterSize = prefersContent ? 1 : 2
            if numberedLineIndices.count >= minClusterSize {
                // Single footnote in academic mode: verify it has citation content
                if numberedLineIndices.count == 1 && prefersContent {
                    let singleIdx = numberedLineIndices[0]
                    let t = lines[singleIdx].text.trimmingCharacters(in: .whitespacesAndNewlines)
                    let hasCitation = citationPattern.firstMatch(in: t, range: NSRange(t.startIndex..., in: t)) != nil
                    if hasCitation {
                        footnoteStartIdx = singleIdx
                    }
                }
            }

            if footnoteStartIdx == nil && numberedLineIndices.count >= 2 {
                // Find the earliest numbered line that's part of a cluster
                // (another numbered line within 3 lines of it)
                for idx in numberedLineIndices {
                    let hasNeighbor = numberedLineIndices.contains(where: { $0 != idx && abs($0 - idx) <= 3 })
                    if hasNeighbor {
                        // Walk backward from this numbered line to include any
                        // non-numbered continuation text that precedes it (from
                        // a footnote that started on the previous page)
                        var start = idx
                        while start > 0 {
                            let prevText = lines[start - 1].text.trimmingCharacters(in: .whitespacesAndNewlines)
                            // Stop if previous line looks like body text (long sentence ending with period)
                            // or is clearly in the top half of the page
                            if start - 1 < bottomHalf { break }
                            let prevHasNum = noteStartPattern.firstMatch(in: prevText, range: NSRange(prevText.startIndex..., in: prevText)) != nil
                            if !prevHasNum && prevText.count > 80 {
                                break
                            }
                            start -= 1
                        }
                        footnoteStartIdx = start
                        break
                    }
                }
            }
        }


        // Strategy 6: Academic citation content pattern.
        // For scanned OCR books where font/gap heuristics fail (Vision OCR
        // normalizes font sizes), detect footnotes by their CONTENT: numbered
        // lines containing citation markers like "ibid.", "cf.", "pp.", "(1991)".
        // This is the most reliable strategy for academic texts regardless of
        // OCR quality.
        if footnoteStartIdx == nil {
            let bottomPortion = Int(Double(lines.count) * 0.5)
            var citationLineIndices: [Int] = []

            for i in max(1, bottomPortion)..<lines.count {
                let text = lines[i].text.trimmingCharacters(in: .whitespacesAndNewlines)
                let hasNoteNum = noteStartPattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
                let hasCitation = citationPattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil

                if hasNoteNum && hasCitation {
                    citationLineIndices.append(i)
                }
            }

            if !citationLineIndices.isEmpty {
                var start = citationLineIndices[0]
                // Walk backward to include non-numbered continuation lines
                while start > 0 && start - 1 >= bottomPortion {
                    let prevText = lines[start - 1].text.trimmingCharacters(in: .whitespacesAndNewlines)
                    let prevHasNum = noteStartPattern.firstMatch(in: prevText, range: NSRange(prevText.startIndex..., in: prevText)) != nil
                    let prevHasCitation = citationPattern.firstMatch(in: prevText, range: NSRange(prevText.startIndex..., in: prevText)) != nil
                    if !prevHasNum && !prevHasCitation && prevText.count > 80 {
                        break
                    }
                    start -= 1
                }
                footnoteStartIdx = start
            }
        }

        // Strategy 7: Gap + font boundary without digit requirement (scanned OCR academic only).
        // In scanned OCR academic books, OCR often mangles footnote numbers ("II" for "11",
        // "I." for "1.") or splits them from the line text. The footnote region is still
        // detectable by a large Y-gap (≥2x body gap) followed by lines with smaller font
        // AND citation content. This strategy does NOT require any line to start with a
        // digit pattern — it relies purely on layout + content signals.
        if footnoteStartIdx == nil && (bookProfile?.preferContentStrategies ?? false) {
            for i in 1..<lines.count {
                let line = lines[i]
                let gap = abs(line.y - lines[i-1].y)

                // Need a gap ≥ 2x body gap AND font drop to < 0.95x body font
                guard gap >= typicalBodyGap * 2.0 && line.fontSize < medianBodyFontSize * 0.95 else { continue }

                // Must be in the bottom 50% of lines
                guard i >= lines.count / 2 else { continue }

                // Verify: the region below must contain citation content
                let regionBelow = lines[i...]
                let hasCitations = regionBelow.contains(where: { l in
                    let t = l.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    return citationPattern.firstMatch(in: t, range: NSRange(t.startIndex..., in: t)) != nil
                })
                // Also verify: remaining lines should mostly have the smaller font
                let smallFontCount = regionBelow.filter { $0.fontSize < medianBodyFontSize * 0.95 }.count
                let smallFontRatio = Double(smallFontCount) / Double(regionBelow.count)

                if hasCitations && smallFontRatio >= 0.5 {
                    footnoteStartIdx = i
                    break
                }
            }
        }

        guard let fnStart = footnoteStartIdx else { return (lines, [], nil) }

        // Verify: at least one more numbered footnote should follow in the remaining lines,
        // OR the footnote region should show a clear font-size drop from the body.
        var foundSecondNote = false
        for i in (fnStart + 1)..<lines.count {
            let text = lines[i].text.trimmingCharacters(in: .whitespacesAndNewlines)
            if noteStartPattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil {
                foundSecondNote = true
                break
            }
        }
        // Check if the footnote region has a clearly smaller font than the body
        let bodyFontsForCheck = lines[0..<fnStart].map { $0.fontSize }
        let footFontsForCheck = lines[fnStart...].map { $0.fontSize }
        let medBodyForCheck = median(bodyFontsForCheck) ?? medianBodyFontSize
        let medFootForCheck = median(Array(footFontsForCheck)) ?? medianBodyFontSize
        let hasFontSignal = medFootForCheck < medBodyForCheck * 0.92
        // Check if footnote region contains academic citation content
        let hasCitationContent = lines[fnStart...].contains(where: { line in
            let t = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return citationPattern.firstMatch(in: t, range: NSRange(t.startIndex..., in: t)) != nil
        })
        if !foundSecondNote && !hasFontSignal && !hasCitationContent && lines.count - fnStart > 3 {
            // If many lines but no second numbered note, no font signal, and no
            // citation content, this is likely a false positive
            return (lines, [], nil)
        }

        // Secondary validation: footnote lines should have smaller font size
        // or tighter line spacing than body text. This catches false positives
        // where body text happens to start with a number after a paragraph gap.
        let bodyFontSizes = lines[0..<fnStart].map { $0.fontSize }
        let footFontSizes = lines[fnStart...].map { $0.fontSize }
        let medianBodyFont = median(bodyFontSizes) ?? 10
        let medianFootFont = median(Array(footFontSizes)) ?? 10
        // If "footnote" lines have clearly larger font than body, likely false positive.
        // Use a relaxed threshold (1.15) because OCR-approximated font sizes from
        // line bounds are unreliable — the gap+number detection is the primary signal.
        if medianFootFont >= medianBodyFont * 1.15 {
            return (lines, [], nil)
        }

        let bodyLines = Array(lines[0..<fnStart])
        let footLines = Array(lines[fnStart...])

        // Parse footnote lines into structured footnotes.
        // A new footnote starts when a line begins with a digit followed by space/period.
        // Subsequent lines without a leading number are continuations.
        // Lines BEFORE the first numbered footnote are "continuation text" from
        // a footnote that started on a previous page/column.
        var footnotes: [Footnote] = []
        var currentNum: Int? = nil
        var currentText = ""
        var continuationParts: [String] = []

        let bodyMedianFont = median(bodyLines.map { $0.fontSize }) ?? 10

        for (idx, line) in footLines.enumerated() {
            let text = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty { continue }

            // Skip standalone page numbers (last line, short, just a number, larger than footnote text)
            if idx == footLines.count - 1 && text.count <= 4 && Int(text) != nil && line.fontSize >= bodyMedianFont * 0.85 {
                continue
            }

            if let match = noteStartPattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
               let fullRange = Range(match.range, in: text),
               let numRange = Range(match.range(at: 1), in: text) {
                // Save previous footnote
                if let num = currentNum, !currentText.isEmpty {
                    footnotes.append(Footnote(number: num, text: currentText.trimmingCharacters(in: .whitespacesAndNewlines)))
                }
                // Extract number (from capture group 1) and start new footnote
                let numStr = String(text[numRange])
                currentNum = Int(numStr)
                currentText = String(text[fullRange.upperBound...]).trimmingCharacters(in: .whitespaces)
            } else if currentNum != nil {
                // Continuation of current footnote
                if currentText.hasSuffix("-") && !currentText.hasSuffix(" -") {
                    currentText = String(currentText.dropLast()) + text
                } else {
                    currentText += " " + text
                }
            } else {
                // Before the first numbered footnote — this is continuation text
                // from a footnote that started on a previous page/column
                continuationParts.append(text)
            }
        }

        // Save last footnote
        if let num = currentNum, !currentText.isEmpty {
            footnotes.append(Footnote(number: num, text: currentText.trimmingCharacters(in: .whitespacesAndNewlines)))
        }

        let continuation: String? = continuationParts.isEmpty ? nil :
            continuationParts.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)

        return (bodyLines, footnotes, continuation)
    }
}
