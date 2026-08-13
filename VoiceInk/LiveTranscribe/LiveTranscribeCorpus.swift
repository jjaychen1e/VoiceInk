import Foundation
import SwiftData

/// Loads Dictionary entries into DashScope realtime `corpus` payloads.
enum LiveTranscribeCorpus {
    /// Soft character budget under the API's 10,000-token corpus.text limit.
    private static let maxCorpusTextCharacters = 8_000
    /// LiveTranslate phrase map size guard.
    private static let maxPhrasePairs = 200

    struct Payload: Sendable {
        /// Contextual biasing text for `input_audio_transcription.corpus.text`.
        let text: String
        /// Source→target pairs for LiveTranslate `translation.corpus.phrases`.
        let phrases: [String: String]

        var isEmpty: Bool { text.isEmpty && phrases.isEmpty }
    }

    /// Builds corpus payloads from Vocabulary + enabled Word Replacements.
    static func load(from modelContext: ModelContext?) -> Payload {
        guard let modelContext else {
            return Payload(text: "", phrases: [:])
        }

        let vocabularyTerms = loadVocabularyTerms(from: modelContext)
        let replacements = loadEnabledReplacements(from: modelContext)

        var phraseMap: [String: String] = [:]
        for pair in replacements {
            if phraseMap.count >= maxPhrasePairs { break }
            phraseMap[pair.original] = pair.replacement
        }

        // Prefer vocabulary terms, then replacement originals, as recognition bias text.
        var biasTerms = vocabularyTerms
        for pair in replacements where !biasTerms.contains(where: { $0.caseInsensitiveCompare(pair.original) == .orderedSame }) {
            biasTerms.append(pair.original)
        }

        let text = joinedCorpusText(biasTerms)
        return Payload(text: text, phrases: phraseMap)
    }

    // MARK: - Private

    private static func loadVocabularyTerms(from modelContext: ModelContext) -> [String] {
        let descriptor = FetchDescriptor<VocabularyWord>(sortBy: [SortDescriptor(\.word)])
        guard let words = try? modelContext.fetch(descriptor) else { return [] }

        var seen = Set<String>()
        var unique: [String] = []
        for entry in words {
            let trimmed = entry.word.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let key = trimmed.lowercased()
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            unique.append(trimmed)
        }
        return unique
    }

    private static func loadEnabledReplacements(
        from modelContext: ModelContext
    ) -> [(original: String, replacement: String)] {
        let descriptor = FetchDescriptor<WordReplacement>(sortBy: [SortDescriptor(\.dateAdded)])
        guard let items = try? modelContext.fetch(descriptor) else { return [] }

        var pairs: [(original: String, replacement: String)] = []
        for item in items where item.isEnabled {
            let original = item.originalText.trimmingCharacters(in: .whitespacesAndNewlines)
            let replacement = item.replacementText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !original.isEmpty, !replacement.isEmpty else { continue }
            pairs.append((original, replacement))
        }
        return pairs
    }

    private static func joinedCorpusText(_ terms: [String]) -> String {
        guard !terms.isEmpty else { return "" }

        var parts: [String] = []
        var total = 0
        for term in terms {
            let addition = parts.isEmpty ? term.count : term.count + 2
            if total + addition > maxCorpusTextCharacters { break }
            parts.append(term)
            total += addition
        }
        return parts.joined(separator: ", ")
    }
}
