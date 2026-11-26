import AppKit
import CoreGraphics
import Foundation
import OMSCore
import Testing
@testable import OMSAnnotate

/// Covers ported Domain B power features and polish on v0.4.0+:
/// - `M-06`: cross-window annotation Cut/Copy/Paste (including v4 Magnifier & Erase redactions)
/// - `M-16`: rectangle corner radius, 3-level Redact strength, 3-level Spotlight dimming,
///   Revert to Original, single-step layer ordering (`bringForward`/`sendBackward`), live pixel dimensions
/// - `U-14` + `F-09`: inline text Undo sync & auto-width reset, counter next-number stepper,
///   multi-select StyleCapsule union, standard zoom steps, `isSpaceHeld` focus-loss reset,
///   continuous color panel live coalescing, `BackdropAdjustments.hasBackdrop` & watermark focus,
///   window cascading & thumbnail sync, distinct `SelectionLayer` handles & rotation knob.
@MainActor
@Suite(.serialized)
struct AnnotationPowerFeaturesTests {
    private let scratch = ScratchDefaults()

    private func makeSession(base: CGImage = makeBase(), scale: CGFloat = 1, tool: AnnotationTool = .select) -> AnnotationSession {
        let session = AnnotationSession(image: base, scale: scale, tool: tool, defaults: scratch.make())
        session.undoManager.groupsByEvent = false
        return session
    }

    private func step(_ session: AnnotationSession, _ change: () -> Void) {
        session.undoManager.beginUndoGrouping()
        change()
        session.undoManager.endUndoGrouping()
    }

    private func makeCanvasWindow(
        base: CGImage = makeBase(),
        scale: CGFloat = 1,
        tool: AnnotationTool = .select,
        viewSize: CGSize = CGSize(width: 400, height: 200)
    ) -> (AnnotationCanvasView, AnnotationSession, NSWindow) {
        let session = makeSession(base: base, scale: scale, tool: tool)
        let window = NSWindow(
            contentRect: CGRect(origin: .zero, size: viewSize),
            styleMask: [.borderless],
            backing: .buffered,
            defer: true
        )
        window.isReleasedWhenClosed = false
        let canvas = AnnotationCanvasView(session: session)
        canvas.contentInsets = NSEdgeInsetsZero
        canvas.frame = CGRect(origin: .zero, size: viewSize)
        window.contentView?.addSubview(canvas)
        canvas.layoutSubtreeIfNeeded()
        return (canvas, session, window)
    }

    // MARK: M-06 — Cross-Window Annotation Cut/Copy/Paste

    @Test func legacyToolSettingsDecodeDefaultsNewerFields() throws {
        let legacySettingsJSON = #"{"color":{"red":1,"green":0,"blue":0,"alpha":1},"lineWidth":4,"shadow":true}"#.data(using: .utf8)!
        let decodedSettings = try JSONDecoder().decode(ToolSettings.self, from: legacySettingsJSON)
        #expect(decodedSettings.zoom == .two)
        #expect(decodedSettings.redactionStrength == Redaction.Strength.medium.rawValue)
        #expect(decodedSettings.spotlightDimming == Spot.Dimming.medium.rawValue)
    }

