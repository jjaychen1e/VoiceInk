import Foundation
import SwiftData
import os

/// Sendable source that bridges audio chunks from any thread into an AsyncStream.
private final class AudioChunkSource: @unchecked Sendable {
    let stream: AsyncStream<Data>
    private let continuation: AsyncStream<Data>.Continuation

    init() {
        let (stream, continuation) = AsyncStream.makeStream(
            of: Data.self,
            bufferingPolicy: .bufferingOldest(2_048)
        )
        self.stream = stream
        self.continuation = continuation
    }

    deinit {
        continuation.finish()
    }

    func send(_ data: Data) -> Bool {
        switch continuation.yield(data) {
        case .enqueued(_):
            return true
        case .dropped(_), .terminated:
            return false
        @unknown default:
            return false
        }
    }

    func finish() {
        continuation.finish()
    }
}

private final class StreamingMetrics: @unchecked Sendable {
    private let lock = NSLock()
    private var receivedChunks = 0
    private var receivedBytes = 0
    private var sentChunks = 0
    private var sentBytes = 0
    private var droppedChunks = 0
    private var droppedBytes = 0

    func reset() {
        lock.lock()
        receivedChunks = 0
        receivedBytes = 0
        sentChunks = 0
        sentBytes = 0
        droppedChunks = 0
        droppedBytes = 0
        lock.unlock()
    }

    func recordReceived(_ byteCount: Int) {
        lock.lock()
        receivedChunks += 1
        receivedBytes += byteCount
        lock.unlock()
    }

    func recordSent(_ byteCount: Int) {
        lock.lock()
        sentChunks += 1
        sentBytes += byteCount
        lock.unlock()
    }

    func recordDropped(_ byteCount: Int) {
        lock.lock()
        droppedChunks += 1
        droppedBytes += byteCount
        lock.unlock()
    }

    func snapshot() -> (
        receivedChunks: Int,
        receivedBytes: Int,
        sentChunks: Int,
        sentBytes: Int,
        droppedChunks: Int,
        droppedBytes: Int
    ) {
        lock.lock()
        defer { lock.unlock() }
        return (receivedChunks, receivedBytes, sentChunks, sentBytes, droppedChunks, droppedBytes)
    }
}

/// Lifecycle states for a streaming transcription session.
enum StreamingState {
    case idle
    case connecting
    case streaming
    case committing
    case done
    case failed
    case cancelled
}

enum StreamingStopResult {
    case finalized(text: String)
    case requiresBatchFallback
}

