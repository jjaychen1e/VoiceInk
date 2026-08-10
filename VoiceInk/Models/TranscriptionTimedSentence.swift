import Foundation

/// Sentence-level ASR timing from Filetrans (times in milliseconds).
struct TranscriptionTimedSentence: Codable, Sendable, Equatable, Identifiable {
    var id: Int { sentenceId ?? beginTimeMs }
    var sentenceId: Int?
    var beginTimeMs: Int
    var endTimeMs: Int
    var text: String
    var language: String?
    var emotion: String?
    var words: [TranscriptionTimedWord]?

    /// Start time in seconds for audio seeking.
    var beginTime: TimeInterval { TimeInterval(beginTimeMs) / 1000.0 }

    /// End time in seconds.
    var endTime: TimeInterval { TimeInterval(endTimeMs) / 1000.0 }

    /// Formats `MM:SS` (or `H:MM:SS` when needed) for the sentence start.
    var beginTimeLabel: String {
        Self.formatClock(beginTime)
    }

    /// Formats `MM:SS`–`MM:SS` range label.
    var timeRangeLabel: String {
        "\(Self.formatClock(beginTime))–\(Self.formatClock(endTime))"
    }

    static func formatClock(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        let hrs = total / 3600
        let mins = (total % 3600) / 60
        let secs = total % 60
        if hrs > 0 {
            return String(format: "%d:%02d:%02d", hrs, mins, secs)
        }
        return String(format: "%d:%02d", mins, secs)
    }
}

/// Word-level ASR timing from Filetrans (times in milliseconds).
struct TranscriptionTimedWord: Codable, Sendable, Equatable {
    var beginTimeMs: Int
    var endTimeMs: Int
    var text: String
    var punctuation: String?
}
