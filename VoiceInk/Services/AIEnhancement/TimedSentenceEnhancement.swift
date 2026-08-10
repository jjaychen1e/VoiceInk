import Foundation

/// Batch JSON request/response helpers for sentence-anchored enhancement (V1).
enum TimedSentenceEnhancement {
    struct SegmentInput: Codable, Sendable {
        let id: Int
        let text: String
    }

    struct SegmentOutput: Codable, Sendable {
        let id: Int
        let text: String
    }

    struct ResponsePayload: Codable, Sendable {
        let segments: [SegmentOutput]
    }

    /// Builds the user message that asks the model to enhance each segment in place.
    static func userMessage(for sentences: [TranscriptionTimedSentence]) throws -> String {
        let inputs = sentences.enumerated().map { index, sentence in
            SegmentInput(id: index, text: sentence.text)
        }
        let data = try JSONEncoder().encode(inputs)
        let json = String(data: data, encoding: .utf8) ?? "[]"
        return """
            Enhance each transcript segment. Keep the same number of segments and the same `id` values.
            Do not merge, split, drop, or reorder segments. Return JSON only in this shape:
            {"segments":[{"id":0,"text":"..."}]}

            <SEGMENTS>
            \(json)
            </SEGMENTS>
            """
    }

    /// Extra system instructions appended for timed batch enhancement.
    static var systemAddon: String {
        """
        # Timed Segment Output
        You are enhancing ASR segments that must stay 1:1 with the input ids.
        Return valid JSON only (no markdown fences). Preserve meaning; clean up ASR errors, punctuation, and filler as instructed by the prompt above.
        """
    }

    /// Parses model output into enhanced sentences that reuse original time windows.
    static func parse(
        response: String,
        originalSentences: [TranscriptionTimedSentence]
    ) throws -> [TranscriptionTimedSentence] {
        let filtered = AIEnhancementOutputFilter.filter(response)
        let jsonText = extractJSONObject(from: filtered)
        guard let data = jsonText.data(using: .utf8) else {
            throw EnhancementError.invalidResponse
        }

        let payload: ResponsePayload
        do {
            payload = try JSONDecoder().decode(ResponsePayload.self, from: data)
        } catch {
            throw EnhancementError.customError("Timed enhancement returned invalid JSON.")
        }

        guard payload.segments.count == originalSentences.count else {
            throw EnhancementError.customError(
                "Timed enhancement segment count mismatch (\(payload.segments.count) vs \(originalSentences.count))."
            )
        }

        var byID: [Int: String] = [:]
        byID.reserveCapacity(payload.segments.count)
        for segment in payload.segments {
            let trimmed = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                throw EnhancementError.customError("Timed enhancement returned an empty segment.")
            }
            if byID[segment.id] != nil {
                throw EnhancementError.customError("Timed enhancement returned duplicate segment ids.")
            }
            byID[segment.id] = trimmed
        }

        return try originalSentences.enumerated().map { index, original in
            guard let enhancedText = byID[index] else {
                throw EnhancementError.customError("Timed enhancement missing segment id \(index).")
            }
            return TranscriptionTimedSentence(
                sentenceId: original.sentenceId ?? index,
                beginTimeMs: original.beginTimeMs,
                endTimeMs: original.endTimeMs,
                text: enhancedText,
                language: original.language,
                emotion: original.emotion,
                words: nil
            )
        }
    }

    /// Joins enhanced sentence texts into a single transcript string.
    static func joinedText(from sentences: [TranscriptionTimedSentence]) -> String {
        sentences.map(\.text).joined(separator: "\n")
    }

    /// Strips optional markdown fences and returns the first JSON object substring.
    private static func extractJSONObject(from text: String) -> String {
        var candidate = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if candidate.hasPrefix("```") {
            let lines = candidate.split(separator: "\n", omittingEmptySubsequences: false)
            if lines.count >= 3 {
                candidate = lines.dropFirst().dropLast().joined(separator: "\n")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        if let start = candidate.firstIndex(of: "{"),
            let end = candidate.lastIndex(of: "}")
        {
            return String(candidate[start...end])
        }
        return candidate
    }
}
