import Foundation
import SwiftData

enum TranscriptionStatus: String, Codable {
    case pending
    case completed
    case failed
    case canceled
}

@Model
final class Transcription {
    static let canceledTranscriptionText = "The transcription was canceled."

    var id: UUID = UUID()
    var text: String = ""
    var enhancedText: String?
    var timestamp: Date = Date()
    var duration: TimeInterval = 0
    var audioFileURL: String?
    var transcriptionModelName: String?
    var aiEnhancementModelName: String?
    var promptName: String?
    var transcriptionDuration: TimeInterval?
    var enhancementDuration: TimeInterval?
    var aiRequestSystemMessage: String?
    var aiRequestUserMessage: String?
    /// Provider-reported prompt / input token count from the last AI request.
    var aiPromptTokens: Int?
    /// Provider-reported completion / output token count from the last AI request.
    var aiCompletionTokens: Int?
    /// Provider-reported total token count from the last AI request.
    var aiTotalTokens: Int?
    /// Prompt tokens served from provider cache (`cached_tokens` / cache read).
    var aiCachedPromptTokens: Int?
    /// Prompt tokens written into provider cache (Anthropic cache creation / OpenAI cache write).
    var aiCacheCreationTokens: Int?
    @Attribute(originalName: "powerModeName")
    var modeName: String?
    @Attribute(originalName: "powerModeEmoji")
    var modeEmoji: String?
    var transcriptionStatus: String?
    /// User-marked favorite for History filtering.
    var isFavorite: Bool = false
    /// Optional companion video path for synced subtitle playback (`file://...`).
    var linkedVideoURL: String?
    /// JSON-encoded `[TranscriptionTimedSentence]` from Filetrans (raw ASR timings).
    var timedSentencesData: Data?
    /// JSON-encoded enhanced sentences that reuse raw ASR time windows.
    var enhancedTimedSentencesData: Data?

    /// Decoded sentence timings, if Filetrans provided them.
    var timedSentences: [TranscriptionTimedSentence]? {
        get {
            guard let timedSentencesData else { return nil }
            return try? JSONDecoder().decode([TranscriptionTimedSentence].self, from: timedSentencesData)
        }
        set {
            timedSentencesData = newValue.flatMap { try? JSONEncoder().encode($0) }
        }
    }

    /// Enhanced sentence texts with original Filetrans begin/end times.
    var enhancedTimedSentences: [TranscriptionTimedSentence]? {
        get {
            guard let enhancedTimedSentencesData else { return nil }
            return try? JSONDecoder().decode([TranscriptionTimedSentence].self, from: enhancedTimedSentencesData)
        }
        set {
            enhancedTimedSentencesData = newValue.flatMap { try? JSONEncoder().encode($0) }
        }
    }

    /// Resolved companion video file URL when the linked path still exists.
    var resolvedLinkedVideoURL: URL? {
        guard let linkedVideoURL, !linkedVideoURL.isEmpty else { return nil }
        let url: URL
        if let parsed = URL(string: linkedVideoURL), parsed.isFileURL {
            url = parsed
        } else {
            url = URL(fileURLWithPath: linkedVideoURL)
        }
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    /// Prefer enhanced timed sentences when present.
    var displayTimedSentences: [TranscriptionTimedSentence]? {
        let sentences = enhancedTimedSentences ?? timedSentences
        guard let sentences, !sentences.isEmpty else { return nil }
        return sentences
    }

    init(
        text: String,
        duration: TimeInterval,
        enhancedText: String? = nil,
        audioFileURL: String? = nil,
        transcriptionModelName: String? = nil,
        aiEnhancementModelName: String? = nil,
        promptName: String? = nil,
        transcriptionDuration: TimeInterval? = nil,
        enhancementDuration: TimeInterval? = nil,
        aiRequestSystemMessage: String? = nil,
        aiRequestUserMessage: String? = nil,
        aiPromptTokens: Int? = nil,
        aiCompletionTokens: Int? = nil,
        aiTotalTokens: Int? = nil,
        aiCachedPromptTokens: Int? = nil,
        aiCacheCreationTokens: Int? = nil,
        modeName: String? = nil,
        modeEmoji: String? = nil,
        transcriptionStatus: TranscriptionStatus = .pending,
        timedSentences: [TranscriptionTimedSentence]? = nil,
        enhancedTimedSentences: [TranscriptionTimedSentence]? = nil
    ) {
        self.id = UUID()
        self.text = text
        self.enhancedText = enhancedText
        self.timestamp = Date()
        self.duration = duration
        self.audioFileURL = audioFileURL
        self.transcriptionModelName = transcriptionModelName
        self.aiEnhancementModelName = aiEnhancementModelName
        self.promptName = promptName
        self.transcriptionDuration = transcriptionDuration
        self.enhancementDuration = enhancementDuration
        self.aiRequestSystemMessage = aiRequestSystemMessage
        self.aiRequestUserMessage = aiRequestUserMessage
        self.aiPromptTokens = aiPromptTokens
        self.aiCompletionTokens = aiCompletionTokens
        self.aiTotalTokens = aiTotalTokens
        self.aiCachedPromptTokens = aiCachedPromptTokens
        self.aiCacheCreationTokens = aiCacheCreationTokens
        self.modeName = modeName
        self.modeEmoji = modeEmoji
        self.transcriptionStatus = transcriptionStatus.rawValue
        self.timedSentences = timedSentences
        self.enhancedTimedSentences = enhancedTimedSentences
    }

    /// Copies provider-reported usage onto this history row.
    func applyAIUsage(_ usage: LLMUsage?) {
        aiPromptTokens = usage?.promptTokens
        aiCompletionTokens = usage?.completionTokens
        aiTotalTokens = usage?.totalTokens
        aiCachedPromptTokens = usage?.cachedPromptTokens
        aiCacheCreationTokens = usage?.cacheCreationTokens
    }

    /// Clears provider-reported usage fields.
    func clearAIUsage() {
        applyAIUsage(nil)
    }

    func markAsCanceledTranscription(
        duration: TimeInterval? = nil,
        modelName: String? = nil
    ) {
        text = Self.canceledTranscriptionText
        enhancedText = nil
        transcriptionStatus = TranscriptionStatus.canceled.rawValue
        if let duration {
            self.duration = duration
        }
        if let modelName {
            transcriptionModelName = modelName
        }
        transcriptionDuration = nil
        enhancementDuration = nil
        aiEnhancementModelName = nil
        promptName = nil
        aiRequestSystemMessage = nil
        aiRequestUserMessage = nil
        clearAIUsage()
        timedSentencesData = nil
        enhancedTimedSentencesData = nil
        linkedVideoURL = nil
        isFavorite = false
    }
}
