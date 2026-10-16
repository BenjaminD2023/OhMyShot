import Foundation
import Testing
@testable import OMSStudio

/// The camera's layouts along the timeline: when each shows what, the change between them, the project's
/// stretches, and how a recording's own fills of the frame become stretches.
struct StudioCameraLayoutTests {
    private typealias Layout = StudioProject.Camera.Layout

    private static func plan(
        _ layout: Layout = .pictureInPicture, segments: [StudioProject.CameraSegment] = [], fills: [ClosedRange<Double>] = [], adopted: Bool = false
    ) -> StudioCameraPlan {
        StudioCameraPlan(camera: StudioProject.Camera(layout: layout, recordedFillsAreSegments: adopted), segments: segments, recordedFills: fills)
    }

    private static func segment(_ start: Double, _ end: Double, _ layout: Layout) -> StudioProject.CameraSegment {
        .init(start: start, end: end, layout: layout)
    }

    private static func near(_ a: Double, _ b: Double) -> Bool {
        abs(a - b) < 1e-9
    }

    // MARK: The plan

    @Test func aLayoutWithNothingElseHoldsFromFirstFrameToLast() {
        for layout in [Layout.pictureInPicture, .cameraOnly, .screenOnly] {
            let plan = Self.plan(layout)
            let expected = StudioCameraPlan.levels(of: layout)
            for time in [-1.0, 0, 1.3, 100] {
                #expect(plan.levels(at: time) == expected && plan.layout(at: time) == layout, "\(layout) at \(time)")
            }
        }
        #expect(StudioCameraPlan.levels(of: .pictureInPicture) == .init(bubble: 1, fill: 0))
        #expect(StudioCameraPlan.levels(of: .cameraOnly) == .init(bubble: 0, fill: 1))
        #expect(StudioCameraPlan.levels(of: .screenOnly) == .init(bubble: 0, fill: 0))
    }

    @Test func whereTheCameraFilledWhileRecordingItFillsAsItAlwaysDid() {
        // The bubble goes out over the first half of the change and the frame fills over the second, and back.
        let plan = Self.plan(fills: [2...3])
        #expect(plan.levels(at: 1.9) == .init(bubble: 1, fill: 0))
        #expect(plan.levels(at: 2) == .init(bubble: 1, fill: 0))
        let quarter = plan.levels(at: 2 + StudioCameraPlan.fade * 0.25)
        #expect(Self.near(quarter.bubble, 0.5) && quarter.fill == 0)
        #expect(plan.levels(at: 2 + StudioCameraPlan.fade * 0.5) == .init(bubble: 0, fill: 0))
        let threeQuarters = plan.levels(at: 2 + StudioCameraPlan.fade * 0.75)
        #expect(threeQuarters.bubble == 0 && Self.near(threeQuarters.fill, 0.5))
        #expect(plan.levels(at: 2.5) == .init(bubble: 0, fill: 1))
        // Back to the bubble from 3 s: the frame empties first.
        let leaving = plan.levels(at: 3 + StudioCameraPlan.fade * 0.25)
        #expect(Self.near(leaving.fill, 0.5) && leaving.bubble == 0)
        #expect(plan.levels(at: 3 + StudioCameraPlan.fade) == .init(bubble: 1, fill: 0))
        #expect(plan.layout(at: 2.5) == .cameraOnly && plan.layout(at: 3.5) == .pictureInPicture)
    }

    @Test func thePersonIsNeverShownTwice() {
        // Between the bubble and the camera filling the movie, one is out before the other comes in.
        for (old, new) in [(Layout.pictureInPicture, Layout.cameraOnly), (.cameraOnly, .pictureInPicture)] {
            for step in 0...20 {
                let levels = StudioCameraPlan.levels(from: old, to: new, progress: Double(step) / 20)
                #expect(!(levels.bubble > 0 && levels.fill > 0), "\(old) to \(new) at \(step)/20: \(levels)")
            }
        }
    }

