import Foundation
import os

/// Result of an asynchronous DashScope Filetrans job.
struct DashScopeFiletransResult: Sendable {
    let text: String
    let sentences: [TranscriptionTimedSentence]
}

/// Asynchronous DashScope Filetrans client (submit → poll → download transcript JSON).
enum DashScopeFiletransClient {
    private static let logger = Logger(
        subsystem: "com.prakashjoshipax.voiceink", category: "DashScopeFiletrans")

    /// Transcribes a local audio file via temporary OSS upload + Filetrans.
    static func transcribe(
        audioURL: URL,
        apiKey: String,
        model: String,
        language: String?,
        region: DashScopeRegion = .current
    ) async throws -> DashScopeFiletransResult {
        guard let filetransModel = DashScopeProvider.filetransModelName(for: model) else {
            throw CloudTranscriptionError.unsupportedProvider
        }
        guard !apiKey.isEmpty else {
            throw CloudTranscriptionError.missingAPIKey
        }

        logger.notice(
            "Filetrans upload start model=\(filetransModel, privacy: .public) file=\(audioURL.lastPathComponent, privacy: .public)"
        )
        let ossURL = try await DashScopeTemporaryUploadClient.upload(
            fileURL: audioURL,
            apiKey: apiKey,
            model: filetransModel,
            region: region
        )
        logger.notice("Filetrans upload done url=\(ossURL, privacy: .public)")

        let taskID = try await submitTask(
            fileURL: ossURL,
            apiKey: apiKey,
            model: filetransModel,
            language: language,
            region: region
        )
        logger.notice("Filetrans task submitted id=\(taskID, privacy: .public)")

        let transcriptionURL = try await waitForTranscriptionURL(
            taskID: taskID,
            apiKey: apiKey,
            region: region
        )
        return try await downloadTranscript(from: transcriptionURL)
    }

    // MARK: - Submit / poll

