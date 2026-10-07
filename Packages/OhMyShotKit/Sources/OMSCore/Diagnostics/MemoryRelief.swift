import Darwin

public enum MemoryRelief {
    /// Hands freed heap pages back to the system.
    ///
    /// After a window closes, its memory is freed but the allocator keeps the pages, so the app's
    /// footprint stays high until the system is under pressure. Call this once a transient UI is gone.
    public static func returnFreedPages() {
        malloc_zone_pressure_relief(nil, 0)
    }
}
