import AVFoundation
import Foundation
import SwiftData
import SwiftUI
import os

@MainActor
class AudioTranscriptionManager: ObservableObject {
    static let shared = AudioTranscriptionManager()

    // MARK: - Published State

    @Published var queue: [AudioFileQueueItem] = []
    @Published var isProcessingQueue = false
    @Published var lastCompletedItemId: UUID?

    // MARK: - Private

    private var processingTask: Task<Void, Never>?
    private var processingGeneration: UInt64 = 0
    private let audioProcessor = AudioProcessor()
    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "AudioTranscriptionManager")

    private init() {}

    // MARK: - Queue Management

    /// Add one or more audio file URLs to the queue. Invalid files are silently skipped.
    func addToQueue(urls: [URL]) {
        for url in urls {
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            guard SupportedMedia.isSupported(url: url) else { continue }

            // Avoid adding the same file path twice if it's already pending/processing
            let path = url.standardizedFileURL.path
            if queue.contains(where: { $0.url.standardizedFileURL.path == path && !$0.status.isTerminal }) {
                continue
            }

            let item = AudioFileQueueItem(url: url)
            queue.append(item)
        }
    }

    /// Remove a pending item from the queue.
    func removeFromQueue(id: UUID) {
        guard let index = queue.firstIndex(where: { $0.id == id }) else { return }
        let item = queue[index]

        // Only allow removing pending items
        guard case .pending = item.status else { return }

        queue.remove(at: index)
    }

    /// Clear all items from the queue, cancelling any in-progress work.
    func clearAll() {
        cancelProcessing()
        queue.removeAll()
        lastCompletedItemId = nil
    }

    /// Retry a failed item by resetting it to pending and re-enqueuing.
    func retryItem(id: UUID) {
        guard let item = queue.first(where: { $0.id == id }),
            case .failed = item.status
        else { return }

        item.status = .pending
    }

    /// Start processing pending items in the queue sequentially.
    func startProcessing(modelContext: ModelContext, engine: VoiceInkEngine, mode: ModeConfig) {
        guard !isProcessingQueue else { return }
        isProcessingQueue = true
        processingGeneration &+= 1
        let generation = processingGeneration

        processingTask = Task { [weak self] in
            guard let self else { return }

            while let item = self.nextPendingItem() {
                guard !Task.isCancelled else { break }
                await self.processItem(item, modelContext: modelContext, engine: engine, mode: mode)
            }

            if self.processingGeneration == generation {
                self.isProcessingQueue = false
            }
        }
    }

    func cancelProcessing() {
        processingTask?.cancel()
        processingTask = nil
        isProcessingQueue = false

        // Reset any in-progress items back to pending
        for item in queue {
            if case .processing = item.status {
                item.status = .pending
            }
        }
    }

    var hasPendingItems: Bool {
        queue.contains {
            if case .pending = $0.status { return true }
            return false
        }
    }

    // MARK: - Private

    private func nextPendingItem() -> AudioFileQueueItem? {
        queue.first {
            if case .pending = $0.status { return true }
            return false
        }
    }

    private func processItem(
        _ item: AudioFileQueueItem, modelContext: ModelContext, engine: VoiceInkEngine, mode: ModeConfig
    ) async {
        let serviceRegistry = TranscriptionServiceRegistry(
            modelProvider: engine.whisperModelManager,
            modelsDirectory: engine.whisperModelManager.modelsDirectory,
            modelContext: modelContext
        )

        do {
            guard
                let transcriptionConfiguration = ModeRuntimeResolver.transcriptionConfiguration(
                    mode: mode,
                    transcriptionModelManager: engine.transcriptionModelManager
                )
            else {
                throw TranscriptionError.noModelSelected
            }
            let currentModel = transcriptionConfiguration.model

            // Phase: Loading
            item.status = .processing(phase: .loading)
            try Task.checkCancellation()

            // Phase: Processing Audio
            item.status = .processing(phase: .processingAudio)

            let accessing = item.url.startAccessingSecurityScopedResource()
            defer { if accessing { item.url.stopAccessingSecurityScopedResource() } }

            let samples = try await audioProcessor.processAudioToSamples(item.url)
            try Task.checkCancellation()

            let audioAsset = AVURLAsset(url: item.url)
            let duration = CMTimeGetSeconds(try await audioAsset.load(.duration))

            let recordingsDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[
                0
            ]
            .appendingPathComponent("com.prakashjoshipax.VoiceInk")
            .appendingPathComponent("Recordings")

            let fileName = "transcribed_\(UUID().uuidString).wav"
            let permanentURL = recordingsDirectory.appendingPathComponent(fileName)

            try FileManager.default.createDirectory(at: recordingsDirectory, withIntermediateDirectories: true)
            try audioProcessor.saveSamplesAsWav(samples: samples, to: permanentURL)
            try Task.checkCancellation()

            // Phase: Transcribing
            item.status = .processing(phase: .transcribing)
            let transcriptionStart = Date()
            var text: String
            var timedSentences: [TranscriptionTimedSentence]?
            switch transcriptionConfiguration.fileStrategy {
            case .stream:
                text = try await FileStreamingTranscriber.transcribe(
                    samples: samples,
                    model: currentModel,
                    context: transcriptionConfiguration.requestContext,
                    modelContext: modelContext,
                    fluidAudioService: serviceRegistry.fluidAudioTranscriptionService,
                    batchFallback: {
                        try await serviceRegistry.transcribe(
                            audioURL: permanentURL,
                            model: currentModel,
                            context: transcriptionConfiguration.requestContext
                        )
                    }
                )
            case .asynchronous:
                guard let apiKey = APIKeyManager.shared.getAPIKey(forProvider: "Alibaba"), !apiKey.isEmpty else {
                    throw CloudTranscriptionError.missingAPIKey
                }
                let filetransResult = try await DashScopeFiletransClient.transcribe(
                    audioURL: permanentURL,
                    apiKey: apiKey,
                    model: currentModel.name,
                    language: transcriptionConfiguration.language
                )
                text = filetransResult.text
                timedSentences = filetransResult.sentences.isEmpty ? nil : filetransResult.sentences
            case .sync:
                text = try await serviceRegistry.transcribe(
                    audioURL: permanentURL,
                    model: currentModel,
                    context: transcriptionConfiguration.requestContext
                )
            }
            let transcriptionDuration = Date().timeIntervalSince(transcriptionStart)
            text = TranscriptionOutputFilter.filter(text)
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)

            let modeMetadata = transcriptionConfiguration.metadata
            let formattingConfiguration = ModeRuntimeResolver.transcriptionFormattingConfiguration(mode: mode)

            if formattingConfiguration.isTextFormattingEnabled {
                text = ParagraphFormatter.format(text)
            }

            text = WordReplacementService.shared.applyReplacements(to: text, using: modelContext)
            let cleanedText = text
            try Task.checkCancellation()

            // Handle enhancement if enabled
            var transcription: Transcription

            let enhancementConfiguration = engine.enhancementService
                .flatMap { enhancementService in
                    enhancementService.getAIService().map { aiService in
                        ModeRuntimeResolver.currentEnhancementConfiguration(
                            mode: mode,
                            enhancementService: enhancementService,
                            aiService: aiService
                        )
                    }
                }

            if let enhancementService = engine.enhancementService,
                let enhancementConfiguration,
                enhancementConfiguration.isEnabled,
                enhancementService.isConfigured(for: enhancementConfiguration)
            {
                item.status = .processing(phase: .enhancing)
                let storedTimeout = UserDefaults.standard.integer(forKey: "EnhancementTimeoutSeconds")
                let baseTimeout = storedTimeout > 0 ? TimeInterval(storedTimeout) : 7
                let enhancementTimeout = EnhancementTimeoutPolicy.forFileTranscription(
                    text: cleanedText,
                    baseTimeout: baseTimeout
                )
                do {
                    let enhancementResult = try await FileTranscriptionEnhancer.enhance(
                        text: text,
                        timedSentences: timedSentences,
                        service: enhancementService,
                        configuration: enhancementConfiguration,
                        timeout: enhancementTimeout
                    )
                    transcription = Transcription(
                        text: cleanedText,
                        duration: duration,
                        enhancedText: enhancementResult.text,
                        audioFileURL: permanentURL.absoluteString,
                        transcriptionModelName: currentModel.displayName,
                        aiEnhancementModelName: enhancementConfiguration.modelName
                            ?? enhancementConfiguration.provider?.defaultModel,
                        promptName: enhancementResult.promptName,
                        transcriptionDuration: transcriptionDuration,
                        enhancementDuration: enhancementResult.duration,
                        aiRequestSystemMessage: enhancementResult.systemMessage,
                        aiRequestUserMessage: enhancementResult.userMessage,
                        aiPromptTokens: enhancementResult.usage?.promptTokens,
                        aiCompletionTokens: enhancementResult.usage?.completionTokens,
                        aiTotalTokens: enhancementResult.usage?.totalTokens,
                        aiCachedPromptTokens: enhancementResult.usage?.cachedPromptTokens,
                        aiCacheCreationTokens: enhancementResult.usage?.cacheCreationTokens,
                        modeName: modeMetadata.name,
                        modeEmoji: modeMetadata.emoji,
                        timedSentences: timedSentences,
                        enhancedTimedSentences: enhancementResult.timedSentences
                    )
                } catch {
                    let failureMessage = EnhancementFailureFormatter.message(for: error)
                    transcription = Transcription(
                        text: cleanedText,
                        duration: duration,
                        enhancedText: failureMessage,
                        audioFileURL: permanentURL.absoluteString,
                        transcriptionModelName: currentModel.displayName,
                        promptName: nil,
                        transcriptionDuration: transcriptionDuration,
                        modeName: modeMetadata.name,
                        modeEmoji: modeMetadata.emoji,
                        timedSentences: timedSentences
                    )
                }
            } else {
                transcription = Transcription(
                    text: cleanedText,
                    duration: duration,
                    audioFileURL: permanentURL.absoluteString,
                    transcriptionModelName: currentModel.displayName,
                    promptName: nil,
                    transcriptionDuration: transcriptionDuration,
                    modeName: modeMetadata.name,
                    modeEmoji: modeMetadata.emoji,
                    timedSentences: timedSentences
                )
            }

            modelContext.insert(transcription)
            try modelContext.save()
            NotificationCenter.default.post(name: .transcriptionCreated, object: transcription)
            NotificationCenter.default.post(name: .transcriptionCompleted, object: transcription)

            item.transcription = transcription
            item.status = .completed
            lastCompletedItemId = item.id

        } catch {
            if Task.isCancelled || error is CancellationError {
                item.status = .pending
            } else {
                logger.error("Transcription error: \(error, privacy: .public)")
                item.status = .failed(message: error.localizedDescription)
            }
        }

        await serviceRegistry.cleanup()
    }
}

enum TranscriptionError: Error, LocalizedError {
    case noModelSelected
    case transcriptionCancelled

    var errorDescription: String? {
        switch self {
        case .noModelSelected:
            return String(localized: "No transcription model selected")
        case .transcriptionCancelled:
            return String(localized: "Transcription was cancelled")
        }
    }
}
