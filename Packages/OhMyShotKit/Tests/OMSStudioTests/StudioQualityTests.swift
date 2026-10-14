import AVFoundation
import Foundation
import Testing
@testable import OMSStudio

@MainActor
struct StudioQualityTests {
    @Test func theQualityIsSavedWithTheProjectAndStandardWhenAnOldProjectHasNone() throws {
        var project = StudioProject()
        #expect(project.quality == .standard)
        project.quality = .best
        #expect(try JSONDecoder().decode(StudioProject.self, from: JSONEncoder().encode(project)).quality == .best)
        // A project saved before the setting existed.
        let old = #"{"padding":0.1,"shadow":0.6,"aspect":"auto"}"#
        #expect(try JSONDecoder().decode(StudioProject.self, from: Data(old.utf8)).quality == .standard)
        // And a different quality is a different project: a movie made at the other is not this one's.
        #expect(StudioProject(quality: .smaller) != StudioProject())
    }

    @Test func eachQualityHasItsEncoderSettingInBothCodecs() throws {
        let colors = StudioComposition.Colors(of: nil)
        let values: [(StudioProject.Quality, Double)] = [(.smaller, 0.45), (.standard, 0.6), (.best, 0.8)]
        for (quality, value) in values {
            for (canvas, codec) in [(CGSize(width: 1920, height: 1080), AVVideoCodecType.h264), (CGSize(width: 5120, height: 2880), .hevc)] {
                let settings = StudioExporter.videoSettings(canvas: canvas, quality: quality, colors: colors)
                #expect(settings[AVVideoCodecKey] as? AVVideoCodecType == codec)
                let properties = try #require(settings[AVVideoCompressionPropertiesKey] as? [String: Any])
                #expect(properties[AVVideoQualityKey] as? Double == value, "\(quality) in \(codec.rawValue)")
            }
        }
    }

    private func estimate(
        bytes: Int = 10_000_000, size: CGSize = CGSize(width: 1600, height: 1000), duration: Double = 10, canvas: CGSize = CGSize(width: 1600, height: 1000),
        kept: Double = 10, quality: StudioProject.Quality = .standard
    ) -> Int? {
        StudioExporter.estimatedByteCount(
            sourceByteCount: bytes, sourceSize: size, sourceDuration: duration, canvas: canvas, keptDuration: kept, quality: quality
        )
    }

    @Test func aBetterQualityIsEstimatedLarger() throws {
        let smaller = try #require(estimate(quality: .smaller)), standard = try #require(estimate(quality: .standard)), best = try #require(estimate(quality: .best))
        #expect(smaller < standard && standard < best, "\(smaller), \(standard), \(best)")
        // Standard is the recording's own quality: the same picture weighs the same.
        #expect(standard == 10_000_000)
    }

    @Test func theEstimateFollowsWhatIsKeptAndTheMoviesSize() throws {
        let whole = try #require(estimate())
        // Half the recording kept, half the bytes.
        #expect(abs(try #require(estimate(kept: 5)) - whole / 2) <= 1)
        #expect(try #require(estimate(kept: 0)) == 0)
        // Four times the pixels, twice the bytes: the background around the recording costs next to nothing.
        let larger = try #require(estimate(canvas: CGSize(width: 3200, height: 2000)))
        #expect(abs(larger - whole * 2) <= 1)
        #expect(try #require(estimate(canvas: CGSize(width: 800, height: 500))) < whole)
        // A recording twice as long and as heavy, half of it kept, is a movie as heavy.
        #expect(try #require(estimate(bytes: 20_000_000, duration: 20, kept: 10)) == whole)
    }

    @Test func theEstimateIsUnknownWithoutTheRecordingsSize() {
        #expect(estimate(bytes: 0) == nil)
        #expect(estimate(duration: 0) == nil)
        #expect(estimate(size: .zero) == nil)
    }

