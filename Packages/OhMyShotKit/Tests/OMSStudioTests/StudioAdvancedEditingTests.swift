import AVFoundation
import CoreGraphics
import CoreImage
import CoreMedia
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import OMSStudio

/// Covers advanced Studio editing features on top of v0.4.0 schemas:
/// 1. Draggable/resizable speed stretches (`StudioProject.speeds`, audio micro-fade seam separation, timeline & undo)
/// 2. Video crop (`StudioProject.crop`, layout, framing, aimed `Zoom.Spot`, blurred background, pixel rendering, undo)
/// 3. Standalone `.omsstudio` project package export & import (`StudioPackage` with v0.4.0 `StudioFiles`)
@Suite(.serialized)
@MainActor
struct StudioAdvancedEditingTests {
    // MARK: 1. Speed Stretches & Audio Seam Separation

    @Test func audioMixSkipsCutMicroFadesAtSpeedSeamsAndKeepsThemAtCutGaps() throws {
        let track = [StudioComposition.AudioTrack(sound: .recorded, trackID: 1)]

        // Continuous speed change seams (no cut gaps) with default audio need no AVAudioMix at all.
        let speedOnly = StudioComposition.keptSegments(duration: 6.0, cuts: [], speeds: [.init(start: 2.0, end: 4.0, rate: 2.0)])
        let speedDuration = speedOnly.reduce(0) { $0 + $1.duration }
        #expect(speedOnly.count == 3 && abs(speedDuration - 5.0) < 1e-9)
        #expect(StudioComposition.makeAudioMix(tracks: track, segments: speedOnly, duration: speedDuration, audio: StudioProject.Audio()) == nil)

        // With custom master volume across continuous speed seams, volume stays flat (no dip to 0 at movie 2.0 s or 3.0 s).
        let scaledMix = try #require(StudioComposition.makeAudioMix(
            tracks: track, segments: speedOnly, duration: speedDuration, audio: StudioProject.Audio(master: .init(volume: 0.8))
        ))
        let scaledParams = try #require(scaledMix.inputParameters.first)
        #expect(abs((Self.volumeAt(2.0, in: scaledParams) ?? -1) - 0.8) < 0.01)
        #expect(abs((Self.volumeAt(3.0, in: scaledParams) ?? -1) - 0.8) < 0.01)

        // Mix of a cut (2...3) and a speed stretch (3...5 at 2×): cut seam at movie 2.0 dips to 0, speed seam at 3.0 stays 1.0.
        let mixed = StudioComposition.keptSegments(duration: 6.0, cuts: [2.0...3.0], speeds: [.init(start: 3.0, end: 5.0, rate: 2.0)])
        let mixedDuration = mixed.reduce(0) { $0 + $1.duration }
        let mixedAudio = try #require(StudioComposition.makeAudioMix(
            tracks: track, segments: mixed, duration: mixedDuration, audio: StudioProject.Audio()
        ))
        let mixedParams = try #require(mixedAudio.inputParameters.first)
        #expect(abs((Self.volumeAt(2.0, in: mixedParams) ?? -1) - 0.0) < 0.02)
        #expect(abs((Self.volumeAt(3.0, in: mixedParams) ?? -1) - 1.0) < 0.01)
    }

    @Test func documentSpeedEditingMoveResizeUndoNavigationAndTimelineLaneHit() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "OMSStudioSpeedDoc-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appending(path: "source.mp4")
        try Data(count: 10_000_000).write(to: source)
        let telemetry = StudioTelemetry(width: 160, height: 100, pixelsPerPoint: 2, samples: [.init(time: 0, x: 80, y: 50, cursor: 0)])
        let document = StudioDocument(
            source: source, telemetry: telemetry, project: StudioProject(), duration: 10,
            recordingSize: CGSize(width: 320, height: 200), folder: folder, hasBeenExported: false, background: { _, _ in nil }
        )
        defer { document.releasePreview() }
        let undo = UndoManager()
        undo.groupsByEvent = false
        document.undoManagerProvider = { undo }

        let baselineBytes = try #require(document.estimatedMovieByteCount)

        // Add Speed at playhead 2.0 -> 2.0...4.0 at 2×.
        document.time = 2.0
        #expect(document.canAddSpeed)
        undo.beginUndoGrouping()
        document.addSpeed(rate: 2.0)
        undo.endUndoGrouping()
        #expect(document.selectedSpeed == 2.0)
        #expect(document.project.speeds.count == 1)
        #expect(document.project.speeds[0] == .init(start: 2.0, end: 4.0, rate: 2.0))
        #expect(undo.undoActionName == "Add Speed")
        // Shorter movie duration reduces estimated bytes.
        #expect(try #require(document.estimatedMovieByteCount) < baselineBytes)

        // Change rate to 0.5× -> longer movie duration increases estimated bytes.
        undo.beginUndoGrouping()
        document.setSpeed(0.5)
        undo.endUndoGrouping()
        #expect(document.project.speeds[0].rate == 0.5)
        #expect(undo.undoActionName == "Change Speed")
        #expect(try #require(document.estimatedMovieByteCount) > baselineBytes)

        // Add second stretch inside first -> placed right after it (4.0...6.0), non-overlapping.
        document.time = 2.5
        undo.beginUndoGrouping()
        document.addSpeed(rate: 4.0)
        undo.endUndoGrouping()
        #expect(document.selectedSpeed == 4.0)
        #expect(document.project.speeds.count == 2)
        #expect(document.limits(ofSpeedAt: 4.0) == 4.0...10.0)

        // Move second speed rightward to 6.0...8.0 and verify selection tracks its new start + named undo.
        undo.beginUndoGrouping()
        let moved = try #require(document.moveSpeed(at: 4.0, to: 6.0))
        undo.endUndoGrouping()
        #expect(moved == 6.0...8.0)
        #expect(document.selectedSpeed == 6.0)
        #expect(undo.undoActionName == "Move Speed")

        // Moving left stops at neighbor 4.0.
        undo.beginUndoGrouping()
        let clampedMove = try #require(document.moveSpeed(at: 6.0, to: 1.0))
        undo.endUndoGrouping()
        #expect(clampedMove == 4.0...6.0)
        #expect(document.selectedSpeed == 4.0)

        // Edge resize stops at neighbor and enforces shortestSpeed.
        undo.beginUndoGrouping()
        let clampedStart = try #require(document.setSpeedEdge(at: 4.0, start: true, to: 1.0))
        undo.endUndoGrouping()
        #expect(clampedStart.lowerBound == 4.0)
        undo.beginUndoGrouping()
        let minWidth = try #require(document.setSpeedEdge(at: 4.0, start: true, to: 8.0))
        undo.endUndoGrouping()
        #expect(abs(minWidth.upperBound - minWidth.lowerBound - StudioProject.shortestSpeed) < 1e-9)
        #expect(undo.undoActionName == "Resize Speed")

        // Keyboard navigation includes speed stretches in time order.
        let navItems = StudioTimelineNavigation.items(
            zooms: [], cuts: [], layouts: [], speeds: document.project.speeds
        )
        #expect(navItems.map(\.selection) == [.speed(2.0), .speed(minWidth.lowerBound)])

        // Timeline lane hit detects speed resize handles and body on the clip foot (y = 96), while narrow bands hit body.
        let viewport = StudioTimelineViewport(duration: 10)
        let width: CGFloat = 1032 // span = 1000 -> 100 pt/s, inset = 16
        let wideSpeeds = [StudioProject.Speed(start: 2, end: 4, rate: 2)]
        let speedY: CGFloat = 96 // clipTop (64) + clipHeight (40) - speedHeight (16) = 88...104
        #expect(StudioTimeline.laneHit(at: CGPoint(x: 16 + 200, y: speedY), width: width, viewport: viewport, zooms: [], cuts: [], speeds: wideSpeeds) == .speedResize(2, start: true))
        #expect(StudioTimeline.laneHit(at: CGPoint(x: 16 + 300, y: speedY), width: width, viewport: viewport, zooms: [], cuts: [], speeds: wideSpeeds) == .speed(2))
        #expect(StudioTimeline.laneHit(at: CGPoint(x: 16 + 402, y: speedY), width: width, viewport: viewport, zooms: [], cuts: [], speeds: wideSpeeds) == .speedResize(2, start: false))
        // Narrow speed band (10 pt < 21 pt threshold) stays body-clickable rather than swallowed by resize handles.
        let narrowSpeeds = [StudioProject.Speed(start: 2, end: 2.1, rate: 2)]
        #expect(StudioTimeline.laneHit(at: CGPoint(x: 16 + 205, y: speedY), width: width, viewport: viewport, zooms: [], cuts: [], speeds: narrowSpeeds) == .speed(2))

        // Delete removes selected speed stretch and Undo brings it back.
        document.selection = .speed(minWidth.lowerBound)
        undo.beginUndoGrouping()
        document.deleteSelection()
        undo.endUndoGrouping()
        #expect(document.project.speeds.count == 1 && document.selectedSpeed == nil)
        #expect(undo.undoActionName == "Remove Speed")
        undo.undo()
        #expect(document.project.speeds.count == 2)
    }

    // MARK: 2. Video Crop

    @Test func cropCodableNormalizationAndCenteredPresets() throws {
        // Legacy project.json without `crop` decodes cleanly to nil.
        let legacyJSON = #"{"padding":0.08,"shadow":0.5,"aspect":"auto"}"#
        let decodedLegacy = try JSONDecoder().decode(StudioProject.self, from: Data(legacyJSON.utf8))
        #expect(decodedLegacy.crop == nil)

        // Normalization clamps bounds, enforces 0.1 minimum, collapses full rect to nil, and avoids drift on valid rects.
        #expect(StudioProject.normalizedCrop(nil) == nil)
        #expect(StudioProject.normalizedCrop(CGRect(x: 0, y: 0, width: 1, height: 1)) == nil)
        #expect(StudioProject.normalizedCrop(CGRect(x: 0.0005, y: 0.0005, width: 0.9995, height: 0.9995)) == nil)
        #expect(StudioProject.normalizedCrop(CGRect(x: .nan, y: 0, width: 0.5, height: 0.5)) == nil)

        let tinyCorner = try #require(StudioProject.normalizedCrop(CGRect(x: 0.96, y: 0.98, width: 0.02, height: 0.01)))
        #expect(abs(tinyCorner.minX - 0.9) < 1e-9 && abs(tinyCorner.width - 0.1) < 1e-9)
        #expect(abs(tinyCorner.minY - 0.9) < 1e-9 && abs(tinyCorner.height - 0.1) < 1e-9)

        let clipped = try #require(StudioProject.normalizedCrop(CGRect(x: -0.2, y: 0.5, width: 0.7, height: 0.8)))
        #expect(abs(clipped.minX - 0.0) < 1e-9 && abs(clipped.width - 0.5) < 1e-9)
        #expect(abs(clipped.minY - 0.5) < 1e-9 && abs(clipped.height - 0.5) < 1e-9)

        // Centered crop presets produce exact target pixel aspect ratios on a 1600×1000 recording.
        let recSize = CGSize(width: 1600, height: 1000)
        for ratio in [16.0 / 9, 4.0 / 3, 1.0, 9.0 / 16] {
            let rect = try #require(StudioProject.centeredCrop(aspectRatio: ratio, recordingSize: recSize))
            let croppedRatio = (rect.width * recSize.width) / (rect.height * recSize.height)
            #expect(abs(croppedRatio - ratio) < 0.001, "ratio \(ratio) gave \(croppedRatio)")
            #expect(abs(rect.midX - 0.5) < 1e-9 && abs(rect.midY - 0.5) < 1e-9)
        }
        // Matching recording aspect returns nil.
        #expect(StudioProject.centeredCrop(aspectRatio: 16.0 / 10, recordingSize: recSize) == nil)

        // Codable round-trip preserves exact crop rect without floating-point drift.
        let crop = CGRect(x: 0.1, y: 0.2, width: 0.6, height: 0.5)
        let project = StudioProject(crop: crop)
        let decoded = try JSONDecoder().decode(StudioProject.self, from: JSONEncoder().encode(project))
        #expect(decoded.crop == crop)
    }

    @Test func cropLayoutFramingAimedSpotBlurredBackgroundMotionCacheAndPixelRendering() async throws {
        // 320×200 recording (160×100 pt @ 2x) cropped to top-right quadrant: x in [0.5, 1.0], y in [0.0, 0.5].
        let crop = CGRect(x: 0.5, y: 0.0, width: 0.5, height: 0.5)
        var project = StudioProject(background: .color(red: 1, green: 1, blue: 1), padding: 0, crop: crop)
        project.shadow = 0
        project.cornerRadius = 0
        project.cursor.hidesWhenIdle = false
        project.cursor.showsClicks = false

        let layout = StudioRenderer.layout(recordingSize: CGSize(width: 320, height: 200), project: project, hasCamera: false)
        #expect(layout.canvas == CGSize(width: 160, height: 100))
        #expect(layout.frame == CGRect(x: 0, y: 0, width: 160, height: 100))

        // Unzoomed track centers on the crop midpoint (120, 25) in recording points.
        let telemetry = StudioTelemetry(
            width: 160, height: 100, pixelsPerPoint: 2,
            samples: [.init(time: 0, x: 10, y: 90, cursor: 0)] // cursor deliberately outside the crop!
        )
        let unzoomedTrack = StudioTrack(telemetry: telemetry, project: project, duration: 2.0)
        #expect(abs(unzoomedTrack.frame(at: 1.0).centerX - 120.0) < 1e-6)
        #expect(abs(unzoomedTrack.frame(at: 1.0).centerY - 25.0) < 1e-6)

        // Zoomed framing stays strictly inside the crop bounds (80...160, 0...50) even when cursor is outside.
        var zoomedProject = project
        zoomedProject.zooms = [.init(start: 0.5, end: 3.5, scale: 2.0, isAutomatic: false)]
        let zoomedTrack = StudioTrack(telemetry: telemetry, project: zoomedProject, duration: 4.0)
        for frame in zoomedTrack.frames {
            let halfW = 80.0 / frame.zoom / 2
            let halfH = 50.0 / frame.zoom / 2
            #expect(frame.centerX >= 80.0 + halfW - 1e-6 && frame.centerX <= 160.0 - halfW + 1e-6)
            #expect(frame.centerY >= 0.0 + halfH - 1e-6 && frame.centerY <= 50.0 - halfH + 1e-6)
        }

        // Aimed Zoom.Spot in full recording coords: (0.625, 0.375) -> (100, 37.5) inside crop (80...160, 0...50).
        // At 2× inside (80...160, 0...50): half = (20, 12.5), valid centerX = 100...140, centerY = 12.5...37.5.
        var aimedProject = project
        aimedProject.zooms = [.init(start: 0.5, end: 3.5, scale: 2.0, isAutomatic: false, target: .init(x: 0.625, y: 0.375))]
        let aimedTrack = StudioTrack(telemetry: telemetry, project: aimedProject, duration: 4.0)
        let steady = aimedTrack.frame(at: 2.0)
        #expect(abs(steady.centerX - 100.0) < 1e-6)
        #expect(abs(steady.centerY - 37.5) < 1e-6)

        // StudioZoomAim coordinate mapping through StudioRenderer maps preview frame corners to crop corners.
        let renderer = StudioRenderer(telemetry: telemetry, project: project, duration: 2.0, recordingSize: CGSize(width: 320, height: 200), background: nil)
        let unzoomedView = renderer.view(at: 1.0)
        let topLeftSpot = renderer.spot(atMovie: CGPoint(x: renderer.layout.frame.minX, y: renderer.layout.frame.maxY), in: unzoomedView)
        #expect(abs(topLeftSpot.x - 0.5) < 1e-9 && abs(topLeftSpot.y - 0.0) < 1e-9)
        let bottomRightSpot = renderer.spot(atMovie: CGPoint(x: renderer.layout.frame.maxX, y: renderer.layout.frame.minY), in: unzoomedView)
        #expect(abs(bottomRightSpot.x - 1.0) < 1e-9 && abs(bottomRightSpot.y - 0.5) < 1e-9)

        // Pixel rendering: 4-quadrant 320×200 source (TL=Red, TR=Green, BL=Blue, BR=Yellow) -> cropped output is pure Green!
        let quadrants = try Self.makeFourQuadrantCIImage(width: 320, height: 200)
        let ciContext = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!])
        let rendered = try #require(ciContext.createCGImage(renderer.image(source: quadrants, at: 1.0), from: CGRect(origin: .zero, size: renderer.layout.canvas)))
        #expect(rendered.width == 160 && rendered.height == 100)
        for (px, py) in [(10, 10), (80, 50), (150, 90)] {
            let rgb = try Self.color(of: rendered, x: px, y: py)
            #expect(rgb[0] < 10 && rgb[1] > 245 && rgb[2] < 10, "expected green at (\(px),\(py)), got \(rgb)")
        }

        // Blurred recording background honors crop too: padding around cropped green quadrant blurs green, not red/blue!
        var blurredProject = project
        blurredProject.background = .blur
        blurredProject.padding = 0.25
        let blurredRenderer = StudioRenderer(telemetry: telemetry, project: blurredProject, duration: 2.0, recordingSize: CGSize(width: 320, height: 200), background: nil)
        let blurredImage = try #require(ciContext.createCGImage(blurredRenderer.image(source: quadrants, at: 1.0), from: CGRect(origin: .zero, size: blurredRenderer.layout.canvas)))
        let marginRGB = try Self.color(of: blurredImage, x: 4, y: blurredImage.height / 2)
        #expect(marginRGB[0] < 15 && marginRGB[1] > 240 && marginRGB[2] < 15, "expected green blurred margin, got \(marginRGB)")

        // StudioDocument crop changes invalidate motion cache and support named Undo/Redo.
        let folder = FileManager.default.temporaryDirectory.appending(path: "OMSStudioCropDoc-\(UUID())")
        defer { try? FileManager.default.removeItem(at: folder) }
        let document = StudioDocument(
            source: folder.appending(path: "source.mp4"), telemetry: telemetry, project: StudioProject(), duration: 4,
            recordingSize: CGSize(width: 320, height: 200), folder: folder, hasBeenExported: false, background: { _, _ in nil }
        )
        defer { document.releasePreview() }
        let undo = UndoManager()
        undo.groupsByEvent = false
        document.undoManagerProvider = { undo }

        _ = try await document.preparedMotion(for: document.project)
        #expect(document.motionBuildCount == 1)

        undo.beginUndoGrouping()
        document.setCrop(crop)
        undo.endUndoGrouping()
        #expect(document.project.crop == crop)
        #expect(undo.undoActionName == "Crop Video")
        _ = try await document.preparedMotion(for: document.project)
        #expect(document.motionBuildCount == 2)

        undo.beginUndoGrouping()
        document.resetCrop()
        undo.endUndoGrouping()
        #expect(document.project.crop == nil)
        #expect(undo.undoActionName == "Reset Crop")
        undo.undo()
        #expect(document.project.crop == crop)
    }

    // MARK: 3. Standalone `.omsstudio` Project Package

    @Test func studioPackageExportAndImportRoundTripAndReplacesExisting() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "OMSStudioPkg-\(UUID())")
        let sourceFolder = root.appending(path: "source-studio")
        let sourceMovie = root.appending(path: "source.mp4")
        let packageURL = root.appending(path: "Demo.\(StudioPackage.fileExtension)")
        let importedMovie = root.appending(path: "imported/movie.mp4")
        let importedFolder = root.appending(path: "imported/studio")
        try FileManager.default.createDirectory(at: sourceFolder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let movieBytes = Data("synthetic-movie-payload".utf8)
        let cameraBytes = Data("synthetic-camera-payload".utf8)
        let systemBytes = Data("synthetic-system-audio".utf8)
        let micBytes = Data("synthetic-mic-audio".utf8)
        let bgName = "background-test.png"

        try movieBytes.write(to: sourceMovie)
        try cameraBytes.write(to: sourceFolder.appending(path: StudioFiles.camera))
        try systemBytes.write(to: sourceFolder.appending(path: StudioFiles.systemAudio))
        try micBytes.write(to: sourceFolder.appending(path: StudioFiles.microphone))
        try Self.writeBandPNG(to: sourceFolder.appending(path: bgName), width: 16, height: 16)
        let bgBytes = try Data(contentsOf: sourceFolder.appending(path: bgName))

        let telemetry = StudioTelemetry(
            width: 1440, height: 900, pixelsPerPoint: 2,
            samples: [.init(time: 0, x: 500, y: 400, cursor: 0)],
            clicks: [.init(time: 1.2, x: 500, y: 400, button: .primary)],
            camera: .init(start: 0.1, fills: [2.0...3.0], bubble: StudioProject.Camera())
        )
        try JSONEncoder().encode(telemetry).write(to: sourceFolder.appending(path: StudioFiles.telemetry))

        let project = StudioProject(
            background: .picture(bgName),
            padding: 0.12,
            cuts: [1.0...1.5],
            audio: .init(master: .init(volume: 0.8), fadeIn: 0.5, fadeOut: 1.0),
            speeds: [.init(start: 2.0, end: 4.0, rate: 2.0)],
            crop: CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8)
        )

        // Export package, then re-export over the same destination to verify clean replacement.
        try StudioPackage.export(sourceMovie: sourceMovie, studioFolder: sourceFolder, project: project, to: packageURL)
        try StudioPackage.export(sourceMovie: sourceMovie, studioFolder: sourceFolder, project: project, to: packageURL)

        let fm = FileManager.default
        #expect(fm.fileExists(atPath: packageURL.appending(path: StudioPackage.movieFileName).path(percentEncoded: false)))
        #expect(fm.fileExists(atPath: packageURL.appending(path: StudioFiles.telemetry).path(percentEncoded: false)))
        #expect(fm.fileExists(atPath: packageURL.appending(path: StudioFiles.project).path(percentEncoded: false)))
        #expect(fm.fileExists(atPath: packageURL.appending(path: StudioFiles.camera).path(percentEncoded: false)))
        #expect(fm.fileExists(atPath: packageURL.appending(path: StudioFiles.systemAudio).path(percentEncoded: false)))
        #expect(fm.fileExists(atPath: packageURL.appending(path: StudioFiles.microphone).path(percentEncoded: false)))
        #expect(fm.fileExists(atPath: packageURL.appending(path: bgName).path(percentEncoded: false)))

        // Import into a clean location and verify full round-trip fidelity.
        let imported = try StudioPackage.importPackage(at: packageURL, toMovieURL: importedMovie, studioFolder: importedFolder)
        #expect(imported.telemetry == telemetry)
        #expect(imported.project == project)
        #expect(try Data(contentsOf: importedMovie) == movieBytes)
        #expect(try Data(contentsOf: importedFolder.appending(path: StudioFiles.camera)) == cameraBytes)
        #expect(try Data(contentsOf: importedFolder.appending(path: StudioFiles.systemAudio)) == systemBytes)
        #expect(try Data(contentsOf: importedFolder.appending(path: StudioFiles.microphone)) == micBytes)
        #expect(try Data(contentsOf: importedFolder.appending(path: bgName)) == bgBytes)

        // Importing a package without project.json falls back cleanly to default StudioProject().
        let noProjectPkg = root.appending(path: "Minimal.\(StudioPackage.fileExtension)")
        try fm.createDirectory(at: noProjectPkg, withIntermediateDirectories: true)
        try movieBytes.write(to: noProjectPkg.appending(path: StudioPackage.movieFileName))
        try JSONEncoder().encode(telemetry).write(to: noProjectPkg.appending(path: StudioFiles.telemetry))
        let minimalImported = try StudioPackage.importPackage(
            at: noProjectPkg,
            toMovieURL: root.appending(path: "minimal/movie.mp4"),
            studioFolder: root.appending(path: "minimal/studio")
        )
        #expect(minimalImported.telemetry == telemetry)
        #expect(minimalImported.project == StudioProject())
    }

    @Test func studioPackageRejectsInvalidMissingCorruptAndTraversalPackages() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "OMSStudioPkgErr-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let outMovie = root.appending(path: "out/movie.mp4")
        let outFolder = root.appending(path: "out/studio")

        // Non-existent or non-directory package -> invalidPackage.
        #expect(throws: StudioPackage.PackageError.invalidPackage) {
            _ = try StudioPackage.importPackage(at: root.appending(path: "missing.omsstudio"), toMovieURL: outMovie, studioFolder: outFolder)
        }
        let plainFile = root.appending(path: "file.omsstudio")
        try Data("x".utf8).write(to: plainFile)
        #expect(throws: StudioPackage.PackageError.invalidPackage) {
            _ = try StudioPackage.importPackage(at: plainFile, toMovieURL: outMovie, studioFolder: outFolder)
        }

        // Empty directory -> missingMovie.
        let missingMoviePkg = root.appending(path: "no-movie.omsstudio")
        try FileManager.default.createDirectory(at: missingMoviePkg, withIntermediateDirectories: true)
        #expect(throws: StudioPackage.PackageError.missingMovie) {
            _ = try StudioPackage.importPackage(at: missingMoviePkg, toMovieURL: outMovie, studioFolder: outFolder)
        }

        // Has movie.mp4, missing telemetry.json -> missingTelemetry.
        let missingTelemetryPkg = root.appending(path: "no-telemetry.omsstudio")
        try FileManager.default.createDirectory(at: missingTelemetryPkg, withIntermediateDirectories: true)
        try Data("movie".utf8).write(to: missingTelemetryPkg.appending(path: StudioPackage.movieFileName))
        #expect(throws: StudioPackage.PackageError.missingTelemetry) {
            _ = try StudioPackage.importPackage(at: missingTelemetryPkg, toMovieURL: outMovie, studioFolder: outFolder)
        }

        // Corrupted telemetry.json -> invalidPackage.
        let corruptTelemetryPkg = root.appending(path: "corrupt-telemetry.omsstudio")
        try FileManager.default.createDirectory(at: corruptTelemetryPkg, withIntermediateDirectories: true)
        try Data("movie".utf8).write(to: corruptTelemetryPkg.appending(path: StudioPackage.movieFileName))
        try Data("not-json".utf8).write(to: corruptTelemetryPkg.appending(path: StudioFiles.telemetry))
        #expect(throws: StudioPackage.PackageError.invalidPackage) {
            _ = try StudioPackage.importPackage(at: corruptTelemetryPkg, toMovieURL: outMovie, studioFolder: outFolder)
        }

        // Path traversal in `.picture` background -> invalidFileName on both export and import.
        let badBgProject = StudioProject(background: .picture("../secret.png"))
        let validTelemetry = StudioTelemetry(width: 160, height: 100, pixelsPerPoint: 2)
        let traversalPkg = root.appending(path: "traversal.omsstudio")
        try FileManager.default.createDirectory(at: traversalPkg, withIntermediateDirectories: true)
        try Data("movie".utf8).write(to: traversalPkg.appending(path: StudioPackage.movieFileName))
        try JSONEncoder().encode(validTelemetry).write(to: traversalPkg.appending(path: StudioFiles.telemetry))
        try JSONEncoder().encode(badBgProject).write(to: traversalPkg.appending(path: StudioFiles.project))

        #expect(throws: StudioPackage.PackageError.invalidFileName) {
            _ = try StudioPackage.importPackage(at: traversalPkg, toMovieURL: outMovie, studioFolder: outFolder)
        }
        #expect(throws: StudioPackage.PackageError.invalidFileName) {
            try StudioPackage.export(
                sourceMovie: traversalPkg.appending(path: StudioPackage.movieFileName),
                studioFolder: traversalPkg,
                project: badBgProject,
                to: root.appending(path: "blocked.omsstudio")
            )
        }
    }

    // MARK: Helpers

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

    private static func color(of image: CGImage, x: Int, y: Int) throws -> [Double] {
        let context = try #require(CGContext(
            data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
        let bytes = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        return (0..<3).map { Double(bytes[$0]) }
    }

    /// 4-quadrant image (top-left Red, top-right Green, bottom-left Blue, bottom-right Yellow) in Core Image y-up space.
    private static func makeFourQuadrantCIImage(width: Int, height: Int) throws -> CIImage {
        let context = try #require(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        let halfW = width / 2, halfH = height / 2
        // CGContext origin is bottom-left (y-up):
        context.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1)) // bottom-left Blue
        context.fill(CGRect(x: 0, y: 0, width: halfW, height: halfH))
        context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 0, alpha: 1)) // bottom-right Yellow
        context.fill(CGRect(x: halfW, y: 0, width: width - halfW, height: halfH))
        context.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)) // top-left Red
        context.fill(CGRect(x: 0, y: halfH, width: halfW, height: height - halfH))
        context.setFillColor(CGColor(srgbRed: 0, green: 1, blue: 0, alpha: 1)) // top-right Green
        context.fill(CGRect(x: halfW, y: halfH, width: width - halfW, height: height - halfH))
        return CIImage(cgImage: try #require(context.makeImage()))
    }

    /// Writes a PNG with a centered square of pure Red and pure Blue left/right margins.
    private static func writeBandPNG(to url: URL, width: Int, height: Int) throws {
        let context = try #require(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let centerSide = min(width, height)
        context.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: (width - centerSide) / 2, y: (height - centerSide) / 2, width: centerSide, height: centerSide))
        let image = try #require(context.makeImage())
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
    }
}
