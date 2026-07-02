import Foundation

/// EPUB (2 and 3) extraction producing the same contentStructure contract as
/// the PDF pipeline: chapters with plainText/htmlContent/tokens/word indices,
/// toc-derived titles and levels, and inline images as data URIs.
/// Pure Foundation — XMLParser for all XML/XHTML, ZipReader for the container.
final class EPUBProcessor {

    // MARK: - Detection

    static func isEPUB(url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        if ext == "epub" { return true }
        if ext == "pdf" { return false }
        // Unknown extension: sniff zip magic + EPUB mimetype entry.
        guard let handle = try? FileHandle(forReadingFrom: url),
              let magic = try? handle.read(upToCount: 4),
              magic == Data([0x50, 0x4B, 0x03, 0x04]) else { return false }
        guard let zip = ZipReader(url: url),
              let mime = zip.contents(of: "mimetype"),
              let mimeString = String(data: mime, encoding: .utf8) else { return false }
        return mimeString.trimmingCharacters(in: .whitespacesAndNewlines) == "application/epub+zip"
    }

    // MARK: - Entry point

    static func processFileForResult(url: URL) -> (text: String, chapters: [[String: Any]], hasStructure: Bool)? {
        guard let zip = ZipReader(url: url) else { return nil }
        guard let containerData = zip.contents(of: "META-INF/container.xml"),
              let opfPath = ContainerParser.rootfilePath(containerData) else {
            NSLog("[EPUBProcessor] No META-INF/container.xml rootfile in %@", url.lastPathComponent)
            return nil
        }
        guard let opfData = zip.contents(of: opfPath) else { return nil }
        let opf = OPFParser.parse(opfData)
        guard !opf.spine.isEmpty else {
            NSLog("[EPUBProcessor] Empty spine in %@", url.lastPathComponent)
            return nil
        }
        let opfDir = parentDirectory(of: opfPath)

        // Table of contents: EPUB3 nav document, falling back to EPUB2 NCX.
        var tocEntries: [TocEntry] = []
        if let navItem = opf.manifest.values.first(where: { $0.properties.contains("nav") }),
           let navData = zip.contents(of: resolvePath(navItem.href, relativeTo: opfDir)) {
            tocEntries = NavParser.parse(navData)
        }
        if tocEntries.isEmpty {
            let ncxItem = opf.spineTocID.flatMap { opf.manifest[$0] }
                ?? opf.manifest.values.first(where: { $0.mediaType == "application/x-dtbncx+xml" })
            if let ncxItem = ncxItem,
               let ncxData = zip.contents(of: resolvePath(ncxItem.href, relativeTo: opfDir)) {
                tocEntries = NCXParser.parse(ncxData)
            }
        }

        // Group toc entries by document path (fragment stripped), in toc order.
        // Toc hrefs are relative to the toc document; both nav and ncx live next
        // to the OPF in the vast majority of books, so resolve against opfDir.
        var tocListByPath: [String: [TocEntry]] = [:]
        for entry in tocEntries {
            let path = resolvePath(stripFragment(entry.href), relativeTo: opfDir)
            tocListByPath[path, default: []].append(entry)
        }

        let scribe = ScribeProcessor()
        var chapters: [[String: Any]] = []
        var fullTextParts: [String] = []
        var spineOrdinal = 0

        NSLog("[EPUBProcessor] %@: %d spine items, %d toc entries",
              url.lastPathComponent, opf.spine.count, tocEntries.count)

        for idref in opf.spine {
            guard let item = opf.manifest[idref], isHTMLMediaType(item.mediaType) else { continue }
            let docPath = resolvePath(item.href, relativeTo: opfDir)
            guard let docData = zip.contents(of: docPath) else { continue }
            spineOrdinal += 1

            let parsed = XHTMLTextParser.parse(docData)
            let docEntries = tocListByPath[docPath] ?? []
            let segments = buildSegments(parsed: parsed, tocEntries: docEntries)

            for segment in segments {
                let text = segment.paragraphs.joined(separator: "\n\n")
                    .trimmingCharacters(in: .whitespacesAndNewlines)

                let images = buildImages(
                    refs: segment.imageRefs,
                    documentDir: parentDirectory(of: docPath),
                    chapterText: text,
                    zip: zip
                )

                // Cover pages and spacer documents contribute nothing — skip them.
                if text.isEmpty && images.isEmpty { continue }

                let title = segment.title ?? parsed.firstHeading ?? "Chapter \(chapters.count + 1)"
                let tokenData = scribe.buildChapterTokenData(text: text)

                var chapterDict: [String: Any] = [
                    "id": "epub-chapter-\(chapters.count)",
                    "title": title,
                    "level": segment.level,
                    "sourceType": "epub",
                    "htmlContent": scribe.textToHtml(text, images: images),
                    "plainText": text,
                    "tokens": tokenData.tokens,
                    "paragraphStarts": tokenData.paragraphStarts,
                    "images": images,
                    // EPUBs have no physical pages; startPage is the 1-based spine ordinal.
                    "startPage": spineOrdinal,
                    "footnotes": segment.footnotes.enumerated().map { i, note in
                        ["number": note.number ?? (i + 1), "text": note.text] as [String: Any]
                    }
                ]
                if isBackMatterTitle(title) {
                    chapterDict["isBackMatter"] = true
                }
                chapters.append(chapterDict)
                fullTextParts.append(text)
            }
        }

        guard !chapters.isEmpty else { return nil }
        chapters = scribe.calculateWordBoundaries(chapters: chapters)
        let hasStructure = !tocEntries.isEmpty
        return (text: fullTextParts.joined(separator: "\n"), chapters: chapters, hasStructure: hasStructure)
    }

