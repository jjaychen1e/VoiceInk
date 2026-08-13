import AVFoundation
import CoreMedia
import Foundation
import OSLog
import ScreenCaptureKit

/// Errors raised while capturing system audio for Live Transcribe.
enum SystemAudioCaptureError: LocalizedError {
    case noDisplay
    case streamStartFailed(String)
    case permissionDenied

    var errorDescription: String? {
        switch self {
        case .noDisplay:
            return String(localized: "No display available for system audio capture")
        case .streamStartFailed(let message):
            return String(format: String(localized: "Failed to start system audio capture: %@"), message)
        case .permissionDenied:
            return String(localized: "Screen Recording permission is required to capture system audio")
        }
    }
}

/// Captures system audio via ScreenCaptureKit without muting media or stealing focus.
///
/// Uses a minimal discarded video surface (2×2 @ 1 fps) so Teams / Zoom screen share
/// sessions are not interrupted. Emits PCM16 / 16 kHz / mono chunks for DashScope realtime APIs.
final class SystemAudioCapture: NSObject, @unchecked Sendable {
    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "SystemAudioCapture")
    private let sampleQueue = DispatchQueue(label: "com.voiceink.liveTranscribe.audio", qos: .userInitiated)
    private let stateLock = NSLock()

    private var stream: SCStream?
    private var resampler = PCM16MonoResampler(targetSampleRate: 16_000)
    private var isCapturing = false
    private var loggedFirstChunk = false
    private var convertFailureCount = 0

    /// Called on a background queue with PCM16 / 16 kHz / mono audio.
    var onAudioChunk: ((Data) -> Void)?

    /// Whether a capture session is currently active.
    var isRunning: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return isCapturing
    }

    /// Starts system-audio capture on the main display.
    func start() async throws {
        if isRunning {
            return
        }

        if !CGPreflightScreenCaptureAccess() {
            let granted = await ScreenCaptureService.requestScreenCapturePermissionRegistration()
            guard granted else {
                throw SystemAudioCaptureError.permissionDenied
            }
        }

        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first else {
            throw SystemAudioCaptureError.noDisplay
        }

        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])

        let configuration = SCStreamConfiguration()
        configuration.capturesAudio = true
        configuration.excludesCurrentProcessAudio = true
        configuration.sampleRate = 48_000
        configuration.channelCount = 2
        // Minimal discarded video surface — required by ScreenCaptureKit, keeps CPU low.
        configuration.width = 2
        configuration.height = 2
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        configuration.showsCursor = false

        let stream = SCStream(filter: filter, configuration: configuration, delegate: nil)

        do {
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: sampleQueue)
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: sampleQueue)
            try await stream.startCapture()
        } catch {
            throw SystemAudioCaptureError.streamStartFailed(error.localizedDescription)
        }

        stateLock.lock()
        self.stream = stream
        self.resampler.reset()
        self.isCapturing = true
        self.loggedFirstChunk = false
        self.convertFailureCount = 0
        stateLock.unlock()

        logger.notice("System audio capture started (display=\(display.displayID, privacy: .public))")
    }

    /// Stops capture and releases the SCStream.
    func stop() async {
        stateLock.lock()
        let activeStream = stream
        stream = nil
        isCapturing = false
        stateLock.unlock()

        guard let activeStream else { return }

        do {
            try await activeStream.stopCapture()
        } catch {
            logger.error("stopCapture failed: \(error.localizedDescription, privacy: .public)")
        }

        logger.notice("System audio capture stopped")
    }
}

// MARK: - SCStreamOutput

extension SystemAudioCapture: SCStreamOutput {
    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        guard type == .audio else { return }
        guard CMSampleBufferIsValid(sampleBuffer), CMSampleBufferGetNumSamples(sampleBuffer) > 0 else {
            return
        }

        guard let chunk = resampler.convert(sampleBuffer: sampleBuffer), !chunk.isEmpty else {
            convertFailureCount += 1
            if convertFailureCount == 1 || convertFailureCount % 200 == 0 {
                logger.error(
                    "Audio convert failed count=\(self.convertFailureCount, privacy: .public)"
                )
            }
            return
        }

        if !loggedFirstChunk {
            loggedFirstChunk = true
            let rms = Self.pcm16RMS(chunk)
            logger.notice(
                "First audio chunk bytes=\(chunk.count, privacy: .public) rms=\(rms, privacy: .public)"
            )
        }

        onAudioChunk?(chunk)
    }

    /// Computes a simple RMS level for PCM16 mono diagnostics.
    private static func pcm16RMS(_ data: Data) -> Float {
        guard !data.isEmpty else { return 0 }
        return data.withUnsafeBytes { raw in
            let samples = raw.bindMemory(to: Int16.self)
            guard !samples.isEmpty else { return 0 }
            var sum: Float = 0
            for sample in samples {
                let value = Float(sample) / Float(Int16.max)
                sum += value * value
            }
            return sqrt(sum / Float(samples.count))
        }
    }
}

// MARK: - Resampler

