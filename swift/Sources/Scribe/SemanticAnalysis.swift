import Foundation
import FoundationModels

/// Foundation Models integration for semantic document understanding.
/// All operations run on-device using Apple Intelligence (~3B parameter model).
@available(iOS 26.0, macOS 26.0, *)
struct SemanticAnalyzer {

    /// Maximum characters to send to the model per request.
    ///
    /// Empirically (probed on-device, macOS 26.5): the guardrail classifier
    /// goes out-of-distribution on LONG mixed-language input — ~8000 chars of
    /// Greek/Latin-quote-heavy history text is flagged "likely to be unsafe"
    /// even under permissive guardrails, while the SAME text passes at ≤4000
    /// chars. 4000 chars (~1300 tokens) also leaves generous headroom in the
    /// model's 4096 combined input+output token window for text that
    /// tokenizes poorly (Greek ≈ 2 chars/token).
    private static let maxInputChars = 4000

    // MARK: - Session & guardrails

    /// Session against the on-device model with the content-transformation
    /// guardrails preset. The DEFAULT guardrails treat ordinary book prose —
    /// war history, crime fiction, a spy biography — as "unsafe" INPUT and
    /// refuse to summarize it. `permissiveContentTransformations` is Apple's
    /// sanctioned fix for that false-positive class: it tells the safety layer
    /// the text is user-provided material being transformed (summarized,
    /// classified, described), not a request to generate harmful content.
    private static func makeSession(instructions: String) -> LanguageModelSession {
        let model = SystemLanguageModel(guardrails: .permissiveContentTransformations)
        return LanguageModelSession(model: model, instructions: instructions)
    }

    /// A slice of `text` starting at `fraction` through it, advanced to the
    /// next word boundary, capped at `length` characters.
    private static func slice(_ text: String, at fraction: Double, length: Int) -> String {
        let offset = min(text.count - 1, max(0, Int(Double(text.count) * fraction)))
        let start = text.index(text.startIndex, offsetBy: offset)
        var s = String(text[start...].prefix(length + 40))
        if let firstSpace = s.firstIndex(of: " ") {
            s = String(s[s.index(after: firstSpace)...])
        }
        return String(s.prefix(length))
    }

    /// Stratified composite: three excerpts from ~10%, ~45%, and ~75% through
    /// the book, joined with gap markers. A prefix-only sample "summarized"
    /// the front matter — copyright page, dedication, table of contents —
    /// which is why real books came back with publication-notes summaries.
    /// Sampling across the span gives the model the actual work.
    private static func compositeSample(_ text: String) -> String {
        let sliceLen = maxInputChars / 3 - 20
        return [0.10, 0.45, 0.75]
            .map { slice(text, at: $0, length: sliceLen) }
            .joined(separator: "\n\n[…]\n\n")
    }

    /// Candidate inputs, best first: the whole-book composite, then two single
    /// windows from different depths, then the raw prefix as a last resort.
    /// When one sample trips the safety layer (a single dark passage is
    /// enough), another usually passes — better a summary built from chapter 3
    /// than a refusal for the whole book.
    private static func sampleWindows(_ text: String) -> [String] {
        guard text.count > maxInputChars * 3 else {
            return [String(text.prefix(maxInputChars))]
        }
        return [
            compositeSample(text),
            slice(text, at: 0.33, length: maxInputChars),
            slice(text, at: 0.66, length: maxInputChars),
            String(text.prefix(maxInputChars)),
        ]
    }

    /// Errors where trying a different excerpt can plausibly succeed: the
    /// input safety filter, a model-level refusal, or a flaky structured
    /// decode. Everything else (unavailable assets, rate limits, context
    /// size…) fails the same way for every window, so throw immediately.
    private static func isRetryableWithDifferentSample(_ error: Error) -> Bool {
        guard let generationError = error as? LanguageModelSession.GenerationError else { return false }
        switch generationError {
        case .guardrailViolation, .refusal, .decodingFailure:
            return true
        default:
            return false
        }
    }

