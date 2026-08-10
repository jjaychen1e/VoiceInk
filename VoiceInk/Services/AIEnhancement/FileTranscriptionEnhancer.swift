import Foundation

/// Chooses timed batch JSON enhancement vs plain text for file-transcription results.
enum FileTranscriptionEnhancer {
    /// Runs timed enhancement when Filetrans sentences exist and the provider is OpenAI-compatible.
    ///
    /// Gemini / Anthropic / other non-compatible providers keep plain enhancement and show a tip.
    @MainActor
    static func enhance(
        text: String,
        timedSentences: [TranscriptionTimedSentence]?,
        service: AIEnhancementService,
        configuration: EnhancementRuntimeConfiguration,
        timeout: TimeInterval
    ) async throws -> AIEnhancementResult {
        guard let sentences = timedSentences, !sentences.isEmpty else {
            return try await service.enhance(text, configuration: configuration, timeout: timeout)
        }

        guard let provider = configuration.provider else {
            return try await service.enhance(text, configuration: configuration, timeout: timeout)
        }

        guard provider.supportsOpenAICompatibleStructuredJSON else {
            NotificationManager.shared.showNotification(
                title:
                    "Timed enhancement needs an OpenAI-compatible provider. \(provider.rawValue) will use plain enhancement.",
                type: .warning,
                duration: 4.5
            )
            return try await service.enhance(text, configuration: configuration, timeout: timeout)
        }

        do {
            return try await service.enhanceTimedSentences(
                sentences,
                configuration: configuration,
                timeout: timeout
            )
        } catch {
            // Keep personal workflow unblocked if JSON mode fails for a specific gateway/model.
            NotificationManager.shared.showNotification(
                title: "Timed enhancement failed; falling back to plain enhancement.",
                type: .warning,
                duration: 4.0
            )
            return try await service.enhance(text, configuration: configuration, timeout: timeout)
        }
    }
}
