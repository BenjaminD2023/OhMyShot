import AVFoundation
import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import Testing
@testable import OMSStudio

/// Covers Studio productivity features on top of v0.4.0 schemas: master audio & fades, cut micro-fades,
/// waveform extraction (M-02), shuttle playback, pinch viewport zoom, and telemetry ticks (M-17).
@Suite(.serialized)
@MainActor
struct StudioProductivityTests {
    // MARK: M-02 — Audio Codable & Clamping

    @Test func audioMasterAndFadesDecodeBackwardsCompatiblyAndClamp() throws {
        // Legacy pre-audio project.json decodes cleanly to default Audio().
        let legacyJSON = """
        {
          "background": {"gradient": {"_0": "sky"}},
          "padding": 0.08,
          "cornerRadius": 12,
          "shadow": 0.5,
          "aspect": "auto",
          "cursor": {"size": 1.5, "smoothing": 0.5, "hidesWhenIdle": true, "showsClicks": true},
          "zooms": [],
          "cuts": [],
          "showsKeys": true
        }
        """
        let decodedLegacy = try JSONDecoder().decode(StudioProject.self, from: Data(legacyJSON.utf8))
        #expect(decodedLegacy.audio == StudioProject.Audio())

        // v0.4.0 audio JSON (without master/fadeIn/fadeOut) decodes cleanly with default master and 0 fades.
        let v040AudioJSON = """
        {
          "system": {"isMuted": false, "volume": 0.7},
          "microphone": {"isMuted": true, "volume": 0.5},
          "recorded": {"isMuted": false, "volume": 1.0}
        }
        """
        let decodedV040 = try JSONDecoder().decode(StudioProject.Audio.self, from: Data(v040AudioJSON.utf8))
        #expect(decodedV040.system == .init(isMuted: false, volume: 0.7))
        #expect(decodedV040.microphone == .init(isMuted: true, volume: 0.5))
        #expect(decodedV040.master == .init())
        #expect(decodedV040.fadeIn == 0 && decodedV040.fadeOut == 0)

        // Out-of-range fade values clamp safely to 0...maxFade on decode and init.
        let clampedAudioJSON = """
        {
          "master": {"isMuted": false, "volume": 0.5},
          "system": {"isMuted": false, "volume": 0.8},
          "fadeIn": -2.0,
          "fadeOut": 12.0
        }
        """
        let clamped = try JSONDecoder().decode(StudioProject.Audio.self, from: Data(clampedAudioJSON.utf8))
        #expect(clamped.fadeIn == 0)
        #expect(clamped.fadeOut == StudioProject.Audio.maxFade)
        #expect(abs(clamped.effectiveGain(for: .system) - 0.4) < 1e-9)

        // Round-trip preserves all fields cleanly.
        var project = decodedLegacy
        project.audio = StudioProject.Audio(
            system: .init(isMuted: false, volume: 0.6),
            microphone: .init(isMuted: false, volume: 0.9),
            recorded: .init(isMuted: false, volume: 0.8),
            master: .init(isMuted: false, volume: 0.75),
            fadeIn: 0.5,
            fadeOut: 1.25
        )
        let roundTripped = try JSONDecoder().decode(StudioProject.self, from: JSONEncoder().encode(project))
        #expect(roundTripped == project)
    }

