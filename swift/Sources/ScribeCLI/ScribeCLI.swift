import ArgumentParser
import Foundation
import Scribe

@main
struct ScribeCLI: AsyncParsableCommand {
    static var configuration: CommandConfiguration {
        var subs: [ParsableCommand.Type] = [Extract.self]
        if #available(iOS 26.0, macOS 26.0, *) {
            subs.append(Analyze.self)
        }
        return CommandConfiguration(
            commandName: "scribe-cli",
            abstract: "On-device document intelligence for PDF files.",
            version: "0.3.0",
            subcommands: subs
        )
    }
}

// MARK: - Extract Command (sync, backward-compatible)

struct Extract: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Extract content from a PDF file."
    )

    @Argument(help: "Path to the PDF file.")
    var input: String

    @Option(name: .shortAndLong, help: "Output file path. Defaults to stdout.")
    var output: String?

    @Option(name: .shortAndLong, help: "Output format: json (default) or text.")
    var format: OutputFormat = .json

    @Flag(help: "Include NLP entities per chapter (no AI required).")
    var entities = false

    enum OutputFormat: String, ExpressibleByArgument {
        case json
        case text
    }

    func run() throws {
        let url = URL(fileURLWithPath: (input as NSString).expandingTildeInPath)

        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ValidationError("File not found: \(url.path)")
        }

        // When --entities is set, use DocumentIntelligence for NLP enrichment (requires iOS 26 / macOS 26).
        if entities && format == .json {
            if #available(iOS 26.0, macOS 26.0, *) {
                let intelligence = DocumentIntelligence()
                let contentStructure = try intelligence.extractWithNLP(document: url)
                let jsonData = try JSONSerialization.data(
                    withJSONObject: contentStructure,
                    options: [.prettyPrinted, .sortedKeys]
                )
                let outputString = String(data: jsonData, encoding: .utf8) ?? "{}"
                try writeOutput(outputString)

                let chapters = contentStructure["chapters"] as? [[String: Any]] ?? []
                let totalWords = chapters.reduce(0) { $0 + ($1["wordCount"] as? Int ?? 0) }
                fputs("Extracted \(chapters.count) chapters, \(totalWords) words (with NLP entities)\n", stderr)
                return
            } else {
                throw ValidationError("--entities requires iOS 26+ / macOS 26+. Falling back is not supported.")
            }
        }

        // Standard extraction (existing behavior)
        guard let result = ScribeProcessor.extractContent(from: url) else {
            throw ValidationError("Failed to extract content from \(url.lastPathComponent)")
        }

        let text = result["text"] as? String ?? ""
        let chapters = result["chapters"] as? [[String: Any]] ?? []
        let hasStructure = result["hasStructure"] as? Bool ?? false

        let outputString: String

        switch format {
        case .text:
            outputString = text

        case .json:
            let contentStructure = buildContentStructure(
                chapters: chapters,
                hasStructure: hasStructure,
                source: url.lastPathComponent
            )
            let jsonData = try JSONSerialization.data(
                withJSONObject: contentStructure,
                options: [.prettyPrinted, .sortedKeys]
            )
            outputString = String(data: jsonData, encoding: .utf8) ?? "{}"
        }

        try writeOutput(outputString)
        let chapterCount = chapters.count
        let wordCount = chapters.reduce(0) { $0 + ($1["wordCount"] as? Int ?? 0) }
        fputs("Extracted \(chapterCount) chapters, \(wordCount) words\n", stderr)
    }

    private func writeOutput(_ string: String) throws {
        if let outputPath = output {
            let outputURL = URL(fileURLWithPath: (outputPath as NSString).expandingTildeInPath)
            try string.write(to: outputURL, atomically: true, encoding: .utf8)
            fputs("→ \(outputURL.path)\n", stderr)
        } else {
            print(string)
        }
    }

    private func buildContentStructure(
        chapters: [[String: Any]],
        hasStructure: Bool,
        source: String
    ) -> [String: Any] {
        var toc: [[String: Any]] = []
        var allImages: [[String: Any]] = []

        for (i, chapter) in chapters.enumerated() {
            toc.append([
                "title": chapter["title"] as? String ?? "Untitled",
                "wordIndex": chapter["startWordIndex"] as? Int ?? 0,
                "chapterIndex": i,
            ])

            if let images = chapter["images"] as? [[String: Any]] {
                allImages.append(contentsOf: images)
            }
        }

        let totalWords = chapters.reduce(0) { $0 + ($1["wordCount"] as? Int ?? 0) }

        return [
            "chapters": chapters,
            "toc": toc,
            "hasStructure": hasStructure,
            "images": allImages,
            "metadata": [
                "source": source,
                "version": "scribe-0.3.0",
                "totalChapters": chapters.count,
                "totalWords": totalWords,
                "generatedAt": ISO8601DateFormatter().string(from: Date()),
            ] as [String: Any],
        ]
    }
}

// MARK: - Analyze Command (async, full intelligence pipeline)

@available(iOS 26.0, macOS 26.0, *)
struct Analyze: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Analyze a PDF with on-device document intelligence.",
        discussion: """
            Runs the full extraction + intelligence pipeline:
            • Extracts text, chapters, footnotes, images (PDFKit + Vision OCR)
            • Detects language (NaturalLanguage)
            • Extracts named entities per chapter (NaturalLanguage)
            • Summarizes content (Apple Intelligence)
            • Classifies genre, subject, reading level (Apple Intelligence)

            Output is a ContentStructure JSON with an added 'intelligence' block.
            Falls back to NLP-only mode if Apple Intelligence is unavailable.
            """
    )

    @Argument(help: "Path to the PDF file.")
    var input: String

    @Option(name: .shortAndLong, help: "Output file path. Defaults to stdout.")
    var output: String?

    func run() async throws {
        let url = URL(fileURLWithPath: (input as NSString).expandingTildeInPath)

        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ValidationError("File not found: \(url.path)")
        }

        let intelligence = DocumentIntelligence()

        if !DocumentIntelligence.isAvailable {
            fputs("Apple Intelligence unavailable — running NLP-only analysis.\n", stderr)
        }

        fputs("Analyzing \(url.lastPathComponent)...\n", stderr)
        let contentStructure = try await intelligence.process(document: url)

        let jsonData = try JSONSerialization.data(
            withJSONObject: contentStructure,
            options: [.prettyPrinted, .sortedKeys]
        )
        let outputString = String(data: jsonData, encoding: .utf8) ?? "{}"

        if let outputPath = output {
            let outputURL = URL(fileURLWithPath: (outputPath as NSString).expandingTildeInPath)
            try outputString.write(to: outputURL, atomically: true, encoding: .utf8)
            fputs("→ \(outputURL.path)\n", stderr)
        } else {
            print(outputString)
        }

        // Summary stats
        let chapters = contentStructure["chapters"] as? [[String: Any]] ?? []
        let totalWords = chapters.reduce(0) { $0 + ($1["wordCount"] as? Int ?? 0) }
        let hasIntelligence = (contentStructure["intelligence"] as? [String: Any])?["summary"] != nil

        fputs("Done: \(chapters.count) chapters, \(totalWords) words", stderr)
        if hasIntelligence {
            fputs(" (with AI intelligence)", stderr)
        } else {
            fputs(" (NLP-only)", stderr)
        }
        fputs("\n", stderr)
    }
}
