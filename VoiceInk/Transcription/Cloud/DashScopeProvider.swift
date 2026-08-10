import Foundation
import SwiftData

struct DashScopeProvider: CloudProvider {
    let modelProvider: ModelProvider = .alibaba
    let providerKey: String = "Alibaba"
    /// Languages officially supported by Qwen3-ASR (provider default / picker fallback).
    let languageCodes: [String]? = [
        "zh", "yue", "en", "ja", "de", "ko", "ru", "fr", "pt", "ar",
        "it", "es", "hi", "id", "th", "tr", "uk", "vi", "cs", "da",
        "fil", "fi", "is", "ms", "no", "pl", "sv",
    ]
    let includesAutoDetect: Bool = true

    /// Languages for `qwen-audio-3.0-asr-flash` (docs use `tl` for Filipino; UI keeps `fil`).
    private static let qwenAudioLanguageCodes: [String] = [
        "zh", "en", "ja", "ko", "vi", "th", "id", "ms", "fil", "hi", "ar",
        "fr", "de", "es", "pt", "ru", "it", "nl", "sv", "da", "fi", "no",
        "el", "pl", "cs", "hu", "ro", "bg", "hr", "sk",
    ]

    var models: [CloudModel] {
        [
            CloudModel(
                name: "qwen3-asr-flash",
                displayName: "Qwen3 ASR Flash",
                description:
                    "Alibaba Cloud Qwen3-ASR Flash with batch transcription and realtime streaming",
                provider: .alibaba,
                speed: 0.95,
                accuracy: 0.96,
                isMultilingual: true,
                supportsStreaming: true,
                supportedLanguages: LanguageDictionary.forProvider(
                    isMultilingual: true, provider: .alibaba)
            ),
            CloudModel(
                name: "qwen3-asr-flash-2026-02-10",
                displayName: "Qwen3 ASR Flash (2026-02-10)",
                description: "Latest Qwen3-ASR Flash snapshot for batch transcription",
                provider: .alibaba,
                speed: 0.95,
                accuracy: 0.96,
                isMultilingual: true,
                supportsStreaming: false,
                supportedLanguages: LanguageDictionary.forProvider(
                    isMultilingual: true, provider: .alibaba)
            ),
            CloudModel(
                name: "qwen-audio-3.0-asr-flash",
                displayName: "Qwen Audio 3.0 ASR Flash",
                description:
                    "Alibaba Cloud Qwen-Audio-3.0-ASR-Flash with batch transcription and realtime streaming",
                provider: .alibaba,
                speed: 0.95,
                accuracy: 0.97,
                isMultilingual: true,
                supportsStreaming: true,
                supportedLanguages: LanguageDictionary.forCodes(
                    Self.qwenAudioLanguageCodes, includesAutoDetect: true)
            ),
        ]
    }

    func transcribe(
        audioData: Data, fileName: String, apiKey: String, model: String, language: String?,
        customVocabulary: [String]
    ) async throws -> String {
        let batchModel = Self.batchModelName(for: model)

        if Self.usesQwenAudioMultimodalAPI(batchModel) {
            return try await DashScopeQwenAudioTranscriptionClient.transcribe(
                audioData: audioData,
                fileName: fileName,
                apiKey: apiKey,
                model: batchModel,
                language: language,
                customVocabulary: customVocabulary
            )
        }

        // Qwen3-ASR rejects text input; customVocabulary is intentionally unused.
        return try await DashScopeTranscriptionClient.transcribe(
            audioData: audioData,
            fileName: fileName,
            apiKey: apiKey,
            model: batchModel,
            language: language
        )
    }

    func makeStreamingProvider(modelContext: ModelContext) -> (any StreamingTranscriptionProvider)? {
        DashScopeStreamingProvider(modelContext: modelContext)
    }

    func verifyAPIKey(_ key: String) async -> (isValid: Bool, errorMessage: String?) {
        await DashScopeTranscriptionClient.verifyAPIKey(key)
    }

    /// Whether the model uses DashScope multimodal-generation / Fun-ASR (Qwen-Audio 3.0 family).
    static func usesQwenAudioMultimodalAPI(_ model: String) -> Bool {
        model.hasPrefix("qwen-audio-3.0-asr")
    }

    /// Whether streaming should use the Fun-ASR inference WebSocket (vs Qwen3 realtime).
    static func usesQwenAudioStreamingAPI(_ model: String) -> Bool {
        model.hasPrefix("qwen-audio-3.0-asr")
    }

    /// Maps a UI / streaming model id to the batch model id.
    static func batchModelName(for model: String) -> String {
        if model.hasPrefix("qwen-audio-3.0-asr") {
            return "qwen-audio-3.0-asr-flash"
        }
        if model.contains("realtime") {
            return "qwen3-asr-flash"
        }
        return model
    }

    /// Maps a UI / batch model id to the streaming WebSocket model id.
    static func realtimeModelName(for model: String) -> String {
        if usesQwenAudioStreamingAPI(model) {
            if model.contains("streaming") {
                return model
            }
            return "qwen-audio-3.0-asr-flash-streaming"
        }
        if model.contains("realtime") {
            return model
        }
        if model.hasPrefix("qwen3-asr-flash-") {
            // Snapshot batch ids do not have matching realtime snapshots in the UI list;
            // fall back to the stable realtime model.
            return "qwen3-asr-flash-realtime"
        }
        return "qwen3-asr-flash-realtime"
    }

    /// Maps a UI / batch model id to the asynchronous Filetrans model id, if available.
    static func filetransModelName(for model: String) -> String? {
        if model.hasPrefix("qwen-audio-3.0-asr") {
            return "qwen-audio-3.0-asr-flash-filetrans"
        }
        if model.hasPrefix("qwen3-asr-flash") {
            return "qwen3-asr-flash-filetrans"
        }
        return nil
    }

    /// Whether Filetrans for this model uses singular `file_url` (Qwen3) vs `file_urls` (Qwen-Audio style).
    static func filetransUsesSingularFileURL(_ filetransModel: String) -> Bool {
        filetransModel.hasPrefix("qwen3-asr-flash-filetrans")
    }
}