    @Test func anEstimateIsSaidInTwoFigures() {
        #expect(StudioExporter.estimateDescription(byteCount: 24_349_000) == "About 24 MB")
        #expect(StudioExporter.estimateDescription(byteCount: 5_312_000) == "About 5.3 MB")
        #expect(StudioExporter.estimateDescription(byteCount: 1_240_000_000) == "About 1.2 GB")
        #expect(StudioExporter.estimateDescription(byteCount: 1_000_000) == "About 1 MB")
        #expect(StudioExporter.estimateDescription(byteCount: 999_999) == "Under 1 MB")
        #expect(StudioExporter.estimateDescription(byteCount: 0) == "Under 1 MB")
    }

    /// A document whose recording is a file of `bytes` bytes (not a movie, which the estimate never opens).
    private func document(recordingBytes bytes: Int) throws -> StudioDocument {
        let folder = FileManager.default.temporaryDirectory.appending(path: "OMSStudioTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let source = folder.appending(path: "source.mp4")
        try Data(count: bytes).write(to: source)
        let telemetry = StudioTelemetry(width: 160, height: 100, pixelsPerPoint: 2, samples: [.init(time: 0, x: 80, y: 50, cursor: 0)])
        return StudioDocument(
            source: source, telemetry: telemetry, project: StudioProject(), duration: 4, recordingSize: CGSize(width: 320, height: 200), folder: folder,
            hasBeenExported: true, background: { _, _ in nil }
        )
    }

    @Test func theDocumentEstimatesTheMovieAsTheProjectIsNow() throws {
        let document = try document(recordingBytes: 8_000_000)
        defer { try? FileManager.default.removeItem(at: document.folder) }
        let first = try #require(document.estimatedMovieByteCount)
        // The default frame is a little larger than the recording: a little more than its bytes.
        #expect(first > 8_000_000 && first < 10_000_000, "\(first)")
        document.project.quality = .best
        let best = try #require(document.estimatedMovieByteCount)
        #expect(best > first)
        document.project.quality = .standard
        // Cutting two of the four seconds halves it; a taller shape makes it larger.
        document.cut(0...2)
        #expect(abs(try #require(document.estimatedMovieByteCount) - first / 2) <= 1)
        document.restoreCut(at: 0)
        document.project.aspect = .vertical
        #expect(try #require(document.estimatedMovieByteCount) > first)
        // The file the estimate starts from is gone: nothing is said.
        let gone = StudioDocument(
            source: document.folder.appending(path: "none.mp4"), telemetry: document.telemetry, project: StudioProject(), duration: 4,
            recordingSize: CGSize(width: 320, height: 200), folder: document.folder, hasBeenExported: true, background: { _, _ in nil }
        )
        #expect(gone.estimatedMovieByteCount == nil)
    }

    @Test func changingTheQualityIsOneStepThatUndoNamesAndASettingToExport() throws {
        let document = try document(recordingBytes: 1_000_000)
        defer { try? FileManager.default.removeItem(at: document.folder) }
        let undo = UndoManager()
        undo.groupsByEvent = false
        document.undoManagerProvider = { undo }
        #expect(!document.hasUnexportedChanges)

        undo.beginUndoGrouping()
        document.setQuality(.smaller)
        undo.endUndoGrouping()
        #expect(document.project.quality == .smaller)
        #expect(document.hasUnexportedChanges)
        #expect(undo.undoActionName == "Change Quality")
        undo.undo()
        #expect(document.project.quality == .standard)
        undo.redo()
        #expect(document.project.quality == .smaller)
    }

    @Test func theQualityIsNoReasonToFilmThePreviewAgain() async throws {
        // The recording is no movie, so a preview made from it fails: that is how a preview made shows here.
        let document = try document(recordingBytes: 1_000_000)
        defer { try? FileManager.default.removeItem(at: document.folder) }
        document.project.quality = .best
        try await Task.sleep(for: .milliseconds(700))
        #expect(!document.compositionFailed)
        document.project.padding = 0.2
        for _ in 0..<100 where !document.compositionFailed { try await Task.sleep(for: .milliseconds(50)) }
        #expect(document.compositionFailed)
    }
}
