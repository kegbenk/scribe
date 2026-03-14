import Foundation
import CoreGraphics

extension ScribeProcessor {

    // MARK: - Running Header Detection

    /// Detect short text patterns that repeat across many pages (running headers)
    /// and strip them from all page texts. Running headers are typically the book
    /// title on even pages and the chapter title on odd pages.
    func detectAndStripRunningHeaders(pageExtractions: inout [PageExtraction]) {
        guard pageExtractions.count > 10 else { return }

        // Collect short non-sentence paragraphs from all pages
        var candidateCounts: [String: Int] = [:]

        for extraction in pageExtractions {
            let text = extraction.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }

            let paragraphs = text.components(separatedBy: "\n\n")
            // Check all short paragraphs (headers can appear mid-page after column joins)
            for para in paragraphs {
                let trimmed = para.trimmingCharacters(in: .whitespacesAndNewlines)
                guard trimmed.count >= 5 && trimmed.count < 70 else { continue }
                // Skip if it ends with sentence punctuation (not a header)
                if trimmed.range(of: #"[.!?]["'"'\)\]]?\s*$"#, options: .regularExpression) != nil { continue }

                // Normalize: strip leading/trailing page numbers and caret OCR artifacts.
                // Handle both contiguous digits ("42") and OCR-spaced digits ("4 2").
                let normalized = trimmed
                    .replacingOccurrences(of: #"^(\d\s){1,3}\d\s*\^?\s*"#, with: "", options: .regularExpression)
                    .replacingOccurrences(of: #"\s*\^?\s*(\d\s){1,3}\d$"#, with: "", options: .regularExpression)
                    .replacingOccurrences(of: #"^\d{1,4}\s*\^?\s*"#, with: "", options: .regularExpression)
                    .replacingOccurrences(of: #"\s*\^?\s*\d{1,4}$"#, with: "", options: .regularExpression)
                    .replacingOccurrences(of: "^", with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)

                guard normalized.count >= 5 else { continue }
                candidateCounts[normalized, default: 0] += 1
            }

            // Also extract running header candidates from long first paragraphs.
            // Running headers often merge with body text when buildParagraphAwareText
            // doesn't detect a paragraph break, producing e.g.:
            //   "The Divine Sickness 3 cast out by the divine remedy..."
            // Extract the title prefix before the page number.
            if let firstPara = paragraphs.first {
                let trimmed = firstPara.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.count > 70 {
                    let words = trimmed.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
                    for j in 1..<min(words.count, 12) {
                        if words[j].range(of: #"^\d{1,4}$"#, options: .regularExpression) != nil && j < words.count - 1 {
                            let titlePart = words[0..<j].joined(separator: " ")
                            if titlePart.count >= 5 && titlePart.count < 60
                                && titlePart.range(of: #"[.!?]["'"'\)\]]?\s*$"#, options: .regularExpression) == nil {
                                candidateCounts[titlePart, default: 0] += 1
                            }
                            break
                        }
                    }
                }
            }
        }

        // Fuzzy merge: group candidates with >70% char similarity, sum counts.
        // Catches OCR variants like "ALiLn iin WONDERLAND" + "ALICE IN WONDERLAND".
        var mergedCounts: [String: Int] = [:]
        let sortedCandidates = candidateCounts.sorted { $0.value > $1.value }
        var consumed = Set<String>()
        for (canonical, count) in sortedCandidates {
            guard !consumed.contains(canonical) else { continue }
            var totalCount = count
            consumed.insert(canonical)
            for (other, otherCount) in sortedCandidates {
                guard !consumed.contains(other) else { continue }
                if Self.charSimilarity(canonical, other) > 0.70 {
                    totalCount += otherCount
                    consumed.insert(other)
                }
            }
            mergedCounts[canonical] = totalCount
        }

        // Running headers appear on many pages (>= 3 occurrences).
        let threshold = 3
        let runningHeaders = Set(mergedCounts.filter { pair in
            pair.value >= threshold
                && pair.key.components(separatedBy: .whitespaces).count <= 10
        }.map { $0.key })

        guard !runningHeaders.isEmpty else { return }
        NSLog("[ScribeProcessor] Detected %d running headers (threshold: %d): %@",
              runningHeaders.count, threshold,
              runningHeaders.sorted().joined(separator: "; "))

        // Strip running headers from each page's text
        for i in 0..<pageExtractions.count {
            let text = pageExtractions[i].text
            let paragraphs = text.components(separatedBy: "\n\n")
            var newParagraphs: [String] = []

            for para in paragraphs {
                let trimmed = para.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }

                // Normalize for comparison — handle both contiguous and OCR-spaced page numbers
                let normalized = trimmed
                    .replacingOccurrences(of: #"^(\d\s){1,3}\d\s*\^?\s*"#, with: "", options: .regularExpression)
                    .replacingOccurrences(of: #"\s*\^?\s*(\d\s){1,3}\d$"#, with: "", options: .regularExpression)
                    .replacingOccurrences(of: #"^\d{1,4}\s*\^?\s*"#, with: "", options: .regularExpression)
                    .replacingOccurrences(of: #"\s*\^?\s*\d{1,4}$"#, with: "", options: .regularExpression)
                    .replacingOccurrences(of: "^", with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)

                // Case 1: Entire paragraph is a running header (possibly with page number)
                // Check exact match first, then fuzzy match for OCR variants
                let isRunningHeader = runningHeaders.contains(normalized)
                    || runningHeaders.contains(where: { Self.charSimilarity($0, normalized) > 0.70 })
                if isRunningHeader {
                    continue
                }

                // Case 2: Paragraph STARTS with header text followed by body text
                // e.g., "Isaac Newton, philosopher by fire 3 biographical works..."
                // or "5^The Janus faces of genius particles are..."
                var strippedPara: String? = nil
                for header in runningHeaders {
                    let escaped = NSRegularExpression.escapedPattern(for: header)
                    let patterns = [
                        // header [pagenum] body — e.g., "Chapter Title 42 Body text..."
                        "^" + escaped + #"\s*\^?\s*\d{0,4}\s+"#,
                        // header [spaced pagenum] body — e.g., "Chapter Title 4 2 Body text..."
                        "^" + escaped + #"\s*\^?\s*(\d\s){1,3}\d\s+"#,
                        // pagenum [^] header body — e.g., "42^The Janus faces... body text"
                        #"^\d{1,4}\s*\^?\s*"# + escaped + #"\s+"#,
                        // spaced pagenum header body — e.g., "7 0 The Janus faces... body text"
                        #"^(\d\s){1,3}\d\s*\^?\s*"# + escaped + #"\s+"#,
                        // pagenum header (standalone with number) — e.g., "42 The Janus faces of genius"
                        #"^\d{1,4}\s*\^?\s*"# + escaped + "$",
                        // spaced pagenum header (standalone) — e.g., "7 0 The Janus faces of genius"
                        #"^(\d\s){1,3}\d\s*\^?\s*"# + escaped + "$",
                    ]
                    for pattern in patterns {
                        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
                              let match = regex.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)),
                              let matchRange = Range(match.range, in: trimmed) else { continue }
                        let remainder = String(trimmed[matchRange.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                        if remainder.count > 10 {
                            strippedPara = remainder
                        } else if remainder.isEmpty {
                            strippedPara = ""
                        }
                        break
                    }
                    if strippedPara != nil { break }
                }

                if let stripped = strippedPara {
                    if !stripped.isEmpty {
                        newParagraphs.append(stripped)
                    }
                } else {
                    newParagraphs.append(trimmed)
                }
            }

            let newText = newParagraphs.joined(separator: "\n\n")
            if newText != text {
                pageExtractions[i] = PageExtraction(
                    text: newText,
                    footnotes: pageExtractions[i].footnotes,
                    images: pageExtractions[i].images,
                    pdfPageIndex: pageExtractions[i].pdfPageIndex
                )
            }
        }
    }

    func median(_ values: [CGFloat]) -> CGFloat? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        if sorted.count % 2 == 0 {
            return (sorted[mid - 1] + sorted[mid]) / 2
        }
        return sorted[mid]
    }
}
