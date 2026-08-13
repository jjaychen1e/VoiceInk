import Foundation
import LLMkit

/// Anthropic Messages client that returns content plus usage (including cache tokens).
enum AnthropicUsageChatClient {
    /// Sends a Messages API request and parses `usage` for cache hit metrics.
    static func chatCompletion(
        apiKey: String,
        model: String,
        messages: [ChatMessage],
        systemPrompt: String? = nil,
        maxTokens: Int = 8192,
        timeout: TimeInterval = 30
    ) async throws -> LLMChatCompletion {
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else {
            throw LLMKitError.missingAPIKey
        }

        let url = URL(string: "https://api.anthropic.com/v1/messages")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(trimmedKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")

        let system: String?
        let nonSystemMessages: [ChatMessage]
        if let systemPrompt {
            system = systemPrompt
            nonSystemMessages = messages.filter { $0.role != "system" }
        } else {
            let systemMessages = messages.filter { $0.role == "system" }
            system = systemMessages.isEmpty ? nil : systemMessages.map(\.content).joined(separator: "\n")
            nonSystemMessages = messages.filter { $0.role != "system" }
        }

        var bodyDict: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            "messages": nonSystemMessages.map { ["role": $0.role, "content": $0.content] },
        ]
        if let system, !system.isEmpty {
            bodyDict["system"] = system
        }

        guard let body = try? JSONSerialization.data(withJSONObject: bodyDict) else {
            throw LLMKitError.encodingError
        }
        request.httpBody = body

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch let urlError as URLError where urlError.code == .timedOut {
            throw LLMKitError.timeout
        } catch {
            throw LLMKitError.networkError(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw LLMKitError.networkError("No HTTP response received.")
        }

        guard (200...299).contains(http.statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? "HTTP \(http.statusCode)"
            throw LLMKitError.httpError(statusCode: http.statusCode, message: message)
        }

        guard
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let contentBlocks = root["content"] as? [[String: Any]]
        else {
            throw LLMKitError.decodingError("Invalid Anthropic response.")
        }

        let text = contentBlocks
            .first { ($0["type"] as? String) == "text" }
            .flatMap { $0["text"] as? String }

        guard let text, !text.isEmpty else {
            throw LLMKitError.noResultReturned
        }

        return LLMChatCompletion(
            text: text,
            usage: LLMUsage.fromAnthropicUsage(root["usage"] as? [String: Any])
        )
    }
}