    @Test func aLoneChangeTakesTheWholeTime() {
        // The bubble out to nothing: it fades the whole time, not just the first half; and in again.
        let out = StudioCameraPlan.levels(from: .pictureInPicture, to: .screenOnly, progress: 0.5)
        #expect(Self.near(out.bubble, 0.5) && out.fill == 0)
        let back = StudioCameraPlan.levels(from: .screenOnly, to: .pictureInPicture, progress: 0.25)
        #expect(Self.near(back.bubble, 0.25))
        let filling = StudioCameraPlan.levels(from: .screenOnly, to: .cameraOnly, progress: 0.75)
        #expect(Self.near(filling.fill, 0.75) && filling.bubble == 0)
        // Whole at both ends, whatever the change.
        for (old, new) in [(Layout.pictureInPicture, Layout.screenOnly), (.screenOnly, .cameraOnly), (.cameraOnly, .pictureInPicture)] {
            #expect(StudioCameraPlan.levels(from: old, to: new, progress: 0) == StudioCameraPlan.levels(of: old))
            #expect(StudioCameraPlan.levels(from: old, to: new, progress: 1) == StudioCameraPlan.levels(of: new))
        }
    }

    @Test func aStretchShowsTheCameraItsOwnWay() {
        let plan = Self.plan(.pictureInPicture, segments: [Self.segment(2, 4, .screenOnly)])
        #expect(plan.layout(at: 1) == .pictureInPicture && plan.layout(at: 3) == .screenOnly && plan.layout(at: 4) == .pictureInPicture)
        #expect(plan.levels(at: 1) == .init(bubble: 1, fill: 0))
        #expect(plan.levels(at: 3) == .init(bubble: 0, fill: 0))
        // The bubble fades out as the stretch begins, and in as it ends.
        #expect(Self.near(plan.levels(at: 2 + StudioCameraPlan.fade / 2).bubble, 0.5))
        #expect(Self.near(plan.levels(at: 4 + StudioCameraPlan.fade / 2).bubble, 0.5))
        // A camera that was hidden shows in a stretch of its own.
        let hidden = Self.plan(.screenOnly, segments: [Self.segment(1, 2, .pictureInPicture)])
        #expect(hidden.usesCamera)
        #expect(hidden.levels(at: 1.5) == .init(bubble: 1, fill: 0) && hidden.levels(at: 0.5) == .init(bubble: 0, fill: 0))
        #expect(!Self.plan(.screenOnly).usesCamera && !Self.plan(.screenOnly, segments: [Self.segment(1, 2, .screenOnly)]).usesCamera)
        #expect(Self.plan(.pictureInPicture).usesCamera && Self.plan(.cameraOnly).usesCamera)
    }

    @Test func aStretchThatBeginsTheMovieHoldsFromTheFirstFrame() {
        let plan = Self.plan(.pictureInPicture, segments: [Self.segment(0, 3, .cameraOnly)])
        #expect(plan.levels(at: 0) == .init(bubble: 0, fill: 1) && plan.levels(at: 0.1) == .init(bubble: 0, fill: 1))
        // It ends, with the usual change back.
        #expect(plan.levels(at: 3.5) == .init(bubble: 1, fill: 0))
    }

    @Test func stretchesThatTouchChangeFromOneToTheNext() {
        let plan = Self.plan(.screenOnly, segments: [Self.segment(1, 2, .cameraOnly), Self.segment(2, 3, .pictureInPicture)])
        #expect(plan.levels(at: 1.5) == .init(bubble: 0, fill: 1))
        // At 2 s the camera goes from filling to the bubble, with nothing between.
        #expect(plan.levels(at: 2) == .init(bubble: 0, fill: 1))
        #expect(plan.levels(at: 2 + StudioCameraPlan.fade / 2) == .init(bubble: 0, fill: 0))
        #expect(plan.levels(at: 2.5) == .init(bubble: 1, fill: 0))
        #expect(plan.layout(at: 2.5) == .pictureInPicture && plan.layout(at: 3.5) == .screenOnly)
    }

