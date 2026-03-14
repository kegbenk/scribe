import Foundation
import PDFKit
import CoreGraphics

extension ScribeProcessor {

    // MARK: - Outline / TOC Extraction

    func extractOutline(pdfDoc: PDFDocument) -> [(title: String, pageIndex: Int)] {
        guard let root = pdfDoc.outlineRoot else { return [] }
        var items: [(title: String, pageIndex: Int)] = []
        collectOutlineItems(outline: root, pdfDoc: pdfDoc, items: &items)
        // When multiple outline items share the same page (nested sections),
        // keep only the first (top-level) one per page. DFS order ensures
        // parents come before children, so the first item is the broadest heading.
        var seenPages = Set<Int>()
        items = items.filter { seenPages.insert($0.pageIndex).inserted }
        return items
    }

    func collectOutlineItems(outline: PDFOutline, pdfDoc: PDFDocument, items: inout [(title: String, pageIndex: Int)]) {
        for i in 0..<outline.numberOfChildren {
            guard let child = outline.child(at: i) else { continue }
            let title = child.label ?? "Untitled"

            var pageIndex = 0
            if let destination = child.destination, let page = destination.page {
                pageIndex = pdfDoc.index(for: page)
            }

            items.append((title: title, pageIndex: pageIndex))

            // Recurse into nested outline levels (e.g., L2 chapters under L1 book title)
            if child.numberOfChildren > 0 {
                collectOutlineItems(outline: child, pdfDoc: pdfDoc, items: &items)
            }
        }
    }

    /// Parse chapter structure from a "Contents" page found in the extracted text.
    /// Searches for chapter titles in subsequent pages to determine chapter start pages.
    /// Detect back-matter sections (Notes, Bibliography, Index) in pages after
    /// the last TOC entry. Returns synthetic outline entries for any detected sections.
    func detectBackMatterSections(pages: [PageExtraction], startOffset: Int) -> [(title: String, pageIndex: Int)] {
        // Match common back-matter section headers, including variants like
        // "Select bibliography", "Bibliography of works cited", "Notes to chapters", etc.
        // Trailing [.\s]* handles period-terminated headings (e.g., "INDEX.")
        let backMatterPattern = try! NSRegularExpression(
            pattern: #"^(Notes(\s+to\s+\w+.*)?|Select(ed)?\s+[Bb]ibliography|Bibliography(\s+of\s+\w+.*)?|References|Index(\s+of\s+\w+.*)?|Glossary|Appendix(\s+[A-Z])?|Acknowledgm?ents?|List of\s+\w+|Abbreviations|An?\s+\w+\s+Greeting(\s+.*)?|About\s+the\s+Author|Also\s+by\s+.*|Author'?s?\s+Note|Afterword|Postscript|Colophon)[.\s]*$"#,
            options: [.caseInsensitive]
        )

        var sections: [(title: String, pageIndex: Int)] = []
        // Track detected section types to avoid duplicates (e.g., every page
        // of an INDEX section has "INDEX" as a running header)
        var detectedSectionTypes = Set<String>()

        // Skip the first few pages (they belong to the last real chapter)
        let skipPages = min(4, pages.count / 3)

        for i in skipPages..<pages.count {
            let text = pages[i].text.trimmingCharacters(in: .whitespacesAndNewlines)
            // Check if the page starts with a back-matter header
            // Try both first paragraph (double-newline separated) and first line
            // (OCR text from scanned books may lack clean paragraph breaks)
            let firstPara = text.components(separatedBy: "\n\n").first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let firstLine = text.components(separatedBy: .newlines).first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

            var matched = false
            var matchedKeyword = ""

            // Tier 1: Check first paragraph and first line
            let candidates = [firstPara, firstLine].filter { $0.count >= 3 && $0.count < 80 }
            for candidate in candidates {
                if backMatterPattern.firstMatch(in: candidate, range: NSRange(candidate.startIndex..., in: candidate)) != nil {
                    matched = true
                    matchedKeyword = candidate.uppercased().components(separatedBy: .whitespaces).first ?? ""
                    break
                }
            }

            // Tier 2: Check individual lines at the beginning of the page
            if !matched {
                let firstLines = text.components(separatedBy: .newlines)
                    .prefix(5)
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                for line in firstLines {
                    guard line.count < 80 && !line.isEmpty else { continue }
                    if backMatterPattern.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil {
                        matched = true
                        matchedKeyword = line.uppercased().components(separatedBy: .whitespaces).first ?? ""
                        break
                    }
                }
            }

            // Tier 3: Check if the page text starts with a back-matter keyword
            // (within first 100 chars) — handles pages where heading has no line break
            if !matched {
                let prefix = String(text.prefix(100))
                let backMatterKeywords = ["INDEX", "BIBLIOGRAPHY", "REFERENCES", "GLOSSARY", "APPENDIX"]
                for keyword in backMatterKeywords {
                    if prefix.range(of: "\\b\(keyword)\\b", options: [.regularExpression, .caseInsensitive]) != nil {
                        if let range = prefix.range(of: keyword, options: .caseInsensitive) {
                            let position = prefix.distance(from: prefix.startIndex, to: range.lowerBound)
                            if position < 30 {
                                matched = true
                                matchedKeyword = keyword
                                break
                            }
                        }
                    }
                }
            }

            // Deduplicate: skip if we already found a section with the same keyword.
            // This prevents every page of an INDEX from becoming a separate section.
            if matched {
                let normalizedKeyword = matchedKeyword
                    .trimmingCharacters(in: CharacterSet.punctuationCharacters.union(.whitespacesAndNewlines))
                    .uppercased()
                if detectedSectionTypes.contains(normalizedKeyword) {
                    continue  // Already found this section type
                }
                detectedSectionTypes.insert(normalizedKeyword)

                let pageIdx = startOffset + i
                // Determine the display title
                var displayTitle: String
                if firstPara.count < 80 && firstPara.count > 0 {
                    displayTitle = firstPara
                } else if firstLine.count < 80 && firstLine.count > 0 {
                    displayTitle = firstLine
                } else {
                    displayTitle = normalizedKeyword.isEmpty ? "Back Matter" : normalizedKeyword.capitalized
                }
                displayTitle = displayTitle.trimmingCharacters(in: CharacterSet.punctuationCharacters.union(.whitespacesAndNewlines))
                NSLog("[ScribeProcessor] Back-matter '%@' at page %d", displayTitle, pageIdx)
                sections.append((title: displayTitle, pageIndex: pageIdx))
            }
        }

        return sections
    }