/// Manages a streaming transcription lifecycle: buffers audio chunks, sends them to the provider, and collects the final text.
@MainActor
class StreamingTranscriptionService {

    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "StreamingTranscriptionService")
    private var provider: StreamingTranscriptionProvider?
    private var sendTask: Task<Void, Never>?
    private var eventConsumerTask: Task<Void, Never>?
    private let chunkSource = AudioChunkSource()
    private var state: StreamingState = .idle
    private var committedSegments: [String] = []
    private let modelContext: ModelContext
    private let fluidAudioService: FluidAudioTranscriptionService?
    private var onPartialTranscript: ((String) -> Void)?
    private let metrics = StreamingMetrics()
    private var stopStartedAt: Date?
    private var firstPartialLogged = false
    private var firstCommitLogged = false
    /// Completes stop wait after a quiet period of commits when the provider never sends sessionFinished.
    private var commitDebounceTask: Task<Void, Never>?

    init(
        modelContext: ModelContext, fluidAudioService: FluidAudioTranscriptionService? = nil,
        onPartialTranscript: ((String) -> Void)? = nil
    ) {
        self.modelContext = modelContext
        self.fluidAudioService = fluidAudioService
        self.onPartialTranscript = onPartialTranscript
    }

    deinit {
        onPartialTranscript = nil
        sendTask?.cancel()
        eventConsumerTask?.cancel()
        chunkSource.finish()
        commitSignal?.finish()
    }

    /// Signal used to notify `waitForFinalization` when stop can complete.
    private var commitSignal: AsyncStream<Void>.Continuation?

    /// Whether the streaming connection is fully established and actively sending.
    var isActive: Bool { state == .streaming || state == .committing }

    /// Start a streaming transcription session for the given model.
    func startStreaming(model: any TranscriptionModel, context: TranscriptionRequestContext) async throws {
        let start = Date()
        state = .connecting
        committedSegments = []
        metrics.reset()
        firstPartialLogged = false
        firstCommitLogged = false

        let provider = createProvider(for: model)
        self.provider = provider

        let selectedLanguage = context.language ?? "auto"
        logger.notice(
            "Streaming start requested model=\(model.displayName, privacy: .public) language=\(selectedLanguage, privacy: .public)"
        )

        try await provider.connect(model: model, language: selectedLanguage)

        // If cancel() was called while we were awaiting the connection, tear down immediately.
        if state == .cancelled {
            await provider.disconnect()
            self.provider = nil
            return
        }

        state = .streaming
        startSendLoop()
        startEventConsumer()

        logger.notice(
            "Streaming connected model=\(model.displayName, privacy: .public) elapsed=\(Date().timeIntervalSince(start), format: .fixed(precision: 3), privacy: .public)s"
        )
    }

    /// Buffers an audio chunk for sending. Safe to call from the recorder processing queue.
    nonisolated func sendAudioChunk(_ data: Data) {
        metrics.recordReceived(data.count)
        if !chunkSource.send(data) {
            metrics.recordDropped(data.count)
        }
    }

    /// Sends precomputed PCM16 audio for file transcription without dropping buffered mic chunks.
    ///
    /// Unlike `sendAudioChunk`, this awaits provider delivery so large files are not truncated by
    /// the realtime mic buffer policy.
    /// - Parameters:
    ///   - data: Little-endian PCM16 mono @ 16 kHz.
    ///   - chunkByteCount: Bytes per WebSocket frame (default ~100 ms of audio).
    ///   - realtimePacing: When true, sleeps to match audio duration so VAD/streaming servers keep up.
    func streamPCM16Audio(
        _ data: Data,
        chunkByteCount: Int = 3_200,
        realtimePacing: Bool = false
    ) async throws {
        guard let provider = provider, state == .streaming else {
            throw StreamingTranscriptionError.notConnected
        }

        let bytesPerSecond = 16_000 * MemoryLayout<Int16>.size
        let alignedCount = data.count - (data.count % MemoryLayout<Int16>.size)
        var offset = 0
        while offset < alignedCount {
            try Task.checkCancellation()
            var end = min(offset + chunkByteCount, alignedCount)
            if (end - offset) % MemoryLayout<Int16>.size != 0 {
                end -= 1
            }
            guard end > offset else { break }

            let chunk = data.subdata(in: offset..<end)
            metrics.recordReceived(chunk.count)
            let sendStarted = ContinuousClock.now
            try await provider.sendAudioChunk(chunk)
            metrics.recordSent(chunk.count)

            if realtimePacing {
                let chunkSeconds = Double(chunk.count) / Double(bytesPerSecond)
                let elapsed = sendStarted.duration(to: .now)
                let elapsedSeconds =
                    Double(elapsed.components.seconds)
                    + Double(elapsed.components.attoseconds) / 1_000_000_000_000_000_000
                let remaining = chunkSeconds - elapsedSeconds
                if remaining > 0.001 {
                    try await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
                }
            }

            offset = end
        }
    }

    /// Stops streaming and follows the provider's requested finalization path.
    func stopAndFinalize() async throws -> StreamingStopResult {
        guard let provider = provider, state == .streaming else {
            throw StreamingTranscriptionError.notConnected
        }

        if provider.stopDisposition == .useBatchFallback {
            logger.notice("Streaming provider requested full batch fallback")
            state = .done
            await cleanupStreaming()
            return .requiresBatchFallback
        }

        state = .committing
        stopStartedAt = Date()
        let beforeDrain = metrics.snapshot()
        logger.notice(
            "Streaming stop requested receivedChunks=\(beforeDrain.receivedChunks, privacy: .public) sentChunks=\(beforeDrain.sentChunks, privacy: .public) droppedChunks=\(beforeDrain.droppedChunks, privacy: .public) receivedBytes=\(beforeDrain.receivedBytes, privacy: .public) sentBytes=\(beforeDrain.sentBytes, privacy: .public) droppedBytes=\(beforeDrain.droppedBytes, privacy: .public)"
        )

        // Finish the chunk source so the send loop drains remaining chunks and exits naturally.
        // Segments may still arrive here; do not arm the completion signal yet or a mid-drain
        // committed event could finish the wait before finish-task / sessionFinished.
        await drainRemainingChunks()

        // Arm the completion signal before commit/finish-task so the final response is not lost.
        let (signalStream, signalContinuation) = AsyncStream.makeStream(of: Void.self)
        self.commitSignal = signalContinuation

        // Send commit/finish-task to finalize any remaining audio.
        do {
            try await provider.commit()
        } catch {
            commitSignal?.finish()
            commitSignal = nil
            logger.error("Failed to send commit: \(error, privacy: .public)")
            state = .failed
            await cleanupStreaming()
            throw error
        }

        // Wait for a post-stop committed result and/or sessionFinished (or timeout).
        let finalText = await waitForFinalization(signalStream: signalStream)
        if let stopStartedAt {
            logger.notice(
                "Streaming stop completed elapsed=\(Date().timeIntervalSince(stopStartedAt), format: .fixed(precision: 3), privacy: .public)s finalChars=\(finalText.count, privacy: .public)"
            )
        }

        state = .done
        await cleanupStreaming()

        return .finalized(text: finalText)
    }

    /// Cancels the streaming session without waiting for results.
    func cancel() {
        state = .cancelled
        onPartialTranscript = nil
        eventConsumerTask?.cancel()
        eventConsumerTask = nil
        sendTask?.cancel()
        sendTask = nil
        chunkSource.finish()

        // Clean up commit signal if waiting
        commitDebounceTask?.cancel()
        commitDebounceTask = nil
        commitSignal?.finish()
        commitSignal = nil

        let providerToDisconnect = provider
        provider = nil

        Task {
            await providerToDisconnect?.disconnect()
        }

        committedSegments = []
        logger.notice("Streaming cancelled")
    }

    // MARK: - Private

    private func createProvider(for model: any TranscriptionModel) -> StreamingTranscriptionProvider {
        if model.provider == .fluidAudio {
            if FluidAudioModelManager.isNemotronModel(named: model.name) {
                return FluidAudioNemotronStreamingProvider()
            }

            if FluidAudioModelManager.isParakeetUnifiedModel(named: model.name) {
                return FluidAudioUnifiedStreamingProvider()
            }

            guard let fluidAudioService else {
                fatalError(
                    "FluidAudioTranscriptionService required for FluidAudio streaming. Ensure it is passed to StreamingTranscriptionService."
                )
            }
            return FluidAudioStreamingProvider(fluidAudioService: fluidAudioService)
        }
        guard let cloudProvider = CloudProviderRegistry.provider(for: model.provider),
            let streamingProvider = cloudProvider.makeStreamingProvider(modelContext: modelContext)
        else {
            fatalError(
                "Unsupported streaming provider: \(model.provider). Check shouldUseRealtimeTranscription() before calling startStreaming()."
            )
        }
        return streamingProvider
    }

    /// Consumes audio chunks from the AsyncStream and sends them to the provider.
    private func startSendLoop() {
        let source = chunkSource
        let provider = provider
        let metrics = metrics

        sendTask = Task.detached { [weak self] in
            for await chunk in source.stream {
                do {
                    try await provider?.sendAudioChunk(chunk)
                    metrics.recordSent(chunk.count)
                } catch {
                    let desc = error.localizedDescription
                    await MainActor.run {
                        self?.logger.error("Failed to send audio chunk: \(desc, privacy: .public)")
                    }
                }
            }
        }
    }

    /// Finishes the chunk source and waits for the send loop to process all remaining buffered chunks.
    private func drainRemainingChunks() async {
        let start = Date()
        chunkSource.finish()
        await sendTask?.value
        sendTask = nil
        let snapshot = metrics.snapshot()
        logger.notice(
            "Streaming drain finished elapsed=\(Date().timeIntervalSince(start), format: .fixed(precision: 3), privacy: .public)s receivedChunks=\(snapshot.receivedChunks, privacy: .public) sentChunks=\(snapshot.sentChunks, privacy: .public) droppedChunks=\(snapshot.droppedChunks, privacy: .public) receivedBytes=\(snapshot.receivedBytes, privacy: .public) sentBytes=\(snapshot.sentBytes, privacy: .public) droppedBytes=\(snapshot.droppedBytes, privacy: .public)"
        )
    }

    /// Consumes transcription events throughout the session, accumulating committed segments.
    private func startEventConsumer() {
        guard let provider = provider else { return }
        let events = provider.transcriptionEvents

        eventConsumerTask = Task.detached { [weak self] in
            for await event in events {
                guard let self = self else { break }
                switch event {
                case .committed(let text):
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    await MainActor.run {
                        if !self.firstCommitLogged {
                            self.firstCommitLogged = true
                            let elapsed = self.stopStartedAt.map { Date().timeIntervalSince($0) } ?? 0
                            self.logger.notice(
                                "Streaming first committed event chars=\(trimmed.count, privacy: .public) stopElapsed=\(elapsed, format: .fixed(precision: 3), privacy: .public)s"
                            )
                        }
                        if !trimmed.isEmpty {
                            self.committedSegments.append(trimmed)
                        }
                        // Refresh the live preview so it keeps showing the full running transcript
                        // after a commit (instead of resetting to empty until the next partial).
                        if self.state == .streaming {
                            self.onPartialTranscript?(self.committedSegments.joined(separator: " "))
                        }
                        if self.state == .committing {
                            // Do not finish on the first sentence_end — VAD models emit many
                            // commits per file. Debounce until results go quiet, or wait for
                            // sessionFinished (preferred).
                            self.scheduleCommitDebounce()
                        }
                    }
                case .partial(let text):
                    await MainActor.run {
                        if !self.firstPartialLogged {
                            self.firstPartialLogged = true
                            self.logger.notice("Streaming first partial event chars=\(text.count, privacy: .public)")
                        }
                        if self.state == .streaming {
                            let prefix = self.committedSegments.joined(separator: " ")
                            let display: String
                            if prefix.isEmpty {
                                display = text
                            } else if text.hasPrefix(prefix) || text.hasPrefix(prefix + " ") {
                                // Provider already sends cumulative partials (e.g. FluidAudio fullText).
                                display = text
                            } else {
                                display = prefix + " " + text
                            }
                            self.onPartialTranscript?(display)
                        }
                    }
                case .sessionStarted:
                    break
                case .sessionFinished:
                    await MainActor.run {
                        if self.state == .committing {
                            let elapsed = self.stopStartedAt.map { Date().timeIntervalSince($0) } ?? 0
                            self.logger.notice(
                                "Streaming sessionFinished stopElapsed=\(elapsed, format: .fixed(precision: 3), privacy: .public)s segments=\(self.committedSegments.count, privacy: .public)"
                            )
                            self.commitDebounceTask?.cancel()
                            self.commitDebounceTask = nil
                            self.commitSignal?.yield()
                        }
                    }
                case .error(let error):
                    await MainActor.run {
                        self.logger.error("Streaming event error: \(error, privacy: .public)")
                    }
                }
            }
        }
    }

    /// After stop, waits for a quiet period of commits when the provider never sends sessionFinished.
    private func scheduleCommitDebounce() {
        commitDebounceTask?.cancel()
        commitDebounceTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard !Task.isCancelled, state == .committing else { return }
            logger.notice(
                "Streaming commit debounce fired segments=\(self.committedSegments.count, privacy: .public)"
            )
            commitSignal?.yield()
        }
    }

    /// Waits for stop finalization: sessionFinished (preferred) or a quiet commit period, with timeout.
    private func waitForFinalization(signalStream: AsyncStream<Void>) async -> String {
        // Race: wait for completion signal vs timeout
        let receivedInTime = await withTaskGroup(of: Bool.self) { group in
            group.addTask { @MainActor in
                for await _ in signalStream {
                    return true
                }
                return false
            }

            group.addTask {
                try? await Task.sleep(nanoseconds: 30_000_000_000)  // 30 seconds
                return false
            }

            let result = await group.next() ?? false
            group.cancelAll()
            return result
        }
        logger.notice(
            "Streaming final wait finished received=\(receivedInTime, privacy: .public) segments=\(self.committedSegments.count, privacy: .public)"
        )

        // Clean up the signal
        commitDebounceTask?.cancel()
        commitDebounceTask = nil
        commitSignal?.finish()
        commitSignal = nil

        if !receivedInTime && committedSegments.isEmpty {
            logger.warning("No transcript received from streaming")
        }

        return committedSegments.isEmpty ? "" : committedSegments.joined(separator: " ")
    }

    private func cleanupStreaming() async {
        onPartialTranscript = nil
        commitDebounceTask?.cancel()
        commitDebounceTask = nil
        eventConsumerTask?.cancel()
        eventConsumerTask = nil
        sendTask?.cancel()
        sendTask = nil
        chunkSource.finish()
        commitSignal?.finish()
        commitSignal = nil
        await provider?.disconnect()
        provider = nil
        state = .idle
        committedSegments = []
    }
}
