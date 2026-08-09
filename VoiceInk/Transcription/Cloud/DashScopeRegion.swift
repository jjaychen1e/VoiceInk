import Foundation

/// DashScope (Alibaba Cloud Model Studio) API region.
/// Beijing and Singapore use different endpoints and require different API keys.
enum DashScopeRegion: String, CaseIterable, Identifiable, Sendable {
    case beijing
    case singapore

    var id: String { rawValue }

    /// UserDefaults key for the selected DashScope region.
    static let userDefaultsKey = "dashScopeRegion"

    /// Display name shown in settings.
    var displayName: String {
        switch self {
        case .beijing:
            return String(localized: "China (Beijing)")
        case .singapore:
            return String(localized: "International (Singapore)")
        }
    }

    /// OpenAI-compatible chat completions base URL (without trailing slash).
    var compatibleBaseURL: URL {
        switch self {
        case .beijing:
            return URL(string: "https://dashscope.aliyuncs.com/compatible-mode/v1")!
        case .singapore:
            return URL(string: "https://dashscope-intl.aliyuncs.com/compatible-mode/v1")!
        }
    }

    /// Native DashScope HTTP API base URL (without trailing slash).
    /// Used by multimodal-generation endpoints such as `qwen-audio-3.0-asr-flash`.
    var nativeAPIBaseURL: URL {
        switch self {
        case .beijing:
            return URL(string: "https://dashscope.aliyuncs.com/api/v1")!
        case .singapore:
            return URL(string: "https://dashscope-intl.aliyuncs.com/api/v1")!
        }
    }

    /// Realtime WebSocket base URL (model is appended as a query parameter).
    /// Used by `qwen3-asr-flash-realtime` (OpenAI Realtime-style protocol).
    var realtimeWebSocketBaseURL: URL {
        switch self {
        case .beijing:
            return URL(string: "wss://dashscope.aliyuncs.com/api-ws/v1/realtime")!
        case .singapore:
            return URL(string: "wss://dashscope-intl.aliyuncs.com/api-ws/v1/realtime")!
        }
    }

    /// Fun-ASR / Qwen-Audio duplex inference WebSocket URL.
    /// Used by `qwen-audio-3.0-asr-flash-streaming`.
    var inferenceWebSocketURL: URL {
        switch self {
        case .beijing:
            return URL(string: "wss://dashscope.aliyuncs.com/api-ws/v1/inference")!
        case .singapore:
            return URL(string: "wss://dashscope-intl.aliyuncs.com/api-ws/v1/inference")!
        }
    }

    /// Console URL for creating API keys in this region.
    var apiConsoleURL: URL {
        switch self {
        case .beijing:
            return URL(string: "https://bailian.console.aliyun.com/?tab=model#/api-key")!
        case .singapore:
            return URL(string: "https://modelstudio.console.alibabacloud.com/?tab=model#/api-key")!
        }
    }

    /// Loads the persisted region, defaulting to Beijing.
    static var current: DashScopeRegion {
        guard let raw = UserDefaults.standard.string(forKey: userDefaultsKey),
            let region = DashScopeRegion(rawValue: raw)
        else {
            return .beijing
        }
        return region
    }

    /// Persists the selected region.
    static func setCurrent(_ region: DashScopeRegion) {
        UserDefaults.standard.set(region.rawValue, forKey: userDefaultsKey)
    }
}
