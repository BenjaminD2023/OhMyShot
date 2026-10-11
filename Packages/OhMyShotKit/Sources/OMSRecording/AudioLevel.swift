import Accelerate
import CoreMedia

/// How loud a buffer of sound is, for the microphone's meter while recording.
public enum AudioLevel {
    /// The buffer's RMS as a fraction of full scale, all channels together; nil for audio that isn't linear
    /// PCM in 32-bit floats or 16-bit integers.
    public static func rms(of sample: CMSampleBuffer) -> Float? {
        guard
            let description = sample.formatDescription,
            let format = description.audioStreamBasicDescription,
            format.mFormatID == kAudioFormatLinearPCM
        else { return nil }
        let isFloat = format.mFormatFlags & kAudioFormatFlagIsFloat != 0
        guard (isFloat && format.mBitsPerChannel == 32) || (!isFloat && format.mBitsPerChannel == 16) else { return nil }
        var sum: Float = 0
        var count = 0
        do {
            try sample.withAudioBufferList { list, _ in
                for buffer in list {
                    guard let data = buffer.mData else { continue }
                    if isFloat {
                        let values = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
                        var squares: Float = 0
                        vDSP_svesq(data.assumingMemoryBound(to: Float.self), 1, &squares, vDSP_Length(values))
                        sum += squares
                        count += values
                    } else {
                        let values = Int(buffer.mDataByteSize) / MemoryLayout<Int16>.size
                        var floats = [Float](repeating: 0, count: values)
                        vDSP_vflt16(data.assumingMemoryBound(to: Int16.self), 1, &floats, 1, vDSP_Length(values))
                        var squares: Float = 0
                        vDSP_svesq(floats, 1, &squares, vDSP_Length(values))
                        sum += squares / (32_768 * 32_768)
                        count += values
                    }
                }
            }
        } catch {
            return nil
        }
        guard count > 0 else { return nil }
        return (sum / Float(count)).squareRoot()
    }

    /// Where an RMS sits on a meter from 0 to 1: -50 dBFS (a quiet room) to -10 dBFS (a raised voice) spread
    /// evenly in decibels, as meters read.
    public static func meterValue(rms: Float) -> Double {
        guard rms > 0 else { return 0 }
        let decibels = 20 * log10(Double(rms))
        return min(max((decibels + 50) / 40, 0), 1)
    }
}
