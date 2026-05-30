import Foundation
import FoundationModels

/// Foundation Models integration for semantic document understanding.
/// All operations run on-device using Apple Intelligence (~3B parameter model).
@available(iOS 26.0, macOS 26.0, *)
struct SemanticAnalyzer {

    /// Maximum characters to send to the model (~2000 words ≈ ~2700 tokens).
    /// The on-device model has a 4096 combined input+output token limit.
    private static let maxInputChars = 8000

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

    static func summarize(_ text: String, style: SummaryStyle) async throws -> DocumentSummary {
        try ensureAvailable()

        let sample = String(text.prefix(maxInputChars))

        let instructions: String
        switch style {
        case .brief:
            instructions = """
            You are a document analyst. Summarize the provided text in exactly 1-2 sentences. \
            Identify the 3 most important key points and the main topics.
            """
        case .concise:
            instructions = """
            You are a document analyst. Provide a concise single-paragraph summary of the provided text. \
            Identify the key points and main topics discussed.
            """
        case .detailed:
            instructions = """
            You are a document analyst. Provide a thorough summary of the provided text. \
            Extract all key points, arguments, and themes comprehensively.
            """
        }

        let session = LanguageModelSession(instructions: instructions)
        let result = try await session.respond(
            to: sample,
            generating: GeneratedSummary.self
        )

        return DocumentSummary(
            text: result.content.summary,
            keyPoints: result.content.keyPoints,
            topics: result.content.topics
        )
    }

    // MARK: - Classification

    static func classify(_ text: String) async throws -> DocumentClassification {
        try ensureAvailable()

        let sample = String(text.prefix(maxInputChars))

        let session = LanguageModelSession(instructions: """
            You are a document classifier. Analyze the provided text and determine its genre, \
            primary subject area, reading difficulty level, intended audience, and writing tone. \
            Base your assessment on vocabulary, structure, and content.
            """)

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
    }

    // MARK: - Question Answering

    static func ask(_ question: String, context: String) async throws -> String {
        try ensureAvailable()

        let contextSample = String(context.prefix(maxInputChars - 500))

        let session = LanguageModelSession(instructions: """
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
