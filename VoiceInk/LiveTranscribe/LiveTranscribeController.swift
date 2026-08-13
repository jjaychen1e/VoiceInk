import AppKit
import Foundation
import OSLog
import SwiftData
import SwiftUI

enum LiveTranscribeSettingsKeys {
    static let isTranslationEnabled = "LiveTranscribeTranslationEnabled"
    static let sourceLanguage = "LiveTranscribeSourceLanguage"
    static let targetLanguage = "LiveTranscribeTargetLanguage"
}

/// Owns the Live Transcribe session: system-audio capture, ASR / LiveTranslate routing, and HUD.
@MainActor
final class LiveTranscribeController: ObservableObject {
    static let shared = LiveTranscribeController()

    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "LiveTranscribe")
    private let capture = SystemAudioCapture()
    private let windowManager = LiveTranscribeWindowManager()

    @Published private(set) var isRunning = false
    @Published private(set) var sourceText = ""
    @Published private(set) var translatedText = ""
    @Published private(set) var hasScreenRecordingPermission = CGPreflightScreenCaptureAccess()
    /// True once at least one non-silent system-audio chunk has been forwarded.
    @Published private(set) var isReceivingAudio = false
    /// How many Dictionary terms / phrase pairs were applied to the current session corpus.
    @Published private(set) var activeCorpusTermCount = 0
    @Published private(set) var activeCorpusPhraseCount = 0
    @Published var errorMessage: String?
    @Published var statusMessage: String?

    @Published var isTranslationEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isTranslationEnabled, forKey: LiveTranscribeSettingsKeys.isTranslationEnabled)
        }
    }

    @Published var sourceLanguage: String {
        didSet {
            UserDefaults.standard.set(sourceLanguage, forKey: LiveTranscribeSettingsKeys.sourceLanguage)
        }
    }

    @Published var targetLanguage: String {
        didSet {
            UserDefaults.standard.set(targetLanguage, forKey: LiveTranscribeSettingsKeys.targetLanguage)
        }
    }

    /// True while hot-swapping ASR ↔ LiveTranslate during an active session.
    @Published private(set) var isSwitchingPipeline = false
    /// Session stays open (HUD visible) but capture + realtime clients are disconnected.
    @Published private(set) var isPaused = false

    private var asrClient: DashScopeStreamingClient?
    private var translateClient: DashScopeLiveTranslateClient?
    private var eventTask: Task<Void, Never>?
    private var sendTask: Task<Void, Never>?
    private var audioChunkContinuation: AsyncStream<Data>.Continuation?
    private var committedSourceSegments: [String] = []
    private var committedTranslationSegments: [String] = []
    private var currentSourcePartial = ""
    private var currentTranslationPartial = ""
    private var forwardedChunkCount = 0
    /// Corpus captured at session start; reused when toggling translation mid-session.
    private var sessionCorpus = LiveTranscribeCorpus.Payload(text: "", phrases: [:])

    /// Soft cap for HUD transcript length — keeps SwiftUI Text / selection responsive.
    private static let maxDisplayCharacters = 1_000
    /// Soft cap on committed utterances kept in memory for each stream.
    private static let maxCommittedSegments = 10

    private init() {
        let defaults = UserDefaults.standard
        isTranslationEnabled = defaults.bool(forKey: LiveTranscribeSettingsKeys.isTranslationEnabled)
        sourceLanguage = defaults.string(forKey: LiveTranscribeSettingsKeys.sourceLanguage) ?? "en"
        targetLanguage = defaults.string(forKey: LiveTranscribeSettingsKeys.targetLanguage) ?? "zh"
        windowManager.bind(to: self)
    }

    /// Whether an Alibaba API key is configured for DashScope realtime.
    var hasAlibabaAPIKey: Bool {
        guard let key = APIKeyManager.shared.getAPIKey(forProvider: "Alibaba") else { return false }
        return !key.isEmpty
    }

    /// Placeholder shown in the HUD while waiting for transcript text.
    var listeningPlaceholder: String {
        if let errorMessage, !errorMessage.isEmpty {
            return errorMessage
        }
        if isPaused {
            return String(localized: "Paused")
        }
        if isReceivingAudio {
            return String(localized: "Hearing audio… waiting for transcript")
        }
        return String(localized: "Listening…")
    }

    /// Placeholder shown in the translation column when there is no translated text yet.
    var translationPlaceholder: String {
        if isPaused {
            return String(localized: "Paused")
        }
        if let errorMessage, !errorMessage.isEmpty {
            return errorMessage
        }
        return String(localized: "Translating…")
    }

    /// Re-reads Screen Recording permission (call after Settings / request prompts).
    func refreshPermissions() {
        hasScreenRecordingPermission = CGPreflightScreenCaptureAccess()
    }

    /// Starts system-audio capture and the selected realtime pipeline.
    ///
    /// - Parameter modelContext: SwiftData context used to load Dictionary corpus entries.
    func start(modelContext: ModelContext? = nil) async {
        guard !isRunning else { return }

        errorMessage = nil
        statusMessage = nil
        isReceivingAudio = false
        isPaused = false
        activeCorpusTermCount = 0
        activeCorpusPhraseCount = 0
        forwardedChunkCount = 0
        refreshPermissions()

        guard hasAlibabaAPIKey else {
            errorMessage = String(localized: "Add an Alibaba (DashScope) API key in AI Models first.")
            return
        }

        guard let apiKey = APIKeyManager.shared.getAPIKey(forProvider: "Alibaba"), !apiKey.isEmpty else {
            errorMessage = String(localized: "Add an Alibaba (DashScope) API key in AI Models first.")
            return
        }

        resetTranscriptBuffers()
        let corpus = LiveTranscribeCorpus.load(from: modelContext)
        sessionCorpus = corpus
        activeCorpusTermCount = corpus.text.isEmpty ? 0 : corpus.text.split(separator: ",").count
        activeCorpusPhraseCount = corpus.phrases.count

        do {
            if isTranslationEnabled {
                try await startTranslateSession(apiKey: apiKey, corpus: corpus)
            } else {
                try await startASRSession(apiKey: apiKey, corpus: corpus)
            }

            startAudioForwarder()

            // Accept chunks before capture starts so early frames are not dropped.
            isRunning = true

            capture.onAudioChunk = { [weak self] data in
                guard let self, self.isRunning, !self.isPaused else { return }
                self.audioChunkContinuation?.yield(data)
            }

            try await capture.start()

            statusMessage = isTranslationEnabled
                ? String(localized: "Live translating…")
                : String(localized: "Live transcribing…")
            windowManager.show()
            logger.notice(
                "Live Transcribe started translation=\(self.isTranslationEnabled, privacy: .public) corpusTerms=\(self.activeCorpusTermCount, privacy: .public) phrases=\(self.activeCorpusPhraseCount, privacy: .public)"
            )
        } catch {
            await teardownSession()
            isRunning = false
            errorMessage = error.localizedDescription
            logger.error("Live Transcribe start failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Stops capture, finishes the WebSocket session, and hides the HUD.
    func stop() async {
        guard isRunning || capture.isRunning || asrClient != nil || translateClient != nil else {
            windowManager.hide()
            return
        }

        capture.onAudioChunk = nil
        audioChunkContinuation?.finish()
        audioChunkContinuation = nil
        await capture.stop()

        if let asrClient {
            try? await asrClient.finish()
            try? await Task.sleep(nanoseconds: 400_000_000)
            await asrClient.disconnect()
        }

        if let translateClient {
            try? await translateClient.finish()
            try? await Task.sleep(nanoseconds: 400_000_000)
            await translateClient.disconnect()
        }

        await teardownSession()
        isRunning = false
        isPaused = false
        isReceivingAudio = false
        statusMessage = nil
        windowManager.hide()
        logger.notice("Live Transcribe stopped forwardedChunks=\(self.forwardedChunkCount, privacy: .public)")
    }

    /// Toggles the session on or off.
    func toggle(modelContext: ModelContext? = nil) async {
        if isRunning {
            await stop()
        } else {
            await start(modelContext: modelContext)
        }
    }

    /// Pauses or resumes processing while keeping the caption window open.
    func setPaused(_ paused: Bool) async {
        guard isRunning, isPaused != paused else { return }
        if paused {
            await pausePipeline()
        } else {
            await resumePipeline()
        }
    }

    /// Toggles the temporary processing pause.
    func togglePaused() async {
        await setPaused(!isPaused)
    }

    /// Updates the Translate preference and, if a session is running, hot-swaps the realtime pipeline.
    func applyTranslationEnabled(_ enabled: Bool) async {
        guard isTranslationEnabled != enabled else { return }
        isTranslationEnabled = enabled
        guard isRunning, !isPaused else { return }
        await switchRealtimePipeline()
    }

    /// Opens System Settings to the Screen Recording privacy pane.
    func openScreenRecordingSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Requests Screen Recording permission registration (may prompt).
    func requestScreenRecordingPermission() async -> Bool {
        let granted = await ScreenCaptureService.requestScreenCapturePermissionRegistration()
        refreshPermissions()
        return granted
    }

    /// Brings the floating caption panel forward if a session is active.
    func bringCaptionWindowToFront() {
        guard isRunning else { return }
        windowManager.show()
    }

    // MARK: - Private

    /// Disconnects capture + realtime clients but leaves the HUD/session open.
    private func pausePipeline() async {
        isPaused = true
        errorMessage = nil
        commitInFlightPartials()

        capture.onAudioChunk = nil
        audioChunkContinuation?.finish()
        audioChunkContinuation = nil
        sendTask?.cancel()
        sendTask = nil
        await capture.stop()
        await disconnectRealtimeClients()

        isReceivingAudio = false
        statusMessage = String(localized: "Paused")
        logger.notice("Live Transcribe paused")
    }

    /// Reconnects realtime clients and restarts system-audio capture.
    private func resumePipeline() async {
        guard isRunning, isPaused else { return }
        errorMessage = nil

        guard let apiKey = APIKeyManager.shared.getAPIKey(forProvider: "Alibaba"), !apiKey.isEmpty else {
            errorMessage = String(localized: "Add an Alibaba (DashScope) API key in AI Models first.")
            return
        }

        do {
            if isTranslationEnabled {
                try await startTranslateSession(apiKey: apiKey, corpus: sessionCorpus)
            } else {
                try await startASRSession(apiKey: apiKey, corpus: sessionCorpus)
            }

            startAudioForwarder()
            capture.onAudioChunk = { [weak self] data in
                guard let self, self.isRunning, !self.isPaused else { return }
                self.audioChunkContinuation?.yield(data)
            }
            try await capture.start()

            isPaused = false
            statusMessage = isTranslationEnabled
                ? String(localized: "Live translating…")
                : String(localized: "Live transcribing…")
            logger.notice("Live Transcribe resumed")
        } catch {
            errorMessage = error.localizedDescription
            statusMessage = String(localized: "Paused")
            logger.error("Live Transcribe resume failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Tears down the current WebSocket client and starts ASR or LiveTranslate without stopping capture.
    private func switchRealtimePipeline() async {
        guard isRunning, !isPaused, !isSwitchingPipeline else { return }
        isSwitchingPipeline = true
        errorMessage = nil
        defer { isSwitchingPipeline = false }

        guard let apiKey = APIKeyManager.shared.getAPIKey(forProvider: "Alibaba"), !apiKey.isEmpty else {
            errorMessage = String(localized: "Add an Alibaba (DashScope) API key in AI Models first.")
            return
        }

        commitInFlightPartials()
        await disconnectRealtimeClients()

        do {
            if isTranslationEnabled {
                try await startTranslateSession(apiKey: apiKey, corpus: sessionCorpus)
                statusMessage = String(localized: "Live translating…")
            } else {
                try await startASRSession(apiKey: apiKey, corpus: sessionCorpus)
                statusMessage = String(localized: "Live transcribing…")
            }
            logger.notice(
                "Live Transcribe pipeline switched translation=\(self.isTranslationEnabled, privacy: .public)"
            )
        } catch {
            errorMessage = error.localizedDescription
            statusMessage = String(localized: "Pipeline switch failed")
            logger.error("Live Transcribe pipeline switch failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Commits any open partials so mid-utterance text survives a pipeline swap.
    private func commitInFlightPartials() {
        if !currentSourcePartial.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            appendCommittedSource(currentSourcePartial)
            currentSourcePartial = ""
            rebuildSourceDisplay()
        }
        if !currentTranslationPartial.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            appendCommittedTranslation(currentTranslationPartial)
            currentTranslationPartial = ""
            rebuildTranslationDisplay()
        }
    }

    /// Finishes and disconnects ASR / LiveTranslate clients without touching capture.
    private func disconnectRealtimeClients() async {
        eventTask?.cancel()
        eventTask = nil

        let asr = asrClient
        let translate = translateClient
        asrClient = nil
        translateClient = nil

        if let asr {
            try? await asr.finish()
            await asr.disconnect()
        }
        if let translate {
            try? await translate.finish()
            await translate.disconnect()
        }
    }

    private func startASRSession(apiKey: String, corpus: LiveTranscribeCorpus.Payload) async throws {
        let client = DashScopeStreamingClient()
        asrClient = client
        eventTask = Task { [weak self] in
            for await event in client.transcriptionEvents {
                await self?.handleASREvent(event)
            }
        }

        try await client.connect(
            apiKey: apiKey,
            model: "qwen3-asr-flash-realtime",
            language: sourceLanguage,
            region: .current,
            serverVad: true,
            corpusText: corpus.text.isEmpty ? nil : corpus.text
        )
    }

    private func startTranslateSession(apiKey: String, corpus: LiveTranscribeCorpus.Payload) async throws {
        let client = DashScopeLiveTranslateClient()
        translateClient = client
        eventTask = Task { [weak self] in
            for await event in client.events {
                await self?.handleTranslateEvent(event)
            }
        }

        try await client.connect(
            apiKey: apiKey,
            sourceLanguage: sourceLanguage,
            targetLanguage: targetLanguage,
            region: .current,
            corpusText: corpus.text.isEmpty ? nil : corpus.text,
            translationPhrases: corpus.phrases
        )
    }

    /// Batches PCM chunks and forwards them on a single task to avoid flooding MainActor.
    private func startAudioForwarder() {
        sendTask?.cancel()
        let (stream, continuation) = AsyncStream<Data>.makeStream(bufferingPolicy: .bufferingNewest(32))
        audioChunkContinuation = continuation

        sendTask = Task { [weak self] in
            var pending = Data()
            let minBatchBytes = 3200 // ~100 ms of PCM16 / 16 kHz mono

            for await chunk in stream {
                guard let self else { break }
                pending.append(chunk)

                let rms = Self.pcm16RMS(chunk)
                if rms > 0.01 {
                    if !self.isReceivingAudio {
                        self.isReceivingAudio = true
                        self.logger.notice("Live Transcribe receiving audible system audio")
                    }
                }

                if pending.count >= minBatchBytes {
                    let batch = pending
                    pending = Data()
                    await self.sendAudioBatch(batch)
                }
            }

            if let self, !pending.isEmpty {
                await self.sendAudioBatch(pending)
            }
        }
    }

    private func sendAudioBatch(_ data: Data) async {
        guard isRunning, !isPaused else { return }
        do {
            if let translateClient {
                try await translateClient.sendAudioChunk(data)
            } else if let asrClient {
                try await asrClient.sendAudioChunk(data)
            }
            forwardedChunkCount += 1
            if forwardedChunkCount == 1 || forwardedChunkCount % 50 == 0 {
                logger.notice(
                    "Forwarded audio batches=\(self.forwardedChunkCount, privacy: .public) bytes=\(data.count, privacy: .public)"
                )
            }
        } catch {
            errorMessage = error.localizedDescription
            logger.error("Audio chunk send failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func handleASREvent(_ event: DashScopeStreamingClientEvent) {
        switch event {
        case .sessionStarted:
            logger.notice("ASR session started")
        case .partial(let text):
            currentSourcePartial = text
            rebuildSourceDisplay()
        case .committed(let text):
            appendCommittedSource(text)
            currentSourcePartial = ""
            rebuildSourceDisplay()
        case .sessionFinished:
            logger.notice("ASR session finished")
        case .error(let message):
            errorMessage = message
            logger.error("ASR error: \(message, privacy: .public)")
        }
    }

    private func handleTranslateEvent(_ event: DashScopeLiveTranslateClientEvent) {
        switch event {
        case .sessionStarted:
            logger.notice("LiveTranslate session started")
        case .sourcePartial(let text):
            currentSourcePartial = text
            rebuildSourceDisplay()
        case .sourceCommitted(let text):
            appendCommittedSource(text)
            currentSourcePartial = ""
            rebuildSourceDisplay()
        case .translationPartial(let text):
            currentTranslationPartial = text
            rebuildTranslationDisplay()
        case .translationCommitted(let text):
            appendCommittedTranslation(text)
            currentTranslationPartial = ""
            rebuildTranslationDisplay()
        case .sessionFinished:
            logger.notice("LiveTranslate session finished")
        case .error(let message):
            errorMessage = message
            logger.error("LiveTranslate error: \(message, privacy: .public)")
        }
    }

    private func appendCommittedSource(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        committedSourceSegments.append(trimmed)
        trimSegments(
            &committedSourceSegments,
            maxCharacters: Self.maxDisplayCharacters,
            maxSegments: Self.maxCommittedSegments
        )
    }

    private func appendCommittedTranslation(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        committedTranslationSegments.append(trimmed)
        trimSegments(
            &committedTranslationSegments,
            maxCharacters: Self.maxDisplayCharacters,
            maxSegments: Self.maxCommittedSegments
        )
    }

    private func rebuildSourceDisplay() {
        sourceText = displayText(
            committed: committedSourceSegments,
            partial: currentSourcePartial
        )
    }

    private func rebuildTranslationDisplay() {
        translatedText = displayText(
            committed: committedTranslationSegments,
            partial: currentTranslationPartial
        )
    }

    /// Builds the HUD string from recent committed segments plus the live partial (uncapped).
    private func displayText(committed: [String], partial: String) -> String {
        var parts = committed
        let trimmedPartial = partial.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedPartial.isEmpty {
            parts.append(trimmedPartial)
        }
        // One VAD/completed utterance per paragraph; API has no explicit newline field.
        return parts.joined(separator: "\n\n")
    }

    /// Drops oldest utterances (and trims a lone oversized segment) so HUD text stays bounded.
    private func trimSegments(
        _ segments: inout [String],
        maxCharacters: Int,
        maxSegments: Int
    ) {
        while segments.count > maxSegments {
            segments.removeFirst()
        }

        var total = segments.reduce(0) { $0 + $1.count + 2 }
        while total > maxCharacters, !segments.isEmpty {
            if segments.count == 1 {
                let only = segments[0]
                if only.count > maxCharacters {
                    segments[0] = String(only.suffix(maxCharacters))
                }
                break
            }
            let removed = segments.removeFirst()
            total -= removed.count + 2
        }
    }

    private func resetTranscriptBuffers() {
        committedSourceSegments = []
        committedTranslationSegments = []
        currentSourcePartial = ""
        currentTranslationPartial = ""
        sourceText = ""
        translatedText = ""
    }

    private func teardownSession() async {
        sendTask?.cancel()
        sendTask = nil
        audioChunkContinuation?.finish()
        audioChunkContinuation = nil
        eventTask?.cancel()
        eventTask = nil
        asrClient = nil
        translateClient = nil
        capture.onAudioChunk = nil
    }

    /// Computes RMS for a PCM16 mono buffer.
    private static func pcm16RMS(_ data: Data) -> Float {
        guard !data.isEmpty else { return 0 }
        return data.withUnsafeBytes { raw in
            let samples = raw.bindMemory(to: Int16.self)
            guard !samples.isEmpty else { return 0 }
            var sum: Float = 0
            for sample in samples {
                let value = Float(sample) / Float(Int16.max)
                sum += value * value
            }
            return sqrt(sum / Float(samples.count))
        }
    }
}
