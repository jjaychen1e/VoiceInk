import Combine
import Foundation

/// Menu-bar snapshot of Live Transcribe. Caption text is excluded so the
/// status-item `NSMenu` is not rebuilt on every ASR token.
@MainActor
final class LiveTranscribeMenuChrome: ObservableObject {
    struct Snapshot: Equatable {
        var isRunning: Bool
        var isTranslationEnabled: Bool
        var isSwitchingPipeline: Bool
        var sourceLanguage: String
        var targetLanguage: String
        var hasAlibabaAPIKey: Bool
    }

    @Published private(set) var snapshot: Snapshot
    private var cancellables = Set<AnyCancellable>()

    /// Observes only the Live Transcribe fields the menu bar needs to render.
    init(controller: LiveTranscribeController = .shared) {
        snapshot = Self.makeSnapshot(controller: controller)

        Publishers.CombineLatest(
            Publishers.CombineLatest3(
                controller.$isRunning,
                controller.$isTranslationEnabled,
                controller.$isSwitchingPipeline
            ),
            Publishers.CombineLatest(
                controller.$sourceLanguage,
                controller.$targetLanguage
            )
        )
        .map { running, languages in
            let (isRunning, isTranslationEnabled, isSwitchingPipeline) = running
            let (sourceLanguage, targetLanguage) = languages
            return Snapshot(
                isRunning: isRunning,
                isTranslationEnabled: isTranslationEnabled,
                isSwitchingPipeline: isSwitchingPipeline,
                sourceLanguage: sourceLanguage,
                targetLanguage: targetLanguage,
                hasAlibabaAPIKey: controller.hasAlibabaAPIKey
            )
        }
        .removeDuplicates()
        .sink { [weak self] snapshot in
            self?.snapshot = snapshot
        }
        .store(in: &cancellables)
    }

    /// Builds a menu snapshot from the current controller values.
    private static func makeSnapshot(controller: LiveTranscribeController) -> Snapshot {
        Snapshot(
            isRunning: controller.isRunning,
            isTranslationEnabled: controller.isTranslationEnabled,
            isSwitchingPipeline: controller.isSwitchingPipeline,
            sourceLanguage: controller.sourceLanguage,
            targetLanguage: controller.targetLanguage,
            hasAlibabaAPIKey: controller.hasAlibabaAPIKey
        )
    }
}
