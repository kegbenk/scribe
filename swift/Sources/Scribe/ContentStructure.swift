import Foundation

/// Output format for Scribe document intelligence, extending the contentStructure JSON schema.
public struct ContentStructure: Codable, Sendable {
    public let chapters: [Chapter]
    public let toc: [TOCEntry]
    public let hasStructure: Bool
    public let images: [Image]
    public let metadata: Metadata?
    /// On-device intelligence analysis (summary, classification, entities, language).
    /// Present when the document was processed with Apple Intelligence enabled.
    public let intelligence: Intelligence?

    public struct Chapter: Codable, Sendable {
        public let title: String
        public let plainText: String
        public let htmlContent: String?
        public let startPage: Int
        public let startWordIndex: Int
        public let endWordIndex: Int
        public let wordCount: Int
        public let footnotes: [Footnote]
        public let images: [Image]
        public let isBackMatter: Bool
        public let sourceType: String?
        /// Named entities detected in this chapter via NLP.
        public let entities: ChapterEntities?
    }

    public struct Footnote: Codable, Sendable {
        public let number: Int
        public let text: String
    }

    public struct Image: Codable, Sendable {
        public let src: String
        public let alt: String?
        public let wordPosition: Int
        public let width: Int
        public let height: Int
        public let pageIndex: Int?
        public let yPosition: Double?
    }

    public struct TOCEntry: Codable, Sendable {
        public let title: String
        public let wordIndex: Int
        public let chapterIndex: Int
        public let level: Int

        public init(title: String, wordIndex: Int, chapterIndex: Int, level: Int = 0) {
            self.title = title
            self.wordIndex = wordIndex
            self.chapterIndex = chapterIndex
            self.level = level
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.title = try c.decode(String.self, forKey: .title)
            self.wordIndex = try c.decode(Int.self, forKey: .wordIndex)
            self.chapterIndex = try c.decode(Int.self, forKey: .chapterIndex)
            self.level = try c.decodeIfPresent(Int.self, forKey: .level) ?? 0
        }
    }

    public struct Metadata: Codable, Sendable {
        public let source: String
        public let version: String
        public let totalPages: Int
        public let totalChapters: Int
        public let totalWords: Int
        public let generatedAt: String
    }

    /// Per-chapter named entities extracted via NaturalLanguage framework.
    public struct ChapterEntities: Codable, Sendable {
        public let people: [String]
        public let places: [String]
        public let organizations: [String]
    }

    /// Document-level intelligence from Apple Intelligence on-device models.
    public struct Intelligence: Codable, Sendable {
        public let summary: Summary
        public let classification: Classification
        public let language: Language
        public let entities: GlobalEntities

        public struct Summary: Codable, Sendable {
            public let text: String
            public let keyPoints: [String]
            public let topics: [String]
        }

        public struct Classification: Codable, Sendable {
            public let genre: String
            public let subject: String
            public let readingLevel: String
            public let audience: String
            public let tone: String
        }

        public struct Language: Codable, Sendable {
            public let dominant: String
            public let confidence: Double
        }

        public struct GlobalEntities: Codable, Sendable {
            public let people: [String]
            public let places: [String]
            public let organizations: [String]
        }
    }
}
