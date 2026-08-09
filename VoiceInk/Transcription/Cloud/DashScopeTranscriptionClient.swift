import Foundation

/// Batch transcription client for DashScope Qwen3-ASR via the OpenAI-compatible chat completions API.
enum DashScopeTranscriptionClient {
    private static let maxAudioBytes = 10 * 1024 * 1024

    /// Transcribes local audio using `qwen3-asr-flash` (or a compatible snapshot id).
    ///
    /// Qwen3-ASR is a dedicated ASR task and rejects text content (system prompts / vocabulary)
    /// alongside audio, so this client sends audio-only user messages.
    static func transcribe(
        audioData: Data,
        fileName: String,
        apiKey: String,
        model: String,
        language: String?,
        region: DashScopeRegion = .current,
        enableITN: Bool = true
    ) async throws -> String {
        guard !apiKey.isEmpty else {
            throw CloudTranscriptionError.missingAPIKey
        }
        guard audioData.count <= maxAudioBytes else {
            throw CloudTranscriptionError.apiRequestFailed(
                statusCode: 413,
                message: String(localized: "Audio exceeds the 10 MB limit for Qwen3-ASR-Flash.")
            )
        }

        let url = region.compatibleBaseURL.appendingPathComponent("chat/completions")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 120

        let mimeType = mimeType(forFileName: fileName)
        let dataURI = "data:\(mimeType);base64,\(audioData.base64EncodedString())"

        // Audio-only: dedicated Qwen3-ASR rejects any text parts in the request.
        let messages: [[String: Any]] = [
            [
                "role": "user",
                "content": [
                    [
                        "type": "input_audio",
                        "input_audio": [
                            "data": dataURI
                        ],
                    ]
                ],
            ]
        ]

        var asrOptions: [String: Any] = [
            "enable_itn": enableITN
        ]
        if let language, !language.isEmpty, language != "auto" {
            asrOptions["language"] = language
        }

        let body: [String: Any] = [
            "model": model,
            "messages": messages,
            "stream": false,
            "asr_options": asrOptions,
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let session = URLSession(configuration: .ephemeral)
        defer { session.finishTasksAndInvalidate() }

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw CloudTranscriptionError.networkError(error)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw CloudTranscriptionError.networkError(URLError(.badServerResponse))
        }

        if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
            throw CloudTranscriptionError.invalidAPIKey
        }

        if !(200...299).contains(httpResponse.statusCode) {
            let message = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw CloudTranscriptionError.apiRequestFailed(
                statusCode: httpResponse.statusCode, message: message)
        }

        guard let text = parseTranscriptionText(from: data), !text.isEmpty else {
            throw CloudTranscriptionError.noTranscriptionReturned
        }
        return text
    }

    /// Verifies an API key by listing compatible-mode models.
    static func verifyAPIKey(
        _ apiKey: String, region: DashScopeRegion = .current
    ) async -> (isValid: Bool, errorMessage: String?) {
        guard !apiKey.isEmpty else {
            return (false, String(localized: "API key is empty."))
        }

        let url = region.compatibleBaseURL.appendingPathComponent("models")
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 20

        let session = URLSession(configuration: .ephemeral)
        defer { session.finishTasksAndInvalidate() }

        do {
            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                return (false, String(localized: "Invalid server response."))
            }
            if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
                return (false, String(localized: "Invalid API key for the selected Alibaba region."))
            }
            if !(200...299).contains(httpResponse.statusCode) {
                let message = String(data: data, encoding: .utf8) ?? "HTTP \(httpResponse.statusCode)"
                return (false, message)
            }
            return (true, nil)
        } catch {
            return (false, error.localizedDescription)
        }
    }

    /// Maps a local filename extension to a MIME type for Data URL encoding.
    private static func mimeType(forFileName fileName: String) -> String {
        let ext = (fileName as NSString).pathExtension.lowercased()
        switch ext {
        case "wav":
            return "audio/wav"
        case "mp3":
            return "audio/mpeg"
        case "m4a":
            return "audio/mp4"
        case "aac":
            return "audio/aac"
        case "ogg":
            return "audio/ogg"
        case "flac":
            return "audio/flac"
        case "webm":
            return "audio/webm"
        case "opus":
            return "audio/opus"
        default:
            return "audio/wav"
        }
    }

    /// Extracts assistant text from an OpenAI-compatible chat completion response.
    private static func parseTranscriptionText(from data: Data) -> String? {
        guard
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let choices = json["choices"] as? [[String: Any]],
            let first = choices.first,
            let message = first["message"] as? [String: Any]
        else {
            return nil
        }

        if let content = message["content"] as? String {
            return content.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // Some responses may return multimodal content arrays.
        if let contentArray = message["content"] as? [[String: Any]] {
            let text = contentArray.compactMap { $0["text"] as? String }.joined()
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }

        return nil
    }
}
