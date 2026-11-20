import Testing
@testable import OMSAnnotate

struct EditorCloseRecoveryTests {
    @Test func keepingAnEditorOpenCancelsQuitWithoutStartingShutdown() async {
        var events: [String] = []
        let allowed = await withCheckedContinuation { reply in
            let deferred = EditorQuitGate.deferQuit {
                events.append("ask editors")
                return false
            } finishWork: { _ in
                events.append("start shutdown")
                return false
            } reply: {
                events.append("reply")
                reply.resume(returning: $0)
            }
            #expect(deferred)
        }
        #expect(!allowed)
        #expect(events == ["ask editors", "reply"])
    }

    @Test(arguments: [true, false]) func allowingQuitWaitsForShutdownAndForwardsItsResult(workSucceeded: Bool) async {
        var events: [String] = []
        let allowed = await withCheckedContinuation { reply in
            let deferred = EditorQuitGate.deferQuit {
                events.append("ask editors")
                return true
            } finishWork: { finished in
                events.append("start shutdown")
                Task {
                    events.append("finish shutdown")
                    finished(workSucceeded)
                }
                return true
            } reply: {
                events.append("reply")
                reply.resume(returning: $0)
            }
            #expect(deferred)
        }
        #expect(allowed == workSucceeded)
        #expect(events == ["ask editors", "start shutdown", "finish shutdown", "reply"])
    }

    @Test func allowingQuitWithNothingToDrainRepliesYes() async {
        let allowed = await withCheckedContinuation { reply in
            let deferred = EditorQuitGate.deferQuit(closeEditors: { true }, finishWork: { _ in false }, reply: { reply.resume(returning: $0) })
            #expect(deferred)
        }
        #expect(allowed)
    }

    @Test func noEditorsAndNothingToDrainAllowsImmediateQuit() {
        let deferred = EditorQuitGate.deferQuit(closeEditors: nil, finishWork: { _ in false }, reply: { _ in Issue.record("Unexpected deferred reply") })
        #expect(!deferred)
    }

    @Test func retryKeepsTheCurrentEditsBeforeClosing() async {
        var keeps = 0
        var prompts = 0
        let closed = await EditorCloseRecovery.mayClose {
            keeps += 1
            return keeps == 1 ? .failed : keeps == 2 ? .changedWhileKeeping : .kept
        } choose: {
            prompts += 1
            return .retry
        } saveProject: {
            Issue.record("Unexpected project save")
            return false
        }
        #expect(closed)
        #expect(keeps == 3)
        #expect(prompts == 1)
    }

    @Test(arguments: [false, true]) func recoveryProjectMustActuallyBeSaved(saved: Bool) async {
        var saves = 0
        let closed = await EditorCloseRecovery.mayClose { .failed } choose: { .saveProject } saveProject: {
            saves += 1
            return saved
        }
        #expect(closed == saved)
        #expect(saves == 1)
    }

    @Test(arguments: [false, true]) func onlyAnExplicitDiscardCanSkipSaving(discard: Bool) async {
        let closed = await EditorCloseRecovery.mayClose { .failed } choose: {
            discard ? .discard : .keepEditing
        } saveProject: {
            Issue.record("Unexpected project save")
            return false
        }
        #expect(closed == discard)
    }
}
