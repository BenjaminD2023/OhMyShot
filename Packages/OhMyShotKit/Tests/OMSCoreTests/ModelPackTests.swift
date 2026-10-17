import CryptoKit
import Foundation
import Synchronization
import Testing
@testable import OMSCore

/// Serves a test's files from its own host name: whole, or from a `Range`, cut off, slowly, or wrong.
final class PackStubProtocol: URLProtocol, @unchecked Sendable {
    struct Behavior: Sendable {
        var files: [String: Data] = [:]
        /// Answers every request with this status and no body.
        var status: Int?
        /// Sends the whole file with 200 whatever the request asks.
        var ignoresRange = false
        /// The first this many requests for a file whose path ends so send only this many bytes, then the
        /// connection drops.
        var cutsOff: (path: String, requests: Int, after: Int)?
        /// Sends these bytes in place of the file's.
        var corrupt = false
        /// Waits this long between chunks of 1000 bytes.
        var chunkDelay: Duration?
        /// Sends no more than this many bytes of a file until `release(host:)`, so a test sees a download under way.
        var holdsAfter: Int?
    }

    struct Seen: Sendable {
        var path: String
        var range: String?
    }

    private static let behaviors = Mutex<[String: Behavior]>([:])
    private static let held = Mutex<Set<String>>([])
    private static let log = Mutex<[String: [Seen]]>([:])
    private let stopped = Atomic<Bool>(false)
    private var streaming: Timer?

    static func install(host: String, _ behavior: Behavior) {
        behaviors.withLock { $0[host] = behavior }
        held.withLock { if behavior.holdsAfter != nil { $0.insert(host) } else { $0.remove(host) } }
        log.withLock { $0[host] = [] }
    }

    static func change(host: String, _ change: (inout Behavior) -> Void) {
        behaviors.withLock { all in if var behavior = all[host] { change(&behavior); all[host] = behavior } }
    }

    static func requests(host: String) -> [Seen] { log.withLock { $0[host] ?? [] } }

    static func release(host: String) { _ = held.withLock { $0.remove(host) } }

    static func configuration() -> URLSessionConfiguration {
        let configuration = ModelPackDownloader.defaultConfiguration()
        configuration.protocolClasses = [PackStubProtocol.self]
        return configuration
    }