    // MARK: - Fragment segmentation

    /// One chapter's worth of a spine document: either the whole document
    /// (zero or one toc entry) or a slice between toc fragment anchors.
    struct Segment {
        let title: String?
        let level: Int
        let paragraphs: ArraySlice<String>
        let imageRefs: [XHTMLTextParser.ImageRef]
        let footnotes: [XHTMLTextParser.FootnoteRef]
    }

    /// Split a parsed document at the anchors its toc entries point to.
    /// Classic single-file EPUBs put every chapter in one XHTML document with
    /// fragment hrefs ("book.html#ch3") — without this they collapse into one
    /// giant chapter.
    static func buildSegments(parsed: XHTMLTextParser.Result, tocEntries: [TocEntry]) -> [Segment] {
        // Whole-document chapter: no fragments to split on.
        guard tocEntries.count > 1 else {
            return [Segment(
                title: tocEntries.first?.title,
                level: tocEntries.first?.level ?? 0,
                paragraphs: parsed.paragraphs[...],
                imageRefs: parsed.imageRefs,
                footnotes: parsed.footnotes
            )]
        }

        // Resolve each entry's fragment to a paragraph boundary. Entries whose
        // anchor is missing merge into the preceding segment.
        var cuts: [(title: String, level: Int, boundary: Int)] = []
        for (i, entry) in tocEntries.enumerated() {
            let fragment = fragmentOf(entry.href)
            let boundary: Int?
            if let fragment = fragment {
                boundary = parsed.anchors[fragment]
            } else {
                boundary = 0
            }
            guard var b = boundary else { continue }
            if i == 0 { b = 0 }  // preamble before the first anchor joins chapter one
            if let last = cuts.last, b < last.boundary { continue }  // out-of-order anchor
            cuts.append((entry.title, entry.level, b))
        }
        guard cuts.count > 1 else {
            return [Segment(
                title: tocEntries.first?.title,
                level: tocEntries.first?.level ?? 0,
                paragraphs: parsed.paragraphs[...],
                imageRefs: parsed.imageRefs,
                footnotes: parsed.footnotes
            )]
        }

        // Per-paragraph token counts, to rebase image word offsets per segment.
        let paragraphWordCounts = parsed.paragraphs.map { ScribeTokenizer.parseText($0).count }
        var cumulative: [Int] = [0]
        for count in paragraphWordCounts { cumulative.append(cumulative.last! + count) }

        var segments: [Segment] = []
        for (i, cut) in cuts.enumerated() {
            let start = cut.boundary
            let end = (i + 1 < cuts.count) ? cuts[i + 1].boundary : parsed.paragraphs.count
            guard start <= end, end <= parsed.paragraphs.count else { continue }

            let isLast = i == cuts.count - 1
            let refs = parsed.imageRefs
                .filter { $0.paragraphIndex >= start && ($0.paragraphIndex < end || (isLast && $0.paragraphIndex == end)) }
                .map { ref in
                    XHTMLTextParser.ImageRef(
                        src: ref.src, alt: ref.alt,
                        wordOffset: max(0, ref.wordOffset - cumulative[start]),
                        paragraphIndex: ref.paragraphIndex - start
                    )
                }
            let notes = parsed.footnotes.filter {
                $0.paragraphIndex >= start && ($0.paragraphIndex < end || (isLast && $0.paragraphIndex == end))
            }
            segments.append(Segment(
                title: cut.title, level: cut.level,
                paragraphs: parsed.paragraphs[start..<end],
                imageRefs: refs,
                footnotes: notes
            ))
        }
        return segments
    }

