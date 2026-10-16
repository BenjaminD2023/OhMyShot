import Foundation

/// User defaults made for one test, kept in a folder of their own in the temporary items and removed when
/// the test ends. A suite named by a plain name leaves a preferences file behind, even emptied; one named
/// by a path does not touch the preferences folder at all. A test suite holds one as a stored property:
/// Swift Testing makes a suite value for each test and lets it go when the test is done.
nonisolated final class ScratchDefaults: @unchecked Sendable {
    private let directory = URL.temporaryDirectory.appending(path: "OhMyShotKit Defaults \(UUID().uuidString)", directoryHint: .isDirectory)
    private let lock = NSLock()
    private var count = 0

    /// Defaults of their own, with nothing in them.
    func make() -> UserDefaults {
        let number = lock.withLock {
            count += 1
            return count
        }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return UserDefaults(suiteName: directory.appending(path: "defaults \(number)").path(percentEncoded: false))!
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }
}