    private static func submitTask(
        fileURL: String,
        apiKey: String,
        model: String,
        language: String?,
        region: DashScopeRegion
    ) async throws -> String {
        let url = region.nativeAPIBaseURL
            .appendingPathComponent("services")
            .appendingPathComponent("audio")
            .appendingPathComponent("asr")
            .appendingPathComponent("transcription")

        var parameters: [String: Any] = [
            "channel_id": [0],
            "enable_itn": true,
            "enable_words": true,
        ]
        if let language, !language.isEmpty, language != "auto" {
            parameters["language"] = language == "fil" ? "tl" : language
        }

        let input: [String: Any]
        if DashScopeProvider.filetransUsesSingularFileURL(model) {
            input = ["file_url": fileURL]
        } else {
            input = ["file_urls": [fileURL]]
        }

        let payload: [String: Any] = [
            "model": model,
            "input": input,
            "parameters": parameters,
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("enable", forHTTPHeaderField: "X-DashScope-Async")
        request.setValue("enable", forHTTPHeaderField: "X-DashScope-OssResourceResolve")
        request.timeoutInterval = 120
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw CloudTranscriptionError.noTranscriptionReturned
        }
        guard (200..<300).contains(http.statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? "Filetrans submit failed"
            throw CloudTranscriptionError.apiRequestFailed(statusCode: http.statusCode, message: message)
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let output = json["output"] as? [String: Any],
            let taskID = output["task_id"] as? String,
            !taskID.isEmpty
        else {
            throw CloudTranscriptionError.noTranscriptionReturned
        }
        return taskID
    }

    private static func waitForTranscriptionURL(
        taskID: String,
        apiKey: String,
        region: DashScopeRegion,
        timeout: TimeInterval = 3600
    ) async throws -> URL {
        let deadline = Date().addingTimeInterval(timeout)
        let queryURL = region.nativeAPIBaseURL.appendingPathComponent("tasks").appendingPathComponent(taskID)

        while Date() < deadline {
            try Task.checkCancellation()

            var request = URLRequest(url: queryURL)
            request.httpMethod = "GET"
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.timeoutInterval = 60

            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw CloudTranscriptionError.noTranscriptionReturned
            }
            guard (200..<300).contains(http.statusCode) else {
                let message = String(data: data, encoding: .utf8) ?? "Filetrans poll failed"
                throw CloudTranscriptionError.apiRequestFailed(statusCode: http.statusCode, message: message)
            }

            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                let output = json["output"] as? [String: Any]
            else {
                throw CloudTranscriptionError.noTranscriptionReturned
            }

            let status = (output["task_status"] as? String)?.uppercased() ?? ""
            switch status {
            case "SUCCEEDED":
                if let url = extractTranscriptionURL(from: output) {
                    return url
                }
                throw CloudTranscriptionError.noTranscriptionReturned
            case "FAILED", "CANCELED", "UNKNOWN":
                let message =
                    (output["message"] as? String)
                    ?? (json["message"] as? String)
                    ?? "Filetrans task failed"
                throw CloudTranscriptionError.apiRequestFailed(statusCode: 500, message: message)
            default:
                try await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }

        throw CloudTranscriptionError.apiRequestFailed(
            statusCode: 408,
            message: String(localized: "Filetrans timed out waiting for results.")
        )
    }

    private static func extractTranscriptionURL(from output: [String: Any]) -> URL? {
        if let result = output["result"] as? [String: Any],
            let urlString = result["transcription_url"] as? String,
            let url = URL(string: urlString)
        {
            return url
        }
        if let results = output["results"] as? [[String: Any]] {
            for item in results {
                if let urlString = item["transcription_url"] as? String,
                    let url = URL(string: urlString)
                {
                    return url
                }
            }
        }
        return nil
    }

    /// Downloads and parses the Filetrans result JSON into text + timed sentences.
    private static func downloadTranscript(from url: URL) async throws -> DashScopeFiletransResult {
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw CloudTranscriptionError.noTranscriptionReturned
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CloudTranscriptionError.noTranscriptionReturned
        }

        let sentences = parseSentences(from: json)
        let text: String
        if let transcripts = json["transcripts"] as? [[String: Any]] {
            let texts = transcripts.compactMap { item -> String? in
                let value = (item["text"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return value.isEmpty ? nil : value
            }
            if !texts.isEmpty {
                text = texts.joined(separator: "\n")
            } else if !sentences.isEmpty {
                text = sentences.map(\.text).joined(separator: " ")
            } else {
                throw CloudTranscriptionError.noTranscriptionReturned
            }
        } else if let rootText = (json["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
            !rootText.isEmpty
        {
            text = rootText
        } else if !sentences.isEmpty {
            text = sentences.map(\.text).joined(separator: " ")
        } else {
            throw CloudTranscriptionError.noTranscriptionReturned
        }

        logger.notice(
            "Filetrans parsed textChars=\(text.count, privacy: .public) sentences=\(sentences.count, privacy: .public)"
        )
        return DashScopeFiletransResult(text: text, sentences: sentences)
    }

    private static func parseSentences(from json: [String: Any]) -> [TranscriptionTimedSentence] {
        var sentences: [TranscriptionTimedSentence] = []
        let transcriptObjects = (json["transcripts"] as? [[String: Any]]) ?? [json]
        for transcript in transcriptObjects {
            guard let rawSentences = transcript["sentences"] as? [[String: Any]] else { continue }
            for raw in rawSentences {
                let text = (raw["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                guard !text.isEmpty else { continue }
                let begin = intValue(raw["begin_time"]) ?? 0
                let end = intValue(raw["end_time"]) ?? begin
                let words = (raw["words"] as? [[String: Any]])?.compactMap { word -> TranscriptionTimedWord? in
                    let wordText = (word["text"] as? String) ?? ""
                    guard !wordText.isEmpty else { return nil }
                    return TranscriptionTimedWord(
                        beginTimeMs: intValue(word["begin_time"]) ?? 0,
                        endTimeMs: intValue(word["end_time"]) ?? 0,
                        text: wordText,
                        punctuation: word["punctuation"] as? String
                    )
                }
                sentences.append(
                    TranscriptionTimedSentence(
                        sentenceId: intValue(raw["sentence_id"]),
                        beginTimeMs: begin,
                        endTimeMs: end,
                        text: text,
                        language: raw["language"] as? String,
                        emotion: raw["emotion"] as? String,
                        words: words?.isEmpty == false ? words : nil
                    )
                )
            }
        }
        return sentences
    }

    private static func intValue(_ value: Any?) -> Int? {
        switch value {
        case let int as Int:
            return int
        case let double as Double:
            return Int(double)
        case let number as NSNumber:
            return number.intValue
        case let string as String:
            return Int(string)
        default:
            return nil
        }
    }
}