    private static func fragmentOf(_ href: String) -> String? {
        guard let hash = href.firstIndex(of: "#") else { return nil }
        let fragment = String(href[href.index(after: hash)...])
        return fragment.isEmpty ? nil : fragment
    }

    // MARK: - Images

    private static let imageMimeTypes: [String: String] = [
        "jpg": "image/jpeg", "jpeg": "image/jpeg", "png": "image/png",
        "gif": "image/gif", "webp": "image/webp", "svg": "image/svg+xml",
    ]

    /// Load referenced images from the archive as data URIs. Unlike the PDF
    /// path's proportional estimate, EPUB gives the exact word offset of each
    /// <img> in the text stream.
    private static func buildImages(
        refs: [XHTMLTextParser.ImageRef],
        documentDir: String,
        chapterText: String,
        zip: ZipReader
    ) -> [[String: Any]] {
        guard !refs.isEmpty else { return [] }
        let totalWords = ScribeTokenizer.parseText(chapterText).count
        var result: [[String: Any]] = []

        for ref in refs {
            let ext = (ref.src as NSString).pathExtension.lowercased()
            guard let mime = imageMimeTypes[ext] else { continue }
            let path = resolvePath(stripFragment(ref.src), relativeTo: documentDir)
            guard let data = zip.contents(of: path) else { continue }
            // Same payload cap as the PDF pipeline.
            guard data.count < 500_000 else { continue }

            result.append([
                "src": "data:\(mime);base64,\(data.base64EncodedString())",
                "alt": ref.alt ?? (path as NSString).lastPathComponent,
                "wordPosition": min(ref.wordOffset, max(0, totalWords - 1)),
                "width": 0,   // Intrinsic size unknown without decoding; 0 = unspecified
                "height": 0
            ])
        }
        return result
    }

    // MARK: - Back matter

    private static let backMatterTitles: Set<String> = [
        "notes", "endnotes", "footnotes", "bibliography", "references",
        "index", "glossary", "appendix", "acknowledgments", "acknowledgements",
        "about the author", "colophon", "copyright",
    ]

    private static func isBackMatterTitle(_ title: String) -> Bool {
        let t = title.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        return backMatterTitles.contains(t)
    }

    // MARK: - Path helpers

    static func parentDirectory(of path: String) -> String {
        guard let idx = path.lastIndex(of: "/") else { return "" }
        return String(path[..<idx])
    }

    static func stripFragment(_ href: String) -> String {
        guard let hash = href.firstIndex(of: "#") else { return href }
        return String(href[..<hash])
    }

    /// Resolve an href relative to a directory inside the archive,
    /// normalizing "." and ".." components and percent-encoding.
    static func resolvePath(_ href: String, relativeTo dir: String) -> String {
        let decoded = href.removingPercentEncoding ?? href
        var components = dir.isEmpty ? [] : dir.split(separator: "/").map(String.init)
        for part in decoded.split(separator: "/") {
            switch part {
            case ".": continue
            case "..": if !components.isEmpty { components.removeLast() }
            default: components.append(String(part))
            }
        }
        return components.joined(separator: "/")
    }

    private static func isHTMLMediaType(_ mediaType: String) -> Bool {
        return mediaType == "application/xhtml+xml" || mediaType == "text/html"
    }
}

// MARK: - Toc model

struct TocEntry {
    let title: String
    let href: String
    let level: Int
}

// MARK: - container.xml

/// Extracts the first rootfile's full-path from META-INF/container.xml.
private final class ContainerParser: NSObject, XMLParserDelegate {
    private var path: String?

    static func rootfilePath(_ data: Data) -> String? {
        let delegate = ContainerParser()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.parse()
        return delegate.path
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes: [String: String]) {
        if path == nil, localName(elementName) == "rootfile",
           let fullPath = attributes["full-path"] {
            path = fullPath
        }
    }
}

// MARK: - OPF package document

