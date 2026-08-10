import Foundation

/// Events emitted by the DashScope realtime WebSocket client.
enum DashScopeStreamingClientEvent: Sendable {
    case sessionStarted
    case partial(text: String)
    case committed(text: String)
    case sessionFinished
    case error(String)
}

/// WebSocket client for `qwen3-asr-flash-realtime` (OpenAI Realtime-style protocol).
actor DashScopeStreamingClient {
    private var webSocketTask: URLSessionWebSocketTask?
    private var session: URLSession?
    private var receiveTask: Task<Void, Never>?
    private let eventsContinuation: AsyncStream<DashScopeStreamingClientEvent>.Continuation
    private var isConnected = false
    private var eventCounter = 0

    let transcriptionEvents: AsyncStream<DashScopeStreamingClientEvent>

    init() {
        var continuation: AsyncStream<DashScopeStreamingClientEvent>.Continuation!
        transcriptionEvents = AsyncStream { continuation = $0 }
        eventsContinuation = continuation
    }

    deinit {
        receiveTask?.cancel()
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        session?.invalidateAndCancel()
        eventsContinuation.finish()
    }

    /// Opens a realtime session and configures Manual (push-to-talk) turn detection.
    ///
    /// Does not send custom vocabulary text — Qwen3-ASR rejects text alongside audio input.
    func connect(
        apiKey: String,
        model: String,
        language: String?,
        region: DashScopeRegion = .current
    ) async throws {
        await closeSocket()

        guard var components = URLComponents(url: region.realtimeWebSocketBaseURL, resolvingAgainstBaseURL: false)
        else {
            throw StreamingTranscriptionError.connectionFailed("Invalid Alibaba realtime URL")
        }
        components.queryItems = [URLQueryItem(name: "model", value: model)]
        guard let url = components.url else {
            throw StreamingTranscriptionError.connectionFailed("Invalid Alibaba realtime URL")
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

        var transcriptionConfig: [String: Any] = [:]
        if let language, !language.isEmpty, language != "auto" {
            transcriptionConfig["language"] = language
        }

        // Manual mode: VoiceInk controls utterance boundaries via commit() on stop.
        var sessionConfig: [String: Any] = [
            "modalities": ["text"],
            "input_audio_format": "pcm",
            "sample_rate": 16000,
        ]
        if !transcriptionConfig.isEmpty {
            sessionConfig["input_audio_transcription"] = transcriptionConfig
        }

        // Encode turn_detection as JSON null for Manual mode.
        var payload: [String: Any] = [
            "event_id": nextEventID(),
            "type": "session.update",
        ]
        var sessionWithNullTurn = sessionConfig
        sessionWithNullTurn["turn_detection"] = NSNull()
        payload["session"] = sessionWithNullTurn

        try await sendJSON(payload)
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

    /// Commits the buffered audio and asks the server to finish the session.
    func commit() async throws {
        guard isConnected, webSocketTask != nil else {
            throw StreamingTranscriptionError.notConnected
        }
        try await sendJSON([
            "event_id": nextEventID(),
            "type": "input_audio_buffer.commit",
        ])
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
            if let transcript = extractTranscript(from: json), !transcript.isEmpty {
                eventsContinuation.yield(.partial(text: transcript))
            }

        case "conversation.item.input_audio_transcription.completed":
            if let transcript = extractTranscript(from: json), !transcript.isEmpty {
                eventsContinuation.yield(.committed(text: transcript))
            }

        case "error":
            let message =
                (json["error"] as? [String: Any])?["message"] as? String
                ?? json["message"] as? String
                ?? "Alibaba realtime error"
            eventsContinuation.yield(.error(message))

        case "session.finished":
            isConnected = false
            eventsContinuation.yield(.sessionFinished)

        default:
            break
        }
    }

    private func extractTranscript(from json: [String: Any]) -> String? {
        if let transcript = json["transcript"] as? String {
            return transcript
        }
        if let text = json["text"] as? String {
            return text
        }
        if let delta = json["delta"] as? String {
            return delta
        }
        return nil
    }
}