    func parseChaptersFromContentsPage(pageExtractions: [PageExtraction], pageCount: Int, pdfDoc: PDFDocument? = nil) -> [(title: String, pageIndex: Int)] {
        // Find the Contents page in the first 30 logical pages
        // (for two-column scans, 15 PDF pages → up to 30 logical pages)
        let searchLimit = min(30, pageExtractions.count)
        var tocPageIdx: Int? = nil

        for i in 0..<searchLimit {
            let text = pageExtractions[i].text
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            let lines = trimmed.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            let hasContentsHeading = lines.contains(where: { line in
                let lower = line.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
                return lower == "contents"
                    || lower.hasPrefix("contents\n")
                    || lower == "table of contents"
            }) || trimmed.lowercased().hasPrefix("contents")
               || trimmed.lowercased().hasPrefix("table of contents")
            if hasContentsHeading {
                tocPageIdx = i
                NSLog("[ScribeProcessor] Found Contents page at index %d", i)
                break
            }
        }

        // Fallback: if no "Contents" heading found, detect TOC by content pattern.
        // Look for pages with multiple lines matching "NUMERAL. TITLE ... PAGE_NUM"
        // (handles decorative headings that OCR can't extract)
        if tocPageIdx == nil {
            NSLog("[ScribeProcessor] No heading-based Contents page found, trying content-pattern detection")
            let tocEntryRe = try! NSRegularExpression(
                pattern: #"(?:^|\s)([IVXLC]{1,6}|[A-Z][a-z]?|\d{1,2})\.?\s+[A-Z][A-Z\s]{3,}"#
            )
            for i in 0..<searchLimit {
                let text = pageExtractions[i].text
                let matches = tocEntryRe.numberOfMatches(in: text, range: NSRange(text.startIndex..., in: text))
                // A real TOC page typically has 4+ chapter-like entries
                if matches >= 4 {
                    // Verify: page should also have trailing page numbers (digits at end of lines)
                    let lines = text.components(separatedBy: .newlines)
                    let linesWithTrailingNum = lines.filter { line in
                        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                        return trimmed.range(of: #"\d{1,3}\s*$"#, options: .regularExpression) != nil
                    }.count
                    if linesWithTrailingNum >= 3 || matches >= 6 {
                        tocPageIdx = i
                        NSLog("[ScribeProcessor] Found Contents page at index %d via content-pattern (%d entries, %d trailing nums)", i, matches, linesWithTrailingNum)
                        break
                    }
                }
            }
        }

        if tocPageIdx == nil {
            NSLog("[ScribeProcessor] No Contents page found in first %d pages", searchLimit)
            for i in 0..<min(16, searchLimit) {
                let lines = pageExtractions[i].text.components(separatedBy: .newlines)
                let firstLine = lines.first ?? "(empty)"
                let lineCount = lines.count
                let totalLen = pageExtractions[i].text.count
                NSLog("[ScribeProcessor] Page %d (%d lines, %d chars) first line: %@", i, lineCount, totalLen, String(firstLine.prefix(80)))
            }
        }

        guard let tocStart = tocPageIdx else { return [] }

        // Filter out the "Contents" heading itself (case-insensitive, with optional punctuation)
        func isContentsHeading(_ line: String) -> Bool {
            let stripped = line.trimmingCharacters(in: CharacterSet.punctuationCharacters.union(.whitespaces))
            return stripped.caseInsensitiveCompare("Contents") == .orderedSame
                || stripped.caseInsensitiveCompare("Table of Contents") == .orderedSame
        }

        // Detect if a line is a page number (roman or arabic) used as running header/footer
        func isPageNumberLine(_ line: String) -> Bool {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            // Arabic page number alone
            if trimmed.range(of: #"^\d{1,4}$"#, options: .regularExpression) != nil { return true }
            // Roman numeral alone (e.g. "ix", "xi", "XIV")
            if trimmed.range(of: #"^[ivxlcIVXLC]+\.?$"#, options: .regularExpression) != nil { return true }
            return false
        }

        // Extract raw PDFKit lines from one page
        func extractRawLines(pdfPageIndex: Int) -> [String] {
            guard let doc = pdfDoc, let page = doc.page(at: pdfPageIndex) else { return [] }
            guard let fullSel = page.selection(for: page.bounds(for: .cropBox)) else { return [] }
            let lineSelections = fullSel.selectionsByLine()
            return lineSelections.compactMap { sel -> String? in
                guard let text = sel.string?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !text.isEmpty else { return nil }
                return text
            }
        }

        // Collect TOC lines from multiple consecutive pages
        // TOC may span several pages; stop when we find a page that looks like body text
        var tocLines: [String] = []
        let maxTocPages = min(10, pageExtractions.count - tocStart)

        for pageOffset in 0..<maxTocPages {
            let pageIdx = tocStart + pageOffset
            let pdfIdx = pageExtractions[pageIdx].pdfPageIndex
            let rawLines = extractRawLines(pdfPageIndex: pdfIdx)

            if rawLines.count > 3 {
                let filtered = rawLines.filter { !isContentsHeading($0) && !isPageNumberLine($0) }
                // Check if this looks like a TOC page: should have "CHAPTER" or page number references
                if pageOffset > 0 {
                    let hasTocMarkers = filtered.contains { line in
                        let up = line.uppercased()
                        return up.contains("CHAPTER") || up.contains("APPENDIX") || up.contains("INDEX")
                            || line.range(of: #"\d{1,3}[-\u{2013}]\d{1,3}"#, options: .regularExpression) != nil
                            || isContentsHeading(line)
                    }
                    if !hasTocMarkers {
                        NSLog("[ScribeProcessor] TOC ends at page offset %d (no TOC markers found)", pageOffset)
                        break
                    }
                }
                tocLines.append(contentsOf: filtered)
            } else {
                // Fall back to extracted text for this page
                let text = pageExtractions[pageIdx].text.trimmingCharacters(in: .whitespacesAndNewlines)
                let lines = text.components(separatedBy: .newlines)
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty && !isContentsHeading($0) && !isPageNumberLine($0) }
                if pageOffset > 0 {
                    let hasTocMarkers = lines.contains { line in
                        let up = line.uppercased()
                        return up.contains("CHAPTER") || up.contains("APPENDIX") || up.contains("INDEX")
                            || line.range(of: #"\d{1,3}[-\u{2013}]\d{1,3}"#, options: .regularExpression) != nil
                    }
                    if !hasTocMarkers { break }
                }
                tocLines.append(contentsOf: lines)
            }
        }
        NSLog("[ScribeProcessor] Collected %d TOC lines across multiple pages", tocLines.count)

        // Parse chapter entries with multiple patterns:
        // Pattern 1: "N  Chapter title" (Arabic numerals, e.g. "1 Introduction")
        // Pattern 2: "CHAPTER <numeral>." (Roman numeral headings, tolerant of OCR errors)
        let arabicChapterPattern = try! NSRegularExpression(pattern: #"^(\d{1,2})\s+(.+)$"#)
        // Match any "CHAPTER <something>." line — OCR often garbles Roman numerals
        let romanChapterPattern = try! NSRegularExpression(pattern: #"^CHAPTER\s+(\S+?)\.?\s*$"#, options: .caseInsensitive)
        var romanChapterSeqNum = 0  // Sequential counter for Roman numeral chapters
        var entries: [(num: Int, title: String, pageNum: Int?)] = []

        // Helper: extract trailing page number from a TOC line
        // Handles OCR garbling: I/l->1, O->0 (e.g., "I28" -> 128)
        func extractTrailingPageNum(_ text: String) -> Int? {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            // Match trailing digits preceded by whitespace or dots: "TITLE ... 42" or "TITLE 42"
            if let range = trimmed.range(of: #"[\s.]+(\d{1,3})\s*$"#, options: .regularExpression) {
                let numStr = trimmed[range].trimmingCharacters(in: CharacterSet.decimalDigits.inverted)
                return Int(numStr)
            }
            // OCR correction: match trailing token that mixes digits with common lookalikes (I, l, O)
            if let range = trimmed.range(of: #"[\s.]+([IlO\d]{1,3})\s*$"#, options: .regularExpression) {
                var numStr = String(trimmed[range]).trimmingCharacters(in: .whitespacesAndNewlines)
                numStr = numStr.trimmingCharacters(in: CharacterSet(charactersIn: " ."))
                numStr = numStr.replacingOccurrences(of: "I", with: "1")
                numStr = numStr.replacingOccurrences(of: "l", with: "1")
                numStr = numStr.replacingOccurrences(of: "O", with: "0")
                if let num = Int(numStr), num > 0 {
                    return num
                }
            }
            return nil
        }

        // Roman numeral to integer conversion
        func romanToInt(_ roman: String) -> Int {
            let map: [Character: Int] = ["I": 1, "V": 5, "X": 10, "L": 50, "C": 100]
            let upper = roman.uppercased()
            var result = 0
            var prev = 0
            for ch in upper.reversed() {
                let val = map[ch] ?? 0
                if val < prev {
                    result -= val
                } else {
                    result += val
                }
                prev = val
            }
            return result
        }

        // Integer to Roman numeral conversion (for chapter heading search)
        func intToRoman(_ num: Int) -> String {
            let values = [(1000, "M"), (900, "CM"), (500, "D"), (400, "CD"),
                          (100, "C"), (90, "XC"), (50, "L"), (40, "XL"),
                          (10, "X"), (9, "IX"), (5, "V"), (4, "IV"), (1, "I")]
            var n = num
            var result = ""
            for (val, sym) in values {
                while n >= val {
                    result += sym
                    n -= val
                }
            }
            return result
        }

        // Check if next line is a new chapter heading or section marker
        func isNewChapterOrSection(_ line: String) -> Bool {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            // Arabic number chapter: "1 Title"
            if trimmed.range(of: #"^\d{1,2}\s+[A-Z]"#, options: .regularExpression) != nil { return true }
            // "CHAPTER" heading (any numeral -- Roman, Arabic, or OCR-garbled)
            if trimmed.range(of: #"^CHAPTER\s+"#, options: [.regularExpression, .caseInsensitive]) != nil { return true }
            // Section markers (case-insensitive)
            let up = trimmed.uppercased()
            if up.hasPrefix("APPENDIX") || up.hasPrefix("BIBLIOGRAPHY") || up.hasPrefix("INDEX")
                || up.hasPrefix("LIST OF") || up.hasPrefix("ACKNOWLEDGMENTS")
                || up.hasPrefix("INTRODUCTION") || up.hasPrefix("PREFACE") { return true }
            return false
        }

        var i = 0
        while i < tocLines.count {
            let line = tocLines[i]
            let nsLine = line as NSString
            let lineRange = NSRange(location: 0, length: nsLine.length)

            // Try Pattern 1: "N  Title" (Arabic numeral)
            if let match = arabicChapterPattern.firstMatch(in: line, range: lineRange) {
                let num = Int(nsLine.substring(with: match.range(at: 1))) ?? 0
                var title = nsLine.substring(with: match.range(at: 2)).trimmingCharacters(in: .whitespaces)
                // Extract page number before stripping it
                let tocPageNum = extractTrailingPageNum(title)
                // Remove trailing page number (must be preceded by whitespace to avoid
                // stripping digits from dates like "1687-1713")
                title = title.replacingOccurrences(of: #"\s+\d{1,3}\s*$"#, with: "", options: .regularExpression)

                if num > 0 && title.count >= 3 {
                    // Consume continuation lines
                    while i + 1 < tocLines.count {
                        let nextLine = tocLines[i + 1].trimmingCharacters(in: .whitespaces)
                        if !isNewChapterOrSection(nextLine) && nextLine.count >= 3 {
                            var contText = nextLine
                            contText = contText.replacingOccurrences(of: #"\s+\d{1,3}\s*$"#, with: "", options: .regularExpression)
                            title += " " + contText
                            i += 1
                        } else {
                            break
                        }
                    }
                    entries.append((num: num, title: title, pageNum: tocPageNum))
                }
            }
            // Try Pattern 2: "CHAPTER <numeral>." (Roman numeral heading, OCR-tolerant)
            else if let match = romanChapterPattern.firstMatch(in: line, range: lineRange) {
                let romanStr = nsLine.substring(with: match.range(at: 1))
                // Try to parse as Roman numeral; if it fails (OCR garble), use sequential number
                let parsedNum = romanToInt(romanStr)
                romanChapterSeqNum += 1
                let num = parsedNum > 0 ? parsedNum : romanChapterSeqNum

                // The title is typically on the next line(s) in this format:
                // "CHAPTER I."
                // "SELF-HELP, -- NATIONAL AND INDIVIDUAL."
                // "Synopsis text... page range 15-39"
                var title = ""
                if i + 1 < tocLines.count {
                    i += 1
                    var titleLine = tocLines[i].trimmingCharacters(in: .whitespaces)
                    // If the title line ends with a comma or dash, the subtitle continues
                    // on the next line (e.g., "LEADERS OF INDUSTRY," / "INVENTORS AND PRODUCERS.")
                    while titleLine.hasSuffix(",") || titleLine.hasSuffix("-") || titleLine.hasSuffix("\u{2013}") {
                        if i + 1 < tocLines.count && !isNewChapterOrSection(tocLines[i + 1]) {
                            i += 1
                            let nextPart = tocLines[i].trimmingCharacters(in: .whitespaces)
                            // Strip page range from continuation
                            let cleanNext = nextPart
                                .replacingOccurrences(of: #"\s+(?:Page\s+)?\d{1,3}[-\u{2013}]\d{1,3}\s*$"#, with: "", options: [.regularExpression, .caseInsensitive])
                                .replacingOccurrences(of: #"\s+\d{1,3}\s*$"#, with: "", options: .regularExpression)
                            if cleanNext.count >= 3 {
                                titleLine += " " + cleanNext
                            }
                        } else {
                            break
                        }
                    }
                    // Remove trailing page range (e.g. "15-39" or "135-179" or "Page 15-39")
                    title = titleLine
                        .replacingOccurrences(of: #"\s+(?:Page\s+)?\d{1,3}[-\u{2013}]\d{1,3}\s*$"#, with: "", options: [.regularExpression, .caseInsensitive])
                        .replacingOccurrences(of: #"\s+\d{1,3}\s*$"#, with: "", options: .regularExpression)
                        .trimmingCharacters(in: CharacterSet.punctuationCharacters.union(.whitespaces))
                }

                if num > 0 && title.count >= 3 {
                    // Skip synopsis/description lines until next chapter or section heading
                    while i + 1 < tocLines.count {
                        let nextLine = tocLines[i + 1].trimmingCharacters(in: .whitespaces)
                        if isNewChapterOrSection(nextLine) { break }
                        i += 1  // Skip synopsis line
                    }
                    entries.append((num: num, title: title, pageNum: nil))
                }
            }
            i += 1
        }

        // If Arabic digit pattern found too few entries, try Roman numeral pattern.
        // Many older/illustrated books use Roman numerals (I., II., III., ...) which OCR
        // may garble (II→H, VIII→Vm, XI→I). Pattern: short token + period + UPPERCASE title.
        if entries.count < 2 {
            NSLog("[ScribeProcessor] Arabic digit pattern found %d entries, trying Roman numeral pattern", entries.count)
            entries.removeAll()
            let romanPattern = try! NSRegularExpression(
                pattern: #"^([IVXLCivxlc]{1,6}|[A-Z][a-z]?)\.?\s+([A-Z][A-Z\s'',\-\?!]{4,})"#
            )
            var seqNum = 0
            var j = 0
            while j < tocLines.count {
                let line = tocLines[j]
                let nsLine = line as NSString
                if let match = romanPattern.firstMatch(in: line, range: NSRange(location: 0, length: nsLine.length)) {
                    seqNum += 1
                    // Extract page number from the FULL line (after the regex match)
                    var tocPageNum = extractTrailingPageNum(line)
                    // If no page number on this line, check next line for standalone number
                    // (PDFKit may split right-aligned page numbers onto separate lines)
                    if tocPageNum == nil && j + 1 < tocLines.count {
                        let nextLine = tocLines[j + 1].trimmingCharacters(in: .whitespacesAndNewlines)
                        if let num = Int(nextLine), num > 0 && num < 500 {
                            tocPageNum = num
                            j += 1  // consume the page number line
                        } else if let num = extractTrailingPageNum(nextLine), num > 0 && num < 500 {
                            // Next line has text + page number (e.g., "BILL 42")
                            tocPageNum = num
                            // Don't consume — line may fail Roman match and be skipped anyway
                        }
                    }
                    var title = nsLine.substring(with: match.range(at: 2)).trimmingCharacters(in: .whitespaces)
                    // Strip trailing page numbers, dots, and spaces
                    title = title.replacingOccurrences(of: #"[\s.]+\d{1,3}\s*$"#, with: "", options: .regularExpression)
                    title = title.replacingOccurrences(of: #"[\s.]+[IVXLC]{1,4}\s*$"#, with: "", options: .regularExpression)
                    title = title.replacingOccurrences(of: #"[.\s]+$"#, with: "", options: .regularExpression)
                    if title.count >= 4 {
                        entries.append((num: seqNum, title: title, pageNum: tocPageNum))
                    }
                }
                j += 1
            }
            NSLog("[ScribeProcessor] Roman numeral pattern found %d entries", entries.count)
        }

        NSLog("[ScribeProcessor] TOC parsing found %d chapter entries", entries.count)
        for entry in entries {
            if let pn = entry.pageNum {
                NSLog("[ScribeProcessor]   Chapter %d: %@ (TOC page %d)", entry.num, entry.title, pn)
            } else {
                NSLog("[ScribeProcessor]   Chapter %d: %@", entry.num, entry.title)
            }
        }

        guard entries.count >= 2 else { return [] }

        // Search for each chapter title in subsequent page texts
        var result: [(title: String, pageIndex: Int)] = []
        var searchStart = tocStart + 1

        // Build search terms: strip OCR artifacts, use distinctive substrings
        func buildSearchTerms(_ title: String) -> [String] {
            var terms: [String] = []
            // Full title
            terms.append(title)
            // Strip non-alphanumeric except spaces (removes OCR artifacts like ^)
            let cleaned = String(title.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) || $0 == " " })
                .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
            if cleaned != title { terms.append(cleaned) }
            // For short titles, just use the full title
            // For longer titles, also try the last distinctive part (subtitle)
            // This helps differentiate "Modes of divine activity: before the Principia"
            // from "Modes of divine activity: the Principia period"
            if let colonRange = title.range(of: ":") {
                let subtitle = String(title[colonRange.upperBound...]).trimmingCharacters(in: .whitespaces)
                if subtitle.count >= 5 {
                    // Clean subtitle of OCR artifacts
                    let cleanSub = String(subtitle.unicodeScalars.filter {
                        CharacterSet.alphanumerics.contains($0) || $0 == " " || $0 == "," || $0 == "-"
                    }).trimmingCharacters(in: .whitespaces)
                    terms.append(cleanSub)
                }
            }
            // Add individual distinctive words as search terms (handles OCR garbling).
            // Minimum 6 chars to avoid common words (POOL, TEARS, LONG, TALE) that
            // cause false positive matches in body text.
            let titleWords = cleaned.components(separatedBy: " ").filter { $0.count >= 6 }
            if titleWords.count >= 1 {
                let sorted = titleWords.sorted { $0.count > $1.count }
                for w in sorted.prefix(3) {
                    terms.append(w)
                }
            }

            // Extract date ranges as search terms (try various dash styles)
            let dateRangePattern = try? NSRegularExpression(pattern: #"(\d{4})[-–—](\d{4})"#)
            if let dp = dateRangePattern {
                let nsTitle = title as NSString
                let dateMatches = dp.matches(in: title, range: NSRange(location: 0, length: nsTitle.length))
                for dm in dateMatches {
                    let year1 = nsTitle.substring(with: dm.range(at: 1))
                    let year2 = nsTitle.substring(with: dm.range(at: 2))
                    // Try different dash styles
                    terms.append("\(year1)-\(year2)")
                    terms.append("\(year1)–\(year2)")
                    terms.append("\(year1)—\(year2)")
                    // Also just the end year (distinctive for chapter differentiation)
                    terms.append(year2)
                }
            }
            return terms
        }

        // Helper: check if a page's text matches any search term
        func pageMatchesTerm(_ pageIdx: Int, terms: [String], prefixOnly: Bool) -> Bool {
            let pageText = pageExtractions[pageIdx].text
            let area = prefixOnly ? String(pageText.prefix(500)) : pageText
            return terms.contains { term in
                area.range(of: term, options: .caseInsensitive) != nil
            }
        }

        // Strict match: requires the full title or cleaned title to match
        // (not just individual words). Used for calibration to avoid false positives.
        func pageMatchesStrongly(_ pageIdx: Int, title: String, prefixOnly: Bool) -> Bool {
            let pageText = pageExtractions[pageIdx].text
            let area = prefixOnly ? String(pageText.prefix(500)) : pageText
            // Try full title
            if area.range(of: title, options: .caseInsensitive) != nil { return true }
            // Try cleaned title (OCR artifacts removed)
            let cleaned = String(title.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) || $0 == " " })
                .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
            if cleaned != title && !cleaned.isEmpty {
                if area.range(of: cleaned, options: .caseInsensitive) != nil { return true }
            }
            return false
        }

        // Strategy: If most TOC entries have page numbers, use offset-based placement.
        // First calibrate the offset from a reliable text-search match, then place
        // all chapters with page numbers using the offset. Text search only for the rest.
        let entriesWithPageNums = entries.filter { $0.pageNum != nil }.count
        let useOffsetStrategy = entriesWithPageNums >= entries.count / 2

        if useOffsetStrategy {
            // === Offset-based strategy with multi-point calibration ===
            // For illustrated books, the ratio of PDF pages to printed pages
            // is >1 (illustration pages have no printed numbers). A constant
            // offset drifts. Instead: text-search each chapter independently,
            // collect calibration points, then use linear interpolation for
            // chapters not found by text search.
            NSLog("[ScribeProcessor] Using offset strategy (%d/%d entries have page numbers)", entriesWithPageNums, entries.count)
            let calibrationStart = tocStart + 1

            // Step 1: Text-search ALL chapters independently to find calibration points.
            // Use STRICT matching (full title or ≥2 distinctive words in first 500 chars)
            // to avoid false positives from individual words appearing in body text.
            var calibrationPoints: [(tocPage: Int, pdfPage: Int)] = []
            var directPlacements: [Int: Int] = [:]  // entryIndex → pdfPage

            for (idx, entry) in entries.enumerated() {
                for i in calibrationStart..<pageExtractions.count {
                    if pageMatchesStrongly(i, title: entry.title, prefixOnly: true) {
                        directPlacements[idx] = i
                        if let tocPage = entry.pageNum, tocPage > 0 {
                            calibrationPoints.append((tocPage: tocPage, pdfPage: i))
                            NSLog("[ScribeProcessor] Calibration: '%@' found at page %d (TOC %d, offset %d)", entry.title, i, tocPage, i - tocPage)
                        }
                        break
                    }
                }
            }
            NSLog("[ScribeProcessor] Found %d calibration points from %d entries", calibrationPoints.count, entries.count)

            // Step 2: Build interpolation function from calibration points.
            // First, enforce monotonicity: PDF page must increase with TOC page.
            // False positive matches produce outliers (e.g. TOC page 42 → PDF page 12).
            // Remove any point that breaks the increasing sequence.
            var rawSorted = calibrationPoints.sorted { $0.tocPage < $1.tocPage }
            var monotonic: [(tocPage: Int, pdfPage: Int)] = []
            for pt in rawSorted {
                if let last = monotonic.last {
                    if pt.pdfPage > last.pdfPage {
                        monotonic.append(pt)
                    } else {
                        NSLog("[ScribeProcessor] Dropping non-monotonic calibration: TOC %d → PDF %d (prev PDF %d)", pt.tocPage, pt.pdfPage, last.pdfPage)
                    }
                } else {
                    // First point: sanity check — PDF page should be > TOC page (offset > 0)
                    if pt.pdfPage >= pt.tocPage {
                        monotonic.append(pt)
                    } else {
                        NSLog("[ScribeProcessor] Dropping negative-offset calibration: TOC %d → PDF %d", pt.tocPage, pt.pdfPage)
                    }
                }
            }
            if monotonic.count < rawSorted.count {
                NSLog("[ScribeProcessor] Monotonicity filter: %d → %d calibration points", rawSorted.count, monotonic.count)
            }
            let sortedCal = monotonic

            func interpolatePdfPage(_ tocPage: Int) -> Int {
                guard !sortedCal.isEmpty else { return tocPage }
                if sortedCal.count == 1 {
                    // Single point: constant offset
                    return tocPage + (sortedCal[0].pdfPage - sortedCal[0].tocPage)
                }
                // Find surrounding calibration points
                if tocPage <= sortedCal.first!.tocPage {
                    let offset = sortedCal.first!.pdfPage - sortedCal.first!.tocPage
                    return tocPage + offset
                }
                if tocPage >= sortedCal.last!.tocPage {
                    let offset = sortedCal.last!.pdfPage - sortedCal.last!.tocPage
                    return tocPage + offset
                }
                // Interpolate between two surrounding points
                for j in 0..<sortedCal.count - 1 {
                    if sortedCal[j].tocPage <= tocPage && tocPage <= sortedCal[j + 1].tocPage {
                        let t1 = sortedCal[j].tocPage, p1 = sortedCal[j].pdfPage
                        let t2 = sortedCal[j + 1].tocPage, p2 = sortedCal[j + 1].pdfPage
                        let frac = Double(tocPage - t1) / Double(t2 - t1)
                        return p1 + Int(Double(p2 - p1) * frac)
                    }
                }
                return tocPage + (sortedCal.last!.pdfPage - sortedCal.last!.tocPage)
            }

            // Step 3: Place all chapters using direct match or interpolation.
            for (idx, entry) in entries.enumerated() {
                if let directPage = directPlacements[idx] {
                    // Chapter found by text search — use direct placement
                    result.append((title: "\(entry.num) \(entry.title)", pageIndex: directPage))
                    NSLog("[ScribeProcessor] '%@' placed at page %d (text search)", entry.title, directPage)
                } else if let tocPage = entry.pageNum {
                    // Not found by text search — interpolate from calibration
                    let estimated = interpolatePdfPage(tocPage)
                    if estimated >= 0 && estimated < pageExtractions.count {
                        result.append((title: "\(entry.num) \(entry.title)", pageIndex: estimated))
                        NSLog("[ScribeProcessor] '%@' placed at page %d (interpolated from TOC %d)", entry.title, estimated, tocPage)
                    }
                } else {
                    // No page number and no text match — search forward from last placed
                    let terms = buildSearchTerms(entry.title)
                    let prevPage = result.last?.pageIndex ?? calibrationStart
                    var found = false
                    for i in prevPage..<pageExtractions.count {
                        if pageMatchesTerm(i, terms: terms, prefixOnly: false) {
                            result.append((title: "\(entry.num) \(entry.title)", pageIndex: i))
                            found = true
                            break
                        }
                    }
                    if !found {
                        NSLog("[ScribeProcessor] Could not find chapter '%@' (no page number, text search failed)", entry.title)
                    }
                }
            }
        } else {
            // === Text-search strategy (for digital PDFs with readable headings) ===
            NSLog("[ScribeProcessor] Using text-search strategy (%d/%d entries have page numbers)", entriesWithPageNums, entries.count)
            for entry in entries {
                let searchTerms = buildSearchTerms(entry.title)
                var found = false
                // Search first 500 chars of pages
                for i in searchStart..<pageExtractions.count {
                    if pageMatchesTerm(i, terms: searchTerms, prefixOnly: true) {
                        result.append((title: "\(entry.num) \(entry.title)", pageIndex: i))
                        searchStart = i + 1
                        found = true
                        break
                    }
                }
                // Fallback: search for "CHAPTER <roman_numeral>" heading in page text.
                // This handles cases where the chapter title is OCR-garbled (e.g., "MONET"
                // instead of "MONEY") but the "CHAPTER IX" heading is intact.
                if !found && entry.num > 0 && entry.num <= 50 {
                    let roman = intToRoman(entry.num)
                    let chapterHeadingPattern = try? NSRegularExpression(
                        pattern: "CHAPTER\\s+\(NSRegularExpression.escapedPattern(for: roman))\\b",
                        options: .caseInsensitive
                    )
                    if let pattern = chapterHeadingPattern {
                        for i in searchStart..<pageExtractions.count {
                            let pageText = pageExtractions[i].text
                            let searchArea = String(pageText.prefix(500))
                            let range = NSRange(searchArea.startIndex..., in: searchArea)
                            if pattern.firstMatch(in: searchArea, range: range) != nil {
                                NSLog("[ScribeProcessor] Found chapter %d via 'CHAPTER %@' heading at page %d", entry.num, roman, i)
                                result.append((title: "\(entry.num) \(entry.title)", pageIndex: i))
                                searchStart = i + 1
                                found = true
                                break
                            }
                        }
                    }
                }
                // Fallback: full page text
                if !found {
                    for i in searchStart..<pageExtractions.count {
                        if pageMatchesTerm(i, terms: searchTerms, prefixOnly: false) {
                            result.append((title: "\(entry.num) \(entry.title)", pageIndex: i))
                            searchStart = i + 1
                            found = true
                            break
                        }
                    }
                }
                if !found {
                    NSLog("[ScribeProcessor] Could not find chapter '%@' in page texts", entry.title)
                }
            }
        }

        // Check for INTRODUCTION or PREFACE heading in pages before the first detected
        // chapter. Many older books have an Introduction that's not listed in the TOC
        // as a numbered chapter. Only match if it appears as a prominent heading.
        if let firstChapter = result.first, firstChapter.pageIndex > 0 {
            let frontMatterHeadings = ["INTRODUCTION", "PREFACE", "FOREWORD", "PROLOGUE"]
            let headingPatterns = frontMatterHeadings.map { heading -> NSRegularExpression? in
                return try? NSRegularExpression(
                    pattern: "(?:^|\\n|\\. )(\(heading))\\.?(?:\\s|$)",
                    options: .caseInsensitive
                )
            }
            var introFound = false
            for i in 0..<firstChapter.pageIndex {
                let pageText = pageExtractions[i].text
                let searchArea = String(pageText.prefix(500))
                for (idx, pattern) in headingPatterns.enumerated() {
                    guard let pat = pattern else { continue }
                    let range = NSRange(searchArea.startIndex..., in: searchArea)
                    if let match = pat.firstMatch(in: searchArea, range: range) {
                        let matchedText = (searchArea as NSString).substring(with: match.range(at: 1))
                        let isHeading = matchedText == matchedText.uppercased()
                            || matchedText.first?.isUppercase == true
                        if isHeading {
                            NSLog("[ScribeProcessor] Found '%@' heading at page %d (before first chapter at %d)",
                                  frontMatterHeadings[idx], i, firstChapter.pageIndex)
                            result.insert((title: frontMatterHeadings[idx].capitalized, pageIndex: i), at: 0)
                            introFound = true
                            break
                        }
                    }
                }
                if introFound { break }
            }
            if !introFound {
                if firstChapter.pageIndex > tocStart + 1 {
                    result.insert((title: "Front Matter", pageIndex: tocStart), at: 0)
                }
            }
        }

        NSLog("[ScribeProcessor] TOC text parsing found %d of %d chapters", result.count, entries.count)
        return result.count >= 2 ? result : []
    }

    // MARK: - Chapter Building

    func buildChaptersFromOutline(
        outline: [(title: String, pageIndex: Int)],
        pageExtractions: [PageExtraction],
        pageCount: Int,
        backMatterStartIndex: Int = Int.max
    ) -> [[String: Any]] {
        var chapters: [[String: Any]] = []

        if let first = outline.first, first.pageIndex > 0 {
            let pages = Array(pageExtractions[0..<first.pageIndex])
            let frontText = appendFootnotesAsEndnotes(pages: pages)
            let frontTextClean = stripPageMarkers(frontText)
            if !frontTextClean.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let tokenData = buildChapterTokenData(text: frontTextClean)
                let images = buildChapterImages(pages: pages, chapterText: frontTextClean)
                let footnotesList = collectFootnotes(pages: pages)
                chapters.append([
                    "id": "pdf-front-matter",
                    "title": "Front Matter",
                    "level": 1,
                    "htmlContent": textToHtml(frontText, images: images),
                    "plainText": frontTextClean,
                    "tokens": tokenData.tokens,
                    "paragraphStarts": tokenData.paragraphStarts,
                    "images": images,
                    "startPage": 1,
                    "footnotes": footnotesList
                ])
            }
        }

        // Back-matter sections are now detected pre-strip and already included in the outline.
        for i in 0..<outline.count {
            let item = outline[i]
            let startPage = item.pageIndex
            let endPage = i < outline.count - 1 ? outline[i + 1].pageIndex : pageCount

            guard startPage < endPage else { continue }

            let pages = Array(pageExtractions[startPage..<endPage])
            let rawText = appendFootnotesAsEndnotes(pages: pages)
            let chapterText = stripLeadingChapterTitle(text: rawText, title: item.title)
            let chapterTextClean = stripPageMarkers(chapterText)
            let tokenData = buildChapterTokenData(text: chapterTextClean)
            let images = buildChapterImages(pages: pages, chapterText: chapterTextClean)
            let footnotesList = collectFootnotes(pages: pages)
            let isBackMatter = i >= backMatterStartIndex || Self.isBackMatterTitle(item.title)

            // Strip leading chapter enumeration (e.g., "1 Isaac Newton..." → "Isaac Newton...")
            // and OCR caret artifacts from titles.
            let cleanTitle = item.title
                .replacingOccurrences(of: #"^\d{1,2}\s+"#, with: "", options: .regularExpression)
                .replacingOccurrences(of: "^", with: "")

            var chapterDict: [String: Any] = [
                "id": "pdf-chapter-\(i)",
                "title": cleanTitle,
                "level": 1,
                "htmlContent": textToHtml(chapterText, images: images),
                "plainText": chapterTextClean,
                "tokens": tokenData.tokens,
                "paragraphStarts": tokenData.paragraphStarts,
                "images": images,
                "startPage": pageExtractions[startPage].pdfPageIndex + 1,  // 1-based PDF page number
                "footnotes": footnotesList
            ]
            if isBackMatter {
                chapterDict["isBackMatter"] = true
            }

            chapters.append(chapterDict)
        }

        return chapters
    }

    /// Check if a chapter title indicates back matter.
    static func isBackMatterTitle(_ title: String) -> Bool {
        let lower = title.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        // Exclude "table of contents" — that's front matter
        if lower.contains("table of contents") || lower.contains("contents") && !lower.contains("index") { return false }
        let patterns = [
            "bibliography", "references", "notes", "index", "glossary",
            "appendix", "acknowledgment", "acknowledgement", "abbreviation",
            "table of", "list of"
        ]
        return patterns.contains(where: { lower.contains($0) })
    }

    /// Collect structured footnotes from pages (for JSON export).
    func collectFootnotes(pages: [PageExtraction]) -> [[String: Any]] {
        var resolved: [Footnote] = []
        for page in pages {
            if let cont = page.footnoteContinuation, !cont.isEmpty, !resolved.isEmpty {
                let lastIdx = resolved.count - 1
                let last = resolved[lastIdx]
                resolved[lastIdx] = Footnote(number: last.number, text: last.text + " " + cont)
            }
            resolved.append(contentsOf: page.footnotes)
        }

        var seen = Set<Int>()
        var unique: [Footnote] = []
        for fn in resolved {
            if seen.insert(fn.number).inserted {
                unique.append(fn)
            }
        }
        unique.sort { $0.number < $1.number }

        return unique.map { ["number": $0.number, "text": $0.text] }
    }

    func buildPageBasedChapters(pageExtractions: [PageExtraction], fileName: String) -> [[String: Any]] {
        var chapters: [[String: Any]] = []
        let totalPages = pageExtractions.count
        let chunkSize = max(1, Int(ceil(Double(totalPages) / max(1, floor(Double(totalPages) / 10.0)))))

        var i = 0
        while i < totalPages {
            let endIdx = min(i + chunkSize, totalPages)
            let pages = Array(pageExtractions[i..<endIdx])
            let chapterText = appendFootnotesAsEndnotes(pages: pages)
            let chapterTextClean = stripPageMarkers(chapterText)
            let pageStart = i + 1
            let pageEnd = endIdx

            let title: String
            if totalPages <= 20 {
                title = "Page \(pageStart)"
            } else {
                title = "Pages \(pageStart)-\(pageEnd)"
            }

            let tokenData = buildChapterTokenData(text: chapterTextClean)
            let images = buildChapterImages(pages: pages, chapterText: chapterTextClean)
            let footnotesList = collectFootnotes(pages: pages)

            chapters.append([
                "id": "pdf-page-\(pageStart)",
                "title": title,
                "level": 1,
                "htmlContent": textToHtml(chapterText, images: images),
                "plainText": chapterTextClean,
                "tokens": tokenData.tokens,
                "paragraphStarts": tokenData.paragraphStarts,
                "images": images,
                "startPage": pageExtractions[i].pdfPageIndex + 1,  // 1-based PDF page number
                "footnotes": footnotesList
            ])

            i = endIdx
        }

        if chapters.count == 1 {
            let stem = (fileName as NSString).deletingPathExtension
            chapters[0]["title"] = stem
        }

        return chapters
    }

    /// Combine page body texts and collect all page footnotes into an endnotes
    /// section appended at the end of the chapter text.
    /// Inserts page-break markers between pages so textToHtml can reset the
    /// sequential caret/glyph counter per-page, preventing drift when a marker
    /// is missed or extra on one page from corrupting all subsequent pages.
    func appendFootnotesAsEndnotes(pages: [PageExtraction]) -> String {
        // Join body texts with page-break markers encoding per-page footnote counts.
        // Format: __VELO_PAGE_FN_<count>__ — tells textToHtml how many footnotes
        // belong to the page that just ended, so it can advance the counter.
        var bodyParts: [String] = []
        for (idx, page) in pages.enumerated() {
            bodyParts.append(page.text)
            if idx < pages.count - 1 {
                let fnCount = page.footnotes.count
                bodyParts.append("__VELO_PAGE_FN_\(fnCount)__")
            }
        }
        let rawBodyText = bodyParts.joined(separator: "\n")

        // Handle cross-page footnote continuations: when a page/column has
        // footnoteContinuation text, append it to the previous page's last footnote.
        var resolvedFootnotes: [Footnote] = []
        for (i, page) in pages.enumerated() {
            // If this page has continuation text AND the previous page had footnotes,
            // append the continuation to the last footnote from the previous page
            if let cont = page.footnoteContinuation, !cont.isEmpty, !resolvedFootnotes.isEmpty {
                let lastIdx = resolvedFootnotes.count - 1
                let last = resolvedFootnotes[lastIdx]
                resolvedFootnotes[lastIdx] = Footnote(number: last.number, text: last.text + " " + cont)
                NSLog("[ScribeProcessor] Appended continuation text to footnote %d from page %d", last.number, page.pdfPageIndex)
            }
            resolvedFootnotes.append(contentsOf: page.footnotes)
        }

        guard !resolvedFootnotes.isEmpty else { return rawBodyText }

        // Do NOT strip inline footnote references — leave them so textToHtml's
        // linkInlineEndnoteNumbers can convert them into clickable hyperlinks.
        let bodyText = rawBodyText

        // Deduplicate by footnote number (same footnote shouldn't appear twice)
        var seen = Set<Int>()
        var uniqueFootnotes: [Footnote] = []
        for fn in resolvedFootnotes {
            if seen.insert(fn.number).inserted {
                uniqueFootnotes.append(fn)
            }
        }

        // Sort by footnote number
        uniqueFootnotes.sort { $0.number < $1.number }

        // Format as endnote paragraphs (separated by double newline for paragraph detection)
        let endnoteBlock = uniqueFootnotes
            .map { "\($0.number) \($0.text)" }
            .joined(separator: "\n\n")

        NSLog("[ScribeProcessor] Converted %d page footnotes to endnotes", uniqueFootnotes.count)

        return bodyText + "\n\n" + endnoteBlock
    }

    /// Map extracted images to word positions within a chapter.
    /// Images are positioned proportionally: if an image is on page 3 of a 5-page chapter,
    /// its wordPosition is roughly 60% through the chapter's token stream.
    func buildChapterImages(pages: [PageExtraction], chapterText: String) -> [[String: Any]] {
        let allImages = pages.flatMap { $0.images }
        guard !allImages.isEmpty else { return [] }

        let tokens = ScribeTokenizer.parseText(chapterText)
        let totalWords = tokens.count
        guard totalWords > 0 else { return [] }

        // Calculate cumulative word counts per page for position mapping
        var pageWordCounts: [Int] = []
        for page in pages {
            let pageWords = ScribeTokenizer.parseText(page.text)
            pageWordCounts.append(pageWords.count)
        }
        let totalPageWords = pageWordCounts.reduce(0, +)
        guard totalPageWords > 0 else { return [] }

        var result: [[String: Any]] = []
        var cumulativeWords = 0

        for (pageIdx, page) in pages.enumerated() {
            for img in page.images {
                // Position within chapter based on cumulative words up to this page
                // plus fractional position within the page
                let pageProgress = Double(cumulativeWords) / Double(totalPageWords)
                let withinPageProgress = Double(img.yPosition) * Double(pageWordCounts[pageIdx]) / Double(totalPageWords)
                let overallProgress = min(1.0, pageProgress + withinPageProgress)
                let wordPosition = Int(overallProgress * Double(totalWords - 1))

                result.append([
                    "src": img.dataURI,
                    "alt": "Image from page \(img.pageIndex + 1)",
                    "wordPosition": wordPosition,
                    "width": img.width,
                    "height": img.height
                ])
            }
            cumulativeWords += pageWordCounts[pageIdx]
        }

        // Sort by wordPosition
        result.sort { ($0["wordPosition"] as? Int ?? 0) < ($1["wordPosition"] as? Int ?? 0) }

        return result
    }

    func buildChapterTokenData(text: String) -> (tokens: [String], paragraphStarts: [Int]) {
        let paragraphs = text.components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        var tokens: [String] = []
        var paragraphStarts: [Int] = []

        for paragraph in paragraphs {
            paragraphStarts.append(tokens.count)
            let words = paragraph.components(separatedBy: .whitespacesAndNewlines)
                .filter { !$0.isEmpty }
            tokens.append(contentsOf: words)
        }

        return (tokens, paragraphStarts)
    }

    func calculateWordBoundaries(chapters: [[String: Any]]) -> [[String: Any]] {
        var result: [[String: Any]] = []
        var currentWordIndex = 0

        for var chapter in chapters {
            let plainText = chapter["plainText"] as? String ?? ""
            let rsvpTokens = ScribeTokenizer.parseText(plainText)
            let wordCount = rsvpTokens.count

            chapter["startWordIndex"] = currentWordIndex
            chapter["endWordIndex"] = currentWordIndex + wordCount
            chapter["wordCount"] = wordCount
            result.append(chapter)
            currentWordIndex += wordCount
        }

        return result
    }
}
