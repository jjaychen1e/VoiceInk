import Foundation

/// Fun-ASR duplex WebSocket client for `qwen-audio-3.0-asr-flash-streaming`.
///
/// Protocol differs from `qwen3-asr-flash-realtime`:
/// connect → `run-task` → wait `task-started` → binary PCM frames → `finish-task`.
actor DashScopeQwenAudioStreamingClient {
    private var webSocketTask: URLSessionWebSocketTask?
    private var session: URLSession?
    private var receiveTask: Task<Void, Never>?
    private let eventsContinuation: AsyncStream<DashScopeStreamingClientEvent>.Continuation
    private var isConnected = false
    private var isTaskStarted = false
    private var taskID = ""
    private var lastPartialText = ""
    private var taskStartedContinuation: CheckedContinuation<Void, Error>?

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

    /// Opens an inference WebSocket and starts a recognition task.
    func connect(
        apiKey: String,
        model: String,
        language: String?,
        customVocabulary: [String],
        region: DashScopeRegion = .current
    ) async throws {
        await closeSocket()

        let url = region.inferenceWebSocketURL
        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 30

        let urlSession = URLSession(configuration: .default)
        session = urlSession
        let task = urlSession.webSocketTask(with: request)
        webSocketTask = task
        task.resume()

        isConnected = true
        isTaskStarted = false
        lastPartialText = ""
        taskID = UUID().uuidString
        startReceiveLoop()

        var parameters: [String: Any] = [
            "format": "pcm",
            "sample_rate": 16000,
        ]
        if let languageHint = languageHint(from: language) {
            parameters["language_hints"] = [languageHint]
        }
        if let vocabulary = vocabularyDictionary(from: customVocabulary) {
            parameters["vocabulary"] = vocabulary
        }

        let runTask: [String: Any] = [
            "header": [
                "action": "run-task",
                "task_id": taskID,
                "streaming": "duplex",
            ],
            "payload": [
                "task_group": "audio",
                "task": "asr",
                "function": "recognition",
                "model": model,
                "parameters": parameters,
                "input": [:] as [String: Any],
            ],
        ]

        try await sendJSON(runTask)

        // Wait until the server accepts the task before streaming audio.
        try await waitForTaskStarted(timeout: 15)

        eventsContinuation.yield(.sessionStarted)
    }

    /// Sends a raw PCM16 / 16 kHz / mono audio chunk as a binary WebSocket frame.
    func sendAudioChunk(_ data: Data) async throws {
        guard isConnected, isTaskStarted, let task = webSocketTask else {
            throw StreamingTranscriptionError.notConnected
        }
        try await task.send(.data(data))
    }

    /// Signals that all audio has been sent and waits for final results via the receive loop.
    func commit() async throws {
        guard isConnected, webSocketTask != nil else {
            throw StreamingTranscriptionError.notConnected
        }
        let finishTask: [String: Any] = [
            "header": [
                "action": "finish-task",
                "task_id": taskID,
                "streaming": "duplex",
            ],
            "payload": [
                "input": [:] as [String: Any],
            ],
        ]
        try await sendJSON(finishTask)
    }

    /// Closes the WebSocket without finishing the long-lived event stream.
    func disconnect() async {
        await closeSocket()
    }

    // MARK: - Private

    /// Suspends until `task-started`, or fails after `timeout` seconds.
    private func waitForTaskStarted(timeout: TimeInterval) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            taskStartedContinuation = continuation
            Task {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                await self.failTaskStartedIfNeeded(
                    StreamingTranscriptionError.connectionFailed(
                        "Timed out waiting for Alibaba streaming task to start")
                )
            }
        }
    }
    private func closeSocket() async {
        if let continuation = taskStartedContinuation {
            taskStartedContinuation = nil
            continuation.resume(throwing: StreamingTranscriptionError.connectionFailed("Connection closed before task started"))
        }
        receiveTask?.cancel()
        receiveTask = nil
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        session?.invalidateAndCancel()
        session = nil
        isConnected = false
        isTaskStarted = false
        lastPartialText = ""
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
                        self.failTaskStartedIfNeeded(error)
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
                    let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                else {
                    continue
                }

                self.handleServerMessage(json)
            }
        }
    }

    private func handleServerMessage(_ json: [String: Any]) {
        let header = json["header"] as? [String: Any]
        let event = header?["event"] as? String
        guard let event else { return }

        switch event {
        case "task-started":
            isTaskStarted = true
            if let continuation = taskStartedContinuation {
                taskStartedContinuation = nil
                continuation.resume()
            }

        case "result-generated":
            guard let sentence = ((json["payload"] as? [String: Any])?["output"] as? [String: Any])?["sentence"]
                as? [String: Any]
            else {
                return
            }
            if sentence["heartbeat"] as? Bool == true {
                return
            }
            let text = (sentence["text"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !text.isEmpty else { return }

            let sentenceEnd = sentence["sentence_end"] as? Bool ?? false
            if sentenceEnd {
                lastPartialText = ""
                eventsContinuation.yield(.committed(text: text))
            } else {
                lastPartialText = text
                eventsContinuation.yield(.partial(text: text))
            }

        case "task-finished":
            // Flush any in-flight partial that never received sentence_end.
            let pending = lastPartialText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !pending.isEmpty {
                lastPartialText = ""
                eventsContinuation.yield(.committed(text: pending))
            }
            isConnected = false
            isTaskStarted = false

        case "task-failed":
            let message =
                header?["error_message"] as? String
                ?? "Alibaba Qwen-Audio streaming task failed"
            failTaskStartedIfNeeded(
                StreamingTranscriptionError.serverError(message)
            )
            eventsContinuation.yield(.error(message))
            isConnected = false
            isTaskStarted = false

        default:
            break
        }
    }

    private func failTaskStartedIfNeeded(_ error: Error) {
        if let continuation = taskStartedContinuation {
            taskStartedContinuation = nil
            continuation.resume(throwing: error)
        }
    }

    /// Maps a VoiceInk language code to a Qwen-Audio language_hints value.
    private func languageHint(from language: String?) -> String? {
        guard let language, !language.isEmpty, language != "auto" else {
            return nil
        }
        if language == "fil" {
            return "tl"
        }
        return language
    }

    /// Builds an instant-hotword map with weight 5 (max non-super weight).
    private func vocabularyDictionary(from terms: [String]) -> [String: Int]? {
        var vocabulary: [String: Int] = [:]
        for term in terms {
            let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            vocabulary[trimmed] = 5
            if vocabulary.count >= 50 { break }
        }
        return vocabulary.isEmpty ? nil : vocabulary
    }
}
