import OMSCore

extension MemoryRelief {
    /// A window controller's `onClose`: `release` lets go of the window on the next turn, never inside the window's own
    /// close, where it would be deallocated inside its own delegate call; then the pages it freed go back to the system.
    static func releasingOnNextTurn(_ release: @escaping @MainActor () async -> Void) -> () -> Void {
        {
            Task { @MainActor in
                await release()
                returnFreedPages()
            }
        }
    }
}