    /// Shared framing that reduces model-level refusals: the model behaves
    /// better when it knows the excerpts come from a published book it is
    /// describing (war history, crime fiction, biography…) rather than
    /// arbitrary user text it might be asked to act on.
    private static let bookFraming = """
        The text consists of excerpts from a published book the user is reading; \
        non-contiguous excerpts are separated by […] markers. Literature and \
        history may contain mature themes — describe the material accurately \
        and neutrally.
        """

    // MARK: - Availability

    static func ensureAvailable() throws {
        let availability = SystemLanguageModel.default.availability
        switch availability {
        case .available:
            return
        case .unavailable(let reason):
            throw DocumentIntelligenceError.modelUnavailable(reason: String(describing: reason))
        @unknown default:
            throw DocumentIntelligenceError.modelUnavailable(reason: "Unknown availability state")
        }
    }

    // MARK: - Summarization

    /// Anchor the model to the actual work. Books quote and discuss OTHER
    /// books; without this, a sampled excerpt that dwells on some cited title
    /// makes the model confidently summarize the wrong book (and confabulate
    /// details to match).
    private static func titleFraming(_ title: String?) -> String {
        if let title, !title.isEmpty {
            return """
             The book being analyzed is titled “\(title)”. The excerpts may quote, cite, \
            or discuss OTHER books and authors — never mistake a mentioned work for the \
            book itself, and never present details of a cited work as this book's subject.
            """
        }
        return """
         The excerpts may quote, cite, or discuss OTHER books and authors — never \
        mistake a mentioned work for the book being analyzed.
        """
    }

    // MARK: Plain-prose fallback (guided-generation refusals)
    //
    // Probed on-device (macOS 26.5, the book "Empire"): GUIDED generation has
    // its own stricter safety gate that hard-refuses certain topics (political
    // theory among them) regardless of schema shape, instructions, or even
    // when the input is the model's own neutral prose — while PLAIN generation
    // happily summarizes the same text. There is no prompt-side workaround, so
    // when a structured request refuses, re-ask in plain prose and parse.

    private static func plainSummarize(_ sample: String, anchor: String) async throws -> DocumentSummary {
        let s1 = makeSession(instructions: """
            You are a book analyst. \(bookFraming)\(anchor) Provide a concise \
            single-paragraph summary of what the book is about. Speak about the BOOK \
            as a whole — never say "this excerpt" or "the excerpts". Respond with the \
            paragraph only.
            """)
        let summary = try await s1.respond(to: sample).content
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !summary.isEmpty else { throw DocumentIntelligenceError.modelUnavailable(reason: "Empty summary") }

        let s2 = makeSession(instructions: """
            List the 5 most important key points from these analyst notes. \
            One per line, no numbering, no other text.
            """)
        let keyPoints = parseLines(try await s2.respond(to: summary).content, max: 7)

        let s3 = makeSession(instructions: """
            List 3-5 short topic labels (1-3 words each) for these analyst notes. \
            One per line, no other text.
            """)
        let topics = parseLines(try await s3.respond(to: summary).content, max: 5)

        return DocumentSummary(text: summary, keyPoints: keyPoints, topics: topics)
    }

    /// One item per line; strips leading bullets/numbering and markdown bold,
    /// drops empties and header-ish lines.
    private static func parseLines(_ raw: String, max: Int) -> [String] {
        var items: [String] = []
        for line in raw.split(separator: "\n") {
            var cleaned = String(line)
            cleaned = cleaned.replacingOccurrences(of: #"^[\s\-•*>]*(\d+[.)])?\s*"#,
                                                   with: "", options: .regularExpression)
            cleaned = cleaned.replacingOccurrences(of: "**", with: "")
            cleaned = cleaned.trimmingCharacters(in: .whitespaces)
            guard !cleaned.isEmpty, cleaned.count > 2, !cleaned.hasSuffix(":") else { continue }
            items.append(cleaned)
            if items.count >= max { break }
        }
        return items
    }