/// Converts ScreenCaptureKit audio buffers into PCM16 mono at a fixed sample rate.
fileprivate struct PCM16MonoResampler {
    let targetSampleRate: Double
    private var sourceSampleRate: Double = 48_000
    private var residual: [Float] = []

    init(targetSampleRate: Double) {
        self.targetSampleRate = targetSampleRate
    }

    mutating func reset() {
        residual.removeAll(keepingCapacity: true)
        sourceSampleRate = 48_000
    }

    /// Converts one CMSampleBuffer into PCM16 mono Data, or nil if conversion fails.
    mutating func convert(sampleBuffer: CMSampleBuffer) -> Data? {
        guard let mono = Self.extractMonoFloatSamples(from: sampleBuffer, sampleRate: &sourceSampleRate),
            !mono.isEmpty
        else {
            return nil
        }

        let combined = residual + mono
        residual.removeAll(keepingCapacity: true)

        let ratio = sourceSampleRate / targetSampleRate
        guard ratio > 0 else { return nil }

        let outputCount = Int(Double(combined.count) / ratio)
        guard outputCount > 0 else {
            residual = combined
            return nil
        }

        var pcm = Data(count: outputCount * MemoryLayout<Int16>.size)
        pcm.withUnsafeMutableBytes { rawBuffer in
            guard let out = rawBuffer.bindMemory(to: Int16.self).baseAddress else { return }
            for i in 0..<outputCount {
                let sourceIndex = Double(i) * ratio
                let left = Int(sourceIndex)
                let right = min(left + 1, combined.count - 1)
                let frac = Float(sourceIndex - Double(left))
                let sample = combined[left] * (1 - frac) + combined[right] * frac
                let clipped = max(-1, min(1, sample))
                out[i] = Int16(clipped * Float(Int16.max))
            }
        }

        let consumed = min(combined.count, Int((Double(outputCount) * ratio).rounded(.up)))
        if consumed < combined.count {
            residual = Array(combined[consumed...])
        }

        return pcm
    }

    /// Extracts mono Float samples from interleaved or non-interleaved CMSampleBuffer audio.
    private static func extractMonoFloatSamples(
        from sampleBuffer: CMSampleBuffer,
        sampleRate: inout Double
    ) -> [Float]? {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
            let asbdPointer = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription)
        else {
            return nil
        }

        let asbd = asbdPointer.pointee
        if asbd.mSampleRate > 0 {
            sampleRate = asbd.mSampleRate
        }

        let frameCount = Int(CMSampleBufferGetNumSamples(sampleBuffer))
        guard frameCount > 0 else { return nil }

        var bufferListSizeNeeded = 0
        var status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: &bufferListSizeNeeded,
            bufferListOut: nil,
            bufferListSize: 0,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
            blockBufferOut: nil
        )

        // First call intentionally probes size; expect `noErr` or size-related status.
        guard bufferListSizeNeeded > 0 else { return nil }

        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: bufferListSizeNeeded,
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { raw.deallocate() }
        raw.initializeMemory(as: UInt8.self, repeating: 0, count: bufferListSizeNeeded)

        let audioBufferList = raw.bindMemory(to: AudioBufferList.self, capacity: 1)
        var blockBuffer: CMBlockBuffer?
        status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: audioBufferList,
            bufferListSize: bufferListSizeNeeded,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
            blockBufferOut: &blockBuffer
        )
        guard status == noErr else { return nil }

        let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
        guard !buffers.isEmpty else { return nil }

        let isFloat = (asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0
        var mono = [Float](repeating: 0, count: frameCount)

        if buffers.count == 1 {
            // Interleaved or mono in a single buffer.
            let buffer = buffers[0]
            guard let dataPointer = buffer.mData else { return nil }
            let channelCount = Int(max(asbd.mChannelsPerFrame, 1))

            if isFloat {
                let floatPointer = dataPointer.assumingMemoryBound(to: Float.self)
                for frame in 0..<frameCount {
                    var sum: Float = 0
                    for channel in 0..<channelCount {
                        sum += floatPointer[frame * channelCount + channel]
                    }
                    mono[frame] = sum / Float(channelCount)
                }
            } else {
                let int16Pointer = dataPointer.assumingMemoryBound(to: Int16.self)
                for frame in 0..<frameCount {
                    var sum: Float = 0
                    for channel in 0..<channelCount {
                        sum += Float(int16Pointer[frame * channelCount + channel]) / Float(Int16.max)
                    }
                    mono[frame] = sum / Float(channelCount)
                }
            }
        } else {
            // Non-interleaved: one buffer per channel.
            let channelCount = buffers.count
            for channel in 0..<channelCount {
                guard let dataPointer = buffers[channel].mData else { continue }
                if isFloat {
                    let floatPointer = dataPointer.assumingMemoryBound(to: Float.self)
                    for frame in 0..<frameCount {
                        mono[frame] += floatPointer[frame]
                    }
                } else {
                    let int16Pointer = dataPointer.assumingMemoryBound(to: Int16.self)
                    for frame in 0..<frameCount {
                        mono[frame] += Float(int16Pointer[frame]) / Float(Int16.max)
                    }
                }
            }
            let divisor = Float(max(channelCount, 1))
            for frame in 0..<frameCount {
                mono[frame] /= divisor
            }
        }

        return mono
    }
}
