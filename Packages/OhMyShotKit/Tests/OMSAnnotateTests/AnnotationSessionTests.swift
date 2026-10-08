import CoreGraphics
import Foundation
import Testing
@testable import OMSAnnotate

@MainActor
struct AnnotationSessionTests {
    private func makeSession() -> AnnotationSession {
        let session = AnnotationSession(image: makeBase(), scale: 2)
        session.undoManager.groupsByEvent = false
        return session
    }

    /// Commits `change` as one undo group, as an event would.
    private func step(_ session: AnnotationSession, _ change: () -> Void) {
        session.undoManager.beginUndoGrouping()
        change()
        session.undoManager.endUndoGrouping()
    }

    private func rectangle(at x: CGFloat) -> Annotation {
        Annotation(shape: .rectangle(Box(rect: CGRect(x: x, y: 10, width: 20, height: 20))), style: Style())
    }

    @Test func changesUndoAndRedoWithTheirSelection() {
        let session = makeSession()
        let mark = rectangle(at: 10)
        step(session) {
            var document = session.document
            document.items.append(mark)
            session.commit(document, selecting: [mark.id], actionName: "Add Rectangle")
        }
        #expect(session.selection == [mark.id])
        #expect(session.undoManager.undoActionName == "Add Rectangle")
        session.undoManager.undo()
        #expect(session.document.items.isEmpty)
        #expect(session.selection.isEmpty)
        session.undoManager.redo()
        #expect(session.document.items == [mark])
        #expect(session.selection == [mark.id])
    }

    @Test func aDragIsOneUndoStep() {
        let session = makeSession()
        let mark = rectangle(at: 10)
        step(session) {
            var document = session.document
            document.items.append(mark)
            session.commit(document, actionName: "Add Rectangle")
        }
        step(session) {
            session.beginLiveChange()
            for offset in stride(from: 1, through: 30, by: 1) {
                var document = session.document
                document.items[0] = mark.translated(by: CGSize(width: CGFloat(offset), height: 0))
                session.updateLive(document)
            }
            session.endLiveChange(actionName: "Move")
        }
        #expect(session.document.items[0].bounds(scale: 2).minX > mark.bounds(scale: 2).minX + 29)
        session.undoManager.undo()
        #expect(session.document.items == [mark])
    }

    @Test func aCancelledDragLeavesNothingBehind() {
        let session = makeSession()
        session.beginLiveChange()
        var document = session.document
        document.items.append(rectangle(at: 10))
        session.updateLive(document)
        session.cancelLiveChange()
        #expect(session.document.items.isEmpty)
        #expect(!session.undoManager.canUndo)
    }

    @Test func styleChangesApplyToTheSelectionAndTheNextMark() {
        let session = makeSession()
        let mark = rectangle(at: 10)
        step(session) {
            var document = session.document
            document.items.append(mark)
            session.commit(document, selecting: [mark.id], actionName: "Add Rectangle")
        }
        step(session) {
            session.changeSettings("Color") { $0.color = .blue }
        }
        #expect(session.document.items[0].style.color == .blue)
        #expect(session.settings(for: .rectangle).color == .blue)
        // Nothing selected: only the tool in hand changes.
        session.select([])
        session.tool = .arrow
        session.changeSettings("Color") { $0.color = .green }
        #expect(session.document.items[0].style.color == .blue)
        #expect(session.settings(for: .arrow).color == .green)
    }

    @Test func duplicatedCountersTakeTheNextNumber() {
        let session = makeSession()
        let counter = Annotation(shape: .counter(Counter(center: CGPoint(x: 20, y: 20), value: 1)), style: Style())
        step(session) {
            var document = session.document
            document.items.append(counter)
            session.commit(document, selecting: [counter.id], actionName: "Add Counter")
        }
        step(session) { session.duplicateSelection() }
        let values = session.document.items.compactMap { item -> Int? in
            if case .counter(let counter) = item.shape { return counter.value }
            return nil
        }
        #expect(values == [1, 2])
        #expect(session.selection.count == 1 && session.selection[0] != counter.id)
    }

    @Test func nudgesMoveByPointsOfTheCapturedScreen() {
        let session = makeSession()
        let mark = rectangle(at: 10)
        step(session) {
            var document = session.document
            document.items.append(mark)
            session.commit(document, selecting: [mark.id], actionName: "Add Rectangle")
        }
        step(session) { session.nudgeSelection(by: CGSize(width: 10, height: 0)) }
        // 10 points at 2× is 20 pixels.
        #expect(session.document.items[0].bounds(scale: 2).minX - mark.bounds(scale: 2).minX == 20)
    }

    @Test func croppingIsUndoable() {
        let session = makeSession()
        step(session) { session.crop(to: CGRect(x: 10, y: 10, width: 50, height: 40)) }
        #expect(session.document.canvas == CGRect(x: 10, y: 10, width: 50, height: 40))
        session.undoManager.undo()
        #expect(session.document.canvas == session.document.imageBounds)
    }

    @Test func keptStateFollowsChanges() {
        let session = makeSession()
        #expect(!session.hasUnkeptChanges)
        step(session) {
            var document = session.document
            document.items.append(rectangle(at: 10))
            session.commit(document, actionName: "Add")
        }
        #expect(session.hasUnkeptChanges)
        session.markKept()
        #expect(!session.hasUnkeptChanges)
    }

    @Test func restylingDuringAnEditIsPartOfThatEdit() {
        let session = makeSession()
        let text = Annotation(shape: .text(TextBlock(origin: .zero, string: "Hi")), style: Style(color: .red))
        step(session) {
            var document = session.document
            document.items.append(text)
            session.commit(document, selecting: [text.id], actionName: "Add Text")
        }
        step(session) {
            session.beginLiveChange()
            session.changeSettings("Color") { $0.color = .blue }
            session.endLiveChange(actionName: "Edit Text")
        }
        #expect(session.document.items[0].style.color == .blue)
        #expect(session.undoManager.undoActionName == "Edit Text")
        session.undoManager.undo()
        #expect(session.document.items[0].style.color == .red)
    }

    @Test func undoStateIsAnnouncedWithEveryChange() {
        // The toolbar's Undo and Redo follow these events; the undo manager's own group notifications
        // arrive only when a group closes, which may be long after the change.
        let session = makeSession()
        var histories = 0
        session.observe { event in if event == .history { histories += 1 } }
        step(session) {
            var document = session.document
            document.items.append(rectangle(at: 10))
            session.commit(document, actionName: "Add Rectangle")
        }
        #expect(histories == 1)
        #expect(session.undoManager.canUndo)
        session.undo()
        #expect(histories >= 2)
        #expect(session.document.items.isEmpty)
        #expect(session.undoManager.canRedo)
        session.redo()
        #expect(session.document.items.count == 1)
    }
}
