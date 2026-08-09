import Foundation
import LLMkit
import SwiftData

/// OpenRouter speech-to-text via the OpenAI-compatible `/api/v1/audio/transcriptions` endpoint.
/// Shares the same API key as OpenRouter enhancement models.
struct OpenRouterProvider: CloudProvider {
    let modelProvider: ModelProvider = .openRouter
    let providerKey: String = "OpenRouter"
    let languageCodes: [String]? = nil
    let includesAutoDetect: Bool = true

    private static let apiBaseURL = URL(string: "https://openrouter.ai/api")!

    var models: [CloudModel] {
        [
            CloudModel(
                name: "openai/gpt-4o-transcribe",
                displayName: "GPT-4o Transcribe",
                description: "OpenAI GPT-4o transcription via OpenRouter",
                provider: .openRouter,
                speed: 0.9,
                accuracy: 0.97,
                isMultilingual: true,
                supportedLanguages: LanguageDictionary.forProvider(
                    isMultilingual: true, provider: .openRouter)
            ),
            CloudModel(
                name: "openai/gpt-4o-mini-transcribe",
                displayName: "GPT-4o Mini Transcribe",
                description: "Faster, lower-cost OpenAI transcription via OpenRouter",
                provider: .openRouter,
                speed: 0.95,
                accuracy: 0.95,
                isMultilingual: true,
                supportedLanguages: LanguageDictionary.forProvider(
                    isMultilingual: true, provider: .openRouter)
            ),
            CloudModel(
                name: "openai/gpt-transcribe",
                displayName: "GPT Transcribe",
                description: "OpenAI GPT Transcribe via OpenRouter",
                provider: .openRouter,
                speed: 0.92,
                accuracy: 0.96,
                isMultilingual: true,
                supportedLanguages: LanguageDictionary.forProvider(
                    isMultilingual: true, provider: .openRouter)
            ),
            CloudModel(
                name: "openai/whisper-large-v3",
                displayName: "Whisper Large V3",
                description: "OpenAI Whisper Large V3 via OpenRouter",
                provider: .openRouter,
                speed: 0.8,
                accuracy: 0.96,
                isMultilingual: true,
                supportedLanguages: LanguageDictionary.forProvider(
                    isMultilingual: true, provider: .openRouter)
            ),
            CloudModel(
                name: "openai/whisper-large-v3-turbo",
                displayName: "Whisper Large V3 Turbo",
                description: "Faster Whisper Large V3 Turbo via OpenRouter",
                provider: .openRouter,
                speed: 0.9,
                accuracy: 0.95,
                isMultilingual: true,
                supportedLanguages: LanguageDictionary.forProvider(
                    isMultilingual: true, provider: .openRouter)
            ),
            CloudModel(
                name: "openai/whisper-1",
                displayName: "Whisper 1",
                description: "OpenAI Whisper 1 via OpenRouter",
                provider: .openRouter,
                speed: 0.85,
                accuracy: 0.93,
                isMultilingual: true,
                supportedLanguages: LanguageDictionary.forProvider(
                    isMultilingual: true, provider: .openRouter)
            ),
            CloudModel(
                name: "google/chirp-3",
                displayName: "Google Chirp 3",
                description: "Google Chirp 3 speech-to-text via OpenRouter",
                provider: .openRouter,
                speed: 0.9,
                accuracy: 0.96,
                isMultilingual: true,
                supportedLanguages: LanguageDictionary.forProvider(
                    isMultilingual: true, provider: .openRouter)
            ),
            CloudModel(
                name: "deepgram/nova-3",
                displayName: "Deepgram Nova 3",
                description: "Deepgram Nova 3 via OpenRouter",
                provider: .openRouter,
                speed: 0.98,
                accuracy: 0.96,
                isMultilingual: true,
                supportedLanguages: LanguageDictionary.forProvider(
                    isMultilingual: true, provider: .openRouter)
            ),
            CloudModel(
                name: "mistralai/voxtral-mini-transcribe",
                displayName: "Voxtral Mini Transcribe",
                description: "Mistral Voxtral Mini transcription via OpenRouter",
                provider: .openRouter,
                speed: 0.95,
                accuracy: 0.94,
                isMultilingual: true,
                supportedLanguages: LanguageDictionary.forProvider(
                    isMultilingual: true, provider: .openRouter)
            ),
            CloudModel(
                name: "qwen/qwen3-asr-flash-2026-02-10",
                displayName: "Qwen3 ASR Flash",
                description: "Alibaba Qwen3-ASR Flash via OpenRouter",
                provider: .openRouter,
                speed: 0.95,
                accuracy: 0.96,
                isMultilingual: true,
                supportedLanguages: LanguageDictionary.forProvider(
                    isMultilingual: true, provider: .openRouter)
            ),
            CloudModel(
                name: "x-ai/grok-stt-1.0",
                displayName: "Grok STT",
                description: "xAI Grok speech-to-text via OpenRouter",
                provider: .openRouter,
                speed: 0.95,
                accuracy: 0.95,
                isMultilingual: true,
                supportedLanguages: LanguageDictionary.forProvider(
                    isMultilingual: true, provider: .openRouter)
            ),
            CloudModel(
                name: "nvidia/parakeet-tdt-0.6b-v3",
                displayName: "Parakeet TDT 0.6B v3",
                description: "NVIDIA Parakeet transcription via OpenRouter",
                provider: .openRouter,
                speed: 0.98,
                accuracy: 0.94,
                isMultilingual: true,
                supportedLanguages: LanguageDictionary.forProvider(
                    isMultilingual: true, provider: .openRouter)
            ),
        ]
    }

    func transcribe(
        audioData: Data, fileName: String, apiKey: String, model: String, language: String?,
        customVocabulary: [String]
    ) async throws -> String {
        let prompt = customVocabulary.isEmpty ? nil : customVocabulary.joined(separator: ", ")
        return try await OpenAITranscriptionClient.transcribe(
            baseURL: Self.apiBaseURL,
            audioData: audioData,
            fileName: fileName,
            apiKey: apiKey,
            model: model,
            language: language,
            prompt: prompt,
            timeout: 90
        )
    }

    func makeStreamingProvider(modelContext: ModelContext) -> (any StreamingTranscriptionProvider)? { nil }

    func verifyAPIKey(_ key: String) async -> (isValid: Bool, errorMessage: String?) {
        // Reuse the same verification path as OpenRouter enhancement.
        await OpenRouterClient.verifyAPIKey(key)
    }
}