    @Test func aProjectsOwnStretchWinsOverWhereTheCameraFilledWhileRecording() {
        // The camera filled from 2 to 4 while recording; the project shows the bubble from 2.5 to 3.5.
        let plan = Self.plan(segments: [Self.segment(2.5, 3.5, .pictureInPicture)], fills: [2...4])
        #expect(plan.stretches == [
            .init(start: 2, end: 2.5, layout: .cameraOnly), .init(start: 2.5, end: 3.5, layout: .pictureInPicture),
            .init(start: 3.5, end: 4, layout: .cameraOnly),
        ])
        #expect(plan.layout(at: 3) == .pictureInPicture && plan.layout(at: 2.25) == .cameraOnly && plan.layout(at: 3.75) == .cameraOnly)
    }

    @Test func theRecordingsFillsAreIgnoredOnceTheyAreStretches() {
        // Adopted: the project's stretches are all there is, so removing one removes the fill.
        let plan = Self.plan(segments: [], fills: [2...3], adopted: true)
        #expect(plan.stretches.isEmpty && plan.layout(at: 2.5) == .pictureInPicture)
        // Not under another layout: the camera hidden or filling throughout stays so.
        #expect(Self.plan(.screenOnly, fills: [2...3]).stretches.isEmpty)
        #expect(Self.plan(.cameraOnly, fills: [2...3]).stretches.isEmpty)
    }

    @Test func sideBySideHasNoStretchesAndNothingFills() {
        let plan = Self.plan(.sideBySide, segments: [Self.segment(1, 2, .cameraOnly)], fills: [3...4])
        #expect(plan.stretches.isEmpty)
        for time in [0.0, 1.5, 3.5] {
            #expect(plan.layout(at: time) == .sideBySide && plan.levels(at: time) == .init(bubble: 0, fill: 0))
        }
        #expect(plan.usesCamera)
    }

    @Test func stretchesNeverOverlapAndNeverMakeTheMovieWider() {
        let plan = Self.plan(segments: [
            Self.segment(3, 6, .screenOnly), Self.segment(1, 4, .cameraOnly), Self.segment(8, 9, .sideBySide), Self.segment(5, 5, .cameraOnly),
        ])
        // 1–4 first; 3–6 begins where that ends; the empty one goes; side by side is the bubble.
        #expect(plan.stretches == [
            .init(start: 1, end: 4, layout: .cameraOnly), .init(start: 4, end: 6, layout: .screenOnly), .init(start: 8, end: 9, layout: .pictureInPicture),
        ])
    }

    @Test func recordedFillsThatOverlapAreOneStretch() {
        let plan = Self.plan(fills: [1...2, 1.5...3, 3...3.5, 6...7])
        #expect(plan.stretches == [.init(start: 1, end: 3.5, layout: .cameraOnly), .init(start: 6, end: 7, layout: .cameraOnly)])
    }

    // MARK: Adopting the recording's fills

    @Test func theRecordingsFillsBecomeStretchesAndTheMovieIsTheSame() {
        let fills: [ClosedRange<Double>] = [2...3, 3.2...4.5, 7...7.2, -0.5...0.8]
        var project = StudioProject()
        let before = Self.plan(fills: fills)
        project.adoptRecordedFills(fills, duration: 9)
        #expect(project.camera.recordedFillsAreSegments)
        // A fill under half a second is no stretch; one begun before the recording begins at its start.
        let kept = project.cameraSegments.map { [$0.start, $0.end] }
        #expect(kept == [[0, 0.8], [2, 3], [3.2, 4.5]], "\(kept)")
        #expect(project.cameraSegments.allSatisfy { $0.layout == .cameraOnly })
        // The movie is the same: the same camera at every moment, but for the sliver that was dropped.
        let after = Self.plan(segments: project.cameraSegments, fills: fills, adopted: true)
        for time in stride(from: 0.0, through: 9, by: 0.05) where !(7...7.5).contains(time) {
            #expect(before.levels(at: time) == after.levels(at: time), "at \(time) s")
        }
    }

    @Test func theFillsAreAdoptedOnceAndOnlyWithTheCameraShown() {
        var project = StudioProject()
        project.adoptRecordedFills([1...2], duration: 5)
        project.cameraSegments.removeAll()
        // Taken once: removing the stretch removes the fill, which doesn't come back at the next opening.
        project.adoptRecordedFills([1...2], duration: 5)
        #expect(project.cameraSegments.isEmpty)
        // A hidden camera stays hidden: nothing is adopted, and it is left for when it is shown again.
        var hidden = StudioProject(camera: StudioProject.Camera(layout: .screenOnly))
        hidden.adoptRecordedFills([1...2], duration: 5)
        #expect(hidden.cameraSegments.isEmpty && !hidden.camera.recordedFillsAreSegments)
    }

    @Test func aFillAdoptsOnlyWhereTheProjectsOwnStretchesLeaveRoom() {
        var project = StudioProject(cameraSegments: [Self.segment(2, 3, .screenOnly)])
        project.adoptRecordedFills([1...4], duration: 6)
        let kept = project.cameraSegments.map { [$0.start, $0.end, $0.layout == .cameraOnly ? 1 : 0] }
        #expect(kept == [[1, 2, 1], [2, 3, 0], [3, 4, 1]], "\(kept)")
    }

    @Test func theSameFillsMakeTheSameStretchesEachTime() {
        // Two projects opened separately, as one kept in the history and one saved on disk are, agree.
        let fills: [ClosedRange<Double>] = [2...3, 3.2...4.5, 6...7]
        var first = StudioProject(), second = StudioProject()
        first.adoptRecordedFills(fills, duration: 9)
        second.adoptRecordedFills(fills, duration: 9)
        #expect(first == second && first.cameraSegments.count == 3)
        // Each stretch has an identifier of its own.
        #expect(Set(first.cameraSegments.map(\.id)).count == 3)
        // Another fill, another stretch.
        var other = StudioProject()
        other.adoptRecordedFills([2...3.5], duration: 9)
        #expect(other.cameraSegments.first?.id != first.cameraSegments.first?.id)
    }

    @Test func aProjectIsOpenedWithTheFillsAsStretchesOnlyOnce() {
        let telemetry = StudioTelemetry(
            width: 160, height: 100, pixelsPerPoint: 2, camera: .init(start: 0, fills: [1...2.5], bubble: StudioProject.Camera())
        )
        let opened = StudioProject().opened(for: telemetry, duration: 5)
        #expect(opened.cameraSegments.map { [$0.start, $0.end] } == [[1, 2.5]] && opened.camera.recordedFillsAreSegments)
        #expect(opened.opened(for: telemetry, duration: 5) == opened)
        // A recording with no camera has no fills to take.
        let none = StudioTelemetry(width: 160, height: 100, pixelsPerPoint: 2)
        #expect(StudioProject().opened(for: none, duration: 5) == StudioProject())
    }

    // MARK: Stretches in a project

    @Test func stretchesAreKeptWithTheProject() throws {
        var project = StudioProject()
        project.cameraSegments = [Self.segment(1, 2.5, .cameraOnly), Self.segment(4, 5, .screenOnly)]
        project.camera.recordedFillsAreSegments = true
        let again = try JSONDecoder().decode(StudioProject.self, from: JSONEncoder().encode(project))
        #expect(again == project)
        #expect(again.cameraSegments.map(\.layout) == [.cameraOnly, .screenOnly] && again.camera.recordedFillsAreSegments)
        // A project saved before them has none, and its fills are still the recording's.
        let old = try JSONDecoder().decode(StudioProject.self, from: Data(#"{"padding":0.1}"#.utf8))
        #expect(old.cameraSegments.isEmpty && !old.camera.recordedFillsAreSegments)
    }

    @Test func aStretchWithALayoutFromANewerVersionShowsTheBubbleInsteadOfLosingTheProject() throws {
        let id = UUID()
        let newer = #"{"padding":0.2,"cameraSegments":[{"id":"\#(id.uuidString)","start":1,"end":2.5,"layout":"splitScreen"},"#
            + #"{"id":"\#(UUID().uuidString)","start":4,"end":5,"layout":"screenOnly"}]}"#
        let project = try JSONDecoder().decode(StudioProject.self, from: Data(newer.utf8))
        #expect(project.padding == 0.2 && project.cameraSegments.count == 2)
        #expect(project.cameraSegments.first == .init(id: id, start: 1, end: 2.5, layout: .pictureInPicture))
        #expect(project.cameraSegments.last?.layout == .screenOnly)
    }
}

/// Editing the stretches in a Studio document.
struct StudioCameraSegmentEditingTests {
    private static func document(camera: Bool = true, layout: StudioProject.Camera.Layout = .pictureInPicture, fills: [ClosedRange<Double>] = [],
        exported: Bool = false, movie: Bool = true
    ) throws -> StudioDocument {
        let folder = FileManager.default.temporaryDirectory.appending(path: "OMSStudioTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // Only that the camera's movie is there is looked at; `movie` false is a camera written down whose movie is gone.
        if camera && movie { try Data().write(to: folder.appending(path: StudioFiles.camera)) }
        let project = StudioProject(camera: StudioProject.Camera(layout: layout))
        let telemetry = StudioTelemetry(
            width: 160, height: 100, pixelsPerPoint: 2, samples: [.init(time: 0, x: 80, y: 50, cursor: 0)],
            camera: camera ? .init(start: 0, fills: fills, bubble: project.camera) : nil
        )
        return StudioDocument(
            source: folder.appending(path: "none.mp4"), telemetry: telemetry, project: project, duration: 10,
            recordingSize: CGSize(width: 320, height: 200), folder: folder, hasBeenExported: exported, background: { _, _ in nil }
        )
    }

    @Test func layoutsCanChangeAlongTheTimelineOnlyWithACameraThatIsNotBesideTheRecording() throws {
        #expect(try Self.document().canChangeLayoutAlongTheTimeline)
        #expect(try Self.document(layout: .screenOnly).canChangeLayoutAlongTheTimeline)
        #expect(try !Self.document(layout: .sideBySide).canChangeLayoutAlongTheTimeline)
        #expect(try !Self.document(camera: false).canChangeLayoutAlongTheTimeline)
    }

    @Test func theBubblesSettingsAndTheMirrorShowWhereverTheCameraDoes() throws {
        func shows(_ layout: StudioProject.Camera.Layout, _ stretches: [StudioProject.CameraSegment] = []) throws -> (camera: Bool, bubble: Bool) {
            let document = try Self.document(layout: layout)
            defer { try? FileManager.default.removeItem(at: document.folder) }
            document.project.cameraSegments = stretches
            return (document.showsCamera, document.showsBubble)
        }
        func stretch(_ layout: StudioProject.Camera.Layout) -> [StudioProject.CameraSegment] { [.init(start: 1, end: 2, layout: layout)] }
        #expect(try shows(.pictureInPicture) == (true, true))
        #expect(try shows(.cameraOnly) == (true, false))
        #expect(try shows(.screenOnly) == (false, false))
        #expect(try shows(.sideBySide) == (true, false))
        // A bubble in a stretch brings its settings, over a layout that has no bubble.
        #expect(try shows(.cameraOnly, stretch(.pictureInPicture)) == (true, true))
        #expect(try shows(.screenOnly, stretch(.pictureInPicture)) == (true, true))
        #expect(try shows(.screenOnly, stretch(.cameraOnly)) == (true, false))
        #expect(try shows(.screenOnly, stretch(.screenOnly)) == (false, false))
        // Side by side has no stretches: whatever they say is ignored.
        #expect(try shows(.sideBySide, stretch(.pictureInPicture)) == (true, false))
        // No camera recorded: nothing to show.
        let none = try Self.document(camera: false)
        defer { try? FileManager.default.removeItem(at: none.folder) }
        #expect(!none.showsCamera && !none.showsBubble)
    }

    @Test func aLayoutIsAddedAtThePlayheadInTheRoomTheOthersLeave() throws {
        let document = try Self.document()
        defer { try? FileManager.default.removeItem(at: document.folder) }
        document.time = 2
        document.addCameraSegment()
        // Camera only, three seconds, chosen.
        #expect(document.project.cameraSegments.map { [$0.start, $0.end] } == [[2, 5]])
        #expect(document.project.cameraSegments.first?.layout == .cameraOnly)
        #expect(document.selectedSegment == document.project.cameraSegments.first?.id)
        // At the playhead's place inside it: after it, in the room left.
        document.time = 3
        document.addCameraSegment()
        #expect(document.project.cameraSegments.map { [$0.start, $0.end] } == [[2, 5], [5, 8]])
        // Before it: no more than the room before the next.
        document.time = 0
        document.addCameraSegment()
        #expect(document.project.cameraSegments.map { [$0.start, $0.end] } == [[0, 2], [2, 5], [5, 8]])
        // Nowhere left at the end of a recording that is full to the last half second.
        document.time = 9.9
        document.addCameraSegment()
        #expect(document.project.cameraSegments.count == 4)
        #expect(document.project.cameraSegments.last.map { $0.end <= 10 && $0.end - $0.start >= StudioProject.shortestSegment } == true)
    }

    @Test func theNewLayoutIsTheOneThatIsNotAlreadyThere() throws {
        let filling = try Self.document(layout: .cameraOnly)
        defer { try? FileManager.default.removeItem(at: filling.folder) }
        filling.addCameraSegment()
        #expect(filling.project.cameraSegments.first?.layout == .pictureInPicture)
        let hidden = try Self.document(layout: .screenOnly)
        defer { try? FileManager.default.removeItem(at: hidden.folder) }
        hidden.addCameraSegment()
        #expect(hidden.project.cameraSegments.first?.layout == .cameraOnly)
    }

    @Test func aLayoutStaysBetweenItsNeighborsAndAtLeastHalfASecondLong() throws {
        let document = try Self.document()
        defer { try? FileManager.default.removeItem(at: document.folder) }
        document.project.cameraSegments = [
            .init(start: 1, end: 2, layout: .cameraOnly), .init(start: 3, end: 4, layout: .screenOnly), .init(start: 6, end: 7, layout: .cameraOnly),
        ]
        let middle = document.project.cameraSegments[1].id
        #expect(document.limits(ofCameraSegment: middle) == 2...6)
        // Moved or stretched past a neighbor, it stops there.
        document.updateCameraSegment(middle) { $0.start = 1; $0.end = 4 }
        #expect(document.project.cameraSegments[1].start == 2 && document.project.cameraSegments[1].end == 4)
        document.updateCameraSegment(middle) { $0.end = 9 }
        #expect(document.project.cameraSegments[1].end == 6)
        // Shrunk to nothing, it keeps its half second.
        document.updateCameraSegment(middle) { $0.end = $0.start }
        #expect(abs(document.project.cameraSegments[1].end - document.project.cameraSegments[1].start - StudioProject.shortestSegment) < 1e-9)
        // The first can go to the start of the recording; the last to its end.
        let first = document.project.cameraSegments[0].id
        document.updateCameraSegment(first) { $0.start = -5 }
        #expect(document.project.cameraSegments[0].start == 0)
        let last = document.project.cameraSegments[2].id
        document.updateCameraSegment(last) { $0.end = 50 }
        #expect(document.project.cameraSegments[2].end == 10)
    }

    @Test func aLayoutCanBeChangedAndRemoved() throws {
        let document = try Self.document()
        defer { try? FileManager.default.removeItem(at: document.folder) }
        document.addCameraSegment()
        let id = try #require(document.project.cameraSegments.first?.id)
        document.setCameraSegmentLayout(id, .screenOnly)
        #expect(document.project.cameraSegments.first?.layout == .screenOnly)
        // Side by side widens the whole movie: it is never a stretch's.
        document.setCameraSegmentLayout(id, .sideBySide)
        #expect(document.project.cameraSegments.first?.layout == .screenOnly)
        // Delete takes the chosen one away.
        #expect(document.selectedSegment == id)
        document.deleteSelection()
        #expect(document.project.cameraSegments.isEmpty && document.selectedSegment == nil)
    }

    @Test func openingAProjectMakesTheRecordedFillsStretchesWithoutChangingTheMovie() throws {
        let document = try Self.document(fills: [2...3.5, 6...6.1])
        defer { try? FileManager.default.removeItem(at: document.folder) }
        #expect(document.project.camera.recordedFillsAreSegments)
        #expect(document.project.cameraSegments.map { [$0.start, $0.end] } == [[2, 3.5]])
        #expect(document.project.cameraSegments.allSatisfy { $0.layout == .cameraOnly })
        // Not a change to export: a movie that was exported is as it was.
        let exported = try Self.document(fills: [2...3.5], exported: true)
        defer { try? FileManager.default.removeItem(at: exported.folder) }
        #expect(!exported.hasUnexportedChanges)
        // The stretches are kept with the project once it is saved.
        document.save()
        let saved = try JSONDecoder().decode(StudioProject.self, from: Data(contentsOf: document.folder.appending(path: StudioFiles.project)))
        #expect(saved == document.project)
    }

    @Test func aProjectKeptAfterBeingOpenedEqualsTheSameOneKeptBeforeItWas() throws {
        // The recording with the camera filling the movie for two stretches, as it was recorded.
        let document = try Self.document(fills: [2...3.5, 6...7])
        defer { try? FileManager.default.removeItem(at: document.folder) }
        let saved = StudioProject(camera: StudioProject.Camera(layout: .pictureInPicture))
        #expect(!saved.camera.recordedFillsAreSegments && saved != document.project)
        // What the history keeps with an exported movie is the project as the window had it, opened.
        let made = try JSONDecoder().decode(StudioProject.self, from: JSONEncoder().encode(document.project))
        let telemetry = document.telemetry
        #expect(made.opened(for: telemetry, duration: 10) == saved.opened(for: telemetry, duration: 10))
        #expect(saved.opened(for: telemetry, duration: 10) == document.project)
    }

    @Test func layoutsAddedAtTheSamePlayheadNeverOverlap() throws {
        let document = try Self.document()
        defer { try? FileManager.default.removeItem(at: document.folder) }
        // Two that touch, and the playhead inside the first: the new one goes after both.
        document.project.cameraSegments = [.init(start: 2, end: 5, layout: .cameraOnly), .init(start: 5, end: 8, layout: .screenOnly)]
        document.time = 3
        for _ in 0..<3 { document.addCameraSegment() }
        #expect(document.project.cameraSegments.map { [$0.start, $0.end] } == [[2, 5], [5, 8], [8, 10]])
        let stretches = document.project.cameraSegments
        #expect(zip(stretches, stretches.dropFirst()).allSatisfy { $0.end <= $1.start })
    }

    @Test func zoomsAddedAtTheSamePlayheadNeverOverlap() throws {
        let document = try Self.document()
        defer { try? FileManager.default.removeItem(at: document.folder) }
        document.project.zooms = [
            .init(start: 2, end: 5, scale: 2, isAutomatic: false), .init(start: 5, end: 8, scale: 2, isAutomatic: false),
        ]
        document.time = 3
        for _ in 0..<3 { document.addZoom() }
        #expect(document.project.zooms.map { [$0.start, $0.end] } == [[2, 5], [5, 8], [8, 10]])
        let zooms = document.project.zooms
        #expect(zip(zooms, zooms.dropFirst()).allSatisfy { $0.end <= $1.start })
    }

    @Test func whatIsChosenOnTheTimelineIsOneThingAtATime() throws {
        let document = try Self.document()
        defer { try? FileManager.default.removeItem(at: document.folder) }
        document.addCameraSegment()
        let layout = try #require(document.selectedSegment)
        // Cutting chooses the cut and lets go of the layout, so Delete takes back the cut and the layout stays.
        document.cut(4...5)
        #expect(document.selectedCut == 4 && document.selectedSegment == nil)
        document.deleteSelection()
        #expect(document.project.cuts.isEmpty && document.project.cameraSegments.map(\.id) == [layout])
        // A zoom chosen lets go of a layout chosen, and the layout of the zoom.
        document.selectedSegment = layout
        document.addZoom()
        let zoom = try #require(document.selectedZoom)
        #expect(document.selectedSegment == nil && document.selectedCut == nil)
        document.selectedSegment = layout
        #expect(document.selectedZoom == nil)
        document.deleteSelection()
        #expect(document.project.cameraSegments.isEmpty && document.project.zooms.map(\.id) == [zoom])
        // Choosing nothing leaves what else is chosen.
        document.selectedZoom = zoom
        document.selectedCut = nil
        #expect(document.selectedZoom == zoom)
    }

    @Test func aCameraWhoseMovieIsGoneLeavesTheMovieAloneWhateverTheLayout() throws {
        let missing = try Self.document(layout: .sideBySide, movie: false)
        defer { try? FileManager.default.removeItem(at: missing.folder) }
        #expect(!missing.hasCamera && missing.cameraFailed && missing.telemetry.camera != nil)
        let alone = StudioRenderer.layout(recordingSize: CGSize(width: 320, height: 200), project: missing.project, hasCamera: false)
        let layout = missing.movieLayout()
        #expect(layout == alone && layout.camera == nil)
        // What the movie is drawn from has no camera either, so the picture and the size agree.
        #expect(missing.drawnTelemetry.camera == nil)
        let renderer = StudioRenderer(
            telemetry: missing.drawnTelemetry, project: missing.project, duration: 10, recordingSize: CGSize(width: 320, height: 200), background: nil
        )
        #expect(renderer.layout == layout && renderer.camera == nil)
        // With its movie there, the same project is wider, for the camera's picture.
        let kept = try Self.document(layout: .sideBySide)
        defer { try? FileManager.default.removeItem(at: kept.folder) }
        #expect(kept.drawnTelemetry.camera != nil)
        #expect(kept.movieLayout().canvas.width > alone.canvas.width && kept.movieLayout().camera != nil)
    }
}