struct OPFPackage {
    struct ManifestItem {
        let id: String
        let href: String
        let mediaType: String
        let properties: Set<String>
    }
    var manifest: [String: ManifestItem] = [:]
    var spine: [String] = []
    var spineTocID: String?
    var title: String?
    var language: String?
}

private final class OPFParser: NSObject, XMLParserDelegate {
    private var package = OPFPackage()
    private var currentElement = ""
    private var currentText = ""

    static func parse(_ data: Data) -> OPFPackage {
        let delegate = OPFParser()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.parse()
        return delegate.package
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes: [String: String]) {
        let name = localName(elementName)
        currentElement = name
        currentText = ""
        switch name {
        case "item":
            guard let id = attributes["id"], let href = attributes["href"] else { return }
            let properties = Set((attributes["properties"] ?? "").split(separator: " ").map(String.init))
            package.manifest[id] = OPFPackage.ManifestItem(
                id: id, href: href,
                mediaType: attributes["media-type"] ?? "",
                properties: properties
            )
        case "spine":
            package.spineTocID = attributes["toc"]
        case "itemref":
            if let idref = attributes["idref"], attributes["linear"]?.lowercased() != "no" {
                package.spine.append(idref)
            }
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        currentText += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?) {
        let name = localName(elementName)
        let text = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
        if name == "title", package.title == nil, !text.isEmpty { package.title = text }
        if name == "language", package.language == nil, !text.isEmpty { package.language = text }
        currentText = ""
    }
}

// MARK: - EPUB3 nav document

/// Parses the toc <nav> of an EPUB3 navigation document.
/// Level = <ol> nesting depth within the toc nav.
final class NavParser: NSObject, XMLParserDelegate {
    private var entries: [TocEntry] = []
    private var inTocNav = false
    private var navDepth = 0        // nested <nav> tracking while inside toc nav
    private var olDepth = 0
    private var currentHref: String?
    private var currentText = ""
    private var inAnchor = false

    static func parse(_ data: Data) -> [TocEntry] {
        let delegate = NavParser()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.parse()
        return delegate.entries
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes: [String: String]) {
        let name = localName(elementName)
        switch name {
        case "nav":
            if inTocNav {
                navDepth += 1
            } else {
                let type = attributes["epub:type"] ?? attributes["type"] ?? ""
                // First nav wins if none is explicitly typed "toc".
                if type.contains("toc") || (entries.isEmpty && type.isEmpty) {
                    inTocNav = true
                    navDepth = 0
                    olDepth = 0
                }
            }
        case "ol" where inTocNav && navDepth == 0:
            olDepth += 1
        case "a" where inTocNav && navDepth == 0:
            inAnchor = true
            currentHref = attributes["href"]
            currentText = ""
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inAnchor { currentText += string }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?) {
        let name = localName(elementName)
        switch name {
        case "nav" where inTocNav:
            if navDepth > 0 { navDepth -= 1 } else { inTocNav = false }
        case "ol" where inTocNav && navDepth == 0:
            olDepth = max(0, olDepth - 1)
        case "a" where inAnchor:
            inAnchor = false
            let title = currentText
                .components(separatedBy: .whitespacesAndNewlines)
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            if let href = currentHref, !title.isEmpty {
                entries.append(TocEntry(title: title, href: href, level: max(0, olDepth - 1)))
            }
            currentHref = nil
        default:
            break
        }
    }
}

// MARK: - EPUB2 NCX

/// Parses navMap/navPoint out of an NCX document.
/// Level = navPoint nesting depth.
final class NCXParser: NSObject, XMLParserDelegate {
    private var entries: [TocEntry] = []
    private var pointDepth = 0
    private var pendingTitle: String?
    private var inText = false
    private var currentText = ""

    static func parse(_ data: Data) -> [TocEntry] {
        let delegate = NCXParser()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.parse()
        return delegate.entries
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes: [String: String]) {
        switch localName(elementName) {
        case "navpoint":
            pointDepth += 1
            pendingTitle = nil
        case "text":
            inText = true
            currentText = ""
        case "content":
            if pointDepth > 0, let src = attributes["src"], let title = pendingTitle {
                entries.append(TocEntry(title: title, href: src, level: pointDepth - 1))
                pendingTitle = nil
            }
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inText { currentText += string }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?) {
        switch localName(elementName) {
        case "text":
            inText = false
            let title = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
            if pointDepth > 0, pendingTitle == nil, !title.isEmpty { pendingTitle = title }
        case "navpoint":
            pointDepth = max(0, pointDepth - 1)
        default:
            break
        }
    }
}

// MARK: - XHTML content extraction

/// SAX extraction of readable text from a chapter document.
/// Block-level elements become paragraph breaks; script/style/head are skipped;
/// image references are recorded with their exact word offset in the text.
final class XHTMLTextParser: NSObject, XMLParserDelegate {
    struct ImageRef {
        let src: String
        let alt: String?
        let wordOffset: Int
        /// Paragraph boundary the image sits at (index into Result.paragraphs).
        let paragraphIndex: Int
    }

