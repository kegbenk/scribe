import Foundation

/// Word tokenizer shared by every part of the pipeline that counts words.
///
/// This is the Swift half of a cross-runtime parity contract: it MUST produce
/// identical word boundaries to `shared/tokenizer/parseText.js`, because
/// `startWordIndex`/`endWordIndex`/`wordCount` in the extraction output are
/// consumed by reader apps for RSVP playback position and by the eval harness
/// for word-level fidelity scoring. Any change here is a breaking change and
/// must land in both implementations in the same PR (see
/// `docs/runtime-contracts.md`).
public enum ScribeTokenizer {

    /// Split text into RSVP display tokens.
    ///
    /// Lines are trimmed and blank lines dropped. Between non-empty lines a
    /// literal `"\n"` token is inserted and the following word is prefixed
    /// with `"⟩"` — reader apps use these markers to render paragraph breaks
    /// during playback. The returned array's `count` is the word count used
    /// everywhere in the contentStructure contract.
    ///
    /// - Parameter text: Plain text (typically a chapter's `plainText`); nil
    ///   or empty input returns an empty array.
    /// - Returns: Display tokens, including `"\n"` break markers.
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
