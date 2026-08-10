import Foundation

/// Uploads a local file to DashScope temporary OSS storage and returns an `oss://` URL (valid ~48h).
enum DashScopeTemporaryUploadClient {
    private static let maxUploadBytes = 1 * 1024 * 1024 * 1024

    /// Uploads `fileURL` for use with `model` and returns an `oss://` temporary URL.
    ///
    /// The upload is bound to `model`; subsequent Filetrans calls must use the same model id.
    static func upload(
        fileURL: URL,
        apiKey: String,
        model: String,
        region: DashScopeRegion = .current
    ) async throws -> String {
        guard !apiKey.isEmpty else {
            throw CloudTranscriptionError.missingAPIKey
        }

        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        let fileSize = (attributes[.size] as? NSNumber)?.intValue ?? 0
        guard fileSize > 0 else {
            throw CloudTranscriptionError.audioFileNotFound
        }
        guard fileSize <= maxUploadBytes else {
            throw CloudTranscriptionError.apiRequestFailed(
                statusCode: 413,
                message: String(localized: "Audio exceeds the 1 GB temporary upload limit.")
            )
        }

        let policy = try await fetchUploadPolicy(apiKey: apiKey, model: model, region: region)
        return try await postFileToOSS(fileURL: fileURL, policy: policy)
    }

    // MARK: - Private

    private struct UploadPolicy {
        let uploadHost: URL
        let uploadDir: String
        let ossAccessKeyId: String
        let signature: String
        let policy: String
        let objectACL: String
        let forbidOverwrite: String
    }

    private static func fetchUploadPolicy(
        apiKey: String,
        model: String,
        region: DashScopeRegion
    ) async throws -> UploadPolicy {
        var components = URLComponents(
            url: region.nativeAPIBaseURL.appendingPathComponent("uploads"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [
            URLQueryItem(name: "action", value: "getPolicy"),
            URLQueryItem(name: "model", value: model),
        ]
        guard let url = components?.url else {
            throw CloudTranscriptionError.dataEncodingError
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 60

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw CloudTranscriptionError.noTranscriptionReturned
        }
        guard (200..<300).contains(http.statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? "Failed to get upload policy"
            throw CloudTranscriptionError.apiRequestFailed(statusCode: http.statusCode, message: message)
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let policyData = json["data"] as? [String: Any],
            let uploadHostString = policyData["upload_host"] as? String,
            let uploadHost = URL(string: uploadHostString),
            let uploadDir = policyData["upload_dir"] as? String,
            let ossAccessKeyId = policyData["oss_access_key_id"] as? String,
            let signature = policyData["signature"] as? String,
            let policy = policyData["policy"] as? String,
            let objectACL = policyData["x_oss_object_acl"] as? String,
            let forbidOverwrite = policyData["x_oss_forbid_overwrite"] as? String
        else {
            throw CloudTranscriptionError.noTranscriptionReturned
        }

        return UploadPolicy(
            uploadHost: uploadHost,
            uploadDir: uploadDir,
            ossAccessKeyId: ossAccessKeyId,
            signature: signature,
            policy: policy,
            objectACL: objectACL,
            forbidOverwrite: forbidOverwrite
        )
    }

    private static func postFileToOSS(fileURL: URL, policy: UploadPolicy) async throws -> String {
        let fileName = fileURL.lastPathComponent
        let key = "\(policy.uploadDir)/\(fileName)"
        let fileData = try Data(contentsOf: fileURL)
        let boundary = "Boundary-\(UUID().uuidString)"

        var body = Data()
        func appendField(_ name: String, _ value: String) {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
            body.append("\(value)\r\n".data(using: .utf8)!)
        }

        appendField("OSSAccessKeyId", policy.ossAccessKeyId)
        appendField("Signature", policy.signature)
        appendField("policy", policy.policy)
        appendField("x-oss-object-acl", policy.objectACL)
        appendField("x-oss-forbid-overwrite", policy.forbidOverwrite)
        appendField("key", key)
        appendField("success_action_status", "200")

        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append(
            "Content-Disposition: form-data; name=\"file\"; filename=\"\(fileName)\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: application/octet-stream\r\n\r\n".data(using: .utf8)!)
        body.append(fileData)
        body.append("\r\n".data(using: .utf8)!)
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)

        var request = URLRequest(url: policy.uploadHost)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        request.timeoutInterval = 600

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw CloudTranscriptionError.noTranscriptionReturned
        }
        guard (200..<300).contains(http.statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? "Temporary upload failed"
            throw CloudTranscriptionError.apiRequestFailed(statusCode: http.statusCode, message: message)
        }

        return "oss://\(key)"
    }
}
