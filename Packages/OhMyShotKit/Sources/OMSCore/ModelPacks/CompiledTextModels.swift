import Darwin
import Foundation

/// Whether this process's Neural Engine compilation of Vision's text models is on disk.
///
/// Vision compiles three of the models a reading uses once for each process identity. It keeps them in Core ML's
/// cache in that process's Caches folder (`CompiledModelCache`). When they are missing, the next reading compiles
/// them again: about 37 s, one model after the other (Docs/perf.md › OCR — Vision's first reading after its cache is
/// emptied). Cleaners empty `~/Library/Caches`, and each macOS build starts a new cache. Nothing outside Core ML's
/// private files says which models an entry holds. So a warmup that read both passes leaves a note beside the cache,
/// naming the build it ran on.
public struct CompiledTextModels: Sendable {
    /// The process's own Caches folder, which holds the note and Core ML's cache.
    public let folder: URL
    /// The macOS build (`kern.osversion`, such as 26B118).
    public let build: String

    public init(folder: URL, build: String) {
        self.folder = folder
        self.build = build
    }

    /// For this process. Nil without a bundle identifier or a build.
    public static func current(bundleIdentifier: String? = Bundle.main.bundleIdentifier) -> Self? {
        guard let bundleIdentifier, let build = osBuild() else { return nil }
        return Self(folder: URL.cachesDirectory.appending(path: bundleIdentifier, directoryHint: .isDirectory), build: build)
    }

    var note: URL { folder.appending(path: "Compiled Text Models") }
    var cache: URL { folder.appending(path: CompiledModelCache.name, directoryHint: .isDirectory) }

    /// A warmup read both passes on this build, and Core ML's cache is still there. If the warmup found no cache to
    /// watch, the build alone decides.
    public var isCompiled: Bool {
        guard let text = try? String(contentsOf: note, encoding: .utf8) else { return false }
        let words = text.split(whereSeparator: \.isWhitespace).map(String.init)
        guard words.first == build else { return false }
        return words.contains(Self.uncached) || FileManager.default.fileExists(atPath: cache.path(percentEncoded: false))
    }

    /// Notes that a warmup just read both passes. If Core ML's cache can't be seen (another runtime, or a layout this
    /// doesn't know), the note says so, and only a new build counts the models as gone.
    public func markCompiled() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let cached = FileManager.default.fileExists(atPath: cache.path(percentEncoded: false))
        try Data((cached ? build : "\(build) \(Self.uncached)").utf8).write(to: note, options: .atomic)
    }

    private static let uncached = "uncached"

    static func osBuild() -> String? {
        var size = 0
        guard sysctlbyname("kern.osversion", nil, &size, nil, 0) == 0, size > 1 else { return nil }
        var bytes = [CChar](repeating: 0, count: size)
        guard sysctlbyname("kern.osversion", &bytes, &size, nil, 0) == 0 else { return nil }
        let build = String(decoding: bytes.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        return build.isEmpty ? nil : build
    }
}
