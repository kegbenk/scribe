import Foundation

/// Output format for Scribe PDF extraction, matching the contentStructure JSON schema.
public struct ContentStructure: Codable {
    public let chapters: [Chapter]
    public let toc: [TOCEntry]
    public let hasStructure: Bool
    public let images: [Image]
    public let metadata: Metadata?

    public struct Chapter: Codable {
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
    }

    public struct Footnote: Codable {
        public let number: Int
        public let text: String
    }

    public struct Image: Codable {
        public let src: String
        public let alt: String?
        public let wordPosition: Int
        public let width: Int
        public let height: Int
        public let pageIndex: Int?
        public let yPosition: Double?
    }

    public struct TOCEntry: Codable {
        public let title: String
        public let wordIndex: Int
        public let chapterIndex: Int
    }

    public struct Metadata: Codable {
        public let source: String
        public let version: String
        public let totalPages: Int
        public let totalChapters: Int
        public let totalWords: Int
        public let generatedAt: String
    }
}
