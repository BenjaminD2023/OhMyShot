import AppKit
import Darwin

public enum MemoryRelief {
    /// Hands freed heap pages back to the system.
    ///
    /// After a window closes, its memory is freed but the allocator keeps the pages, so the app's
    /// footprint stays high until the system is under pressure. Call this once a transient UI is gone.
    public static func returnFreedPages() {
        malloc_zone_pressure_relief(nil, 0)
    }

    /// Lets go of a closed window that the run loop still holds until the next event comes.
    ///
    /// Work done outside an event (a task on the main queue) autoreleases into the pool of the run loop's
    /// wait for the next event, and the application's current event names the window the last event went
    /// to. Both keep a closed window, and everything its views hold, until another event comes, which for
    /// a menu bar app can be a long while. An event of the app's own ends the wait and replaces the current
    /// event. Call this once the window's owner has let it go.
    @MainActor
    public static func endEventWait() {
        guard let event = NSEvent.otherEvent(
            with: .applicationDefined, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, subtype: 0, data1: 0, data2: 0
        ) else { return }
        NSApp.postEvent(event, atStart: false)
    }
}
