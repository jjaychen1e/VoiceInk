import Foundation

/// Resolves which file-transcription strategies a model can use.
enum TranscriptionFileSupport {
    /// Strategies the UI may offer for this model.
    static func availableStrategies(for model: any TranscriptionModel) -> [FileTranscriptionStrategy] {
        var strategies: [FileTranscriptionStrategy] = [.sync]
        if supportsAsync(for: model) {
            strategies.append(.asynchronous)
        }
        if TranscriptionRealtimeSupport.isAvailable(for: model) {
            strategies.append(.stream)
        }
        return strategies
    }

    /// Whether Async (Filetrans + temporary upload) is available.
    static func supportsAsync(for model: any TranscriptionModel) -> Bool {
        guard model.provider == .alibaba else { return false }
        return DashScopeProvider.filetransModelName(for: model.name) != nil
    }

    /// Clamps a saved strategy to one the model actually supports.
    static func resolved(
        _ strategy: FileTranscriptionStrategy,
        for model: any TranscriptionModel
    ) -> FileTranscriptionStrategy {
        let available = availableStrategies(for: model)
        return available.contains(strategy) ? strategy : .sync
    }
}
