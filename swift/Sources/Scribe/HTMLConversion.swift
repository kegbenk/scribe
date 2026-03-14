import Foundation

extension ScribeProcessor {

    // MARK: - HTML Conversion

    func textToHtml(_ text: String, images: [[String: Any]] = []) -> String {
        let escaped = text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        var paragraphs = escaped.components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        // Pre-process: extract __VELO_PAGE_FN_N__ markers that may be merged
        // into adjacent paragraphs (because pages are joined with \n, not \n\n).
        // Split merged paragraphs around markers so each marker becomes standalone.
        let markerRegex = try! NSRegularExpression(pattern: #"__VELO_PAGE_FN_(\d+)__"#)
        var cleaned: [String] = []
        for para in paragraphs {
            let range = NSRange(para.startIndex..., in: para)
            let matches = markerRegex.matches(in: para, range: range)
            if matches.isEmpty {
                cleaned.append(para)
                continue
            }
            var lastEnd = para.startIndex
            for match in matches {
                guard let numRange = Range(match.range(at: 1), in: para),
                      let fullRange = Range(match.range, in: para) else { continue }
                let fnCount = String(para[numRange])
                let before = String(para[lastEnd..<fullRange.lowerBound])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !before.isEmpty { cleaned.append(before) }
                cleaned.append("__VELO_PAGE_FN_\(fnCount)__")
                lastEnd = fullRange.upperBound
            }
            let after = String(para[lastEnd...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !after.isEmpty { cleaned.append(after) }
        }
        paragraphs = cleaned

        if paragraphs.isEmpty { return "" }

        // Detect endnote definitions section: find where consecutive paragraphs
        // start with a number (e.g., "307 Ibid., p. 53.")
        let noteDefPattern = try! NSRegularExpression(pattern: #"^\d{1,4}[.\s]"#)
        var endnoteStartIdx = paragraphs.count
        // Scan backwards to find the first run of ≥3 consecutive note-like paragraphs
        var consecutiveNotes = 0
        for i in stride(from: paragraphs.count - 1, through: 0, by: -1) {
            let para = paragraphs[i]
            let isNoteDef = noteDefPattern.firstMatch(in: para, range: NSRange(para.startIndex..., in: para)) != nil
            if isNoteDef {
                consecutiveNotes += 1
            } else {
                if consecutiveNotes >= 3 {
                    endnoteStartIdx = i + 1
                    break
                }
                consecutiveNotes = 0
            }
        }
        // Handle case where notes run all the way to the beginning
        if consecutiveNotes >= 3 && endnoteStartIdx == paragraphs.count {
            endnoteStartIdx = paragraphs.count - consecutiveNotes
        }

        let hasEndnotes = endnoteStartIdx < paragraphs.count

        // Collect endnote numbers defined in the notes section
        var definedNotes = Set<Int>()
        if hasEndnotes {
            let noteNumPattern = try! NSRegularExpression(pattern: #"^(\d{1,4})[.\s]"#)
            for i in endnoteStartIdx..<paragraphs.count {
                if let match = noteNumPattern.firstMatch(in: paragraphs[i], range: NSRange(paragraphs[i].startIndex..., in: paragraphs[i])),
                   let range = Range(match.range(at: 1), in: paragraphs[i]),
                   let num = Int(paragraphs[i][range]) {
                    definedNotes.insert(num)
                }
            }
        }

        // If we have images, insert them at proportional positions in the HTML
        if !images.isEmpty {
            let totalParagraphs = paragraphs.count
            for img in images.reversed() { // Reverse to insert from end
                let wordPos = img["wordPosition"] as? Int ?? 0
                let src = img["src"] as? String ?? ""
                let alt = img["alt"] as? String ?? ""
                let w = img["width"] as? Int ?? 0
                let h = img["height"] as? Int ?? 0

                guard !src.isEmpty else { continue }

                // Calculate which paragraph this image should appear after
                let tokens = ScribeTokenizer.parseText(text)
                let totalTokens = max(1, tokens.count)
                let progress = Double(wordPos) / Double(totalTokens)
                let insertIdx = min(totalParagraphs, max(0, Int(progress * Double(totalParagraphs))))

                let imgHtml = "<figure class=\"transposed-figure\"><img src=\"\(src)\" alt=\"\(alt)\" width=\"\(w)\" height=\"\(h)\" loading=\"lazy\"></figure>"

                if insertIdx < paragraphs.count {
                    paragraphs.insert(imgHtml, at: insertIdx)
                    if insertIdx <= endnoteStartIdx { endnoteStartIdx += 1 }
                } else {
                    paragraphs.append(imgHtml)
                }
            }
        }

        // Build HTML with endnote linking
        // Skip inline linking when the ratio of body paragraphs to defined notes
        // is too high — indicates a bloated chapter (e.g., epilogue absorbing
        // Notes/Bibliography) where linking numbers 1-N produces mostly false positives.
        let bodyParaCount = endnoteStartIdx
        let shouldLink = hasEndnotes && definedNotes.count >= 5 &&
            (bodyParaCount < definedNotes.count * 20)

        // Detect if body uses caret (^) markers for footnote references instead of
        // actual numbers (common in OCR'd scanned books where superscript digits
        // are rendered as ^ characters).
        let bodyText = paragraphs[0..<endnoteStartIdx].joined(separator: "\n\n")
        let caretRefPattern = try! NSRegularExpression(pattern: #"[.,:;!?'"\)\]]\s?\^"#)
        let caretCount = caretRefPattern.numberOfMatches(in: bodyText, range: NSRange(bodyText.startIndex..., in: bodyText))
        let useCaretLinking = hasEndnotes && shouldLink && caretCount >= 3 && definedNotes.count >= 5

        // Detect garbled glyph markers: some PDFs encode superscript footnote digits
        // using custom font glyphs that PDFKit misreads as special characters (*, ®, ', etc.).
        // If we have many endnote definitions but very few inline number references,
        // try to find and replace these garbled markers sequentially.
        var useGlyphLinking = false
        if hasEndnotes && shouldLink && !useCaretLinking && definedNotes.count >= 3 {
            // Count how many inline number references we can actually find
            let inlinePattern = try! NSRegularExpression(
                pattern: #"(?<=[.,:;!?'"\)\]^])[\s]?(\d{1,3})(?=\s|$)"#
            )
            let inlineCount = inlinePattern.numberOfMatches(in: bodyText, range: NSRange(bodyText.startIndex..., in: bodyText))
            // Also count !N markers from superscript recovery
            let caretCountInBody = bodyText.components(separatedBy: "!").count - 1

            // If we found < 30% of expected references via normal linking, try glyph detection
            let totalFound = inlineCount + caretCountInBody
            if totalFound < definedNotes.count / 3 {
                // Count garbled glyph markers: single non-alphanumeric chars after punctuation
                // that are NOT common punctuation themselves
                // Match garbled glyph markers after punctuation/word chars.
                // Right-single-quote (\u{2019}) only after closing quotes/parens/period
                // (e.g., ."') — NOT after letters (which would be apostrophes like d'una).
                let glyphPattern = try! NSRegularExpression(
                    pattern: #"(?<=[.,:;!?\)\]""\x{201C}\x{201D}])[\s]?([*®†‡§¶©°«»¤¥£¢¦¬~`\x{2019}]|!\d{1,3})|(?<=\p{L})[\s]?([*®†‡§¶©°«»¤¥£¢¦¬~`]|!\d{1,3})"#
                )
                let glyphCount = glyphPattern.numberOfMatches(in: bodyText, range: NSRange(bodyText.startIndex..., in: bodyText))
                // Lower threshold: activate if we find ≥25% of expected refs via glyph detection
                if glyphCount + totalFound >= definedNotes.count / 4 {
                    useGlyphLinking = true
                }
            }
        }

        var htmlParts: [String] = []
        var caretNoteCounter = 0  // Sequential counter for caret-based linking
        var glyphNoteCounter = 0  // Sequential counter for glyph-based linking
        var cumulativePageFn = 0  // Tracks expected counter position based on per-page footnote counts
        let sortedNotes = definedNotes.sorted()

        for (i, para) in paragraphs.enumerated() {
            // Page-break marker: advance the sequential counter to the expected
            // position for the next page, preventing drift from missed/extra markers.
            if para.hasPrefix("__VELO_PAGE_FN_") && para.hasSuffix("__") {
                let numStr = para.dropFirst("__VELO_PAGE_FN_".count).dropLast("__".count)
                if let fnCount = Int(numStr) {
                    cumulativePageFn += fnCount
                    if useCaretLinking {
                        caretNoteCounter = max(caretNoteCounter, cumulativePageFn)
                    } else if useGlyphLinking {
                        glyphNoteCounter = max(glyphNoteCounter, cumulativePageFn)
                    }
                }
                continue  // Don't emit marker as HTML
            }

            if para.hasPrefix("<figure") || para.hasPrefix("&lt;figure") {
                htmlParts.append(para)
                continue
            }

            if hasEndnotes && i >= endnoteStartIdx {
                // Endnote definition paragraph: add anchor ID
                let noteNumPattern = try! NSRegularExpression(pattern: #"^(\d{1,4})[.\s]"#)
                if let match = noteNumPattern.firstMatch(in: para, range: NSRange(para.startIndex..., in: para)),
                   let numRange = Range(match.range(at: 1), in: para),
                   let fullRange = Range(match.range, in: para) {
                    let noteNum = String(para[numRange])
                    let rest = String(para[fullRange.upperBound...]).trimmingCharacters(in: .whitespaces)
                    htmlParts.append("<p id=\"endnote-\(noteNum)\"><strong>\(noteNum)</strong> \(rest)</p>")
                } else {
                    htmlParts.append("<p>\(para)</p>")
                }
            } else if useCaretLinking {
                // OCR caret-based linking: replace ^ markers with sequential endnote links
                let linked = linkCaretFootnoteMarkers(para, sortedNotes: sortedNotes, counter: &caretNoteCounter)
                htmlParts.append("<p>\(linked)</p>")
            } else if useGlyphLinking {
                // Garbled glyph linking: replace garbled single chars + !N markers with sequential endnote links
                let linked = linkGarbledGlyphMarkers(para, sortedNotes: sortedNotes, counter: &glyphNoteCounter)
                htmlParts.append("<p>\(linked)</p>")
            } else if shouldLink {
                // Body paragraph: link inline endnote numbers
                let linked = linkInlineEndnoteNumbers(para, definedNotes: definedNotes)
                htmlParts.append("<p>\(linked)</p>")
            } else {
                htmlParts.append("<p>\(para)</p>")
            }
        }

        // Wrap endnotes in a section if present
        if hasEndnotes {
            // Find the first endnote HTML part
            let bodyEndIdx = htmlParts.count - (paragraphs.count - endnoteStartIdx)
            let bodyHtml = htmlParts[0..<bodyEndIdx].joined()
            let notesHtml = htmlParts[bodyEndIdx...].joined()
            return bodyHtml + "<section class=\"transposed-endnotes\"><hr><h3>Notes</h3>" + notesHtml + "</section>"
        }

        return htmlParts.joined()
    }

    /// Replace inline endnote numbers with superscript links.
    /// Only matches numbers that look like genuine footnote references:
    ///   - After sentence-ending punctuation + optional space (e.g., "sentence.3 " or "sentence.' 3 ")
    ///   - After a closing quote/bracket + optional space (e.g., "word,'3 ")
    /// Does NOT match standalone numbers in text (years, page numbers, volumes).
    func linkInlineEndnoteNumbers(_ text: String, definedNotes: Set<Int>) -> String {
        guard !definedNotes.isEmpty else { return text }

        // Match a number that appears right after sentence-ending punctuation or closing
        // quotes/brackets — this is where inline footnote references appear in academic text.
        // The number may or may not have a space before it.
        // Examples: "reviews,'1 " "reviews.1 " "edifice.^ 4 " "notion.4 "
        let pattern = try! NSRegularExpression(
            pattern: #"(?<=[.,:;!?'"\)\]^])[\s]?(\d{1,3})(?=\s|$)"#
        )

        var result = text
        let matches = pattern.matches(in: text, range: NSRange(text.startIndex..., in: text))
        for match in matches.reversed() {
            guard let numRange = Range(match.range(at: 1), in: result) else { continue }
            let numStr = String(result[numRange])
            guard let num = Int(numStr), definedNotes.contains(num) else { continue }
            // Don't link numbers > 200 (very unlikely to be a footnote reference)
            guard num <= 200 else { continue }
            let replacement = "<sup><a href=\"#endnote-\(num)\" data-note-link=\"1\">\(numStr)</a></sup>"
            result.replaceSubrange(numRange, with: replacement)
        }

        return result
    }

    /// Replace OCR caret (^) footnote markers with sequential endnote links.
    /// In scanned books, superscript footnote numbers are often OCR'd as ^ characters.
    /// This method matches ^, ^^, ^', ^° etc. after punctuation and maps them
    /// sequentially to the sorted list of defined endnote numbers.
    func linkCaretFootnoteMarkers(_ text: String, sortedNotes: [Int], counter: inout Int) -> String {
        guard !sortedNotes.isEmpty else { return text }

        // Match caret clusters after punctuation: "word.^" "word,^" "word."^" etc.
        // Also match ^' ^° ^^ patterns (OCR renders multi-digit superscripts as caret clusters)
        let pattern = try! NSRegularExpression(
            pattern: #"(?<=[.,:;!?'"\)\]])\s?(\^[\^'°*]*)"#
        )

        let matches = pattern.matches(in: text, range: NSRange(text.startIndex..., in: text))
        guard !matches.isEmpty else { return text }

        // Build result by iterating forward, replacing each caret match
        // with the next sequential footnote number
        var result = ""
        var lastEnd = text.startIndex

        for match in matches {
            guard counter < sortedNotes.count else { break }
            guard let fullRange = Range(match.range, in: text) else { continue }

            let noteNum = sortedNotes[counter]
            counter += 1

            // Append text before the match (the space+caret is the full match, after lookbehind)
            result += text[lastEnd..<fullRange.lowerBound]
            result += "<sup><a href=\"#endnote-\(noteNum)\" data-note-link=\"1\">\(noteNum)</a></sup>"
            lastEnd = fullRange.upperBound
        }

        // Append remaining text
        result += text[lastEnd...]
        return result
    }

    /// Replace garbled font glyph markers with sequential endnote links.
    /// Some PDFs encode superscript footnote digits using custom font glyphs
    /// that PDFKit misreads as special characters (*, ®, ', †, etc.).
    /// Also handles !N markers from superscript digit recovery.
    /// Assigns endnote numbers sequentially based on position in text.
    func linkGarbledGlyphMarkers(_ text: String, sortedNotes: [Int], counter: inout Int) -> String {
        guard !sortedNotes.isEmpty else { return text }

        // Match garbled glyph markers OR !N superscript markers after word/punctuation boundaries.
        // Garbled chars: single special characters that appear where a footnote ref should be.
        // !N markers: from superscript digit recovery (e.g., "word.!4 ")
        // Also match raw digits after ! that were embedded in text (e.g., "sis8 ")
        // Right-single-quote (\u{2019}) only after closing punct/quotes/parens — not after
        // letters (where it's a legitimate apostrophe like d'una, l'amaro).
        let pattern = try! NSRegularExpression(
            pattern: #"(?<=[.,:;!?\)\]""\x{201C}\x{201D}])[\s]?([*®†‡§¶©°«»¤¥£¢¦¬~`\x{2019}]|!\d{1,3})|(?<=\p{L})[\s]?([*®†‡§¶©°«»¤¥£¢¦¬~`]|!\d{1,3})"#
        )

        let matches = pattern.matches(in: text, range: NSRange(text.startIndex..., in: text))
        guard !matches.isEmpty else { return text }

        var result = ""
        var lastEnd = text.startIndex

        for match in matches {
            guard counter < sortedNotes.count else { break }
            guard let fullRange = Range(match.range, in: text) else { continue }

            let noteNum = sortedNotes[counter]
            counter += 1

            result += text[lastEnd..<fullRange.lowerBound]
            result += "<sup><a href=\"#endnote-\(noteNum)\" data-note-link=\"1\">\(noteNum)</a></sup>"
            lastEnd = fullRange.upperBound
        }

        result += text[lastEnd...]
        return result
    }

    /// Remove __VELO_PAGE_FN_N__ markers from text.
    /// These are internal markers used by textToHtml for per-page counter reset
    /// and must not appear in plainText, tokens, or exported JSON.
    func stripPageMarkers(_ text: String) -> String {
        return text.replacingOccurrences(
            of: #"\n?__VELO_PAGE_FN_\d+__\n?"#,
            with: "\n",
            options: .regularExpression
        )
    }

    func stripLeadingChapterTitle(text: String, title: String) -> String {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else { return text }

        let titleWords = trimmedTitle.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .map { normalizeToken($0) }
        guard !titleWords.isEmpty else { return text }

        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)

        // Find the title words at the start of the text without destroying the rest
        var searchPos = trimmedText.startIndex
        for titleWord in titleWords {
            // Skip whitespace/newlines
            while searchPos < trimmedText.endIndex && trimmedText[searchPos].isWhitespace {
                searchPos = trimmedText.index(after: searchPos)
            }
            guard searchPos < trimmedText.endIndex else { return text }

            // Find the end of the current word
            var wordEnd = searchPos
            while wordEnd < trimmedText.endIndex && !trimmedText[wordEnd].isWhitespace {
                wordEnd = trimmedText.index(after: wordEnd)
            }

            let candidate = normalizeToken(String(trimmedText[searchPos..<wordEnd]))
            guard candidate == titleWord else { return text }
            searchPos = wordEnd
        }

        // Skip whitespace after title, preserving the rest of the text intact
        while searchPos < trimmedText.endIndex && trimmedText[searchPos].isWhitespace {
            searchPos = trimmedText.index(after: searchPos)
        }

        if searchPos >= trimmedText.endIndex { return "" }
        return String(trimmedText[searchPos...])
    }

    func normalizeToken(_ token: String) -> String {
        let stripped = token.unicodeScalars.filter {
            CharacterSet.alphanumerics.contains($0)
        }
        return String(stripped).lowercased()
    }

    func buildTOCFromChapters(chapters: [[String: Any]]) -> [[String: Any]] {
        return chapters.enumerated().map { (index, chapter) in
            [
                "id": chapter["id"] as? String ?? "pdf-chapter-\(index)",
                "title": chapter["title"] as? String ?? "Untitled",
                "level": chapter["level"] as? Int ?? 1,
                "chapterIndex": index
            ]
        }
    }
}
