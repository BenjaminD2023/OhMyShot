import AppKit
import CoreGraphics
import Foundation
import Testing
@testable import OMSAnnotate

@MainActor
@Suite(.serialized)
struct RedactionSuggestionTests {
    private static let email = RedactionSuggestion(rect: CGRect(x: 100, y: 20, width: 200, height: 30), label: "Email address")
    private static let phone = RedactionSuggestion(rect: CGRect(x: 100, y: 80, width: 180, height: 30), label: "Phone number")

    /// A session whose capture reads as holding an email address and a phone number, counting each read;
    /// each read takes `delay`.
    private func makeSession(reads: ReadCounter, delay: Duration = .zero) -> AnnotationSession {
        let found = [Self.email, Self.phone]
        let context = CGContext(
            data: nil, width: 400, height: 200, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 400, height: 200))
        let session = AnnotationSession(image: context.makeImage()!, scale: 1, tool: .arrow)
        session.undoManager.groupsByEvent = false
        session.textReader = { _ in
            CaptureReading(redactionSuggestions: {
                await reads.increment()
                if delay > .zero { try? await Task.sleep(for: delay) }
                return found
            })
        }
        return session
    }

    private func waitForSuggestions(_ session: AnnotationSession) async {
        for _ in 0..<100 where session.isFindingRedactions || session.redactionSuggestions.isEmpty {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    /// The canvas on `session`, filling an unshown window (hit queries and accessibility frames need one).
    private func makeCanvas(_ session: AnnotationSession) -> (canvas: AnnotationCanvasView, window: NSWindow) {
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 400, height: 200), styleMask: [.borderless], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let canvas = AnnotationCanvasView(session: session)
        canvas.contentInsets = NSEdgeInsetsZero
        canvas.frame = window.contentView!.bounds
        window.contentView!.addSubview(canvas)
        canvas.layoutSubtreeIfNeeded()
        return (canvas, window)
    }

    private func step(_ session: AnnotationSession, _ change: () -> Void) {
        session.undoManager.beginUndoGrouping()
        change()
        session.undoManager.endUndoGrouping()
    }

    @Test func theCaptureIsReadOnceTheRedactionToolIsInHand() async {
        let reads = ReadCounter()
        let session = makeSession(reads: reads)
        #expect(session.redactionSuggestions.isEmpty)
        session.tool = .redact
        await waitForSuggestions(session)
        #expect(session.openRedactionSuggestions == [Self.email, Self.phone])
        session.tool = .arrow
        session.tool = .redact
        try? await Task.sleep(for: .milliseconds(30))
        #expect(await reads.value == 1)
    }

    @Test func aClickCoversOneAndUndoBringsItBack() async {
        let session = makeSession(reads: ReadCounter())
        session.tool = .redact
        await waitForSuggestions(session)
        step(session) { #expect(session.acceptRedactionSuggestion(at: CGPoint(x: 150, y: 35))) }
        guard case .redaction(let redaction) = session.document.items.first?.shape else {
            Issue.record("no redaction")
            return
        }
        // A little larger than the text, so its anti-aliased edges are covered too.
        #expect(redaction.rect.contains(Self.email.rect))
        #expect(redaction.method == session.settings(for: .redact).redaction)
        #expect(session.openRedactionSuggestions == [Self.phone])
        // Nowhere near a suggestion: nothing.
        #expect(!session.acceptRedactionSuggestion(at: CGPoint(x: 10, y: 190)))
        session.undoManager.undo()
        #expect(session.document.items.isEmpty)
        #expect(session.openRedactionSuggestions == [Self.email, Self.phone])
    }

    @Test func redactAllIsOneStep() async {
        let session = makeSession(reads: ReadCounter())
        session.tool = .redact
        await waitForSuggestions(session)
        step(session) { session.acceptAllRedactionSuggestions() }
        #expect(session.document.items.count == 2)
        #expect(session.openRedactionSuggestions.isEmpty)
        #expect(session.undoManager.undoActionName == "Redact All")
        session.undoManager.undo()
        #expect(session.document.items.isEmpty)
    }

    @Test func aSuggestionCoveredByHandIsNotOffered() async {
        let session = makeSession(reads: ReadCounter())
        session.tool = .redact
        await waitForSuggestions(session)
        step(session) {
            var document = session.document
            document.items.append(Annotation(shape: .redaction(Redaction(rect: CGRect(x: 90, y: 70, width: 210, height: 50))), style: Style()))
            session.commit(document, actionName: "Add Redaction")
        }
        #expect(session.openRedactionSuggestions == [Self.email])
    }

    @Test func aSuggestionCroppedAwayIsNotOffered() async {
        let session = makeSession(reads: ReadCounter())
        session.tool = .redact
        await waitForSuggestions(session)
        step(session) {
            var document = session.document
            document.canvas = CGRect(x: 0, y: 60, width: 400, height: 140)
            session.commit(document, actionName: "Crop")
        }
        #expect(session.openRedactionSuggestions == [Self.phone])
        // Redact All covers only what is left to see.
        step(session) { session.acceptAllRedactionSuggestions() }
        #expect(session.document.items.count == 1)
    }
}

extension RedactionSuggestionTests {
    @Test func aSuggestionPartlyCroppedIsCoveredOnlyWithinTheCrop() async {
        let session = makeSession(reads: ReadCounter())
        session.tool = .redact
        await waitForSuggestions(session)
        step(session) {
            var document = session.document
            document.canvas = CGRect(x: 0, y: 0, width: 200, height: 200)
            session.commit(document, actionName: "Crop")
        }
        #expect(session.openRedactionSuggestions.count == 2)
        step(session) { session.acceptAllRedactionSuggestions() }
        for item in session.document.items {
            guard case .redaction(let redaction) = item.shape else { continue }
            #expect(redaction.rect.maxX <= 200, "\(redaction.rect)")
        }
        // What the crop keeps of them is covered.
        #expect(session.openRedactionSuggestions.isEmpty)
    }

    @Test func aReadingDroppedMidwayReadsAgainTheNextTime() async {
        let reads = ReadCounter()
        let session = makeSession(reads: reads, delay: .milliseconds(150))
        session.tool = .redact
        #expect(session.isFindingRedactions)
        session.cancelReading()
        #expect(!session.isFindingRedactions)
        try? await Task.sleep(for: .milliseconds(250))
        // The dropped reading never lands.
        #expect(session.redactionSuggestions.isEmpty)
        session.tool = .arrow
        session.tool = .redact
        await waitForSuggestions(session)
        #expect(session.openRedactionSuggestions == [Self.email, Self.phone])
        #expect(await reads.value == 2)
    }

    @Test func aCanvasLeavingItsWindowDropsTheReading() async {
        let session = makeSession(reads: ReadCounter(), delay: .milliseconds(150))
        let (canvas, window) = makeCanvas(session)
        defer { window.close() }
        session.tool = .redact
        #expect(session.isFindingRedactions)
        canvas.removeFromSuperview()
        #expect(!session.isFindingRedactions)
    }

    @Test func aSuggestionsHelpTagNamesItsKindAndWhatAClickDoes() async {
        let session = makeSession(reads: ReadCounter())
        let (canvas, window) = makeCanvas(session)
        defer { window.close() }
        session.tool = .redact
        await waitForSuggestions(session)
        // AppKit asks the owner through Objective-C; without the protocol it shows the view's description.
        #expect(canvas.responds(to: #selector(NSViewToolTipOwner.view(_:stringForToolTip:point:userData:))))
        let point = canvas.convert(canvas.windowPoint(forDocument: CGPoint(x: 150, y: 35)), from: nil)
        #expect(canvas.view(canvas, stringForToolTip: 0, point: point, userData: nil) == "Email address\nClick to redact")
    }

    @Test func voiceOverFindsEachSuggestionAsAButtonThatCoversIt() async throws {
        let session = makeSession(reads: ReadCounter())
        let (canvas, window) = makeCanvas(session)
        defer { window.close() }
        session.tool = .redact
        await waitForSuggestions(session)
        let buttons = (canvas.accessibilityChildren() ?? []).compactMap { $0 as? SuggestionElement }
        #expect(buttons.map { $0.accessibilityLabel() } == ["Email address, suggested redaction", "Phone number, suggested redaction"])
        #expect(buttons.allSatisfy { $0.accessibilityRole() == .button })
        #expect(canvas.accessibilityLabel()?.contains("2 suggestions to redact") == true)
        // Each sits where its outline is, on the screen.
        let frame = try #require(buttons.first).accessibilityFrame()
        #expect(frame.width > 0 && frame.height > 0)
        var pressed = false
        step(session) { pressed = buttons.last?.accessibilityPerformPress() ?? false }
        #expect(pressed)
        #expect(session.openRedactionSuggestions == [Self.email])
        #expect((canvas.accessibilityChildren() ?? []).compactMap { $0 as? SuggestionElement }.count == 1)
    }
}

/// Counts calls from any task.
actor ReadCounter {
    private(set) var value = 0
    func increment() { value += 1 }
}
