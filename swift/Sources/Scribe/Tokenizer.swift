import Foundation

// MARK: - Tokenizer (must match parseText() in rsvp-utils.js exactly)

public enum ScribeTokenizer {

    public static func parseText(_ text: String?) -> [String] {
        guard let text = text, !text.isEmpty else { return [] }

        let lines = text.components(separatedBy: "\n")
        var words: [String] = []

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }

            var lineWords = trimmed.components(separatedBy: .whitespacesAndNewlines)
                .filter { !$0.isEmpty }

            if !words.isEmpty && !lineWords.isEmpty {
                words.append("\n")
                lineWords[0] = "⟩" + lineWords[0]
            }

            for word in lineWords {
                words.append(word)
            }
        }

        return words
    }
}
