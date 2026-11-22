import Foundation
import OMSCore

actor AsyncSaveOutcomeGate {
    private var continuation: CheckedContinuation<SaveOutcome, Never>?
    private var pendingOutcome: SaveOutcome?

    func wait() async -> SaveOutcome {
        if let pendingOutcome {
            self.pendingOutcome = nil
            return pendingOutcome
        }
        return await withCheckedContinuation { continuation = $0 }
    }

    func complete(_ outcome: SaveOutcome) {
        if let continuation {
            self.continuation = nil
            continuation.resume(returning: outcome)
        } else {
            pendingOutcome = outcome
        }
    }
}

actor AsyncEventReader<Element: Sendable> {
    private var events: [Element] = []
    private var waiters: [UUID: CheckedContinuation<Element?, Never>] = [:]
    private var finished = false

    init(_ stream: AsyncStream<Element>) {
        Task { [weak self] in
            for await event in stream {
                await self?.receive(event)
            }
            await self?.finish()
        }
    }

    func next() async -> Element? {
        if !events.isEmpty { return events.removeFirst() }
        guard !finished else { return nil }
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(returning: nil)
                } else {
                    waiters[id] = continuation
                }
            }
        } onCancel: {
            Task { await self.cancel(id) }
        }
    }

    private func receive(_ event: Element) {
        if let (id, waiter) = waiters.first {
            waiters[id] = nil
            waiter.resume(returning: event)
        } else {
            events.append(event)
        }
    }

    private func finish() {
        finished = true
        let waiting = waiters.values
        waiters.removeAll()
        waiting.forEach { $0.resume(returning: nil) }
    }

    private func cancel(_ id: UUID) {
        waiters.removeValue(forKey: id)?.resume(returning: nil)
    }
}

func waitForEvent<Element: Sendable>(from reader: AsyncEventReader<Element>, timeout: Duration = .seconds(3)) async -> Element? {
    await withTaskGroup(of: Element?.self) { group in
        group.addTask { await reader.next() }
        group.addTask {
            try? await Task.sleep(for: timeout)
            return nil
        }
        let event = await group.next() ?? nil
        group.cancelAll()
        return event
    }
}