    static func summarize(_ text: String, style: SummaryStyle,
                          chapterTitles: [String] = [],
                          title: String? = nil) async throws -> DocumentSummary {
        try ensureAvailable()

        let anchor = titleFraming(title)
        let instructions: String
        switch style {
        case .brief:
            instructions = """
            You are a book analyst. \(bookFraming)\(anchor) Summarize what the book is about \
            in exactly 1-2 sentences. Identify the 3 most important key points and the main topics.
            """
        case .concise:
            instructions = """
            You are a book analyst. \(bookFraming)\(anchor) Provide a concise single-paragraph summary \
            of what the book is about. Identify the key points and main topics discussed.
            """
        case .detailed:
            instructions = """
            You are a book analyst. \(bookFraming)\(anchor) Provide a thorough summary of what the \
            book is about. Extract all key points, arguments, and themes comprehensively.
            """
        }

        // Retry across text windows: guardrail refusals are usually triggered
        // by one specific passage, not the whole book.
        var lastError: Error = DocumentIntelligenceError.modelUnavailable(reason: "No text to summarize")
        for sample in sampleWindows(text) {
            do {
                let session = makeSession(instructions: instructions)
                let result = try await session.respond(
                    to: sample,
                    generating: GeneratedSummary.self
                )
                return DocumentSummary(
                    text: result.content.summary,
                    keyPoints: result.content.keyPoints,
                    topics: result.content.topics
                )
            } catch {
                lastError = error
                guard let generationError = error as? LanguageModelSession.GenerationError else { throw error }
                switch generationError {
                case .refusal, .decodingFailure:
                    // The guided decoder balked at CONTENT it will happily
                    // discuss in prose — re-ask plain on the same sample.
                    if let plain = try? await plainSummarize(sample, anchor: anchor) { return plain }
                case .guardrailViolation:
                    break // input flagged — a different excerpt may pass
                default:
                    throw error
                }
            }
        }

        // Every direct window refused — salvage scan (map-reduce). Books dense
        // with flagged themes throughout (war history, intelligence agencies,
        // ancient atrocities…) can refuse every large excerpt; small slices
        // sail through far more often, and the SYNTHESIS step runs over our
        // own neutral mini-summaries, which the safety layer accepts.
        if let salvaged = try? await salvageSummarize(text, instructions: instructions, anchor: anchor) {
            return salvaged
        }

        // Absolute last resort: infer the summary from the chapter titles
        // alone. Titles are short, innocuous metadata that cannot trip the
        // safety layer, so with a table of contents this path always works.
        if chapterTitles.count > 1,
           let fromTitles = try? await summarizeFromTitles(chapterTitles, instructions: instructions, anchor: anchor) {
            return fromTitles
        }
        throw lastError
    }

    private static func summarizeFromTitles(_ titles: [String], instructions: String, anchor: String) async throws -> DocumentSummary {
        let list = titles.prefix(60).enumerated()
            .map { "\($0.offset + 1). \($0.element)" }
            .joined(separator: "\n")
        let prompt = "Chapter titles:\n\(list)"
        do {
            let session = makeSession(instructions: instructions + """
                 You are given only the book's chapter titles; infer what the book \
                is about from them, without inventing specifics the titles don't support.
                """)
            let result = try await session.respond(to: prompt, generating: GeneratedSummary.self)
            return DocumentSummary(
                text: result.content.summary,
                keyPoints: result.content.keyPoints,
                topics: result.content.topics
            )
        } catch {
            return try await plainSummarize(prompt, anchor: anchor)
        }
    }

    /// Map-reduce fallback: 2–3-sentence mini-summaries of small slices spread
    /// across the book (skipping any slice that refuses), then a final
    /// structured summary synthesized from the surviving synopses. Returns nil
    /// only when every single slice refused.
    private static func salvageSummarize(_ text: String, instructions: String, anchor: String) async throws -> DocumentSummary? {
        let fractions: [Double] = [0.06, 0.16, 0.28, 0.40, 0.52, 0.64, 0.76, 0.88]
        let sliceLen = 1600
        var synopses: [String] = []

        for fraction in fractions {
            if synopses.count >= 4 { break }
            let sample = slice(text, at: fraction, length: sliceLen)
            guard !sample.isEmpty else { continue }
            do {
                let session = makeSession(instructions: """
                    You are a book analyst. \(bookFraming) Summarize this excerpt \
                    in 2-3 neutral, factual sentences.
                    """)
                let response = try await session.respond(to: sample)
                synopses.append(response.content)
            } catch {
                continue // this slice refused — move on, others may pass
            }
        }
        guard !synopses.isEmpty else { return nil }

        let joined = synopses.enumerated()
            .map { "Excerpt synopsis \($0.offset + 1): \($0.element)" }
            .joined(separator: "\n\n")
        do {
            let session = makeSession(instructions: instructions + """
                 You are given neutral synopses of excerpts taken from across the book; \
                synthesize them into one coherent picture of the whole work.
                """)
            let result = try await session.respond(to: joined, generating: GeneratedSummary.self)
            return DocumentSummary(
                text: result.content.summary,
                keyPoints: result.content.keyPoints,
                topics: result.content.topics
            )
        } catch {
            // Guided decoder refused the synthesis — plain prose it is.
            return try await plainSummarize(joined, anchor: anchor)
        }
    }

