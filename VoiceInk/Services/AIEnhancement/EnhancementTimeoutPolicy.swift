import Foundation

/// Resolves Enhancement request timeouts for different transcription entry points.
enum EnhancementTimeoutPolicy {
    /// Mic / default path uses the user-configured timeout.
    static func standard(baseTimeout: TimeInterval) -> TimeInterval {
        baseTimeout
    }

    /// File queue / retranscribe: longer floor scaled by transcript length.
    ///
    /// - Floor: 60s (or `baseTimeout` if higher)
    /// - Scale: ~50 characters per extra second
    /// - Cap: 300s
    static func forFileTranscription(text: String, baseTimeout: TimeInterval) -> TimeInterval {
        let scaled = 60.0 + Double(text.count) / 50.0
        return max(baseTimeout, min(300.0, scaled))
    }
}
