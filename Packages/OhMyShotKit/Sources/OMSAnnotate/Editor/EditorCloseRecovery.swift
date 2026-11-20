enum EditorCloseRecovery {
    enum KeepResult {
        case kept, changedWhileKeeping, failed
    }

    enum Choice {
        case retry, saveProject, discard, keepEditing
    }

    static func mayClose(
        keep: () async -> KeepResult,
        choose: () async -> Choice,
        saveProject: () async -> Bool
    ) async -> Bool {
        while true {
            switch await keep() {
            case .kept: return true
            case .changedWhileKeeping: continue
            case .failed:
                switch await choose() {
                case .retry: continue
                case .saveProject: return await saveProject()
                case .discard: return true
                case .keepEditing: return false
                }
            }
        }
    }
}

public enum EditorQuitGate {
    public static func deferQuit(
        closeEditors: (() async -> Bool)?,
        finishWork: @escaping (@escaping (Bool) -> Void) -> Bool,
        reply: @escaping (Bool) -> Void
    ) -> Bool {
        guard let closeEditors else { return finishWork(reply) }
        Task {
            guard await closeEditors() else { return reply(false) }
            if !finishWork(reply) { reply(true) }
        }
        return true
    }
}
