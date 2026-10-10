import AVFoundation
import CoreMedia
import Foundation
import VideoToolbox

/// How a recording's video is encoded: codec, frame size, frame rate, and quality.
///
/// Measured on this hardware (Docs/perf.md, M4 spike): the H.264 hardware encoder takes no side over 4096
/// pixels (AVAssetWriter fails beyond it, and there is no usable software fallback), while HEVC's goes to
/// 8192 × 4320. So H.264 is used whenever the frame fits, for players and sites that lack HEVC, and HEVC
/// otherwise, or always when asked for.
public struct RecordingFormat: Equatable, Sendable {
    public enum Codec: String, Sendable {
        case h264
        case hevc

        public var avCodec: AVVideoCodecType {
            switch self {
            case .h264: .h264
            case .hevc: .hevc
            }
        }
    }

    public var codec: Codec
    /// The frame in pixels; both sides even, as 4:2:0 video wants and some decoders require.
    public var width: Int
    public var height: Int
    public var framesPerSecond: Int
    /// Constant-quality encoding, 0 to 1. Screen content is mostly still, so a quality target spends bits
    /// only where something moves; 0.6 keeps 2× text sharp while scrolling (the spike's text frames).
    public var quality: Double

    /// The largest side the H.264 hardware encoder takes.
    public static let largestH264Side = 4096
    /// The quality recordings use unless Settings says otherwise.
    public static let standardQuality = 0.6

    public init(codec: Codec, width: Int, height: Int, framesPerSecond: Int, quality: Double = Self.standardQuality) {
        self.codec = codec
        self.width = width
        self.height = height
        self.framesPerSecond = framesPerSecond
        self.quality = quality
    }

    /// The format for a frame of `width` × `height` pixels (made even, never larger): H.264 when it fits
    /// the hardware encoder, unless HEVC is preferred.
    public static func choose(width: Int, height: Int, framesPerSecond: Int, quality: Double = Self.standardQuality, prefersHEVC: Bool = false) -> RecordingFormat {
        let evenWidth = max(2, width - width % 2)
        let evenHeight = max(2, height - height % 2)
        let fitsH264 = evenWidth <= largestH264Side && evenHeight <= largestH264Side
        return RecordingFormat(
            codec: prefersHEVC || !fitsH264 ? .hevc : .h264,
            width: evenWidth, height: evenHeight, framesPerSecond: framesPerSecond, quality: quality
        )
    }

    /// AVAssetWriter's settings for the video track while recording. The pixel buffers' own color tags are
    /// kept: the stream tags them as it converts the display's pixels.
    public var videoSettings: [String: Any] {
        videoSettings(realTime: true)
    }

    /// The same, for encoding as fast as the encoder goes (`realTime` false), as an edited recording is.
    public func videoSettings(realTime: Bool) -> [String: Any] {
        var properties: [String: Any] = [
            AVVideoQualityKey: quality,
            AVVideoExpectedSourceFrameRateKey: framesPerSecond,
            // A key frame at least every two seconds: seeking stays quick and a file cut short by a crash
            // starts decoding soon after any point.
            AVVideoMaxKeyFrameIntervalDurationKey: 2,
            // No B-frames: frames leave the encoder in the order they came, with less latency.
            AVVideoAllowFrameReorderingKey: false,
            kVTCompressionPropertyKey_RealTime as String: realTime,
        ]
        properties[AVVideoProfileLevelKey] = switch codec {
        case .h264: AVVideoProfileLevelH264HighAutoLevel
        case .hevc: kVTProfileLevel_HEVC_Main_AutoLevel as String
        }
        return [
            AVVideoCodecKey: codec.avCodec,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: properties,
            // Hardware only: a software encoder at these sizes would cost a core or more.
            AVVideoEncoderSpecificationKey: [kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder as String: true],
        ]
    }

    /// The minimum time between frames for the stream.
    public var frameInterval: CMTime {
        CMTime(value: 1, timescale: CMTimeScale(max(1, framesPerSecond)))
    }
}

/// The audio a recording keeps, each in a track of its own while recording; they are mixed into one when
/// the file is finished.
public struct RecordingAudio: Equatable, Sendable {
    /// What the Mac plays, without this app's own sounds.
    public var system: Bool
    /// A microphone: the system's default input, or the device with this unique ID.
    public var microphone: Microphone?

    public enum Microphone: Equatable, Sendable {
        case systemDefault
        case device(String)

        public var deviceID: String? {
            if case .device(let id) = self { id } else { nil }
        }
    }

    public static let none = RecordingAudio(system: false, microphone: nil)

    public init(system: Bool, microphone: Microphone?) {
        self.system = system
        self.microphone = microphone
    }

    public var isEmpty: Bool { !system && microphone == nil }

    static let sampleRate = 48_000

    /// AAC for a track: stereo for what the Mac plays, mono for a voice.
    static func settings(channels: Int) -> [String: Any] {
        var layout = AudioChannelLayout()
        layout.mChannelLayoutTag = channels == 1 ? kAudioChannelLayoutTag_Mono : kAudioChannelLayoutTag_Stereo
        return [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels,
            AVEncoderBitRateKey: channels == 1 ? 96_000 : 160_000,
            AVChannelLayoutKey: Data(bytes: &layout, count: MemoryLayout<AudioChannelLayout>.size),
        ]
    }
}