    override class func canInit(with request: URLRequest) -> Bool { behaviors.withLock { $0[request.url?.host() ?? ""] != nil } }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let url = request.url!, host = url.host() ?? ""
        let range = request.value(forHTTPHeaderField: "Range")
        let path = url.path(percentEncoded: false)
        let index: Int = Self.log.withLock { log in
            log[host, default: []].append(Seen(path: path, range: range))
            return log[host]!.filter { $0.path == path }.count
        }
        guard let behavior = Self.behaviors.withLock({ $0[host] }) else { return }
        if let status = behavior.status {
            respond(status: status, headers: [:], body: Data(), cutAfter: nil, delay: nil)
            return
        }
        let name = String(path.dropFirst())
        guard var file = behavior.files[name] else {
            respond(status: 404, headers: [:], body: Data(), cutAfter: nil, delay: nil)
            return
        }
        if behavior.corrupt { file = Data(file.map { $0 ^ 0x5A }) }
        let cut = behavior.cutsOff.flatMap { path.hasSuffix($0.path) && index <= $0.requests ? $0.after : nil }
        if let range, !behavior.ignoresRange, range.hasPrefix("bytes="), let start = Int(range.dropFirst(6).prefix { $0 != "-" }) {
            guard start < file.count else {
                respond(status: 416, headers: ["Content-Range": "bytes */\(file.count)"], body: Data(), cutAfter: nil, delay: nil)
                return
            }
            let body = file.subdata(in: start ..< file.count)
            respond(status: 206, headers: ["Content-Range": "bytes \(start)-\(file.count - 1)/\(file.count)", "Content-Length": "\(body.count)"], body: body, cutAfter: cut, delay: behavior.chunkDelay)
        } else {
            respond(status: 200, headers: ["Content-Length": "\(file.count)"], body: file, cutAfter: cut, delay: behavior.chunkDelay)
        }
    }

    private func respond(status: Int, headers: [String: String], body: Data, cutAfter: Int?, delay: Duration?) {
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        let sent = cutAfter.map { min($0, body.count) } ?? body.count
        guard let delay else {
            client?.urlProtocol(self, didLoad: body.prefix(sent))
            guard cutAfter != nil else { return finish(cut: false) }
            // A connection drops after what it sent has arrived, as one over a network does.
            let drop = Timer(timeInterval: 0.05, repeats: false) { [weak self] _ in self?.finish(cut: true) }
            RunLoop.current.add(drop, forMode: .common)
            streaming = drop
            return
        }
        // Chunks on a timer of the loading thread's run loop, where URL loading wants its client told things.
        var offset = 0
        let interval = Double(delay.components.seconds) + Double(delay.components.attoseconds) / 1e18
        let host = request.url?.host() ?? "", holdsAfter = Self.behaviors.withLock { $0[host]?.holdsAfter }
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] timer in
            guard let self, !stopped.load(ordering: .relaxed) else { return timer.invalidate() }
            if let holdsAfter, offset >= holdsAfter, Self.held.withLock({ $0.contains(host) }) { return }
            let end = min(offset + 1000, sent)
            client?.urlProtocol(self, didLoad: body.subdata(in: offset ..< end))
            offset = end
            if offset >= sent {
                timer.invalidate()
                finish(cut: cutAfter != nil)
            }
        }
        RunLoop.current.add(timer, forMode: .common)
        streaming = timer
    }

    private func finish(cut: Bool) {
        if cut {
            client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
        } else {
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {
        stopped.store(true, ordering: .relaxed)
        streaming?.invalidate()
    }
}

struct ModelPackTests {
    private struct Rig {
        let store: ModelPackStore
        let downloader: ModelPackDownloader
        let resources: ActiveResources
        let files: [String: Data]

        /// `files` with the license every pack carries.
        func licensed(_ files: [String: Data]) -> [String: Data] {
            files.merging(["LICENSE.txt": self.files["LICENSE.txt"]!]) { kept, _ in kept }
        }
    }

    private static func bytes(_ count: Int, seed: UInt8) -> Data {
        Data((0 ..< count).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ Int(seed)) })
    }

    private static func sha(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func rig(space: Int64? = nil) throws -> Rig {
        let root = FileManager.default.temporaryDirectory.appending(path: "OMSModelPackTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = ModelPackStore(root: root)
        let resources = ActiveResources()
        let downloader = ModelPackDownloader(
            store: store, resources: resources, sessionConfiguration: PackStubProtocol.configuration,
            availableSpace: { _ in space ?? 1 << 40 }
        )
        let files = [
            "LICENSE.txt": Data("Apache License 2.0, and what was changed.".utf8),
            "det.mlpackage/Data/weights/weight.bin": Self.bytes(10_000, seed: 3),
            "rec/model 1.bin": Self.bytes(4321, seed: 9),
        ]
        return Rig(store: store, downloader: downloader, resources: resources, files: files)
    }

    private func pack(hosts: [String], files: [String: Data], version: String = "1", id: String = "test-pack") -> ModelPack {
        ModelPack(
            id: id, version: version, name: "Test", summary: "For tests.",
            license: .init(name: "Apache-2.0", file: "LICENSE.txt", url: URL(string: "https://www.apache.org/licenses/LICENSE-2.0")!),
            original: URL(string: "https://huggingface.co/PaddlePaddle")!, host: "Test Host",
            mirrors: hosts.map { URL(string: "https://\($0)/org/repo/resolve/abc123/")! },
            files: files.keys.sorted().map { ModelPack.File(path: $0, size: Int64(files[$0]!.count), sha256: Self.sha(files[$0]!)) }
        )
    }

    // MARK: Listing

    @Test func aListingWithAWayOutOfItsFolderIsRefused() {
        let file = ModelPack.File(path: "a.bin", size: 1, sha256: String(repeating: "a", count: 64))
        func listing(_ files: [ModelPack.File], mirror: String = "https://h.test/x/", license: String = "a.bin") -> ModelPack {
            ModelPack(
                id: "p", version: "1", name: "P", summary: "", license: .init(name: "MIT", file: license, url: URL(string: "https://x.test")!),
                original: URL(string: "https://x.test")!, host: "H", mirrors: [URL(string: mirror)!], files: files
            )
        }
        #expect(listing([file]).problem == nil)
        for path in ["/etc/passwd", "../a.bin", "x/../../a.bin", "x//a.bin", "./a.bin", "~/a.bin", ""] {
            #expect(listing([ModelPack.File(path: path, size: 1, sha256: file.sha256), file]).problem != nil, "\(path)")
        }
        #expect(listing([file, file]).problem != nil)
        #expect(listing([ModelPack.File(path: "a.bin", size: 1, sha256: String(repeating: "A", count: 64))]).problem != nil)
        #expect(listing([ModelPack.File(path: "a.bin", size: 0, sha256: file.sha256)]).problem != nil)
        #expect(listing([file], mirror: "http://h.test/x/").problem != nil)
        #expect(listing([file], mirror: "https://h.test/x").problem != nil)
        #expect(listing([file], license: "LICENSE").problem != nil)
    }

    @Test func everyPackTheBuildOffersIsUsable() {
        for pack in ModelPackCatalog.packs + [ModelPackCatalog.ppocrV6Small] {
            #expect(pack.problem == nil, "\(pack.id): \(pack.problem ?? "")")
            #expect(pack.mirrors.first?.host() == "huggingface.co", "\(pack.id) comes from Hugging Face first")
        }
        #expect(Set(ModelPackCatalog.packs.map(\.id)).count == ModelPackCatalog.packs.count)
    }

    @Test func theL2PackIsTheOneUploaded() {
        let pack = ModelPackCatalog.ppocrV6Small
        // Every mirror names a fixed revision, so a file never changes under its address.
        #expect(pack.mirrors.allSatisfy { $0.absoluteString.contains("/resolve/f163489663ba2ef788f3389c61d21c7308cc554d/") })
        #expect(pack.files.count == 10)
        #expect(pack.size == 15_829_675)
        #expect(Set(["det.mlpackage/Manifest.json", "rec.mlpackage/Manifest.json", "characters.txt", "config.json"]).isSubset(of: pack.files.map(\.path)))
    }

    @Test func aFileIsFetchedByItsPathUnderTheMirror() {
        let pack = pack(hosts: ["h.test"], files: ["rec/model 1.bin": Data([1])])
        #expect(pack.url(of: pack.files[0], at: pack.mirrors[0]).absoluteString == "https://h.test/org/repo/resolve/abc123/rec/model%201.bin")
    }

    // MARK: Downloading

    @Test func aPackComesDownChecksOutAndIsInstalled() async throws {
        let rig = try rig()
        let host = "packs-whole.test"
        PackStubProtocol.install(host: host, .init(files: rig.files.mapKeys { "org/repo/resolve/abc123/\($0)" }))
        let pack = pack(hosts: [host], files: rig.files)
        let reports = Mutex<[Int64]>([])
        let receipt = try await rig.downloader.download(pack) { done in reports.withLock { $0.append(done) } }

        #expect(receipt.size == pack.size)
        #expect(rig.store.receipt(of: pack) == receipt)
        for file in pack.files {
            #expect(try Data(contentsOf: rig.store.url(of: file, in: pack)) == rig.files[file.path])
        }
        #expect(!FileManager.default.fileExists(atPath: rig.store.downloadFolder(of: pack).path(percentEncoded: false)))
        let seen = reports.withLock { $0 }
        #expect(seen.last == pack.size)
        #expect(seen.count <= 105)
        #expect(PackStubProtocol.requests(host: host).allSatisfy { $0.range == nil })
        #expect(rig.resources.isIdle)
    }

    @Test func aDownloadCutOffGoesOnFromWhereItStopped() async throws {
        let rig = try rig()
        let host = "packs-cut.test"
        let big = "det.mlpackage/Data/weights/weight.bin"
        let files = rig.licensed([big: rig.files[big]!])
        PackStubProtocol.install(host: host, .init(files: files.mapKeys { "org/repo/resolve/abc123/\($0)" }, cutsOff: (path: big, requests: 1, after: 3000)))
        let pack = pack(hosts: [host], files: files)

        await #expect(throws: ModelPackError.self) { try await rig.downloader.download(pack) }
        let license = Int64(files["LICENSE.txt"]!.count)
        #expect(rig.store.downloaded(pack) == license + 3000)
        #expect(rig.resources.isIdle)

        _ = try await rig.downloader.download(pack)
        let seen = PackStubProtocol.requests(host: host).filter { $0.path.hasSuffix(big) }
        #expect(seen.map(\.range) == [nil, "bytes=3000-"])
        #expect(try Data(contentsOf: rig.store.url(of: pack.file(big), in: pack)) == files[big])
    }

    @Test func aServerThatIgnoresTheRangeHasTheFileStartedOver() async throws {
        let rig = try rig()
        let host = "packs-norange.test"
        let path = "rec/model 1.bin"
        let files = rig.licensed([path: rig.files[path]!])
        PackStubProtocol.install(host: host, .init(files: files.mapKeys { "org/repo/resolve/abc123/\($0)" }, ignoresRange: true))
        let pack = pack(hosts: [host], files: files)
        let partial = try leavePartial(of: pack, path, rig: rig, bytes: files[path]!.prefix(1000))

        _ = try await rig.downloader.download(pack)
        #expect(PackStubProtocol.requests(host: host).filter { $0.path.hasSuffix(path) }.map(\.range) == ["bytes=1000-"])
        #expect(try Data(contentsOf: rig.store.url(of: pack.file(path), in: pack)) == files[path])
        #expect(!FileManager.default.fileExists(atPath: partial.path(percentEncoded: false)))
    }

    @Test func aPartialFileThatIsWrongIsCaughtAndFetchedAgain() async throws {
        let rig = try rig()
        let host = "packs-wrongpart.test"
        let path = "rec/model 1.bin"
        let files = rig.licensed([path: rig.files[path]!])
        PackStubProtocol.install(host: host, .init(files: files.mapKeys { "org/repo/resolve/abc123/\($0)" }))
        let pack = pack(hosts: [host], files: files)
        _ = try leavePartial(of: pack, path, rig: rig, bytes: Data(repeating: 7, count: 1000))

        _ = try await rig.downloader.download(pack)
        #expect(PackStubProtocol.requests(host: host).filter { $0.path.hasSuffix(path) }.map(\.range) == ["bytes=1000-", nil])
        #expect(try Data(contentsOf: rig.store.url(of: pack.file(path), in: pack)) == files[path])
    }

    @Test func aFileDamagedTwiceFailsTheDownload() async throws {
        let rig = try rig()
        let host = "packs-damaged.test"
        PackStubProtocol.install(host: host, .init(files: rig.files.mapKeys { "org/repo/resolve/abc123/\($0)" }, corrupt: true))
        let pack = pack(hosts: [host], files: rig.files)

        await #expect(throws: ModelPackError.damaged(file: pack.files[0].path)) { try await rig.downloader.download(pack) }
        #expect(PackStubProtocol.requests(host: host).count == 2)
        #expect(rig.store.downloaded(pack) == 0)
        #expect(rig.store.receipt(of: pack) == nil)
        #expect(rig.resources.isIdle)
    }

    @Test func theNextMirrorIsTriedWhenOneFails() async throws {
        let rig = try rig()
        let down = "packs-down.test", up = "packs-up.test"
        PackStubProtocol.install(host: down, .init(status: 503))
        PackStubProtocol.install(host: up, .init(files: rig.files.mapKeys { "org/repo/resolve/abc123/\($0)" }))
        let pack = pack(hosts: [down, up], files: rig.files)

        _ = try await rig.downloader.download(pack)
        #expect(PackStubProtocol.requests(host: down).count == pack.files.count)
        #expect(PackStubProtocol.requests(host: up).count == pack.files.count)
        #expect(rig.store.receipt(of: pack) != nil)
    }

    @Test func everyMirrorDownIsUnreachable() async throws {
        let rig = try rig()
        let host = "packs-alldown.test"
        PackStubProtocol.install(host: host, .init(status: 404))
        let pack = pack(hosts: [host], files: rig.files)
        await #expect(throws: ModelPackError.unreachable(host: host, reason: "It answered HTTP 404.")) { try await rig.downloader.download(pack) }
    }

    @Test func aDiskTooFullStopsBeforeAnyRequest() async throws {
        let rig = try rig(space: 1000)
        let host = "packs-full.test"
        PackStubProtocol.install(host: host, .init(files: rig.files.mapKeys { "org/repo/resolve/abc123/\($0)" }))
        let pack = pack(hosts: [host], files: rig.files)
        await #expect(throws: ModelPackError.self) { try await rig.downloader.download(pack) }
        #expect(PackStubProtocol.requests(host: host).isEmpty)
        #expect(rig.resources.isIdle)
    }

    @Test func stoppingADownloadKeepsWhatCameAndItGoesOnLater() async throws {
        let rig = try rig()
        let host = "packs-slow.test"
        let big = "det.mlpackage/Data/weights/weight.bin"
        let files = rig.licensed([big: rig.files[big]!])
        PackStubProtocol.install(host: host, .init(files: files.mapKeys { "org/repo/resolve/abc123/\($0)" }, chunkDelay: .milliseconds(30)))
        let pack = pack(hosts: [host], files: files)
        let license = Int64(files["LICENSE.txt"]!.count)

        let downloader = rig.downloader
        let task = Task { try await downloader.download(pack) }
        try await waitUntil { rig.store.downloaded(pack) >= license + 2000 }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        let kept = rig.store.downloaded(pack) - license
        #expect(kept >= 2000 && kept < files[big]!.count)
        #expect(rig.resources.isIdle)

        PackStubProtocol.change(host: host) { $0.chunkDelay = nil }
        _ = try await rig.downloader.download(pack)
        #expect(PackStubProtocol.requests(host: host).last?.range == "bytes=\(kept)-")
        #expect(try Data(contentsOf: rig.store.url(of: pack.file(big), in: pack)) == files[big])
    }

    // MARK: The store

    @Test func whatNoListedPackUsesIsRemovedAndAPausedDownloadStays() async throws {
        let rig = try rig()
        let host = "packs-versions.test"
        PackStubProtocol.install(host: host, .init(files: rig.files.mapKeys { "org/repo/resolve/abc123/\($0)" }))
        let old = pack(hosts: [host], files: rig.files, version: "1")
        _ = try await rig.downloader.download(old)
        let gone = pack(hosts: [host], files: rig.files, id: "gone-pack")
        _ = try await rig.downloader.download(gone)
        let new = pack(hosts: [host], files: rig.files, version: "2")
        _ = try leavePartial(of: new, "LICENSE.txt", rig: rig, bytes: Data([1, 2, 3]))

        let removed = rig.store.removeUnused(keeping: [new])
        #expect(Set(removed) == ["gone-pack", "test-pack/1"])
        #expect(rig.store.receipt(of: old) == nil)
        #expect(rig.store.downloaded(new) == 3)
        try rig.store.remove(new)
        #expect(rig.store.downloaded(new) == 0)
    }

    @MainActor
    @Test func aLicenseReadButNotAgreedToLeavesThePackAvailable() async throws {
        let rig = try rig()
        let host = "packs-license.test"
        PackStubProtocol.install(host: host, .init(files: rig.files.mapKeys { "org/repo/resolve/abc123/\($0)" }))
        let pack = pack(hosts: [host], files: rig.files)
        let center = ModelPackCenter(packs: [pack], store: rig.store, downloader: rig.downloader)
        let text = try await center.license(of: pack)
        #expect(text == String(decoding: rig.files["LICENSE.txt"]!, as: UTF8.self))
        await center.refresh()
        #expect(center.state(of: pack) == .available)

        // Agreed to, the download doesn't fetch it again.
        center.download(pack)
        try await waitUntil { if case .installed = center.state(of: pack) { true } else { false } }
        #expect(PackStubProtocol.requests(host: host).filter { $0.path.hasSuffix("LICENSE.txt") }.count == 1)
    }

    // MARK: The center

    @MainActor
    @Test func theCenterDownloadsPausesAndRemoves() async throws {
        let rig = try rig()
        let host = "packs-center.test"
        let big = "det.mlpackage/Data/weights/weight.bin"
        let files = ["LICENSE.txt": rig.files["LICENSE.txt"]!, big: rig.files[big]!]
        // The weights stop at 3000 bytes until released: the download is surely under way when it is paused.
        PackStubProtocol.install(host: host, .init(files: files.mapKeys { "org/repo/resolve/abc123/\($0)" }, chunkDelay: .milliseconds(5), holdsAfter: 3000))
        let pack = pack(hosts: [host], files: files)
        let center = ModelPackCenter(packs: [pack], store: rig.store, downloader: rig.downloader)
        #expect(center.state(of: pack) == .available)

        let evidence = { "requests \(PackStubProtocol.requests(host: host).count), downloaded \(rig.store.downloaded(pack)), state \(center.state(of: pack))" }
        center.download(pack)
        try await waitUntil({ rig.store.downloaded(pack) >= 3000 }, evidence: evidence)
        center.pause(pack)
        try await waitUntil({ if case .paused = center.state(of: pack) { true } else { false } }, evidence: evidence)
        guard case .paused(let done) = center.state(of: pack) else { Issue.record("not paused"); return }
        #expect(done >= 3000)

        PackStubProtocol.change(host: host) { $0.chunkDelay = nil; $0.holdsAfter = nil }
        PackStubProtocol.release(host: host)
        var installed: URL?
        center.onInstalled = { _, folder in installed = folder }
        center.download(pack)
        try await waitUntil { if case .installed = center.state(of: pack) { true } else { false } }
        #expect(installed == rig.store.folder(of: pack))
        #expect(center.installedFolder(of: pack) == rig.store.folder(of: pack))

        center.remove(pack)
        try await waitUntil { center.state(of: pack) == .available && !FileManager.default.fileExists(atPath: rig.store.folder(of: pack).path(percentEncoded: false)) }
        await center.refresh()
        #expect(center.state(of: pack) == .available)
        #expect(rig.resources.isIdle)
    }

    @MainActor
    @Test func aFailedDownloadKeepsItsReasonWhenSettingsLooksAgain() async throws {
        let rig = try rig()
        let host = "packs-failed.test"
        let big = "det.mlpackage/Data/weights/weight.bin"
        let files = rig.licensed([big: rig.files[big]!])
        PackStubProtocol.install(host: host, .init(files: files.mapKeys { "org/repo/resolve/abc123/\($0)" }, cutsOff: (path: big, requests: 1, after: 3000)))
        let pack = pack(hosts: [host], files: files)
        let center = ModelPackCenter(packs: [pack], store: rig.store, downloader: rig.downloader)
        center.download(pack)
        try await waitUntil { if case .failed = center.state(of: pack) { true } else { false } }
        await center.refresh()
        guard case .failed(_, let done) = center.state(of: pack) else { Issue.record("not failed: \(center.state(of: pack))"); return }
        #expect(done == Int64(files["LICENSE.txt"]!.count) + 3000)
    }

    @MainActor
    @Test func aCenterOfferingNothingSaysSo() {
        let center = ModelPackCenter(packs: [], store: ModelPackStore(root: URL(filePath: "/nonexistent")), downloader: ModelPackDownloader(store: ModelPackStore(root: URL(filePath: "/nonexistent"))))
        #expect(center.isEmpty)
    }

    // MARK: Helpers

    private func leavePartial(of pack: ModelPack, _ path: String, rig: Rig, bytes: Data) throws -> URL {
        let staging = rig.store.downloadFolder(of: pack)
        let target = ModelPackStore.place(path, under: staging)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        let partial = ModelPackStore.partial(of: target)
        try bytes.write(to: partial)
        return partial
    }

    /// Waits up to a minute; a pass takes a fraction of a second. On a timeout, `evidence` says what was going on.
    private func waitUntil(_ condition: () -> Bool, evidence: () -> String = { "" }) async throws {
        for _ in 0 ..< 6000 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("timed out \(evidence())")
    }
}

private extension ModelPack {
    func file(_ path: String) -> File { files.first { $0.path == path }! }
}

private extension Dictionary where Key == String {
    func mapKeys(_ transform: (String) -> String) -> [String: Value] {
        Dictionary(uniqueKeysWithValues: map { (transform($0.key), $0.value) })
    }
}
