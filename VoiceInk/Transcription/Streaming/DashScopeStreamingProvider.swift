import Foundation
import SwiftData

/// DashScope streaming provider that routes Qwen3 Realtime vs Qwen-Audio Fun-ASR by model name.
final class DashScopeStreamingProvider: StreamingTranscriptionProvider {
    private enum Backend {
        case qwen3(DashScopeStreamingClient)
        case qwenAudio(DashScopeQwenAudioStreamingClient)
    }

    private var backend: Backend?
    private var eventsContinuation: AsyncStream<StreamingTranscriptionEvent>.Continuation?
    private var forwardingTask: Task<Void, Never>?
    private let modelContext: ModelContext

    private(set) var transcriptionEvents: AsyncStream<StreamingTranscriptionEvent>

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
        var continuation: AsyncStream<StreamingTranscriptionEvent>.Continuation!
        transcriptionEvents = AsyncStream { continuation = $0 }
        eventsContinuation = continuation
    }

    deinit {
        forwardingTask?.cancel()
        eventsContinuation?.finish()
    }

    func connect(model: any TranscriptionModel, language: String?) async throws {
        guard let apiKey = APIKeyManager.shared.getAPIKey(forProvider: "Alibaba"), !apiKey.isEmpty else {
            throw StreamingTranscriptionError.missingAPIKey
        }

        forwardingTask?.cancel()
        if let existing = backend {
            switch existing {
            case .qwen3(let client):
                await client.disconnect()
            case .qwenAudio(let client):
                await client.disconnect()
            }
            backend = nil
        }

        let usesQwenAudio = DashScopeProvider.usesQwenAudioStreamingAPI(model.name)
        if usesQwenAudio {
            let client = DashScopeQwenAudioStreamingClient()
            backend = .qwenAudio(client)
            startEventForwarding(from: client)
            do {
                try await client.connect(
                    apiKey: apiKey,
                    model: DashScopeProvider.realtimeModelName(for: model.name),
                    language: language,
                    customVocabulary: getCustomVocabularyTerms()
                )
            } catch {
                forwardingTask?.cancel()
                forwardingTask = nil
                backend = nil
                throw error
            }
        } else {
            let client = DashScopeStreamingClient()
            backend = .qwen3(client)
            startEventForwarding(from: client)
            do {
                try await client.connect(
                    apiKey: apiKey,
                    model: DashScopeProvider.realtimeModelName(for: model.name),
                    language: language
                )
            } catch {
                forwardingTask?.cancel()
                forwardingTask = nil
                backend = nil
                throw error
            }
        }
    }

    func sendAudioChunk(_ data: Data) async throws {
        switch backend {
        case .qwen3(let client):
            try await client.sendAudioChunk(data)
        case .qwenAudio(let client):
            try await client.sendAudioChunk(data)
        case nil:
            throw StreamingTranscriptionError.notConnected
        }
    }

    func commit() async throws {
        switch backend {
        case .qwen3(let client):
            try await client.commit()
        case .qwenAudio(let client):
            try await client.commit()
        case nil:
            throw StreamingTranscriptionError.notConnected
        }
    }

    func disconnect() async {
        forwardingTask?.cancel()
        forwardingTask = nil
        switch backend {
        case .qwen3(let client):
            await client.disconnect()
        case .qwenAudio(let client):
            await client.disconnect()
        case nil:
            break
        }
        backend = nil
        eventsContinuation?.finish()
    }

    // MARK: - Private

    private func startEventForwarding(from client: DashScopeStreamingClient) {
        forwardingTask = Task { [weak self] in
            guard let self else { return }
            for await event in await client.transcriptionEvents {
                self.forward(event)
            }
        }
    }

    private func startEventForwarding(from client: DashScopeQwenAudioStreamingClient) {
        forwardingTask = Task { [weak self] in
            guard let self else { return }
            for await event in await client.transcriptionEvents {
                self.forward(event)
            }
        }
    }

    private func forward(_ event: DashScopeStreamingClientEvent) {
        switch event {
        case .sessionStarted:
            eventsContinuation?.yield(.sessionStarted)
        case .partial(let text):
            eventsContinuation?.yield(.partial(text: text))
        case .committed(let text):
            eventsContinuation?.yield(.committed(text: text))
        case .sessionFinished:
            eventsContinuation?.yield(.sessionFinished)
        case .error(let message):
            eventsContinuation?.yield(.error(StreamingTranscriptionError.serverError(message)))
        }
    }

    /// Loads unique dictionary terms for Qwen-Audio instant hotwords.
    private func getCustomVocabularyTerms() -> [String] {
        let descriptor = FetchDescriptor<VocabularyWord>(sortBy: [SortDescriptor(\.word)])
        guard let vocabularyWords = try? modelContext.fetch(descriptor) else {
            return []
        }
        var seen = Set<String>()
        var unique: [String] = []
        for word in vocabularyWords {
            let trimmed = word.word.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let key = trimmed.lowercased()
            if !seen.contains(key) {
                seen.insert(key)
                unique.append(trimmed)
            }
        }
        return Array(unique.prefix(50))
    }
}
