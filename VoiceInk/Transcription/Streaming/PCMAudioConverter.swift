import AVFoundation
import Foundation

enum PCMAudioConverter {
    static func float32Samples(fromPCM16Data data: Data) -> [Float] {
        let sampleCount = data.count / MemoryLayout<Int16>.size
        var samples = [Float](repeating: 0, count: sampleCount)

        data.withUnsafeBytes { rawBuffer in
            let int16Samples = rawBuffer.bindMemory(to: Int16.self)
            for index in 0..<sampleCount {
                samples[index] = max(-1.0, min(Float(Int16(littleEndian: int16Samples[index])) / 32767.0, 1.0))
            }
        }

        return samples
    }

    /// Converts normalized float32 mono samples to little-endian PCM16 bytes for streaming providers.
    static func pcm16Data(fromFloat32Samples samples: [Float]) -> Data {
        var data = Data(capacity: samples.count * MemoryLayout<Int16>.size)
        for sample in samples {
            let clamped = max(-1.0, min(1.0, sample))
            var value = Int16(clamped * Float(Int16.max)).littleEndian
            withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
        }
        return data
    }

    static func pcmBuffer(fromPCM16Data data: Data) -> AVAudioPCMBuffer? {
        let samples = float32Samples(fromPCM16Data: data)
        guard !samples.isEmpty,
            let format = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: 16000.0,
                channels: 1,
                interleaved: false
            ),
            let buffer = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(samples.count)
            ),
            let channel = buffer.floatChannelData?[0]
        else {
            return nil
        }

        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { pointer in
            guard let baseAddress = pointer.baseAddress else { return }
            channel.update(from: baseAddress, count: samples.count)
        }

        return buffer
    }
}
