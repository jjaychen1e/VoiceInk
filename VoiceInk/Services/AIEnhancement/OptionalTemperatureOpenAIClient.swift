import Foundation
import LLMkit

/// OpenAI-compatible chat client that can omit optional Chat Completions fields.
///
/// LLMkit's `OpenAILLMClient` always sends `temperature`, which breaks GPT-5.6-class
/// models that reject the parameter. Custom providers also need optional
/// `reasoning_effort` so latency-sensitive polish can pin `none` without forcing it
/// on gateways that reject unknown fields.
enum OptionalTemperatureOpenAIClient {
    /// Sends a chat completion, including optional fields only when non-nil.
    ///
    /// - Parameter enableSystemPromptCache: When true, the system prompt is sent as a
    ///   structured text block with DashScope/Anthropic-style
    ///   `cache_control: { type: ephemeral }` for explicit context cache.
    static func chatCompletion(
        baseURL: URL,
        apiKey: String,
        model: String,
        messages: [ChatMessage],
        systemPrompt: String? = nil,
        temperature: Double? = nil,
        reasoningEffort: String? = nil,
        extraBody: [String: Any]? = nil,
        enableSystemPromptCache: Bool = false,
        timeout: TimeInterval = 30
    ) async throws -> LLMChatCompletion {
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else {
            throw LLMKitError.missingAPIKey
        }

        var request = URLRequest(url: baseURL)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(trimmedKey)", forHTTPHeaderField: "Authorization")

        var bodyDict: [String: Any] = [
            "model": model,
            "messages": encodeMessages(
                messages: messages,
                systemPrompt: systemPrompt,
                enableSystemPromptCache: enableSystemPromptCache
            ),
            "stream": false,
        ]
        if let temperature {
            bodyDict["temperature"] = temperature
        }
        if let reasoningEffort {
            bodyDict["reasoning_effort"] = reasoningEffort
        }
        if let extraBody {
            for (key, value) in extraBody {
                bodyDict[key] = value
            }
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

        let decoded: OptionalTemperatureChatResponse
        do {
            decoded = try JSONDecoder().decode(OptionalTemperatureChatResponse.self, from: data)
        } catch {
            throw LLMKitError.decodingError(error.localizedDescription)
        }

        guard let content = decoded.choices.first?.message.content else {
            throw LLMKitError.noResultReturned
        }

        let usageJSON = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["usage"]
            as? [String: Any]
        return LLMChatCompletion(
            text: content,
            usage: LLMUsage.fromOpenAICompatibleUsage(usageJSON)
        )
    }

    /// Builds the OpenAI-compatible `messages` payload, optionally marking the system prompt for explicit cache.
    private static func encodeMessages(
        messages: [ChatMessage],
        systemPrompt: String?,
        enableSystemPromptCache: Bool
    ) -> [[String: Any]] {
        var encoded: [[String: Any]] = []

        if let systemPrompt, !systemPrompt.isEmpty {
            if enableSystemPromptCache {
                let textBlock: [String: Any] = [
                    "type": "text",
                    "text": systemPrompt,
                    "cache_control": ["type": "ephemeral"],
                ]
                encoded.append([
                    "role": "system",
                    "content": [textBlock],
                ])
            } else {
                encoded.append([
                    "role": "system",
                    "content": systemPrompt,
                ])
            }
        }

        for message in messages where message.role != "system" {
            encoded.append([
                "role": message.role,
                "content": message.content,
            ])
        }

        return encoded
    }
}

private struct OptionalTemperatureChatResponse: Decodable {
    let choices: [OptionalTemperatureChatChoice]
}

private struct OptionalTemperatureChatChoice: Decodable {
    let message: OptionalTemperatureChatMessage
}

private struct OptionalTemperatureChatMessage: Decodable {
    let content: String?
}
