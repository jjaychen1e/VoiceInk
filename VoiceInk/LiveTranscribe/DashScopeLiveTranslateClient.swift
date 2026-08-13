import Foundation

/// Events emitted by the DashScope LiveTranslate realtime WebSocket client.
enum DashScopeLiveTranslateClientEvent: Sendable {
    case sessionStarted
    case sourcePartial(text: String)
    case sourceCommitted(text: String)
    case translationPartial(text: String)
    case translationCommitted(text: String)
    case sessionFinished
    case error(String)
}

/// WebSocket client for `qwen3.5-livetranslate-flash-realtime` (text-only captions).
actor DashScopeLiveTranslateClient {
    static let modelName = "qwen3.5-livetranslate-flash-realtime"

    private var webSocketTask: URLSessionWebSocketTask?
    private var session: URLSession?
    private var receiveTask: Task<Void, Never>?
    private let eventsContinuation: AsyncStream<DashScopeLiveTranslateClientEvent>.Continuation
    private var isConnected = false
    private var eventCounter = 0

    let events: AsyncStream<DashScopeLiveTranslateClientEvent>

    init() {
        var continuation: AsyncStream<DashScopeLiveTranslateClientEvent>.Continuation!
        events = AsyncStream { continuation = $0 }
        eventsContinuation = continuation
    }

    deinit {
        receiveTask?.cancel()
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        session?.invalidateAndCancel()
        eventsContinuation.finish()
    }

    /// Opens a LiveTranslate session with text-only output and optional source transcription.
    ///
    /// - Parameter corpusText: Biasing text for source ASR (`input_audio_transcription.corpus.text`).
    /// - Parameter translationPhrases: Source→target hotword map for `translation.corpus.phrases`.
    func connect(
        apiKey: String,
        sourceLanguage: String,
        targetLanguage: String,
        region: DashScopeRegion = .current,
        corpusText: String? = nil,
        translationPhrases: [String: String] = [:]
    ) async throws {
        await closeSocket()

        guard var components = URLComponents(url: region.realtimeWebSocketBaseURL, resolvingAgainstBaseURL: false)
        else {
            throw StreamingTranscriptionError.connectionFailed("Invalid Alibaba LiveTranslate URL")
        }
        components.queryItems = [URLQueryItem(name: "model", value: Self.modelName)]
        guard let url = components.url else {
            throw StreamingTranscriptionError.connectionFailed("Invalid Alibaba LiveTranslate URL")
        }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 30

        let urlSession = URLSession(configuration: .default)
        session = urlSession
        let task = urlSession.webSocketTask(with: request)
        webSocketTask = task
        task.resume()

        isConnected = true
        startReceiveLoop()

        var transcriptionConfig: [String: Any] = [
            "model": "qwen3-asr-flash-realtime",
        ]
        if !sourceLanguage.isEmpty, sourceLanguage != "auto" {
            transcriptionConfig["language"] = sourceLanguage
        }
        let trimmedCorpus = corpusText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmedCorpus.isEmpty {
            transcriptionConfig["corpus"] = ["text": trimmedCorpus]
        }

        var translationConfig: [String: Any] = [
            "language": targetLanguage,
        ]
        if !translationPhrases.isEmpty {
            translationConfig["corpus"] = [
                "phrases": translationPhrases,
            ]
        }

        let sessionConfig: [String: Any] = [
            "modalities": ["text"],
            "input_audio_format": "pcm",
            "sample_rate": 16000,
            "input_audio_transcription": transcriptionConfig,
            "translation": translationConfig,
        ]

        try await sendJSON([
            "event_id": nextEventID(),
            "type": "session.update",
            "session": sessionConfig,
        ])
        eventsContinuation.yield(.sessionStarted)
    }

    /// Sends a raw PCM16 / 16 kHz / mono audio chunk as base64.
    func sendAudioChunk(_ data: Data) async throws {
        guard isConnected, webSocketTask != nil else {
            throw StreamingTranscriptionError.notConnected
        }
        try await sendJSON([
            "event_id": nextEventID(),
            "type": "input_audio_buffer.append",
            "audio": data.base64EncodedString(),
        ])
    }

    /// Asks the server to finish the session cleanly before disconnecting.
    func finish() async throws {
        guard isConnected, webSocketTask != nil else {
            throw StreamingTranscriptionError.notConnected
        }
        try await sendJSON([
            "event_id": nextEventID(),
            "type": "session.finish",
        ])
    }

    /// Closes the WebSocket without finishing the long-lived event stream.
    func disconnect() async {
        await closeSocket()
    }

    // MARK: - Private

    private func closeSocket() async {
        receiveTask?.cancel()
        receiveTask = nil
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        session?.invalidateAndCancel()
        session = nil
        isConnected = false
    }

    private func nextEventID() -> String {
        eventCounter += 1
        return "event_\(eventCounter)_\(UUID().uuidString.prefix(8))"
    }

    private func sendJSON(_ payload: [String: Any]) async throws {
        guard let task = webSocketTask else {
            throw StreamingTranscriptionError.notConnected
        }
        let data = try JSONSerialization.data(withJSONObject: payload)
        guard let text = String(data: data, encoding: .utf8) else {
            throw StreamingTranscriptionError.serverError("Failed to encode WebSocket payload")
        }
        try await task.send(.string(text))
    }

    private func startReceiveLoop() {
        receiveTask = Task {
            while !Task.isCancelled {
                let message: URLSessionWebSocketTask.Message
                do {
                    guard let task = self.webSocketTask else { break }
                    message = try await task.receive()
                } catch {
                    if !Task.isCancelled {
                        self.eventsContinuation.yield(.error(error.localizedDescription))
                    }
                    break
                }

                let text: String?
                switch message {
                case .string(let value):
                    text = value
                case .data(let data):
                    text = String(data: data, encoding: .utf8)
                @unknown default:
                    text = nil
                }

                guard let text, let data = text.data(using: .utf8),
                    let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                    let type = json["type"] as? String
                else {
                    continue
                }

                self.handleServerEvent(type: type, json: json)
            }
        }
    }

    private func handleServerEvent(type: String, json: [String: Any]) {
        switch type {
        case "conversation.item.input_audio_transcription.text",
            "conversation.item.input_audio_transcription.delta":
            // Qwen-ASR: `text` is finalized prefix, `stash` is revisable draft. Always show text+stash.
            if let partial = Self.combinedPartialTranscript(from: json), !partial.isEmpty {
                eventsContinuation.yield(.sourcePartial(text: partial))
            }

        case "conversation.item.input_audio_transcription.completed":
            if let transcript = (json["transcript"] as? String) ?? (json["text"] as? String),
                !transcript.isEmpty
            {
                eventsContinuation.yield(.sourceCommitted(text: transcript))
            }

        case "response.text.text":
            // Confirmed text + optional tentative stash for text-only LiveTranslate.
            if let partial = Self.combinedPartialTranscript(from: json), !partial.isEmpty {
                eventsContinuation.yield(.translationPartial(text: partial))
            }

        case "response.text.done":
            if let text = json["text"] as? String, !text.isEmpty {
                eventsContinuation.yield(.translationCommitted(text: text))
            }

        case "response.audio_transcript.text":
            if let partial = Self.combinedPartialTranscript(from: json), !partial.isEmpty {
                eventsContinuation.yield(.translationPartial(text: partial))
            }

        case "response.audio_transcript.done":
            if let text = (json["transcript"] as? String) ?? (json["text"] as? String), !text.isEmpty {
                eventsContinuation.yield(.translationCommitted(text: text))
            }

        case "error":
            let message =
                (json["error"] as? [String: Any])?["message"] as? String
                ?? json["message"] as? String
                ?? "Alibaba LiveTranslate error"
            eventsContinuation.yield(.error(message))

        case "session.finished":
            isConnected = false
            eventsContinuation.yield(.sessionFinished)

        default:
            break
        }
    }

    /// Builds the live preview string from confirmed `text`/`transcript` plus revisable `stash`.
    private static func combinedPartialTranscript(from json: [String: Any]) -> String? {
        let confirmed =
            (json["text"] as? String)
            ?? (json["transcript"] as? String)
            ?? ""
        let stash = json["stash"] as? String ?? ""
        let combined = confirmed + stash
        if !combined.isEmpty {
            return combined
        }
        if let delta = json["delta"] as? String, !delta.isEmpty {
            return delta
        }
        return nil
    }
}
