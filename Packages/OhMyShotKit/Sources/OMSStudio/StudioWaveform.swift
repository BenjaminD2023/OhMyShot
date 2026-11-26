import AVFoundation
import CoreMedia
import Foundation

/// Reads an asset's audio off the main actor into normalized peak amplitude bins (`0...1`) for rendering
/// a lightweight waveform silhouette along the Studio timeline.
nonisolated public enum StudioWaveform {
    /// Target mono sample rate used by `AVAssetReader` when computing timeline peaks.
    private static let analysisSampleRate = 8_000.0

    /// Extracts `binCount` normalized peak amplitude bins (`0...1`) across the duration of `url`.
    /// Returns an empty array when `url` has no audio tracks, cannot be read, or the task is cancelled.
    @concurrent
    public static func extract(from url: URL, binCount: Int = 200) async -> [Float] {
        guard let raw = await rawPeaks(from: url, binCount: binCount) else { return [] }
        return normalize(peaks: raw)
    }

    /// Extracts `binCount` normalized peak amplitude bins (`0...1`) combined across all readable audio assets in `urls`
    /// (for example, Studio's separate system audio and microphone `.m4a` tracks).
    @concurrent
    public static func extract(from urls: [URL], binCount: Int = 200) async -> [Float] {
        guard binCount > 0, !urls.isEmpty, !Task.isCancelled else { return [] }
        var combined: [Float]?
        for url in urls {
            guard !Task.isCancelled else { return [] }
            guard let peaks = await rawPeaks(from: url, binCount: binCount) else { continue }
            if var current = combined {
                for index in 0..<min(current.count, peaks.count) {
                    current[index] = max(current[index], peaks[index])
                }
                combined = current
            } else {
                combined = peaks
            }
        }
        guard let combined else { return [] }
        return normalize(peaks: combined)
    }

    private static func rawPeaks(from url: URL, binCount: Int) async -> [Float]? {
        guard binCount > 0, !Task.isCancelled else { return nil }
        let asset = AVURLAsset(url: url)
        guard
            let tracks = try? await asset.loadTracks(withMediaType: .audio),
            !tracks.isEmpty,
            let duration = try? await asset.load(.duration).seconds,
            duration.isFinite, duration > 0
        else { return nil }
        guard !Task.isCancelled else { return nil }

        guard let reader = try? AVAssetReader(asset: asset) else { return nil }
        let output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: analysisSampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false,
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { return nil }
        reader.add(output)
        guard reader.startReading() else { return nil }

        var bins = [Float](repeating: 0, count: binCount)
        var scratch: [Float] = []
        var buffersRead = 0
        let invDuration = Double(binCount) / duration
        let invSampleRate = 1.0 / analysisSampleRate

        while let sample = output.copyNextSampleBuffer() {
            buffersRead += 1
            if buffersRead.isMultiple(of: 16), Task.isCancelled {
                reader.cancelReading()
                return nil
            }
            guard let blockBuffer = CMSampleBufferGetDataBuffer(sample) else { continue }
            let pts = sample.presentationTimeStamp.seconds
            guard pts.isFinite else { continue }
            let byteLength = CMBlockBufferGetDataLength(blockBuffer)
            let floatCount = byteLength / MemoryLayout<Float>.stride
            guard floatCount > 0 else { continue }
            if scratch.count < floatCount {
                scratch = [Float](repeating: 0, count: floatCount)
            }
            let status = scratch.withUnsafeMutableBytes { destination in
                guard let baseAddress = destination.baseAddress else { return OSStatus(-1) }
                return CMBlockBufferCopyDataBytes(
                    blockBuffer,
                    atOffset: 0,
                    dataLength: floatCount * MemoryLayout<Float>.stride,
                    destination: baseAddress
                )
            }
            guard status == kCMBlockBufferNoErr else { continue }

            for index in 0..<floatCount {
                let value = scratch[index]
                guard value.isFinite else { continue }
                let time = pts + Double(index) * invSampleRate
                guard time >= 0 else { continue }
                let bin = min(max(Int(time * invDuration), 0), binCount - 1)
                let magnitude = abs(value)
                if magnitude > bins[bin] {
                    bins[bin] = magnitude
                }
            }
        }

        if Task.isCancelled {
            reader.cancelReading()
            return nil
        }
        return bins
    }

    /// Downsamples linear PCM mono `samples` into `binCount` normalized peak amplitude bins (`0...1`).
    public static func binPeaks(samples: [Float], binCount: Int) -> [Float] {
        guard binCount > 0 else { return [] }
        guard !samples.isEmpty else { return [Float](repeating: 0, count: binCount) }
        var bins = [Float](repeating: 0, count: binCount)
        let count = samples.count
        for index in 0..<count {
            let value = samples[index]
            guard value.isFinite else { continue }
            let bin = min(max((index * binCount) / count, 0), binCount - 1)
            let magnitude = abs(value)
            if magnitude > bins[bin] {
                bins[bin] = magnitude
            }
        }
        return normalize(peaks: bins)
    }

    /// Normalizes raw peak amplitudes into `0...1`. Non-finite and negative values clamp to `0`;
    /// silent inputs (peak `<= 1e-6`) return all zeros.
    public static func normalize(peaks: [Float]) -> [Float] {
        guard !peaks.isEmpty else { return [] }
        var maximum: Float = 0
        for value in peaks where value.isFinite && value > maximum {
            maximum = value
        }
        guard maximum > 1e-6 else {
            return [Float](repeating: 0, count: peaks.count)
        }
        return peaks.map { value in
            guard value.isFinite, value > 0 else { return 0 }
            return min(max(value / maximum, 0), 1)
        }
    }
}
