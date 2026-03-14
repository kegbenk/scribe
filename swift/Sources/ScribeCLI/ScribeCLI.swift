import ArgumentParser
import Foundation
import Scribe

@main
struct ScribeCLI: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "scribe-cli",
        abstract: "Extract structured content from PDF files.",
        version: "0.1.0",
        subcommands: [Extract.self]
    )
}

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

    enum OutputFormat: String, ExpressibleByArgument {
        case json
        case text
    }

    func run() throws {
        let url = URL(fileURLWithPath: (input as NSString).expandingTildeInPath)

        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ValidationError("File not found: \(url.path)")
        }

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

        if let outputPath = output {
            let outputURL = URL(fileURLWithPath: (outputPath as NSString).expandingTildeInPath)
            try outputString.write(to: outputURL, atomically: true, encoding: .utf8)
            let chapterCount = chapters.count
            let wordCount = chapters.reduce(0) { $0 + ($1["wordCount"] as? Int ?? 0) }
            fputs("Extracted \(chapterCount) chapters, \(wordCount) words → \(outputURL.path)\n", stderr)
        } else {
            print(outputString)
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
                "chapterIndex": i
            ])

            if let images = chapter["images"] as? [[String: Any]] {
                allImages.append(contentsOf: images)
            }
        }

        let totalWords = chapters.reduce(0) { $0 + ($1["wordCount"] as? Int ?? 0) }

        let structure: [String: Any] = [
            "chapters": chapters,
            "toc": toc,
            "hasStructure": hasStructure,
            "images": allImages,
            "metadata": [
                "source": source,
                "version": "scribe-0.1.0",
                "totalChapters": chapters.count,
                "totalWords": totalWords,
                "generatedAt": ISO8601DateFormatter().string(from: Date())
            ] as [String: Any]
        ]

        return structure
    }
}
