import Darwin

/// Memory taken straight from the system in whole pages, and given back the moment it is let go.
///
/// The allocator keeps the large blocks it frees for reuse, dirty: a few frame-sized buffers freed after
/// making a GIF stayed in the app's footprint, some 30 MB of it, until the app quit, and pressure relief does
/// not return them. Big buffers that live for one task (frames, a stitched picture) come from here instead.
/// The pages start zeroed. In debug builds a page nobody may touch stands on each side, so a write past
/// either end stops the app where it happens.
public final class PageBuffer: @unchecked Sendable {
    public let baseAddress: UnsafeMutableRawPointer
    public let byteCount: Int
    /// What was mapped, guard pages and all.
    private let mapping: UnsafeMutableRawPointer
    private let mappedBytes: Int

    /// Nil when the system has no room for `byteCount` bytes.
    public init?(byteCount: Int) {
        let size = max(byteCount, 1)
        #if DEBUG
        let page = Int(getpagesize())
        let rounded = (size + page - 1) / page * page
        let total = rounded + 2 * page
        #else
        let total = size
        #endif
        guard let pointer = mmap(nil, total, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0), pointer != MAP_FAILED else {
            return nil
        }
        mapping = pointer
        mappedBytes = total
        #if DEBUG
        mprotect(pointer, page, PROT_NONE)
        mprotect(pointer + page + rounded, page, PROT_NONE)
        // The buffer ends where the guard page after it begins, give or take its 64-byte alignment.
        baseAddress = pointer + page + ((rounded - size) & ~63)
        #else
        baseAddress = pointer
        #endif
        self.byteCount = size
    }

    deinit {
        munmap(mapping, mappedBytes)
    }

    /// The buffer as `count` values of `type`.
    public func bound<T>(to type: T.Type, count: Int) -> UnsafeMutablePointer<T> {
        baseAddress.bindMemory(to: type, capacity: count)
    }
}
