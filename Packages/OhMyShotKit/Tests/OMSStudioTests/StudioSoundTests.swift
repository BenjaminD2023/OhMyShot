import AVFoundation
import Foundation
import Testing
@testable import OMSStudio

/// One at a time, as the export tests are: each makes and encodes movies.
@Suite(.serialized)
struct StudioSoundTests {
    /// A movie of `seconds` at 30 fps, 320 × 200, with an AAC track for each of `sounds`: its channels and how loud
    /// its 440 Hz tone is (0 is silence). The recorder writes the system's sound in stereo first, then the microphone in mono.
    /// The track at `muLawTrack` is µ-law instead, which the recorder never writes and an M4A can't hold.
    private static func movie(seconds: Double, sounds: [(channels: Int, loudness: Float)], muLawTrack: Int? = nil) async throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "OMSStudioSoundTests-\(UUID().uuidString).mov")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 320, AVVideoHeightKey: 200,
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: 320,
            kCVPixelBufferHeightKey as String: 200,
        ])
        // Taken as it comes, as the recorder's are: a writer waiting to interleave tracks fed one after another
        // would wait on each other.
        video.expectsMediaDataInRealTime = true
        writer.add(video)
        let audio = sounds.enumerated().map { index, sound in
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: index == muLawTrack ? [
                AVFormatIDKey: kAudioFormatULaw, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: sound.channels,
            ] : [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: sound.channels, AVEncoderBitRateKey: 64_000 * sound.channels,
            ])
            input.expectsMediaDataInRealTime = true
            writer.add(input)
            return input
        }
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        let frames = Int(seconds * 30)
        for frame in 0..<frames {
            try await Self.ready(video)
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &buffer)
            let pixels = try #require(buffer)
            CVPixelBufferLockBaseAddress(pixels, [])
            memset(CVPixelBufferGetBaseAddress(pixels), 90, CVPixelBufferGetBytesPerRow(pixels) * 200)
            CVPixelBufferUnlockBaseAddress(pixels, [])
            adaptor.append(pixels, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 30))
            // The sound of the same thirtieth of a second, 1600 samples, alongside.
            for (input, sound) in zip(audio, sounds) {
                try await Self.ready(input)
                input.append(tone(from: frame * 1600, frames: 1600, channels: sound.channels, loudness: sound.loudness))
            }
        }
        video.markAsFinished()
        audio.forEach { $0.markAsFinished() }
        await writer.finishWriting()
        #expect(writer.status == .completed)
        return url
    }

    /// Waits until `input` takes more, failing rather than hanging past five seconds.
    private static func ready(_ input: AVAssetWriterInput) async throws {
        for _ in 0..<5000 where !input.isReadyForMoreMediaData {
            try await Task.sleep(for: .milliseconds(1))
        }
        try #require(input.isReadyForMoreMediaData)
    }

    /// `frames` samples of a 440 Hz tone at `loudness`, interleaved float at 48 kHz, from sample `start`.
    private static func tone(from start: Int, frames: Int, channels: Int, loudness: Float) -> CMSampleBuffer {
        var format = AudioStreamBasicDescription(
            mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM, mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: UInt32(4 * channels), mFramesPerPacket: 1, mBytesPerFrame: UInt32(4 * channels),
            mChannelsPerFrame: UInt32(channels), mBitsPerChannel: 32, mReserved: 0
        )
        var description: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(
            allocator: nil, asbd: &format, layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil,
            formatDescriptionOut: &description
        )
        let byteCount = frames * channels * 4
        var block: CMBlockBuffer?
        CMBlockBufferCreateWithMemoryBlock(
            allocator: nil, memoryBlock: nil, blockLength: byteCount, blockAllocator: nil, customBlockSource: nil,
            offsetToData: 0, dataLength: byteCount, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block
        )
        var samples = [Float](repeating: 0, count: frames * channels)
        for index in 0..<frames {
            let value = Float(sin(Double(start + index) / 48_000 * 440 * 2 * .pi)) * loudness
            for channel in 0..<channels { samples[index * channels + channel] = value }
        }
        samples.withUnsafeBytes { bytes in
            _ = CMBlockBufferReplaceDataBytes(with: bytes.baseAddress!, blockBuffer: block!, offsetIntoDestination: 0, dataLength: byteCount)
        }
        var sample: CMSampleBuffer?
        CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: nil, dataBuffer: block!, formatDescription: description!, sampleCount: frames,
            presentationTimeStamp: CMTime(value: CMTimeValue(start), timescale: 48_000), packetDescriptions: nil, sampleBufferOut: &sample
        )
        return sample!
    }

    private static func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "OMSStudioSoundTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func renderer(_ project: StudioProject, duration: Double) -> StudioRenderer {
        StudioRenderer(
            telemetry: StudioTelemetry(width: 160, height: 100, pixelsPerPoint: 2), project: project, duration: duration,
            recordingSize: CGSize(width: 320, height: 200), background: nil
        )
    }

    /// The channels of each of the movie's audio tracks, and its length.
    private static func audio(of url: URL) async throws -> [(channels: Int, seconds: Double)] {
        var tracks: [(Int, Double)] = []
        for track in try await AVURLAsset(url: url).loadTracks(withMediaType: .audio) {
            let description = try await track.load(.formatDescriptions).first
            let channels = description.flatMap { CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee.mChannelsPerFrame } ?? 0
            tracks.append((Int(channels), try await track.load(.timeRange).duration.seconds))
        }
        return tracks
    }

    /// How loud the movie's sound is, as the root mean square of its samples; nil when it has none.
    private static func loudness(of url: URL) async throws -> Double? {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { return nil }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false, AVLinearPCMIsBigEndianKey: false,
        ])
        reader.add(output)
        reader.startReading()
        var sum = 0.0, count = 0
        while let sample = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
            let length = CMBlockBufferGetDataLength(block)
            var values = [Float](repeating: 0, count: length / 4)
            values.withUnsafeMutableBytes { bytes in
                _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: bytes.baseAddress!)
            }
            for value in values { sum += Double(value * value) }
            count += values.count
        }
        return count == 0 ? 0 : (sum / Double(count)).squareRoot()
    }

    private static func exported(_ composition: StudioComposition) async throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "OMSStudioSoundTests-\(UUID().uuidString).mp4")
        _ = try await StudioExporter.export(composition, to: url)
        return url
    }

    // MARK: Keeping the sounds apart

    @Test func theSoundsAreToldApartByTheirChannels() {
        #expect(StudioSound.sounds(ofTracksWithChannels: []) == [])
        #expect(StudioSound.sounds(ofTracksWithChannels: [2]) == [.system])
        #expect(StudioSound.sounds(ofTracksWithChannels: [1]) == [.microphone])
        #expect(StudioSound.sounds(ofTracksWithChannels: [2, 1]) == [.system, .microphone])
        #expect(StudioSound.sounds(ofTracksWithChannels: [2, 1, 1]) == nil)
    }

    @Test func aRecordingKeepsEachOfItsSoundsInAFileOfItsOwn() async throws {
        let movie = try await Self.movie(seconds: 2, sounds: [(2, 0.2), (1, 0.2)])
        let folder = try Self.folder()
        defer { [movie, folder].forEach { try? FileManager.default.removeItem(at: $0) } }

        let kept = try await StudioSound.keep(from: movie, in: folder)

        #expect(kept == [.system, .microphone])
        #expect(StudioSound.areKept(in: folder))
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path(percentEncoded: false)).sorted()
        // Nothing half written is left beside them.
        #expect(names == [StudioFiles.microphone, StudioFiles.systemAudio])
        let system = try await Self.audio(of: folder.appending(path: StudioFiles.systemAudio))
        let microphone = try await Self.audio(of: folder.appending(path: StudioFiles.microphone))
        #expect(system.count == 1 && system[0].channels == 2 && abs(system[0].seconds - 2) < 0.1)
        #expect(microphone.count == 1 && microphone[0].channels == 1 && abs(microphone[0].seconds - 2) < 0.1)
    }

    @Test func aRecordingOfOneSoundKeepsThatOneAndOneWithoutSoundKeepsNone() async throws {
        let microphoneOnly = try await Self.movie(seconds: 1, sounds: [(1, 0.2)])
        let silent = try await Self.movie(seconds: 1, sounds: [])
        let first = try Self.folder(), second = try Self.folder()
        defer { [microphoneOnly, silent, first, second].forEach { try? FileManager.default.removeItem(at: $0) } }

        #expect(try await StudioSound.keep(from: microphoneOnly, in: first) == [.microphone])
        #expect(StudioSound.files(in: first).map(\.sound) == [.microphone])
        #expect(try await StudioSound.keep(from: silent, in: second) == [])
        #expect(!StudioSound.areKept(in: second))
        #expect(try FileManager.default.contentsOfDirectory(atPath: second.path(percentEncoded: false)).isEmpty)
    }

    @Test func aSoundThatCantBeKeptKeepsNoneApart() async throws {
        // The microphone in a form an M4A can't hold as it is: the system's sound, kept first, must not stay alone.
        let movie = try await Self.movie(seconds: 1, sounds: [(2, 0.2), (1, 0.2)], muLawTrack: 1)
        let folder = try Self.folder()
        defer { [movie, folder].forEach { try? FileManager.default.removeItem(at: $0) } }

        await #expect(throws: StudioError.self) { try await StudioSound.keep(from: movie, in: folder) }
        #expect(!StudioSound.areKept(in: folder))
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path(percentEncoded: false)).isEmpty)
    }

    // MARK: Playing them

    @Test func theMovieCutsEachSoundAsItCutsThePicture() async throws {
        let movie = try await Self.movie(seconds: 2, sounds: [(2, 0.2), (1, 0.2)])
        let folder = try Self.folder()
        defer { [movie, folder].forEach { try? FileManager.default.removeItem(at: $0) } }
        _ = try await StudioSound.keep(from: movie, in: folder)
        let sounds = StudioSound.files(in: folder).map { StudioComposition.SoundSource(sound: $0.sound, asset: AVURLAsset(url: $0.url)) }

        let apart = try await StudioComposition.make(
            source: AVURLAsset(url: movie), renderer: Self.renderer(StudioProject(), duration: 2), cuts: [0.5...1], sounds: sounds
        )
        #expect(apart.sounds == [.system, .microphone])
        let tracks = try await apart.asset.loadTracks(withMediaType: .audio)
        #expect(tracks.count == 2)
        for track in tracks {
            #expect(abs(try await track.load(.timeRange).duration.seconds - 1.5) < 0.05)
        }

        // Without them, the recording's own sound plays, as one.
        let asOne = try await StudioComposition.make(source: AVURLAsset(url: movie), renderer: Self.renderer(StudioProject(), duration: 2), cuts: [])
        #expect(asOne.sounds == [.recorded])
        let silent = try await Self.movie(seconds: 1, sounds: [])
        defer { try? FileManager.default.removeItem(at: silent) }
        let none = try await StudioComposition.make(source: AVURLAsset(url: silent), renderer: Self.renderer(StudioProject(), duration: 1), cuts: [])
        #expect(none.sounds.isEmpty)
    }

    @Test func eachSoundPlaysAsLoudAsTheProjectSetsIt() async throws {
        let movie = try await Self.movie(seconds: 1, sounds: [(2, 0.2), (1, 0.2)])
        let folder = try Self.folder()
        defer { [movie, folder].forEach { try? FileManager.default.removeItem(at: $0) } }
        _ = try await StudioSound.keep(from: movie, in: folder)
        let sounds = StudioSound.files(in: folder).map { StudioComposition.SoundSource(sound: $0.sound, asset: AVURLAsset(url: $0.url)) }
        let composition = try await StudioComposition.make(
            source: AVURLAsset(url: movie), renderer: Self.renderer(StudioProject(), duration: 1), cuts: [], sounds: sounds
        )

        // As recorded, no mix is needed.
        #expect(composition.audioMix(for: StudioProject.Audio()) == nil)
        var audio = StudioProject.Audio()
        audio.system.volume = 0.5
        audio.microphone.isMuted = true
        let mix = try #require(composition.audioMix(for: audio))
        func volume(of sound: StudioSound) -> Float? {
            guard let id = composition.audioTracks.first(where: { $0.sound == sound })?.trackID,
                  let parameters = mix.inputParameters.first(where: { $0.trackID == id })
            else { return nil }
            var start: Float = -1, end: Float = -1
            var range = CMTimeRange.zero
            _ = parameters.getVolumeRamp(for: .zero, startVolume: &start, endVolume: &end, timeRange: &range)
            return start
        }
        #expect(volume(of: .system) == 0.5)
        #expect(volume(of: .microphone) == 0)
    }

    @Test func theExportPlaysEachSoundAsSetAndLeavesSoundOutWhenAllIsMuted() async throws {
        // The system's sound a tone, the microphone silent: what the movie plays is the system's sound alone.
        let movie = try await Self.movie(seconds: 2, sounds: [(2, 0.3), (1, 0)])
        let folder = try Self.folder()
        var made: [URL] = []
        defer { ([movie, folder] + made).forEach { try? FileManager.default.removeItem(at: $0) } }
        _ = try await StudioSound.keep(from: movie, in: folder)
        let sounds = StudioSound.files(in: folder).map { StudioComposition.SoundSource(sound: $0.sound, asset: AVURLAsset(url: $0.url)) }
        func export(_ audio: StudioProject.Audio) async throws -> URL {
            var project = StudioProject()
            project.audio = audio
            let composition = try await StudioComposition.make(
                source: AVURLAsset(url: movie), renderer: Self.renderer(project, duration: 2), cuts: [], sounds: sounds
            )
            let url = try await Self.exported(composition)
            made.append(url)
            return url
        }

        let full = try #require(try await Self.loudness(of: try await export(StudioProject.Audio())))
        var half = StudioProject.Audio()
        half.system.volume = 0.5
        let halfLoudness = try #require(try await Self.loudness(of: try await export(half)))
        var systemMuted = StudioProject.Audio()
        systemMuted.system.isMuted = true
        let mutedLoudness = try #require(try await Self.loudness(of: try await export(systemMuted)))
        var allMuted = StudioProject.Audio()
        allMuted.system.isMuted = true
        allMuted.microphone.volume = 0

        #expect(full > 0.1)
        #expect((0.4...0.6).contains(halfLoudness / full))
        // The microphone, silent, is all that plays.
        #expect(mutedLoudness < 0.01)
        // Nothing to hear: no sound at all.
        #expect(try await Self.audio(of: try await export(allMuted)).isEmpty)
    }

    // MARK: Keeping the project

    @Test func aProjectFromBeforeSoundsWereSetPlaysThemAsRecorded() throws {
        let old = try JSONDecoder().decode(StudioProject.self, from: Data(#"{"padding": 0.1}"#.utf8))
        #expect(old.audio == StudioProject.Audio())
        #expect(old.audio[.system].gain == 1 && old.audio[.recorded].gain == 1)

        var project = StudioProject()
        project.audio.microphone.isMuted = true
        project.audio.system.volume = 0.4
        let read = try JSONDecoder().decode(StudioProject.self, from: JSONEncoder().encode(project))
        #expect(read.audio == project.audio)
        #expect(read.audio[.microphone].gain == 0 && read.audio[.system].gain == 0.4)
    }
}