    struct FootnoteRef {
        /// Parsed leading number, if the note text started with one.
        let number: Int?
        let text: String
        /// Paragraph boundary the note sat at (index into Result.paragraphs).
        let paragraphIndex: Int
    }

    struct Result {
        let text: String
        let paragraphs: [String]
        let imageRefs: [ImageRef]
        let footnotes: [FootnoteRef]
        let firstHeading: String?
        /// Element id/name → paragraph boundary index, for splitting a single
        /// document into chapters at toc fragment anchors.
        let anchors: [String: Int]
    }

    private static let blockElements: Set<String> = [
        "p", "div", "h1", "h2", "h3", "h4", "h5", "h6", "li", "blockquote",
        "tr", "section", "article", "aside", "figure", "figcaption",
        "dt", "dd", "pre", "hr", "br", "table", "ul", "ol",
    ]
    private static let skippedElements: Set<String> = ["script", "style", "head", "title", "template"]
    private static let headingElements: Set<String> = ["h1", "h2", "h3", "h4"]

    private var paragraphs: [String] = []
    private var current = ""
    private var skipDepth = 0
    private var imageRefs: [ImageRef] = []
    private var footnotes: [FootnoteRef] = []
    private var footnoteElementDepth = 0
    private var footnoteBuffer = ""
    private var footnoteParagraphIndex = 0
    private var firstHeading: String?
    private var headingCapture: String?
    private var wordCount = 0
    private var anchors: [String: Int] = [:]

    static func parse(_ data: Data) -> Result {
        let delegate = XHTMLTextParser()
        let parser = XMLParser(data: preprocessEntities(data))
        parser.delegate = delegate
        parser.parse()
        // A parse error mid-document keeps everything accumulated so far —
        // partial text beats none for malformed books.
        delegate.flushParagraph()
        return Result(
            text: delegate.paragraphs.joined(separator: "\n\n"),
            paragraphs: delegate.paragraphs,
            imageRefs: delegate.imageRefs,
            footnotes: delegate.footnotes,
            firstHeading: delegate.firstHeading,
            anchors: delegate.anchors
        )
    }

    /// EPUB3 semantic footnote/endnote containers: `epub:type` vocabulary
    /// or ARIA DPUB roles.
    private static func isFootnoteContainer(_ attributes: [String: String]) -> Bool {
        let epubType = attributes["epub:type"] ?? ""
        let role = attributes["role"] ?? ""
        let types = Set(epubType.split(separator: " ").map(String.init))
        let roles = Set(role.split(separator: " ").map(String.init))
        return types.contains("footnote") || types.contains("endnote")
            || types.contains("rearnote")
            || roles.contains("doc-footnote") || roles.contains("doc-endnote")
    }

    private func finalizeFootnote() {
        let text = footnoteBuffer
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        footnoteBuffer = ""
        guard !text.isEmpty else { return }

        // "12. Note text" / "12 Note text" / "12) Note text" → number + body
        var number: Int?
        var body = text
        if let match = text.range(of: #"^\d{1,4}[.):\]]?\s+"#, options: .regularExpression) {
            number = Int(text[match].trimmingCharacters(in: CharacterSet.decimalDigits.inverted))
            body = String(text[match.upperBound...])
        }
        footnotes.append(FootnoteRef(number: number, text: body, paragraphIndex: footnoteParagraphIndex))
    }

