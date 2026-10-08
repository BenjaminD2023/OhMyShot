/// Vision can stall, without an error, when more than two accurate text requests run at once in a process
/// (Docs/ocr.md). A recognition now runs two models side by side, and the OCR panel and Capture Text can
/// overlap, so every accurate request the pipeline makes holds one of two slots; a third waits its turn.
actor RecognitionSlots {
    static let shared = RecognitionSlots(count: 2)

    private var free: Int
    private var waiting: [CheckedContinuation<Void, Never>] = []

    init(count: Int) {
        free = count
    }

    /// Runs `operation` in a slot, waiting for one if both are taken.
    nonisolated func run<T>(_ operation: () async throws -> T) async throws -> T {
        await acquire()
        do {
            let value = try await operation()
            await release()
            return value
        } catch {
            await release()
            throw error
        }
    }

    private func acquire() async {
        if free > 0 {
            free -= 1
        } else {
            await withCheckedContinuation { waiting.append($0) }
        }
    }

    private func release() {
        if waiting.isEmpty {
            free += 1
        } else {
            waiting.removeFirst().resume()
        }
    }
}