    @Test func pasteboardEncodesDecodesOffsetsClampsAndAdvancesCounters() throws {
        let rect = Annotation(shape: .rectangle(Box(rect: CGRect(x: 300, y: 250, width: 40, height: 30))), style: Style(color: .red, shadow: false))
        let counter = Annotation(shape: .counter(Counter(center: CGPoint(x: 310, y: 260), value: 1)), style: Style(color: .blue, shadow: false))
        let loupe = Annotation(
            shape: .magnifier(Magnifier(source: CGPoint(x: 300, y: 250), center: CGPoint(x: 330, y: 270), radius: 20, zoom: .three)),
            style: Style(color: .white, lineWidth: 2, shadow: false)
        )
        let erase = Annotation(
            shape: .redaction(Redaction(rect: CGRect(x: 295, y: 245, width: 30, height: 20), method: .erase)),
            style: Style()
        )
        let data = try AnnotationPasteboard.encode([rect, counter, loupe, erase])
        let decoded = try AnnotationPasteboard.decode(data)
        #expect(decoded == [rect, counter, loupe, erase])

        // Paste into a smaller 100×80 canvas that already has Counter #1.
        var target = AnnotationDocument(pixelSize: CGSize(width: 100, height: 80), scale: 1)
        target.items = [Annotation(shape: .counter(Counter(center: CGPoint(x: 20, y: 20), value: 1)), style: Style())]
        let prepared = AnnotationPasteboard.preparedForPaste(decoded, into: target)
        #expect(prepared.count == 4)
        #expect(prepared[0].id != rect.id && prepared[1].id != counter.id && prepared[2].id != loupe.id && prepared[3].id != erase.id)
        for mark in prepared {
            let bounds = mark.bounds(scale: 1)
            #expect(bounds.minX >= 0 && bounds.maxX <= 100)
            #expect(bounds.minY >= 0 && bounds.maxY <= 80)
        }
        if case .counter(let pastedCounter) = prepared[1].shape {
            #expect(pastedCounter.value == 2)
        } else {
            Issue.record("Expected counter as second pasted mark")
        }
        if case .magnifier(let pastedLoupe) = prepared[2].shape {
            #expect(pastedLoupe.zoom == .three && pastedLoupe.radius == 20)
        } else {
            Issue.record("Expected magnifier as third pasted mark")
        }
        if case .redaction(let pastedErase) = prepared[3].shape {
            #expect(pastedErase.method == .erase)
        } else {
            Issue.record("Expected erase redaction as fourth pasted mark")
        }
    }

    @Test func crossWindowCutCopyAndPasteBetweenTwoCanvases() throws {
        let (sourceCanvas, sourceSession, sourceWindow) = makeCanvasWindow(base: makeBase(width: 400, height: 200))
        let (targetCanvas, targetSession, targetWindow) = makeCanvasWindow(base: makeBase(width: 140, height: 100))
        defer {
            sourceWindow.close()
            targetWindow.close()
        }

        let mark = Annotation(
            shape: .rectangle(Box(rect: CGRect(x: 240, y: 120, width: 40, height: 20))),
            style: Style(color: .green, lineWidth: 2, shadow: false)
        )
        step(sourceSession) {
            var doc = sourceSession.document
            doc.items = [mark]
            sourceSession.commit(doc, selecting: [mark.id], actionName: "Add Rectangle")
        }

        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }

        // Copy from source window and paste into smaller target window.
        #expect(sourceCanvas.copySelectedAnnotations(to: pasteboard))
        #expect(AnnotationPasteboard.hasAnnotations(on: pasteboard))

        step(targetSession) {
            #expect(targetCanvas.pasteAnnotations(from: pasteboard))
        }
        #expect(targetSession.document.items.count == 1)
        let pasted = try #require(targetSession.document.items.first)
        #expect(pasted.id != mark.id)
        #expect(targetSession.selection == [pasted.id])
        #expect(targetSession.document.canvas.contains(pasted.bounds(scale: 1)))

        // Cut from source removes marks in one Undo step and puts them on the pasteboard.
        step(sourceSession) {
            #expect(sourceCanvas.cutSelectedAnnotations(to: pasteboard))
        }
        #expect(sourceSession.document.items.isEmpty)
        #expect(sourceSession.selection.isEmpty)
        sourceSession.undo()
        #expect(sourceSession.document.items == [mark])