    /// XMLParser resolves only the five XML entities. XHTML in the wild uses
    /// HTML named entities without inline DTDs, so translate the common ones
    /// (and strip soft hyphens) before parsing.
    private static let entityReplacements: [(String, String)] = [
        ("&nbsp;", "\u{00A0}"), ("&shy;", ""), ("&mdash;", "\u{2014}"),
        ("&ndash;", "\u{2013}"), ("&lsquo;", "\u{2018}"), ("&rsquo;", "\u{2019}"),
        ("&ldquo;", "\u{201C}"), ("&rdquo;", "\u{201D}"), ("&hellip;", "\u{2026}"),
        ("&copy;", "\u{00A9}"), ("&reg;", "\u{00AE}"), ("&trade;", "\u{2122}"),
        ("&sect;", "\u{00A7}"), ("&middot;", "\u{00B7}"), ("&bull;", "\u{2022}"),
        ("&eacute;", "\u{00E9}"), ("&egrave;", "\u{00E8}"), ("&agrave;", "\u{00E0}"),
        ("&ccedil;", "\u{00E7}"), ("&uuml;", "\u{00FC}"), ("&ouml;", "\u{00F6}"),
        ("&auml;", "\u{00E4}"), ("&szlig;", "\u{00DF}"),
    ]

    private static func preprocessEntities(_ data: Data) -> Data {
        guard var s = String(data: data, encoding: .utf8) else { return data }
        guard s.contains("&") else { return data }
        for (entity, replacement) in entityReplacements {
            s = s.replacingOccurrences(of: entity, with: replacement)
        }
        return Data(s.utf8)
    }

    private func flushParagraph() {
        let text = current
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        current = ""
        guard !text.isEmpty else { return }
        paragraphs.append(text)
        wordCount += ScribeTokenizer.parseText(text).count
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes: [String: String]) {
        let name = localName(elementName)
        if XHTMLTextParser.skippedElements.contains(name) {
            skipDepth += 1
            return
        }
        guard skipDepth == 0 else { return }

        // Inside a footnote container: text accumulates in the note buffer;
        // nested blocks just add separation, never body paragraphs.
        if footnoteElementDepth > 0 {
            footnoteElementDepth += 1
            if XHTMLTextParser.blockElements.contains(name) {
                footnoteBuffer += " "
            }
            return
        }

        // Flush before recording anchors/images so paragraph boundaries and
        // word offsets refer to completed paragraphs.
        if name == "img" || name == "image" || XHTMLTextParser.blockElements.contains(name) {
            flushParagraph()
        }

        // Record fragment anchors (id on any element; name on legacy <a name>).
        if let id = attributes["id"], anchors[id] == nil {
            anchors[id] = paragraphs.count
        }
        if name == "a", let anchorName = attributes["name"], anchors[anchorName] == nil {
            anchors[anchorName] = paragraphs.count
        }

        if XHTMLTextParser.isFootnoteContainer(attributes) {
            footnoteElementDepth = 1
            footnoteBuffer = ""
            footnoteParagraphIndex = paragraphs.count
            return
        }

        if name == "img", let src = attributes["src"] {
            imageRefs.append(ImageRef(src: src, alt: attributes["alt"], wordOffset: wordCount, paragraphIndex: paragraphs.count))
            return
        }
        if name == "image", let href = attributes["xlink:href"] ?? attributes["href"] {
            // SVG-wrapped cover images
            imageRefs.append(ImageRef(src: href, alt: nil, wordOffset: wordCount, paragraphIndex: paragraphs.count))
            return
        }
        if firstHeading == nil, XHTMLTextParser.headingElements.contains(name) {
            headingCapture = ""
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard skipDepth == 0 else { return }
        if footnoteElementDepth > 0 {
            footnoteBuffer += string
            return
        }
        current += string
        if headingCapture != nil { headingCapture! += string }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?) {
        let name = localName(elementName)
        if XHTMLTextParser.skippedElements.contains(name) {
            skipDepth = max(0, skipDepth - 1)
            return
        }
        guard skipDepth == 0 else { return }
        if footnoteElementDepth > 0 {
            footnoteElementDepth -= 1
            if footnoteElementDepth == 0 {
                finalizeFootnote()
            }
            return
        }
        if XHTMLTextParser.blockElements.contains(name) {
            flushParagraph()
        }
        if XHTMLTextParser.headingElements.contains(name), let captured = headingCapture {
            let title = captured
                .components(separatedBy: .whitespacesAndNewlines)
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            if !title.isEmpty, firstHeading == nil { firstHeading = title }
            headingCapture = nil
        }
    }
}

/// Strip any namespace prefix ("opf:item" → "item", "epub:nav" → "nav").
private func localName(_ elementName: String) -> String {
    guard let colon = elementName.lastIndex(of: ":") else { return elementName.lowercased() }
    return String(elementName[elementName.index(after: colon)...]).lowercased()
}
