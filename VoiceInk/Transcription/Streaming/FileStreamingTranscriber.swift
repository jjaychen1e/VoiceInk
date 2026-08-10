import Foundation
import SwiftData
import os

/// Streams pre-converted float samples through a model's streaming API for the file transcription path.
@MainActor
enum FileStreamingTranscriber {
    private static let logger = Logger(
        subsystem: "com.prakashjoshipax.voiceink", category: "FileStreamingTranscriber")

    /// Transcribes normalized 16 kHz mono float samples via streaming, with optional batch fallback.
    static func transcribe(
        samples: [Float],
        model: any TranscriptionModel,
        context: TranscriptionRequestContext,
        modelContext: ModelContext,
        fluidAudioService: FluidAudioTranscriptionService?,
        batchFallback: () async throws -> String
    ) async throws -> String {
        let pcm16 = PCMAudioConverter.pcm16Data(fromFloat32Samples: samples)
        let streamingService = StreamingTranscriptionService(
            modelContext: modelContext,
            fluidAudioService: model.provider == .fluidAudio ? fluidAudioService : nil
        )

        do {
            logger.notice(
                "File streaming start model=\(model.displayName, privacy: .public) bytes=\(pcm16.count, privacy: .public)"
            )
            try await streamingService.startStreaming(model: model, context: context)
            try await streamingService.streamPCM16Audio(pcm16, realtimePacing: true)
            let result = try await streamingService.stopAndFinalize()
            switch result {
            case .finalized(let text):
                logger.notice(
                    "File streaming finished model=\(model.displayName, privacy: .public) chars=\(text.count, privacy: .public)"
                )
                return text
            case .requiresBatchFallback:
                logger.notice(
                    "File streaming requested batch fallback model=\(model.displayName, privacy: .public)"
                )
                return try await batchFallback()
            }
        } catch {
            logger.error(
                "File streaming failed, falling back to batch: \(error, privacy: .public)"
            )
            streamingService.cancel()
            return try await batchFallback()
        }
    }
}