        // Pasting twice into source offsets each paste progressively.
        step(sourceSession) { #expect(sourceCanvas.pasteAnnotations(from: pasteboard)) }
        step(sourceSession) { #expect(sourceCanvas.pasteAnnotations(from: pasteboard)) }
        #expect(sourceSession.document.items.count == 3)
        let firstPasted = sourceSession.document.items[1].bounds(scale: 1)
        let secondPasted = sourceSession.document.items[2].bounds(scale: 1)
        #expect(secondPasted.minX > firstPasted.minX && secondPasted.minY > firstPasted.minY)
    }

    // MARK: M-16 — Precision & Canvas Controls

    @Test func cornerRadiusRedactionStrengthAndSpotlightDimmingCodableCompatibility() throws {
        #expect(Box.cornerRadiusPresets == [0, 4, 10, 18])

        // Legacy Redaction JSON without `strength` defaults to 1.0 (Medium).
        let legacyRedaction = #"{"rect":[[0,0],[50,20]],"method":"pixelate"}"#.data(using: .utf8)!
        let decodedRedaction = try JSONDecoder().decode(Redaction.self, from: legacyRedaction)
        #expect(decodedRedaction.strength == Redaction.Strength.medium.rawValue)

        let highRedaction = Redaction(rect: CGRect(x: 0, y: 0, width: 50, height: 20), method: .blur, strength: Redaction.Strength.high.rawValue)
        let roundTrippedRedaction = try JSONDecoder().decode(Redaction.self, from: JSONEncoder().encode(highRedaction))
        #expect(roundTrippedRedaction == highRedaction)

        // Legacy Spot JSON without `dimming` defaults to 0.50 (Medium).
        let legacySpot = #"{"rect":[[10,10],[40,30]],"oval":true}"#.data(using: .utf8)!
        let decodedSpot = try JSONDecoder().decode(Spot.self, from: legacySpot)
        #expect(decodedSpot.dimming == Spot.Dimming.medium.rawValue)

        let darkSpot = Spot(rect: CGRect(x: 10, y: 10, width: 40, height: 30), oval: false, dimming: Spot.Dimming.dark.rawValue)
        let roundTrippedSpot = try JSONDecoder().decode(Spot.self, from: JSONEncoder().encode(darkSpot))
        #expect(roundTrippedSpot == darkSpot)
    }

    @Test func redactorScalesWithStrengthAndSpotlightHonorsDimmingLevels() throws {
        let rect = CGRect(x: 0, y: 0, width: 240, height: 120)
        let lowBlock = Redactor.blockSize(for: rect, scale: 1, strength: Redaction.Strength.low.rawValue)
        let medBlock = Redactor.blockSize(for: rect, scale: 1, strength: Redaction.Strength.medium.rawValue)
        let highBlock = Redactor.blockSize(for: rect, scale: 1, strength: Redaction.Strength.high.rawValue)
        #expect(lowBlock < medBlock && medBlock < highBlock)

        // Blur strength: higher strength blurs the black band across a wider radius (lifting its center more and
        // darkening white further away).
        func blurPixels(strength: Redaction.Strength) throws -> Pixels {
            let item = Annotation(
                shape: .redaction(Redaction(rect: CGRect(x: 10, y: 15, width: 100, height: 70), method: .blur, strength: strength.rawValue)),
                style: Style()
            )
            let doc = AnnotationDocument(pixelSize: CGSize(width: 200, height: 100), scale: 1, items: [item])
            return Pixels(try #require(AnnotationRenderer.flatten(doc, base: makeBase())))
        }
        let lowBlur = try blurPixels(strength: .low)
        let medBlur = try blurPixels(strength: .medium)
        let highBlur = try blurPixels(strength: .high)
        #expect(lowBlur[60, 50].r < medBlur[60, 50].r && medBlur[60, 50].r < highBlur[60, 50].r)
        #expect(highBlur[60, 18].r < lowBlur[60, 18].r)

        // Spotlight dimming: Light > Medium > Dark brightness outside the spotlight.
        func outsideBrightness(dimming: Spot.Dimming) throws -> Int {
            let spot = Annotation(
                shape: .spotlight(Spot(rect: CGRect(x: 10, y: 5, width: 40, height: 20), dimming: dimming.rawValue)),
                style: Style(shadow: false)
            )
            let doc = AnnotationDocument(pixelSize: CGSize(width: 200, height: 100), scale: 1, items: [spot])
            return Pixels(try #require(AnnotationRenderer.flatten(doc, base: makeBase())))[150, 80].r
        }
        let light = try outsideBrightness(dimming: .light)
        let medium = try outsideBrightness(dimming: .medium)
        let dark = try outsideBrightness(dimming: .dark)
        #expect(light > medium && medium > dark)
        #expect(abs(light - 166) < 8)
        #expect(abs(medium - 128) < 8)
        #expect(abs(dark - 56) < 8)
    }

    @Test func bringForwardAndSendBackwardStepSingleLayerPreservingRelativeOrder() {
        let session = makeSession()
        let a = Annotation(shape: .rectangle(Box(rect: CGRect(x: 0, y: 0, width: 10, height: 10))), style: Style())
        let b = Annotation(shape: .rectangle(Box(rect: CGRect(x: 20, y: 0, width: 10, height: 10))), style: Style())
        let c = Annotation(shape: .rectangle(Box(rect: CGRect(x: 40, y: 0, width: 10, height: 10))), style: Style())
        let d = Annotation(shape: .rectangle(Box(rect: CGRect(x: 60, y: 0, width: 10, height: 10))), style: Style())
        step(session) {
            var doc = session.document
            doc.items = [a, b, c, d]
            session.commit(doc, selecting: [b.id], actionName: "Add")
        }

        step(session) { session.bringForward() }
        #expect(session.document.items.map(\.id) == [a.id, c.id, b.id, d.id])

        step(session) { session.sendBackward() }
        #expect(session.document.items.map(\.id) == [a.id, b.id, c.id, d.id])

        // Multi-selection [a, c] shifts each one step toward front while preserving order.
        session.select([a.id, c.id])
        step(session) { session.bringForward() }
        #expect(session.document.items.map(\.id) == [b.id, a.id, d.id, c.id])

        session.undo()
        #expect(session.document.items.map(\.id) == [a.id, b.id, c.id, d.id])

        // Boundary no-ops leave order untouched.
        session.select([d.id])
        session.bringForward()
        #expect(session.document.items.map(\.id) == [a.id, b.id, c.id, d.id])
        session.select([a.id])
        session.sendBackward()
        #expect(session.document.items.map(\.id) == [a.id, b.id, c.id, d.id])
    }

    @Test func revertToOriginalRestoresCaptureUndoably() {
        let session = makeSession(scale: 2)
        #expect(!session.canRevertToOriginal)

        let mark = Annotation(shape: .rectangle(Box(rect: CGRect(x: 10, y: 10, width: 30, height: 20))), style: Style())
        step(session) {
            var doc = session.document
            doc.items = [mark]
            session.commit(doc, selecting: [mark.id], actionName: "Add")
        }
        step(session) { session.crop(to: CGRect(x: 10, y: 10, width: 100, height: 60)) }
        step(session) { session.setBackdrop(Backdrop(fill: .color(.blue)), actionName: "Background") }
        step(session) { session.apply(.rotateRight) }
        step(session) { session.apply(.resize(to: CGSize(width: 120, height: 200))) }
        #expect(session.canRevertToOriginal)

        step(session) { session.revertToOriginal() }
        #expect(!session.canRevertToOriginal)
        #expect(session.document.items.isEmpty)
        #expect(session.document.backdrop == nil)
        #expect(session.document.transform == nil)
        #expect(session.document.canvas == session.document.imageBounds)
        #expect(session.document.scale == 2)
        #expect(session.selection.isEmpty)

        // Single undo restores the edited state.
        session.undo()
        #expect(session.canRevertToOriginal)
        #expect(session.document.items.count == 1)
        #expect(session.document.backdrop != nil)
        #expect(session.document.transform != nil)
    }

    @Test func cropDimensionPillAndEditorSubtitleTrackOutputPixels() {
        let base = makeBase(width: 200, height: 100)
        let (canvas, session, window) = makeCanvasWindow(base: base, scale: 1, tool: .select)
        defer { window.close() }

        #expect(canvas.cropDimensionText == nil)
        session.tool = .crop
        #expect(canvas.cropDimensionText == "200 × 100 px")

        // Editor window subtitle reflects current output pixel dimensions live.
        let temp = URL.temporaryDirectory.appending(path: "oms-subtitle-\(UUID().uuidString).png")
        let editor = AnnotationEditorWindowController(
            image: base, scale: 1, document: nil, title: "Capture", fileURL: temp,
            actions: .init(keep: { _, _, _ in temp }, save: { $0 })
        )
        defer { editor.window?.delegate = nil; editor.close() }
        #expect(editor.window?.subtitle == "200 × 100 px")
        editor.session.crop(to: CGRect(x: 20, y: 10, width: 120, height: 60))
        #expect(editor.window?.subtitle == "120 × 60 px")
    }

    // MARK: U-14 + F-09 — Annotation UX Polish

    @Test func counterNextStepperOverridesPerNumberingAndAdvancesOnPlacement() {
        let session = makeSession(tool: .counter)
        #expect(session.nextCounterValue(for: .numbers) == 1)
        session.setNextCounterValue(5, for: .numbers)
        #expect(session.nextCounterValue(for: .numbers) == 5)
        #expect(session.nextCounterValue(for: .letters) == 1)

        // Clamping below 1 keeps at 1.
        session.setNextCounterValue(0, for: .letters)
        #expect(session.nextCounterValue(for: .letters) == 1)

        // Placing counter 5 advances next override to 6.
        session.didPlaceCounter(value: 5, numbering: .numbers)
        #expect(session.nextCounterValue(for: .numbers) == 6)
    }

    @Test func multiSelectStyleCapsuleUnionAppliesChangesOnlyToSupportingMarks() {
        let (canvas, session, window) = makeCanvasWindow()
        defer { window.close() }

        let rect = Annotation(
            shape: .rectangle(Box(rect: CGRect(x: 10, y: 10, width: 40, height: 30))),
            style: Style(color: .red, lineWidth: 2, shadow: false)
        )
        let spot = Annotation(
            shape: .spotlight(Spot(rect: CGRect(x: 80, y: 10, width: 40, height: 30), oval: true, dimming: 0.78)),
            style: Style(color: .black, lineWidth: 4, shadow: false)
        )
        let loupe = Annotation(
            shape: .magnifier(Magnifier(source: CGPoint(x: 130, y: 30), center: CGPoint(x: 150, y: 50), radius: 24, zoom: .three)),
            style: Style(color: .white, lineWidth: 3, shadow: false)
        )
        let erase = Annotation(
            shape: .redaction(Redaction(rect: CGRect(x: 10, y: 60, width: 30, height: 20), method: .erase)),
            style: Style(color: .black, lineWidth: 4, shadow: false)
        )
        step(session) {
            var doc = session.document
            doc.items = [rect, spot, loupe, erase]
            session.commit(doc, selecting: [rect.id, spot.id, loupe.id, erase.id], actionName: "Add")
        }

        #expect(session.hasMixedSelection)
        #expect(session.selectedKinds == [.rectangle, .spotlight, .magnifier, .redact])
        #expect(session.selectionSupportsColor)
        #expect(session.selectionSupportsLineWidth)
        #expect(session.selectionSupportsShadow)

        // Changing color and lineWidth updates the rectangle without mangling spotlight, magnifier, or erase redaction.
        step(session) { session.changeSettings("Color") { $0.color = .blue } }
        step(session) { session.changeSettings("Size") { $0.lineWidth = 6 } }
        let updatedRect = session.document.items[0]
        let updatedSpot = session.document.items[1]
        let updatedLoupe = session.document.items[2]
        let updatedErase = session.document.items[3]
        #expect(updatedRect.style.color == .blue && updatedRect.style.lineWidth == 6)
        #expect(updatedSpot.style.color == .black && updatedSpot.style.lineWidth == 4)
        #expect(updatedLoupe.style.color == .white && updatedLoupe.style.lineWidth == 3)
        #expect(updatedErase.style.color == .black && updatedErase.style.lineWidth == 4)
        if case .spotlight(let s) = updatedSpot.shape {
            #expect(s.oval && s.dimming == 0.78)
        } else {
            Issue.record("Expected spotlight intact")
        }

        // Selecting only non-color, non-stroked marks (magnifier + erase redaction) hides color, size, and shadow.
        session.select([loupe.id, erase.id])
        #expect(session.hasMixedSelection)
        #expect(!session.selectionSupportsColor)
        #expect(!session.selectionSupportsLineWidth)
        #expect(!session.selectionSupportsShadow)

        // StyleCapsule refreshes cleanly for mixed selection.
        session.select([rect.id, spot.id])
        let capsule = StyleCapsule()
        capsule.refresh(from: session, canvas: canvas)
        #expect(capsule.fittingSize.width > 0)
    }

    @Test func standardZoomStepsSnapCleanlyAtOneXAndTwoX() {
        // 1× capture matching 400×200 view -> initial display zoom is 1.0 (100%).
        let (canvas1x, _, window1x) = makeCanvasWindow(base: makeBase(width: 400, height: 200), scale: 1, viewSize: CGSize(width: 400, height: 200))
        defer { window1x.close() }
        #expect(abs(canvas1x.zoom - 1.0) < 0.01)
        canvas1x.zoomIn()
        #expect(abs(canvas1x.zoom - 1.5) < 0.01)
        canvas1x.zoomIn()
        #expect(abs(canvas1x.zoom - 2.0) < 0.01)
        canvas1x.zoomIn()
        #expect(abs(canvas1x.zoom - 3.0) < 0.01)
        canvas1x.zoomIn()
        #expect(abs(canvas1x.zoom - 4.0) < 0.01)
        canvas1x.zoomOut()
        #expect(abs(canvas1x.zoom - 3.0) < 0.01)
        canvas1x.zoomToActualSize()
        canvas1x.zoomOut()
        #expect(abs(canvas1x.zoom - 0.75) < 0.01)
        canvas1x.zoomOut()
        #expect(abs(canvas1x.zoom - 0.5) < 0.01)
        canvas1x.zoomOut()
        #expect(abs(canvas1x.zoom - 0.25) < 0.01)

        // 2× Retina capture (800×400 px = 400×200 pt) -> zoom * scale tracks the same clean steps.
        let (canvas2x, _, window2x) = makeCanvasWindow(base: makeBase(width: 800, height: 400), scale: 2, viewSize: CGSize(width: 400, height: 200))
        defer { window2x.close() }
        #expect(abs(canvas2x.zoom * 2 - 1.0) < 0.01)
        canvas2x.zoomIn()
        #expect(abs(canvas2x.zoom * 2 - 1.5) < 0.01)
        canvas2x.zoomOut()
        #expect(abs(canvas2x.zoom * 2 - 1.0) < 0.01)
        canvas2x.zoomOut()
        #expect(abs(canvas2x.zoom * 2 - 0.75) < 0.01)
    }

    @Test func spaceHeldResetsOnFocusLossAndFlagsChanged() throws {
        let (canvas, _, window) = makeCanvasWindow()
        defer { window.close() }

        func holdSpace() throws {
            let down = try #require(NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil,
                characters: " ", charactersIgnoringModifiers: " ", isARepeat: false, keyCode: 49
            ))
            canvas.keyDown(with: down)
            #expect(canvas.isSpaceHeld)
        }

        // Resigning first responder clears space-pan state.
        try holdSpace()
        _ = canvas.resignFirstResponder()
        #expect(!canvas.isSpaceHeld)

        // Window resigning key clears space-pan state.
        try holdSpace()
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
        #expect(!canvas.isSpaceHeld)

        // Flags change outside an active pan drag clears stale space-pan state.
        try holdSpace()
        let flags = try #require(NSEvent.keyEvent(
            with: .flagsChanged, location: .zero, modifierFlags: [.command], timestamp: 0,
            windowNumber: window.windowNumber, context: nil,
            characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 55
        ))
        canvas.flagsChanged(with: flags)
        #expect(!canvas.isSpaceHeld)
    }

    @Test func textAutoWidthResetsOnRightHandleDoubleClickAndInlineUndoStaysSynced() throws {
        let (canvas, session, window) = makeCanvasWindow(base: makeBase(width: 400, height: 200), scale: 1, viewSize: CGSize(width: 400, height: 200))
        defer { window.close() }

        let mark = Annotation(
            shape: .text(TextBlock(origin: CGPoint(x: 40, y: 40), string: "Hello world", fontSize: 18, width: 140)),
            style: Style(color: .red, shadow: false)
        )
        step(session) {
            var doc = session.document
            doc.items = [mark]
            session.commit(doc, selecting: [mark.id], actionName: "Add Text")
        }

        // Double-clicking the right width handle resets `block.width` to nil (auto-fit) undoably.
        let rightHandle = try #require(mark.handles(scale: 1).first { $0.handle == .right }).point
        let clickPoint = canvas.windowPoint(forDocument: rightHandle)
        let doubleClick = try #require(NSEvent.mouseEvent(
            with: .leftMouseDown, location: clickPoint, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 2, pressure: 1
        ))
        step(session) { canvas.mouseDown(with: doubleClick) }
        if case .text(let resetBlock) = session.document.items[0].shape {
            #expect(resetBlock.width == nil)
        } else {
            Issue.record("Expected text mark")
        }
        session.undo()
        if case .text(let restoredBlock) = session.document.items[0].shape {
            #expect(restoredBlock.width == 140)
        } else {
            Issue.record("Expected text mark after undo")
        }

        // Inline text editing Undo keeps document text synced without resurrecting stale text.
        canvas.beginEditing(mark.id, isNew: false)
        let textView = try #require(canvas.subviews.compactMap { $0 as? NSTextView }.first)
        let textUndo = canvas.activeUndoManager
        textUndo.groupsByEvent = false
        textUndo.beginUndoGrouping()
        textView.setSelectedRange(NSRange(location: (textView.string as NSString).length, length: 0))
        textView.insertText("!", replacementRange: NSRange(location: NSNotFound, length: 0))
        textView.breakUndoCoalescing()
        textUndo.endUndoGrouping()
        if case .text(let editedBlock) = session.document.items[0].shape {
            #expect(editedBlock.string == "Hello world!")
        }
        canvas.undo(nil)
        if case .text(let undoneBlock) = session.document.items[0].shape {
            #expect(undoneBlock.string == "Hello world")
        }
        canvas.endEditing()
        if case .text(let finalBlock) = session.document.items[0].shape {
            #expect(finalBlock.string == "Hello world")
        }
    }

    @Test func backdropAdjustmentsTracksNoBackgroundStateAndWatermarkFocus() {
        let session = makeSession()
        let adjustments = BackdropAdjustments(session: session)
        #expect(!adjustments.hasBackdrop)
        #expect(adjustments.focusWatermarkToken == 0 && !adjustments.highlightWatermark)

        step(session) { session.setBackdrop(Backdrop(fill: .color(.blue)), actionName: "Background") }
        adjustments.refresh()
        #expect(adjustments.hasBackdrop)

        adjustments.focusWatermark()
        #expect(adjustments.focusWatermarkToken == 1 && adjustments.highlightWatermark)
        adjustments.finish()

        step(session) { session.setBackdrop(nil, actionName: "Background") }
        adjustments.refresh()
        #expect(!adjustments.hasBackdrop)
    }

    @Test func editorWindowsCascadeAndRefreshDragOutThumbnailAfterEdits() async throws {
        let base = makeBase(width: 200, height: 100)
        let firstURL = URL.temporaryDirectory.appending(path: "oms-cascade-1-\(UUID().uuidString).png")
        let secondURL = URL.temporaryDirectory.appending(path: "oms-cascade-2-\(UUID().uuidString).png")
        let first = AnnotationEditorWindowController(
            image: base, scale: 1, document: nil, title: "First", fileURL: firstURL,
            actions: .init(keep: { _, _, _ in firstURL }, save: { $0 })
        )
        let second = AnnotationEditorWindowController(
            image: base, scale: 1, document: nil, title: "Second", fileURL: secondURL,
            actions: .init(keep: { _, _, _ in secondURL }, save: { $0 })
        )
        defer {
            first.window?.delegate = nil
            second.window?.delegate = nil
            first.close()
            second.close()
        }

        let firstWindow = try #require(first.window)
        let secondWindow = try #require(second.window)
        firstWindow.setFrameOrigin(CGPoint(x: 200, y: 200))
        secondWindow.setFrameOrigin(CGPoint(x: 200, y: 200))
        second.cascade(from: firstWindow)
        #expect(secondWindow.frame.origin != firstWindow.frame.origin)

        // Draw a solid red box covering the whole capture and verify the drag-out thumbnail updates asynchronously.
        let initialThumb = try #require(first.currentThumbnail)
        let cover = Annotation(
            shape: .rectangle(Box(rect: CGRect(x: 0, y: 0, width: 200, height: 100), filled: true)),
            style: Style(color: .red, shadow: false)
        )
        var doc = first.session.document
        doc.items = [cover]
        first.session.commit(doc, actionName: "Cover")

        for _ in 0..<50 where first.currentThumbnail === initialThumb {
            try await Task.sleep(for: .milliseconds(25))
        }
        let updatedThumb = try #require(first.currentThumbnail)
        #expect(updatedThumb !== initialThumb)
        let center = Pixels(updatedThumb)[updatedThumb.width / 2, updatedThumb.height / 2]
        #expect(center.r > 200 && center.g < 80)
    }

    @Test func styleCapsuleLiveColorChangesCoalesceIntoOneUndoStep() {
        let (canvas, session, window) = makeCanvasWindow()
        defer { window.close() }

        let rect = Annotation(shape: .rectangle(Box(rect: CGRect(x: 10, y: 10, width: 40, height: 30))), style: Style(color: .red, shadow: false))
        step(session) {
            var doc = session.document
            doc.items = [rect]
            session.commit(doc, selecting: [rect.id], actionName: "Add")
        }

        let capsule = StyleCapsule()
        capsule.bind(to: session, canvas: canvas, refresh: {})
        step(session) {
            capsule.onBeginLiveChange?()
            capsule.onChange?("Color") { $0.color = .orange }
            capsule.onChange?("Color") { $0.color = .green }
            capsule.onChange?("Color") { $0.color = .blue }
            capsule.onEndLiveChange?("Color")
        }
        #expect(session.document.items[0].style.color == .blue)
        session.undo()
        #expect(session.document.items[0].style.color == .red)
    }

    @Test func selectionLayerRendersDistinctHandleKindsAndRotationKnob() throws {
        let layer = SelectionLayer()
        layer.frame = CGRect(x: 0, y: 0, width: 200, height: 120)
        layer.accent = CGColor(srgbRed: 0, green: 0.48, blue: 1, alpha: 1)
        layer.outlines = [
            SelectionLayer.Outline(
                box: CGRect(x: 30, y: 40, width: 100, height: 50),
                handles: [
                    SelectionLayer.HandleMarker(point: CGPoint(x: 30, y: 40), kind: .corner),
                    SelectionLayer.HandleMarker(point: CGPoint(x: 80, y: 40), kind: .edge),
                    SelectionLayer.HandleMarker(point: CGPoint(x: 40, y: 100), kind: .tail),
                    SelectionLayer.HandleMarker(point: CGPoint(x: 120, y: 100), kind: .arrowHead),
                    SelectionLayer.HandleMarker(point: CGPoint(x: 80, y: 100), kind: .control),
                ],
                knob: (base: CGPoint(x: 80, y: 40), point: CGPoint(x: 80, y: 18))
            ),
        ]
        let context = try #require(CGContext(
            data: nil, width: 200, height: 120, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        // SelectionLayer flips unflipped contexts internally when `!contentsAreFlipped()`.
        layer.draw(in: context)
        let rendered = try #require(context.makeImage())
        let pixels = Pixels(rendered)
        // Arrow head handle is filled with accent blue (not white like tail/corner).
        let headCenter = pixels[120, 100]
        let tailCenter = pixels[40, 100]
        #expect(headCenter.b > 200 && headCenter.r < 60)
        #expect(tailCenter.r > 240 && tailCenter.g > 240 && tailCenter.b > 240)
        // Rotation knob center is drawn cleanly above the box.
        #expect(pixels[80, 18].a > 200)
    }
}