    // MARK: - Classification

    static func classify(_ text: String, title: String? = nil) async throws -> DocumentClassification {
        try ensureAvailable()

        let instructions = """
            You are a book classifier. \(bookFraming)\(titleFraming(title)) Analyze the excerpts and determine the \
            book's genre, primary subject area, reading difficulty level, intended audience, \
            and writing tone. Base your assessment on vocabulary, structure, and content.
            """

        // Windows first; if the whole ladder refuses, fall back to small
        // slices — classification needs far less context than a summary, and
        // 2400-char excerpts pass the safety layer much more often.
        var candidates = sampleWindows(text)
        if text.count > maxInputChars * 3 {
            candidates += [0.20, 0.50, 0.80].map { slice(text, at: $0, length: 2400) }
        }

        var lastError: Error = DocumentIntelligenceError.modelUnavailable(reason: "No text to classify")
        for sample in candidates {
            do {
                let session = makeSession(instructions: instructions)
                let result = try await session.respond(
                    to: sample,
                    generating: GeneratedClassification.self
                )
                return DocumentClassification(
                    genre: result.content.genre,
                    subject: result.content.subject,
                    readingLevel: result.content.readingLevel,
                    audience: result.content.audience,
                    tone: result.content.tone
                )
            } catch {
                lastError = error
                guard let generationError = error as? LanguageModelSession.GenerationError else { throw error }
                switch generationError {
                case .refusal, .decodingFailure:
                    // Guided decoder balked — same sample usually classifies fine in prose.
                    if let plain = try? await plainClassify(sample, instructions: instructions) { return plain }
                case .guardrailViolation:
                    break
                default:
                    throw error
                }
            }
        }
        throw lastError
    }

    /// Plain-prose classification for guided-generation refusals: fixed
    /// labeled lines, parsed by prefix.
    private static func plainClassify(_ sample: String, instructions: String) async throws -> DocumentClassification {
        let session = makeSession(instructions: instructions + """
             Respond with exactly five lines, nothing else:
            Genre: <genre>
            Subject: <subject>
            Reading level: <level>
            Audience: <audience>
            Tone: <tone>
            """)
        let raw = try await session.respond(to: sample).content
        func field(_ label: String) -> String? {
            for line in raw.split(separator: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "**", with: "")
                if trimmed.lowercased().hasPrefix(label.lowercased() + ":") {
                    let value = trimmed.dropFirst(label.count + 1).trimmingCharacters(in: .whitespaces)
                    return value.isEmpty ? nil : value
                }
            }
            return nil
        }
        guard let genre = field("Genre"), let subject = field("Subject") else {
            throw DocumentIntelligenceError.modelUnavailable(reason: "Unparseable classification")
        }
        return DocumentClassification(
            genre: genre,
            subject: subject,
            readingLevel: field("Reading level") ?? "Unknown",
            audience: field("Audience") ?? "General",
            tone: field("Tone") ?? "Neutral"
        )
    }

    // MARK: - Question Answering

    static func ask(_ question: String, context: String) async throws -> String {
        try ensureAvailable()

        let contextSample = String(context.prefix(maxInputChars - 500))

        let session = makeSession(instructions: """
            You are a document assistant. Answer questions accurately based only on the \
            provided document content. If the answer is not in the text, say so.
            """)

        let prompt = """
            Document content:
            \(contextSample)

            Question: \(question)
            """

        let result = try await session.respond(
            to: prompt,
            generating: GeneratedAnswer.self
        )

        return result.content.answer
    }
}