    @Test func documentAudioMasterAndFadeControlsSupportUndoWithoutRebuildingPreview() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "OMSStudioAudioDoc-\(UUID())")
        defer { try? FileManager.default.removeItem(at: folder) }
        let document = StudioDocument(
            source: folder.appending(path: "source.mp4"),
            telemetry: StudioTelemetry(width: 160, height: 100, pixelsPerPoint: 2, samples: [.init(time: 0, x: 80, y: 50, cursor: 0)]),
            project: StudioProject(), duration: 4, recordingSize: CGSize(width: 320, height: 200),
            folder: folder, hasBeenExported: false, background: { _, _ in nil }
        )
        defer { document.releasePreview() }
        let undo = UndoManager()
        undo.groupsByEvent = false
        document.undoManagerProvider = { undo }

        let initialPreviewState = document.previewState
        undo.beginUndoGrouping()
        document.setMasterMuted(true)
        undo.endUndoGrouping()
        #expect(document.project.audio.master.isMuted)
        #expect(document.previewState == initialPreviewState)
        #expect(undo.undoActionName == "Mute Audio")

        undo.beginUndoGrouping()
        document.beginContinuousChange()
        document.project.audio.master.volume = 0.5
        document.project.audio[.system].volume = 0.4
        document.setAudioFadeIn(0.75)
        document.setAudioFadeOut(1.25)
        document.endContinuousChange()
        undo.endUndoGrouping()
        #expect(document.project.audio.master.volume == 0.5)
        #expect(document.project.audio.system.volume == 0.4)
        #expect(document.project.audio.fadeIn == 0.75)
        #expect(document.project.audio.fadeOut == 1.25)

        undo.undo()
        #expect(document.project.audio.master.volume == 1.0)
        #expect(document.project.audio.fadeIn == 0 && document.project.audio.fadeOut == 0)
        #expect(document.project.audio.master.isMuted)

        undo.undo()
        #expect(!document.project.audio.master.isMuted)
    }

    // MARK: M-02 — Audio Mix, Fades, Cut Micro-Fades & Export

    private static func volumeAt(_ seconds: Double, in parameters: AVAudioMixInputParameters) -> Float? {
        var start: Float = 0, end: Float = 0
        var range = CMTimeRange()
        let t = StudioComposition.time(seconds)
        guard parameters.getVolumeRamp(for: t, startVolume: &start, endVolume: &end, timeRange: &range) else {
            return nil
        }
        let duration = range.duration.seconds
        guard duration.isFinite, duration > 0 else { return start }
        let fraction = min(max((t.seconds - range.start.seconds) / duration, 0), 1)
        return start + (end - start) * Float(fraction)
    }

    @Test func audioMixHonorsMasterGainPerSoundBalanceFadesAndCutMicroFades() throws {
        let singleSegment = [StudioComposition.Segment(movieStart: 0, sourceStart: 0, duration: 4.0)]
        let recordedTrack = [StudioComposition.AudioTrack(sound: .recorded, trackID: 1)]

        // Default audio with no real cut gaps returns nil (preserving StudioSoundTests invariant).
        #expect(StudioComposition.makeAudioMix(tracks: recordedTrack, segments: singleSegment, duration: 4.0, audio: StudioProject.Audio()) == nil)

        // Master mute sets track volume to 0 across the duration.
        let mutedMix = try #require(StudioComposition.makeAudioMix(
            tracks: recordedTrack, segments: singleSegment, duration: 4.0,
            audio: StudioProject.Audio(master: .init(isMuted: true, volume: 0.8))
        ))
        #expect(Self.volumeAt(2.0, in: try #require(mutedMix.inputParameters.first)) == 0)

        // Dual-track system/microphone balance multiplied by master volume.
        let dualTracks = [
            StudioComposition.AudioTrack(sound: .system, trackID: 10),
            StudioComposition.AudioTrack(sound: .microphone, trackID: 20),
        ]
        let balancedMix = try #require(StudioComposition.makeAudioMix(
            tracks: dualTracks, segments: singleSegment, duration: 4.0,
            audio: StudioProject.Audio(
                system: .init(volume: 0.5),
                microphone: .init(volume: 1.0),
                master: .init(volume: 0.8)
            )
        ))
        let sysParams = try #require(balancedMix.inputParameters.first { $0.trackID == 10 })
        let micParams = try #require(balancedMix.inputParameters.first { $0.trackID == 20 })
        #expect(abs((Self.volumeAt(2.0, in: sysParams) ?? -1) - 0.4) < 0.001)
        #expect(abs((Self.volumeAt(2.0, in: micParams) ?? -1) - 0.8) < 0.001)

        // Fade-in (1s) and fade-out (1s) over 4s at master 0.8.
        let fadedMix = try #require(StudioComposition.makeAudioMix(
            tracks: recordedTrack, segments: singleSegment, duration: 4.0,
            audio: StudioProject.Audio(master: .init(volume: 0.8), fadeIn: 1.0, fadeOut: 1.0)
        ))
        let fadeParams = try #require(fadedMix.inputParameters.first)
        #expect(abs((Self.volumeAt(0.0, in: fadeParams) ?? -1) - 0.0) < 0.01)
        #expect(abs((Self.volumeAt(0.5, in: fadeParams) ?? -1) - 0.4) < 0.01)
        #expect(abs((Self.volumeAt(2.0, in: fadeParams) ?? -1) - 0.8) < 0.01)
        #expect(abs((Self.volumeAt(3.5, in: fadeParams) ?? -1) - 0.4) < 0.01)

        // Overlapping fade-in + fade-out > duration scales proportionally without overlapping ramps.
        let longFadeMix = try #require(StudioComposition.makeAudioMix(
            tracks: recordedTrack, segments: singleSegment, duration: 4.0,
            audio: StudioProject.Audio(fadeIn: 3.0, fadeOut: 3.0)
        ))
        let longParams = try #require(longFadeMix.inputParameters.first)
        #expect(abs((Self.volumeAt(1.0, in: longParams) ?? -1) - 0.5) < 0.02)
        #expect(abs((Self.volumeAt(2.0, in: longParams) ?? -1) - 1.0) < 0.02)
        #expect(abs((Self.volumeAt(3.0, in: longParams) ?? -1) - 0.5) < 0.02)

        // Interior cut gap receives 15 ms micro-fade dip and recovery.
        let cutSegments = [
            StudioComposition.Segment(movieStart: 0, sourceStart: 0, duration: 2.0),
            StudioComposition.Segment(movieStart: 2.0, sourceStart: 3.0, duration: 2.0),
        ]
        let cutMix = try #require(StudioComposition.makeAudioMix(
            tracks: recordedTrack, segments: cutSegments, duration: 4.0,
            audio: StudioProject.Audio()
        ))
        let cutParams = try #require(cutMix.inputParameters.first)
        #expect(abs((Self.volumeAt(1.0, in: cutParams) ?? -1) - 1.0) < 0.01)
        #expect((Self.volumeAt(1.9925, in: cutParams) ?? 1) < 0.6)
        #expect(abs((Self.volumeAt(2.0, in: cutParams) ?? -1) - 0.0) < 0.02)
        #expect((Self.volumeAt(2.0075, in: cutParams) ?? 1) < 0.6)
        #expect(abs((Self.volumeAt(3.0, in: cutParams) ?? -1) - 1.0) < 0.01)
    }

    @Test func masterMuteExportsNoAudioTracksAndMasterVolumeAttenuatesExport() async throws {
        let videoURL = try await Self.makeTestMovie(seconds: 2, withAudio: true, toneAmplitude: 0.4)
        let systemURL = try await Self.makeAudioFile(seconds: 2, channels: 2, amplitude: 0.5)
        let micURL = try await Self.makeAudioFile(seconds: 2, channels: 1, amplitude: 0.25)
        let mutedOut = FileManager.default.temporaryDirectory.appending(path: "OMSStudioMasterMuted-\(UUID()).mp4")
        let attenuatedOut = FileManager.default.temporaryDirectory.appending(path: "OMSStudioMasterAtten-\(UUID()).mp4")
        defer { [videoURL, systemURL, micURL, mutedOut, attenuatedOut].forEach { try? FileManager.default.removeItem(at: $0) } }

        let telemetry = StudioTelemetry(width: 160, height: 100, pixelsPerPoint: 2)
        let sounds: [StudioComposition.SoundSource] = [
            .init(sound: .system, asset: AVURLAsset(url: systemURL)),
            .init(sound: .microphone, asset: AVURLAsset(url: micURL)),
        ]

        // Master mute writes 0 audio tracks on export (matching v0.4.0 StudioSoundTests invariant).
        var mutedProject = StudioProject(background: .color(red: 1, green: 1, blue: 1), padding: 0)
        mutedProject.shadow = 0
        mutedProject.audio.master.isMuted = true
        let mutedRenderer = StudioRenderer(telemetry: telemetry, project: mutedProject, duration: 2, recordingSize: CGSize(width: 320, height: 200), background: nil)
        let mutedComposition = try await StudioComposition.make(
            source: AVURLAsset(url: videoURL), renderer: mutedRenderer, cuts: [], sounds: sounds
        )
        #expect(try await mutedComposition.asset.loadTracks(withMediaType: .audio).count == 2)
        _ = try await StudioExporter.export(mutedComposition, to: mutedOut)
        #expect(try await AVURLAsset(url: mutedOut).loadTracks(withMediaType: .audio).isEmpty)

        // System muted, microphone 100%, master 50% -> exports 1 audio track attenuated below full system loudness.
        var attenuatedProject = mutedProject
        attenuatedProject.audio = StudioProject.Audio(
            system: .init(isMuted: true, volume: 1.0),
            microphone: .init(isMuted: false, volume: 1.0),
            master: .init(isMuted: false, volume: 0.5)
        )
        let attenuatedRenderer = StudioRenderer(telemetry: telemetry, project: attenuatedProject, duration: 2, recordingSize: CGSize(width: 320, height: 200), background: nil)
        let attenuatedComposition = try await StudioComposition.make(
            source: AVURLAsset(url: videoURL), renderer: attenuatedRenderer, cuts: [], sounds: sounds
        )
        _ = try await StudioExporter.export(attenuatedComposition, to: attenuatedOut)
        #expect(try await AVURLAsset(url: attenuatedOut).loadTracks(withMediaType: .audio).count == 1)
        let rms = try await Self.rmsLoudness(of: attenuatedOut)
        #expect(rms > 0.02 && rms < 0.2, "attenuated export RMS was \(rms)")
    }

    // MARK: M-02 — Waveform

    @Test func waveformNormalizationBinningAndExtraction() async throws {
        #expect(StudioWaveform.normalize(peaks: []).isEmpty)
        #expect(StudioWaveform.normalize(peaks: [0, 0, 0]) == [0, 0, 0])
        #expect(StudioWaveform.normalize(peaks: [1e-7, 0]) == [0, 0])
        #expect(StudioWaveform.normalize(peaks: [0.2, 0.4, 0.1]) == [0.5, 1.0, 0.25])
        #expect(StudioWaveform.normalize(peaks: [.nan, -0.5, 0.25, .infinity, 0.5]) == [0, 0, 0.5, 0, 1.0])

        let binned = StudioWaveform.binPeaks(samples: [0.1, -0.2, 0.0, 0.4, -0.8, 0.2], binCount: 3)
        #expect(binned.count == 3)
        #expect(abs(binned[0] - 0.25) < 0.001)
        #expect(abs(binned[1] - 0.5) < 0.001)
        #expect(abs(binned[2] - 1.0) < 0.001)

        // End-to-end extraction from a real audio file, multiple sidecar files, and a silent video-only file.
        let audioFile = try await Self.makeAudioFile(seconds: 1, channels: 2, amplitude: 0.5)
        let quietFile = try await Self.makeAudioFile(seconds: 1, channels: 1, amplitude: 0.2)
        let videoOnlyFile = try await Self.makeTestMovie(seconds: 1, withAudio: false, toneAmplitude: 0)
        defer { [audioFile, quietFile, videoOnlyFile].forEach { try? FileManager.default.removeItem(at: $0) } }

        let extracted = await StudioWaveform.extract(from: audioFile, binCount: 64)
        #expect(extracted.count == 64)
        #expect(extracted.allSatisfy { $0 >= 0 && $0 <= 1 })
        #expect((extracted.max() ?? 0) > 0.99)

        let combined = await StudioWaveform.extract(from: [audioFile, quietFile], binCount: 64)
        #expect(combined.count == 64)
        #expect((combined.max() ?? 0) > 0.99)

        #expect(await StudioWaveform.extract(from: videoOnlyFile, binCount: 64).isEmpty)
    }

    // MARK: M-17 — Shuttle, Pinch Viewport & Telemetry Ticks

    @Test func shuttleRatesPinchViewportAndTelemetryTickCoalescing() {
        // J / K / L shuttle progression and transport pill labels.
        #expect(StudioShuttle.nextForwardRate(from: 0) == 1)
        #expect(StudioShuttle.nextForwardRate(from: 1) == 2)
        #expect(StudioShuttle.nextForwardRate(from: 2) == 4)
        #expect(StudioShuttle.nextForwardRate(from: 4) == 4)
        #expect(StudioShuttle.nextForwardRate(from: -1) == 1)

        #expect(StudioShuttle.nextReverseRate(from: 0, canPlayReverse: true, canPlayFastReverse: true) == -1)
        #expect(StudioShuttle.nextReverseRate(from: -1, canPlayReverse: true, canPlayFastReverse: true) == -2)
        #expect(StudioShuttle.nextReverseRate(from: -2, canPlayReverse: true, canPlayFastReverse: true) == -2)
        #expect(StudioShuttle.nextReverseRate(from: 2, canPlayReverse: true, canPlayFastReverse: true) == -1)
        #expect(StudioShuttle.nextReverseRate(from: -1, canPlayReverse: true, canPlayFastReverse: false) == -1)
        #expect(StudioShuttle.nextReverseRate(from: 0, canPlayReverse: false, canPlayFastReverse: false) == nil)

        #expect(TransportBar.shuttleLabel(2) == "2×")
        #expect(TransportBar.shuttleLabel(4) == "4×")
        #expect(TransportBar.shuttleLabel(-1) == "−1×")
        #expect(TransportBar.shuttleLabel(-2) == "−2×")

        // Pinch viewport `setSpan` preserves anchor screen fraction and updates `zoomLevel`.
        var viewport = StudioTimelineViewport(duration: 20)
        #expect(abs(viewport.zoomLevel - 1.0) < 1e-9)
        let anchorX = viewport.position(of: 8.0, width: 1000)
        viewport.setSpan(5.0, around: 8.0, anchorFraction: 0.4)
        #expect(abs(viewport.zoomLevel - 4.0) < 1e-9)
        #expect(abs(viewport.position(of: 8.0, width: 1000) - anchorX) < 1e-6)

        // Telemetry tick positions filter to viewport and coalesce dense events.
        var zoomed = StudioTimelineViewport(duration: 10)
        zoomed.fit(2.0...4.0)
        let events = [0.5, 2.5, 2.501, 2.502, 3.5, 9.0]
        let positions = StudioTimeline.visibleEventPositions(times: events, viewport: zoomed, width: 400, minimumSpacing: 3.5)
        #expect(positions.count == 2)
        #expect(positions[1] - positions[0] > 100)
    }

    // MARK: Synthetic Media Helpers

    private static func makeAudioFile(seconds: Int, channels: Int, amplitude: Float) async throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "OMSStudioAudio-\(UUID()).m4a")
        let writer = try AVAssetWriter(outputURL: url, fileType: .m4a)
        var layout = AudioChannelLayout()
        layout.mChannelLayoutTag = channels == 1 ? kAudioChannelLayoutTag_Mono : kAudioChannelLayoutTag_Stereo
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: channels,
            AVEncoderBitRateKey: channels == 1 ? 96_000 : 160_000,
            AVChannelLayoutKey: Data(bytes: &layout, count: MemoryLayout<AudioChannelLayout>.size),
        ])
        writer.add(input)
        guard writer.startWriting() else {
            throw StudioError.writingFailed("makeAudioFile startWriting failed: \(String(describing: writer.error))")
        }
        writer.startSession(atSourceTime: .zero)
        let sampleRate = 48_000
        let framesPerBuffer = 960
        var offset = 0
        while offset < seconds * sampleRate {
            while !input.isReadyForMoreMediaData {
                guard writer.status == .writing else {
                    throw StudioError.writingFailed("makeAudioFile writer status \(writer.status.rawValue): \(String(describing: writer.error))")
                }
                try await Task.sleep(for: .milliseconds(1))
            }
            let sample = try Self.sineAudioSample(at: offset, frames: framesPerBuffer, channels: channels, sampleRate: sampleRate, amplitude: amplitude)
            guard input.append(sample) else {
                throw StudioError.writingFailed("makeAudioFile append failed: \(String(describing: writer.error))")
            }
            offset += framesPerBuffer
        }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw StudioError.writingFailed("makeAudioFile finish failed: \(String(describing: writer.error))")
        }
        return url
    }

    private static func makeTestMovie(seconds: Int, withAudio: Bool, toneAmplitude: Float) async throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "OMSStudioMovie-\(UUID()).mov")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 320, AVVideoHeightKey: 200,
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: videoInput, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 320, kCVPixelBufferHeightKey as String: 200,
        ])
        writer.add(videoInput)
        var audioInput: AVAssetWriterInput?
        if withAudio {
            var layout = AudioChannelLayout()
            layout.mChannelLayoutTag = kAudioChannelLayoutTag_Stereo
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 160_000,
                AVChannelLayoutKey: Data(bytes: &layout, count: MemoryLayout<AudioChannelLayout>.size),
            ])
            writer.add(input)
            audioInput = input
        }
        guard writer.startWriting() else {
            throw StudioError.writingFailed("makeTestMovie startWriting failed: \(String(describing: writer.error))")
        }
        writer.startSession(atSourceTime: .zero)
        // Feed whichever track AVAssetWriter is ready to accept and mark each finished immediately at EOF.
        let totalVideoFrames = seconds * 30
        let totalAudioSamples = seconds * 48_000
        var videoFrame = 0
        var audioOffset = 0
        var videoMarkedFinished = false
        var audioMarkedFinished = audioInput == nil
        let deadline = ContinuousClock.now + .seconds(30)
        while !videoMarkedFinished || !audioMarkedFinished {
            guard writer.status == .writing else {
                throw StudioError.writingFailed("makeTestMovie writer status \(writer.status.rawValue): \(String(describing: writer.error))")
            }
            if !videoMarkedFinished, videoFrame >= totalVideoFrames {
                videoInput.markAsFinished()
                videoMarkedFinished = true
                continue
            }
            if !audioMarkedFinished, audioOffset >= totalAudioSamples {
                audioInput?.markAsFinished()
                audioMarkedFinished = true
                continue
            }
            let videoReady = !videoMarkedFinished && videoInput.isReadyForMoreMediaData
            let audioReady = !audioMarkedFinished && (audioInput?.isReadyForMoreMediaData == true)
            let videoTime = Double(videoFrame) / 30.0
            let audioTime = Double(audioOffset) / 48_000.0
            if videoReady && (!audioReady || videoTime <= audioTime) {
                var buffer: CVPixelBuffer?
                CVPixelBufferPoolCreatePixelBuffer(nil, try #require(adaptor.pixelBufferPool), &buffer)
                let pixels = try #require(buffer)
                CVPixelBufferLockBaseAddress(pixels, [])
                memset(CVPixelBufferGetBaseAddress(pixels), 90, CVPixelBufferGetBytesPerRow(pixels) * 200)
                CVPixelBufferUnlockBaseAddress(pixels, [])
                guard adaptor.append(pixels, withPresentationTime: CMTime(value: CMTimeValue(videoFrame), timescale: 30)) else {
                    throw StudioError.writingFailed("makeTestMovie video append failed: \(String(describing: writer.error))")
                }
                videoFrame += 1
            } else if audioReady, let audioInput {
                let count = min(960, totalAudioSamples - audioOffset)
                let sample = try Self.sineAudioSample(at: audioOffset, frames: count, channels: 2, sampleRate: 48_000, amplitude: toneAmplitude)
                guard audioInput.append(sample) else {
                    throw StudioError.writingFailed("makeTestMovie audio append failed: \(String(describing: writer.error))")
                }
                audioOffset += count
            } else {
                guard ContinuousClock.now < deadline else {
                    throw StudioError.writingFailed("makeTestMovie timed out")
                }
                try await Task.sleep(for: .milliseconds(1))
            }
        }
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw StudioError.writingFailed("makeTestMovie finish failed: \(String(describing: writer.error))")
        }
        return url
    }

    private static func sineAudioSample(at sampleOffset: Int, frames: Int, channels: Int, sampleRate: Int, amplitude: Float) throws -> CMSampleBuffer {
        var asbd = AudioStreamBasicDescription(
            mSampleRate: Double(sampleRate),
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: UInt32(4 * channels),
            mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(4 * channels),
            mChannelsPerFrame: UInt32(channels),
            mBitsPerChannel: 32,
            mReserved: 0
        )
        var format: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &format)
        let description = try #require(format)

        let totalFloats = frames * channels
        var samples = [Float](repeating: 0, count: totalFloats)
        for frame in 0..<frames {
            let value = sin(Float(sampleOffset + frame) * 2 * .pi * 440 / Float(sampleRate)) * amplitude
            for channel in 0..<channels {
                samples[frame * channels + channel] = value
            }
        }
        let byteCount = totalFloats * MemoryLayout<Float>.stride
        var block: CMBlockBuffer?
        CMBlockBufferCreateWithMemoryBlock(
            allocator: nil, memoryBlock: nil, blockLength: byteCount, blockAllocator: nil, customBlockSource: nil,
            offsetToData: 0, dataLength: byteCount, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block
        )
        let blockBuffer = try #require(block)
        _ = samples.withUnsafeBytes { bytes in
            CMBlockBufferReplaceDataBytes(with: bytes.baseAddress!, blockBuffer: blockBuffer, offsetIntoDestination: 0, dataLength: byteCount)
        }
        var sampleBuffer: CMSampleBuffer?
        let pts = CMTime(value: CMTimeValue(sampleOffset), timescale: CMTimeScale(sampleRate))
        CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: nil, dataBuffer: blockBuffer, formatDescription: description, sampleCount: frames,
            presentationTimeStamp: pts, packetDescriptions: nil, sampleBufferOut: &sampleBuffer
        )
        return try #require(sampleBuffer)
    }

    private static func rmsLoudness(of url: URL) async throws -> Double {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard !tracks.isEmpty else { return 0 }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false, AVLinearPCMIsBigEndianKey: false,
        ])
        reader.add(output)
        guard reader.startReading() else { return 0 }
        var sumSquares = 0.0
        var count = 0
        var scratch: [Float] = []
        while let sample = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
            let floats = CMBlockBufferGetDataLength(block) / MemoryLayout<Float>.stride
            guard floats > 0 else { continue }
            if scratch.count < floats { scratch = [Float](repeating: 0, count: floats) }
            let status = scratch.withUnsafeMutableBytes { dest in
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: floats * MemoryLayout<Float>.stride, destination: dest.baseAddress!)
            }
            guard status == kCMBlockBufferNoErr else { continue }
            for i in 0..<floats {
                let v = Double(scratch[i])
                sumSquares += v * v
                count += 1
            }
        }
        return count > 0 ? (sumSquares / Double(count)).squareRoot() : 0
    }
}
