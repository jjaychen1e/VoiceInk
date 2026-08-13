import Foundation

/// Provider-reported token usage from a chat completion response.
struct LLMUsage: Sendable, Equatable {
    let promptTokens: Int?
    let completionTokens: Int?
    let totalTokens: Int?
    /// Prompt tokens served from cache (OpenAI-compatible `cached_tokens` / Anthropic `cache_read_input_tokens`).
    let cachedPromptTokens: Int?
    /// Prompt tokens written into cache (Anthropic `cache_creation_input_tokens`).
    let cacheCreationTokens: Int?

    /// Whether any prompt tokens were read from cache.
    var didHitCache: Bool {
        (cachedPromptTokens ?? 0) > 0
    }

    /// Builds usage from an OpenAI-compatible `usage` JSON object.
    static func fromOpenAICompatibleUsage(_ usage: [String: Any]?) -> LLMUsage? {
        guard let usage else { return nil }

        let promptTokens = intValue(usage["prompt_tokens"])
        let completionTokens = intValue(usage["completion_tokens"])
        let totalTokens = intValue(usage["total_tokens"])

        let details = usage["prompt_tokens_details"] as? [String: Any]
        let detailsCached = intValue(details?["cached_tokens"])
        // Some DashScope regions expose cached tokens at the top level.
        let topLevelCached = intValue(usage["cached_tokens"])
        let cachedPromptTokens = detailsCached ?? topLevelCached

        let cacheCreationTokens =
            intValue(details?["cache_write_tokens"])
            ?? intValue(usage["cache_creation_input_tokens"])

        guard promptTokens != nil || completionTokens != nil || totalTokens != nil
            || cachedPromptTokens != nil || cacheCreationTokens != nil
        else {
            return nil
        }

        return LLMUsage(
            promptTokens: promptTokens,
            completionTokens: completionTokens,
            totalTokens: totalTokens,
            cachedPromptTokens: cachedPromptTokens,
            cacheCreationTokens: cacheCreationTokens
        )
    }

    /// Builds usage from an Anthropic Messages API `usage` JSON object.
    static func fromAnthropicUsage(_ usage: [String: Any]?) -> LLMUsage? {
        guard let usage else { return nil }

        let promptTokens = intValue(usage["input_tokens"])
        let completionTokens = intValue(usage["output_tokens"])
        let cachedPromptTokens = intValue(usage["cache_read_input_tokens"])
        let cacheCreationTokens = intValue(usage["cache_creation_input_tokens"])

        let total: Int?
        if let promptTokens, let completionTokens {
            total = promptTokens + completionTokens
                + (cachedPromptTokens ?? 0)
                + (cacheCreationTokens ?? 0)
        } else {
            total = nil
        }

        guard promptTokens != nil || completionTokens != nil
            || cachedPromptTokens != nil || cacheCreationTokens != nil
        else {
            return nil
        }

        return LLMUsage(
            promptTokens: promptTokens,
            completionTokens: completionTokens,
            totalTokens: total,
            cachedPromptTokens: cachedPromptTokens,
            cacheCreationTokens: cacheCreationTokens
        )
    }

    /// Reads an integer from JSONSerialization output (`Int` or `NSNumber`).
    private static func intValue(_ value: Any?) -> Int? {
        switch value {
        case let int as Int:
            return int
        case let number as NSNumber:
            return number.intValue
        default:
            return nil
        }
    }
}

/// Chat completion content plus optional provider usage metadata.
struct LLMChatCompletion: Sendable {
    let text: String
    let usage: LLMUsage?
}
