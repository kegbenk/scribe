import Foundation
import NaturalLanguage

/// NaturalLanguage framework integration for entity recognition, language detection, and sentiment.
/// All operations run on-device with no network access required.
struct LanguageAnalyzer {

    // MARK: - Language Detection

    static func detectLanguage(of text: String) -> LanguageDetection {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)

        let dominant = recognizer.dominantLanguage ?? .undetermined
        let hypotheses = recognizer.languageHypotheses(withMaximum: 5)
        let dominantConfidence = hypotheses[dominant] ?? 0

        let alternatives = hypotheses
            .filter { $0.key != dominant }
            .map { LanguageHypothesis(language: $0.key.rawValue, confidence: $0.value) }
            .sorted { $0.confidence > $1.confidence }

        return LanguageDetection(
            dominantLanguage: dominant.rawValue,
            confidence: dominantConfidence,
            alternatives: alternatives
        )
    }

    // MARK: - Named Entity Recognition

    static func extractEntities(from text: String) -> [NamedEntity] {
        let tagger = NLTagger(tagSchemes: [.nameType])
        tagger.string = text

        var entities: [NamedEntity] = []
        var seen = Set<String>()

        tagger.enumerateTags(
            in: text.startIndex..<text.endIndex,
            unit: .word,
            scheme: .nameType,
            options: [.omitPunctuation, .omitWhitespace, .joinNames]
        ) { tag, tokenRange in
            guard let tag = tag else { return true }

            let entityText = String(text[tokenRange])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !entityText.isEmpty else { return true }

            // Deduplicate by type+text
            let key = "\(tag.rawValue):\(entityText)"
            guard !seen.contains(key) else { return true }
            seen.insert(key)

            let entityType: NamedEntity.EntityType
            switch tag {
            case .personalName:
                entityType = .person
            case .placeName:
                entityType = .place
            case .organizationName:
                entityType = .organization
            default:
                return true
            }

            entities.append(NamedEntity(text: entityText, type: entityType))
            return true
        }

        return entities
    }

    // MARK: - Sentiment Analysis

    /// Returns a sentiment score from -1.0 (very negative) to +1.0 (very positive).
    static func analyzeSentiment(of text: String) -> Double {
        let tagger = NLTagger(tagSchemes: [.sentimentScore])
        tagger.string = text

        guard let sentiment = tagger.tag(
            at: text.startIndex,
            unit: .paragraph,
            scheme: .sentimentScore
        ).0 else {
            return 0.0
        }

        return Double(sentiment.rawValue) ?? 0.0
    }

    // MARK: - Tokenization

    /// Tokenize text into words using NLTokenizer.
    static func tokenize(_ text: String) -> [String] {
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = text

        var tokens: [String] = []
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            tokens.append(String(text[range]))
            return true
        }
        return tokens
    }

    // MARK: - Semantic Similarity

    /// Compute semantic distance between two words (0 = identical, larger = less similar).
    /// Returns nil if embeddings are unavailable for the language.
    static func wordDistance(_ word1: String, _ word2: String, language: NLLanguage = .english) -> Double? {
        guard let embedding = NLEmbedding.wordEmbedding(for: language) else { return nil }
        return embedding.distance(between: word1, and: word2)
    }
}
