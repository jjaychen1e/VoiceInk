import Foundation

/// How VoiceInk should request DashScope/Qwen prompt caching for Alibaba enhancement calls.
enum AlibabaPromptCacheMode: String, CaseIterable, Identifiable, Sendable {
    /// Send `cache_control: ephemeral` on the system prompt (deterministic, 5-minute TTL).
    case explicit
    /// Omit `cache_control` and rely on DashScope automatic prefix caching (best-effort).
    case implicit

    var id: String { rawValue }

    /// UserDefaults key for the selected Alibaba prompt-cache mode.
    static let userDefaultsKey = "alibabaPromptCacheMode"

    /// Label shown in Alibaba provider settings.
    var displayName: String {
        switch self {
        case .explicit:
            return String(localized: "Explicit")
        case .implicit:
            return String(localized: "Implicit")
        }
    }

    /// Whether requests should include DashScope explicit `cache_control` markers.
    var usesExplicitCacheControl: Bool {
        self == .explicit
    }

    /// Loads the persisted mode, defaulting to explicit.
    static var current: AlibabaPromptCacheMode {
        guard let raw = UserDefaults.standard.string(forKey: userDefaultsKey),
            let mode = AlibabaPromptCacheMode(rawValue: raw)
        else {
            return .explicit
        }
        return mode
    }

    /// Persists the selected mode.
    static func setCurrent(_ mode: AlibabaPromptCacheMode) {
        UserDefaults.standard.set(mode.rawValue, forKey: userDefaultsKey)
    }
}
