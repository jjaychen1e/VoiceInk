import Foundation

/// Batch transcription client for `qwen-audio-3.0-asr-flash` via DashScope multimodal-generation.
///
/// This model uses a different request/response shape from `qwen3-asr-flash`
/// (OpenAI-compatible chat/completions) and does not share that client path.
enum DashScopeQwenAudioTranscriptionClient {
    /// Raw audio size limit chosen so Base64 Data URI stays under the documented ~10 MB cap.
    private static let maxAudioBytes = 7 * 1024 * 1024

    /// Transcribes local audio with the Qwen-Audio-3.0-ASR-Flash multimodal-generation API.
    static func transcribe(
        audioData: Data,
        fileName: String,
        apiKey: String,
        model: String = "qwen-audio-3.0-asr-flash",
        language: String?,
        customVocabulary: [String],
        region: DashScopeRegion = .current
    ) async throws -> String {
        guard !apiKey.isEmpty else {
            throw CloudTranscriptionError.missingAPIKey
        }
        guard audioData.count <= maxAudioBytes else {
            throw CloudTranscriptionError.apiRequestFailed(
                statusCode: 413,
                message: String(localized: "Audio exceeds the size limit for Qwen-Audio-3.0-ASR-Flash.")
            )
        }

        let url = region.nativeAPIBaseURL
            .appendingPathComponent("services/aigc/multimodal-generation/generation")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("disable", forHTTPHeaderField: "X-DashScope-SSE")
        request.timeoutInterval = 120

        let format = audioFormat(forFileName: fileName)
        let mimeType = mimeType(forFormat: format)
        let dataURI = "data:\(mimeType);base64,\(audioData.base64EncodedString())"

        var parameters: [String: Any] = [
            "format": format,
            "sample_rate": "16000",
        ]
        if let languageHint = languageHint(from: language) {
            parameters["language_hints"] = [languageHint]
        }
        if let vocabulary = vocabularyDictionary(from: customVocabulary) {
            parameters["vocabulary"] = vocabulary
        }

        let body: [String: Any] = [
            "model": model,
            "input": [
                "messages": [
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
            ],
            "parameters": parameters,
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

    /// Maps a VoiceInk language code to a Qwen-Audio language_hints value.
    private static func languageHint(from language: String?) -> String? {
        guard let language, !language.isEmpty, language != "auto" else {
            return nil
        }
        // Docs use `tl` for Filipino/Tagalog; VoiceInk historically uses `fil`.
        if language == "fil" {
            return "tl"
        }
        return language
    }

    /// Builds an instant-hotword map with weight 5 (max non-super weight).
    private static func vocabularyDictionary(from terms: [String]) -> [String: Int]? {
        var vocabulary: [String: Int] = [:]
        for term in terms {
            let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            vocabulary[trimmed] = 5
            if vocabulary.count >= 50 { break }
        }
        return vocabulary.isEmpty ? nil : vocabulary
    }

    /// Maps a local filename extension to the DashScope `parameters.format` value.
    private static func audioFormat(forFileName fileName: String) -> String {
        let ext = (fileName as NSString).pathExtension.lowercased()
        switch ext {
        case "wav", "mp3", "m4a", "aac", "ogg", "flac", "webm", "opus", "amr", "wma":
            return ext
        case "mpeg":
            return "mp3"
        case "mp4", "mov", "mkv", "avi", "flv", "wmv":
            return ext
        default:
            return "wav"
        }
    }

    /// Maps an audio format string to a Data URI MIME type.
    private static func mimeType(forFormat format: String) -> String {
        switch format {
        case "wav":
            return "audio/wav"
        case "mp3":
            return "audio/mpeg"
        case "m4a", "mp4":
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
            return "audio/\(format)"
        }
    }

    /// Extracts recognition text from the multimodal-generation response.
    private static func parseTranscriptionText(from data: Data) -> String? {
        guard
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let output = json["output"] as? [String: Any]
        else {
            return nil
        }

        if let text = output["text"] as? String {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }

        if let sentence = output["sentence"] as? [String: Any],
            let text = sentence["text"] as? String
        {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }

        // Some docs show a nested `output.output` shape for this family.
        if let nested = output["output"] as? [String: Any] {
            if let text = nested["text"] as? String {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            }
            if let sentence = nested["sentence"] as? [String: Any],
                let text = sentence["text"] as? String
            {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            }
        }

        return nil
    }
}
