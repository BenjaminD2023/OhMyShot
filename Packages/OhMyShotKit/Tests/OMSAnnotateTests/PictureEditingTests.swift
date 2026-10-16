import AppKit
import CoreGraphics
import Foundation
import Testing
@testable import OMSAnnotate

/// The session and the canvas around turning, resizing, locking the canvas, and the crop's ratios.
@MainActor
@Suite(.serialized)
struct PictureEditingTests {
    init() {
        PictureStore.use(URL.temporaryDirectory.appending(path: "OhMyShotKit Tests \(ProcessInfo.processInfo.processIdentifier)", directoryHint: .isDirectory))
    }

    private let scratch = ScratchDefaults()

    private func makeDefaults() -> UserDefaults {
        scratch.make()
    }

    private func makeSession(defaults: UserDefaults? = nil) -> AnnotationSession {
        let session = AnnotationSession(image: makeBase(), scale: 2, tool: .arrow, defaults: defaults ?? makeDefaults())
        session.undoManager.groupsByEvent = false
        return session
    }

    private func step(_ session: AnnotationSession, _ change: () -> Void) {
        session.undoManager.beginUndoGrouping()
        change()
        session.undoManager.endUndoGrouping()
    }

    private func makeCanvas(_ session: AnnotationSession) -> (canvas: AnnotationCanvasView, window: NSWindow) {
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.borderless], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let canvas = AnnotationCanvasView(session: session)
        canvas.contentInsets = NSEdgeInsetsZero
        canvas.frame = window.contentView!.bounds
        window.contentView!.addSubview(canvas)
        canvas.layoutSubtreeIfNeeded()
        return (canvas, window)
    }

    private func rectangle() -> Annotation {
        Annotation(shape: .rectangle(Box(rect: CGRect(x: 10, y: 20, width: 30, height: 10))), style: Style())
    }

    // MARK: Turning and resizing

    @Test func aTurnIsOneNamedStepThatUndoesWithItsPicture() throws {
        let session = makeSession()
        let mark = rectangle()
        step(session) {
            var document = session.document
            document.items.append(mark)
            session.commit(document, selecting: [mark.id], actionName: "Add Rectangle")
        }
        let before = session.document
        let capture = session.picture
        #expect(capture === session.base)
        step(session) { session.apply(.rotateRight) }
        #expect(session.undoManager.undoActionName == "Rotate Right")
        #expect(session.picture.width == 100 && session.picture.height == 200)
        #expect(session.document.imageBounds == CGRect(x: 0, y: 0, width: 100, height: 200))
        // The capture as it was taken is untouched, and the selection is kept.
        #expect(session.base.width == 200 && session.base.height == 100)
        #expect(session.selection == [mark.id])
        #expect(session.hasUnkeptChanges)
        // The picture is made once for a turn.
        #expect(session.picture === session.picture)
        session.undoManager.undo()
        #expect(session.document == before)
        #expect(session.picture.width == 200 && session.picture.height == 100)
        session.undoManager.redo()
        #expect(session.picture.width == 100)
        #expect(session.undoManager.canUndo)
    }

    @Test func resizingIsOneStepAndTheSessionKeepsReadingTheRightPixels() throws {
        let session = makeSession()
        step(session) { session.apply(.resize(to: CGSize(width: 100, height: 50))) }
        #expect(session.undoManager.undoActionName == "Resize Image")
        #expect(session.picture.width == 100 && session.picture.height == 50)
        #expect(session.document.scale == 1)
        // A resize asking for what the picture is changes nothing, and neither does nonsense.
        let kept = session.document
        session.apply(.resize(to: CGSize(width: 100, height: 50)))
        session.apply(.resize(to: CGSize(width: 0, height: 50)))
        #expect(session.document == kept)
        session.undoManager.undo()
        #expect(session.document.scale == 2 && session.document.transform == nil)
    }

    @Test func whatWasReadOfThePictureIsReadAgainOnceItIsTurned() async {
        nonisolated final class Reads: @unchecked Sendable {
            var sizes: [CGSize] = []
        }
        let reads = Reads()
        let session = makeSession()
        session.textReader = { image in
            reads.sizes.append(CGSize(width: image.width, height: image.height))
            return CaptureReading(redactionSuggestions: { [RedactionSuggestion(rect: CGRect(x: 10, y: 10, width: 40, height: 10), label: "Email address")] })
        }
        session.tool = .redact
        for _ in 0..<100 where session.isFindingRedactions || session.redactionSuggestions.isEmpty {
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(reads.sizes == [CGSize(width: 200, height: 100)])
        step(session) { session.apply(.rotateRight) }
        for _ in 0..<100 where session.isFindingRedactions || session.redactionSuggestions.isEmpty || reads.sizes.count < 2 {
            try? await Task.sleep(for: .milliseconds(10))
        }
        // Read again from the picture as it is now, in its pixels.
        #expect(reads.sizes == [CGSize(width: 200, height: 100), CGSize(width: 100, height: 200)])
        // Undone, the first reading's picture is back and it is read once more, not remembered wrongly.
        session.undoManager.undo()
        for _ in 0..<100 where session.isFindingRedactions || reads.sizes.count < 3 {
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(reads.sizes.last == CGSize(width: 200, height: 100))
    }

    @Test func aBackgroundGoesOnAroundTheTurnedPicture() throws {
        let session = makeSession()
        step(session) { session.setBackdrop(Backdrop(fill: .gradient(.sky), padding: 0.1), actionName: "Background") }
        step(session) { session.apply(.rotateLeft) }
        let layout = try #require(session.backdropLayout)
        #expect(layout.picture == CGRect(x: 0, y: 0, width: 100, height: 200))
        #expect(layout.card.size == layout.picture.size)
        #expect(layout.output.width > 100 && layout.output.height > 200)
        #expect(session.document.backdrop?.padding == 0.1)
    }

    @Test func theCanvasTurnsAndFlipsOnItsCommandsAndEndsACropFirst() throws {
        let session = makeSession()
        let (canvas, window) = makeCanvas(session)
        defer { window.close() }
        step(session) { canvas.rotateLeft(nil) }
        #expect(session.document.orientation == Orientation(quarterTurns: 3))
        step(session) { canvas.flipHorizontal(nil) }
        step(session) { canvas.flipVertical(nil) }
        step(session) { canvas.rotateRight(nil) }
        #expect(session.document.orientation != .identity)
        // The crop being chosen is made before the turn takes the picture.
        session.tool = .crop
        canvas.chooseCropRatio(.fixed(1, 1))
        canvas.rotateRight(nil)
        #expect(session.tool != .crop)
        #expect(session.document.canvas.width == session.document.canvas.height)
        let item = NSMenuItem(title: "", action: #selector(AnnotationCanvasView.rotateRight(_:)), keyEquivalent: "")
        #expect(canvas.validateMenuItem(item))
        #expect(canvas.validateMenuItem(NSMenuItem(title: "", action: #selector(AnnotationCanvasView.flipVertical(_:)), keyEquivalent: "")))
    }

    @Test func inPlaceTheCanvasIsTheSelectionAndNothingTurns() {
        let session = makeSession()
        let (canvas, window) = makeCanvas(session)
        defer { window.close() }
        canvas.configureInPlace()
        canvas.onImageSize = {}
        for action in [#selector(AnnotationCanvasView.rotateRight(_:)), #selector(AnnotationCanvasView.rotateLeft(_:)), #selector(AnnotationCanvasView.flipHorizontal(_:)), #selector(AnnotationCanvasView.flipVertical(_:)), #selector(AnnotationCanvasView.showImageSize(_:)), #selector(AnnotationCanvasView.toggleCanvasLock(_:))] {
            #expect(!canvas.validateMenuItem(NSMenuItem(title: "", action: action, keyEquivalent: "")))
        }
        canvas.toggleCanvasLock(nil)
        #expect(!session.locksCanvas)
    }

    @Test func aTurnWithACropPendingIsOneStepOfItsOwn() {
        // Grouping by event is off, so a step registered outside a group of the canvas's own would raise.
        let session = makeSession()
        let (canvas, window) = makeCanvas(session)
        defer { window.close() }
        session.tool = .crop
        canvas.chooseCropRatio(.fixed(1, 1))
        canvas.rotateRight(nil)
        #expect(session.tool != .crop)
        #expect(session.document.orientation == Orientation(quarterTurns: 1))
        #expect(session.document.canvas.width == session.document.canvas.height)
        #expect(session.undoManager.undoActionName == "Rotate Right")
        // One Undo takes back the turn and the crop.
        session.undoManager.undo()
        #expect(session.document.canvas == CGRect(x: 0, y: 0, width: 200, height: 100) && session.document.orientation == .identity)
        #expect(!session.undoManager.canUndo)
        session.undoManager.redo()
        #expect(session.document.orientation == Orientation(quarterTurns: 1) && session.document.canvas.width == session.document.canvas.height)
        #expect(!session.undoManager.canRedo)
    }

    @Test func aCropFrameThatIsTheWholeCanvasMakesNoStepOfItsOwn() {
        let session = makeSession()
        let (canvas, window) = makeCanvas(session)
        defer { window.close() }
        session.tool = .crop
        // The frame is the whole canvas and the size asked for is the one it has: nothing to make, and no
        // empty group left to undo.
        canvas.resizePicture(to: CGSize(width: 200, height: 100))
        #expect(session.tool != .crop && !session.undoManager.canUndo)
    }

    @Test func imageSizeMeasuresACropPendingAndOnlyResizeMakesIt() {
        let session = makeSession()
        let (canvas, window) = makeCanvas(session)
        defer { window.close() }
        var asked = 0
        canvas.onImageSize = { asked += 1 }
        session.tool = .crop
        canvas.chooseCropRatio(.fixed(1, 1))
        canvas.showImageSize(nil)
        #expect(asked == 1)
        // The sheet is up and the crop waits: Cancel leaves the editor as it was.
        #expect(session.tool == .crop && !session.undoManager.canUndo && session.document.canvas == CGRect(x: 0, y: 0, width: 200, height: 100))
        #expect(canvas.validateMenuItem(NSMenuItem(title: "", action: #selector(AnnotationCanvasView.showImageSize(_:)), keyEquivalent: "")))
        // It measures the canvas the crop would make.
        let model = ImageSizeModel(document: canvas.documentForImageSize)
        #expect(model.sizing.current == CGSize(width: 100, height: 100))
        model.setPercent(50)
        canvas.resizePicture(to: model.sizing.size)
        // Resize makes the crop and the resize together: one step, named for the resize.
        #expect(session.tool != .crop)
        #expect(session.document.canvas.size == CGSize(width: 50, height: 50))
        #expect(session.document.pictureSize == CGSize(width: 100, height: 50))
        #expect(session.undoManager.undoActionName == "Resize Image")
        session.undoManager.undo()
        #expect(session.document.canvas == CGRect(x: 0, y: 0, width: 200, height: 100) && session.document.transform == nil)
        #expect(!session.undoManager.canUndo)
    }

    @Test func imageSizeMeasuresThePlainCanvasWithoutACrop() {
        let session = makeSession()
        let (canvas, window) = makeCanvas(session)
        defer { window.close() }
        #expect(canvas.documentForImageSize == session.document)
        // A crop only begun is the whole canvas: the same size.
        session.tool = .crop
        #expect(canvas.pendingCrop == session.document.canvas)
        #expect(ImageSizeModel(document: canvas.documentForImageSize).sizing.current == CGSize(width: 200, height: 100))
    }

    // MARK: Canvas lock

    private func swatch() -> (name: String, size: CGSize) {
        (name: "a.png", size: CGSize(width: 60, height: 40))
    }

    @Test func combinedImagesGrowTheCanvasUnlessItIsLocked() {
        let open = makeSession()
        step(open) { open.addImages([swatch()], at: CGPoint(x: 190, y: 50)) }
        #expect(open.document.canvas.width > 200)

        let locked = makeSession()
        locked.locksCanvas = true
        step(locked) { locked.addImages([swatch()], at: CGPoint(x: 190, y: 50)) }
        #expect(locked.document.canvas == CGRect(x: 0, y: 0, width: 200, height: 100))
        #expect(locked.document.items.count == 1)
        // Moving the image further out leaves the canvas alone too; unlocked, it follows.
        var document = locked.document
        document.items[0] = document.items[0].translated(by: CGSize(width: 100, height: 0))
        locked.updateLive(document)
        locked.growCanvasToHoldImages()
        #expect(locked.document.canvas == CGRect(x: 0, y: 0, width: 200, height: 100))
        locked.locksCanvas = false
        step(locked) { locked.growCanvasToHoldImages() }
        #expect(locked.document.canvas.maxX >= locked.document.items[0].bounds(scale: 2).maxX)
    }

    @Test func theLockIsRememberedForTheNextEditorAndTellsListeners() {
        let defaults = makeDefaults()
        let session = makeSession(defaults: defaults)
        var heard: [AnnotationSession.Event] = []
        session.observe { heard.append($0) }
        #expect(!session.locksCanvas)
        session.locksCanvas = true
        session.locksCanvas = true
        #expect(heard == [.settings])
        #expect(makeSession(defaults: defaults).locksCanvas)
        session.locksCanvas = false
        #expect(!makeSession(defaults: defaults).locksCanvas)
    }

    @Test func theCanvasCommandTogglesTheLock() {
        let session = makeSession()
        let (canvas, window) = makeCanvas(session)
        defer { window.close() }
        let item = NSMenuItem(title: "", action: #selector(AnnotationCanvasView.toggleCanvasLock(_:)), keyEquivalent: "")
        #expect(canvas.validateMenuItem(item) && item.state == .off)
        canvas.toggleCanvasLock(nil)
        #expect(session.locksCanvas)
        #expect(canvas.validateMenuItem(item) && item.state == .on)
    }

    // MARK: Crop ratios

    @Test func aChosenRatioFitsThePictureAndTheCropKeepsIt() throws {
        let session = makeSession()
        let (canvas, window) = makeCanvas(session)
        defer { window.close() }
        session.tool = .crop
        #expect(session.cropRatio == .free)
        // Tried one after another, each the largest frame of its shape the 200 × 100 picture holds.
        canvas.chooseCropRatio(.fixed(1, 1))
        #expect(session.cropRatio == .fixed(1, 1))
        #expect(canvas.pendingCrop == CGRect(x: 50, y: 0, width: 100, height: 100))
        canvas.chooseCropRatio(.fixed(16, 9))
        var frame = try #require(canvas.pendingCrop)
        #expect(frame.height == 100 && abs(frame.width / frame.height - 16.0 / 9) < 0.02, "\(frame)")
        canvas.chooseCropRatio(.fixed(9, 16))
        frame = try #require(canvas.pendingCrop)
        #expect(frame.height == 100 && abs(frame.width / frame.height - 9.0 / 16) < 0.03, "\(frame)")
        canvas.chooseCropRatio(.original)
        #expect(canvas.pendingCrop == CGRect(x: 0, y: 0, width: 200, height: 100))
        canvas.chooseCropRatio(.fixed(4, 3))
        step(session) { canvas.commitCrop() }
        let cropped = session.document.canvas
        #expect(cropped.height == 100 && abs(cropped.width / cropped.height - 4.0 / 3) < 0.02)
        // After a crop the room is still the picture's: Original gives the whole of it back.
        canvas.chooseCropRatio(.original)
        step(session) { canvas.commitCrop() }
        #expect(session.document.canvas == CGRect(x: 0, y: 0, width: 200, height: 100))
        // Leaving the tool and coming back starts free again.
        step(session) { session.tool = .arrow }
        session.tool = .crop
        #expect(session.cropRatio == .free)
    }

    @Test func escapeLeavesTheRatioAsResetDoes() throws {
        let session = makeSession()
        let (canvas, window) = makeCanvas(session)
        defer { window.close() }
        session.tool = .crop
        canvas.chooseCropRatio(.fixed(16, 9))
        #expect(session.cropRatio == .fixed(16, 9) && canvas.pendingCrop != session.document.canvas)
        let escape = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
            characters: "\u{1B}", charactersIgnoringModifiers: "\u{1B}", isARepeat: false, keyCode: 53
        ))
        canvas.keyDown(with: escape)
        // The frame is the whole canvas again, any shape, and the chip says Free.
        #expect(session.tool == .crop && session.cropRatio == .free)
        #expect(canvas.pendingCrop == session.document.canvas)
        canvas.chooseCropRatio(.fixed(1, 1))
        step(session) { canvas.resetCrop() }
        #expect(session.cropRatio == .free)
    }

    @Test func settingTheRatioTellsTheCapsuleOnce() {
        let session = makeSession()
        var heard: [AnnotationSession.Event] = []
        session.observe { heard.append($0) }
        session.setCropRatio(.fixed(16, 9))
        session.setCropRatio(.fixed(16, 9))
        #expect(heard == [.settings])
    }

    // MARK: Image Size

    @Test func theSheetKeepsProportionsByDefault() {
        var sizing = ImageSizing(current: CGSize(width: 1600, height: 900))
        #expect(sizing.size == CGSize(width: 1600, height: 900) && sizing.percent == 100 && !sizing.changesSize)
        sizing.setWidth(800)
        #expect(sizing.size == CGSize(width: 800, height: 450) && sizing.percent == 50 && sizing.changesSize)
        sizing.setHeight(300)
        #expect(sizing.size == CGSize(width: 533, height: 300))
        sizing.setPercent(25)
        #expect(sizing.size == CGSize(width: 400, height: 225))
        sizing.setPercent(200)
        #expect(sizing.size == CGSize(width: 3200, height: 1800))
    }

    @Test func theSheetResizesTheCanvasThroughTheEditorAsOneStep() {
        let session = makeSession()
        let (canvas, window) = makeCanvas(session)
        defer { window.close() }
        let model = ImageSizeModel(document: session.document)
        #expect(!model.canResize)
        model.setPercent(50)
        #expect(model.canResize && model.sizing.size == CGSize(width: 100, height: 50))
        step(session) { canvas.resizePicture(to: model.sizing.size) }
        #expect(session.document.canvas == CGRect(x: 0, y: 0, width: 100, height: 50))
        #expect(session.undoManager.undoActionName == "Resize Image")
        // Asked of the canvas as it is now: the sheet opened again starts from the new size.
        #expect(ImageSizeModel(document: session.document).sizing.current == CGSize(width: 100, height: 50))
        session.undoManager.undo()
        #expect(session.document.canvas == CGRect(x: 0, y: 0, width: 200, height: 100))
    }

    @Test func aSizeNoPictureCanHaveCannotBeAskedFor() {
        let model = ImageSizeModel(document: AnnotationDocument(pixelSize: CGSize(width: 1600, height: 900), scale: 2))
        model.setWidth(16000)
        // 16000 × 9000 is within a side's limit and past the pixels in all.
        #expect(model.sizing.size == CGSize(width: 16000, height: 9000))
        #expect(!model.allowed && !model.canResize)
        model.setWidth(8000)
        #expect(model.allowed && model.canResize)
        // Without proportions to keep, the sides are free to go to either extreme.
        model.setKeepsProportions(false)
        model.setHeight(16384)
        #expect(!model.allowed)
        model.setKeepsProportions(true)
        #expect(model.sizing.height == Int((Double(model.sizing.width) * 900 / 1600).rounded()))
    }

    @Test func proportionsCanBeLeftBehind() {
        var sizing = ImageSizing(current: CGSize(width: 1600, height: 900))
        sizing.keepsProportions = false
        sizing.setWidth(1000)
        #expect(sizing.size == CGSize(width: 1000, height: 900))
        sizing.setHeight(100)
        #expect(sizing.size == CGSize(width: 1000, height: 100))
        // A percent scales both sides evenly whatever the setting.
        sizing.setPercent(50)
        #expect(sizing.size == CGSize(width: 800, height: 450))
    }

    @Test func theSheetStaysWithinWhatAPictureCanBe() {
        var sizing = ImageSizing(current: CGSize(width: 100, height: 100))
        sizing.setWidth(0)
        #expect(sizing.size == CGSize(width: 1, height: 1))
        sizing.setWidth(1_000_000)
        #expect(sizing.width == AnnotationDocument.maxPictureSide)
        sizing.setPercent(-10)
        #expect(sizing.size == CGSize(width: 1, height: 1))
    }
}
