import Darwin
import Foundation
import Synchronization
import Testing
@testable import OMSCore

/// Uploads to real servers on 127.0.0.1: `rclone serve s3`, `rclone serve webdav` and a small receiver for
/// custom uploaders. Off unless OMS_UPLOAD_LIVE names the folder the servers were started from; the normal
/// suite never needs them. Ports: S3 19000 (ACCESSKEY / SECRETKEY123, bucket `bk`), WebDAV 19001
/// (alice / wonderland), receiver 19002 (token tok123).
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["OMS_UPLOAD_LIVE"] != nil))
struct UploadLiveTests {
    private let lab = URL(fileURLWithPath: ProcessInfo.processInfo.environment["OMS_UPLOAD_LIVE"] ?? "/nonexistent")

    private func makeFile(name: String, megabytes: Int) throws -> URL {
        let dir = lab.appending(path: "files")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appending(path: name)
        guard FileManager.default.createFile(atPath: url.path(), contents: nil) else { throw UploadError.fileUnreadable }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        var generator = SystemRandomNumberGenerator()
        let chunk = Data((0..<(1 << 20)).map { _ in UInt8.random(in: 0...255, using: &generator) })
        for _ in 0..<megabytes { try handle.write(contentsOf: chunk) }
        try handle.write(contentsOf: Data([1, 2, 3]))
        return url
    }

    private func uploader(_ secrets: InMemorySecretStore) throws -> Uploader {
        let temp = lab.appending(path: "tmp")
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        return Uploader(secrets: secrets, resources: ActiveResources(), temporaryDirectory: temp)
    }

    private func s3Destination(_ secrets: InMemorySecretStore, secret: String = "SECRETKEY123", style: S3Settings.LinkStyle = .publicURL, prefix: String = "shots") throws -> UploadDestination {
        let settings = S3Settings(endpoint: URL(string: "http://127.0.0.1:19000")!, region: "us-east-1", bucket: "bk", keyPrefix: prefix, linkStyle: style)
        let destination = UploadDestination(name: "live s3", fileNaming: .original, configuration: .s3(settings))
        try secrets.setSecret("ACCESSKEY", field: SecretField.s3AccessKeyID, of: destination.id)
        try secrets.setSecret(secret, field: SecretField.s3SecretAccessKey, of: destination.id)
        return destination
    }

    private func fetch(_ url: URL, headers: [String: String] = [:]) async throws -> Data {
        var request = URLRequest(url: url)
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        let (data, response) = try await URLSession.shared.data(for: request)
        #expect((response as? HTTPURLResponse)?.statusCode == 200, "GET \(url.host() ?? "") \(url.path())")
        return data
    }

    // MARK: S3

    @Test func s3RejectsAWrongSecretAndAcceptsTheRightOne() async throws {
        let secrets = InMemorySecretStore()
        let file = try makeFile(name: "s3-small.png", megabytes: 1)
        let content = try Data(contentsOf: file)
        let up = try uploader(secrets)

        let bad = try s3Destination(secrets, secret: "WRONGSECRET")
        do {
            _ = try await up.upload(fileAt: file, to: bad, originalName: "x.png")
            Issue.record("a wrong secret was accepted")
        } catch let error as UploadError {
            print("LIVE s3 wrong secret ->", error)
            #expect(error == .authRejected(detail: nil) || { if case .authRejected = error { true } else { false } }())
        }

        let good = try s3Destination(secrets)
        let name = "CleanShot 2026-10-16 at 14.02.11 微信+a#b.png"
        let result = try await up.upload(fileAt: file, to: good, originalName: name)
        print("LIVE s3 link ->", result.link.absoluteString)
        let stored = lab.appending(path: "s3root/bk/shots/\(name)")
        #expect(try Data(contentsOf: stored) == content)
    }

    @Test func s3PresignedLinkFetchesTheSameBytes() async throws {
        let secrets = InMemorySecretStore()
        let file = try makeFile(name: "s3-presign.png", megabytes: 1)
        let content = try Data(contentsOf: file)
        let destination = try s3Destination(secrets, style: .presigned, prefix: "p/q r")
        let result = try await uploader(secrets).upload(fileAt: file, to: destination, originalName: "a b+c#d 微.png")
        print("LIVE s3 presigned host/path ->", result.link.host() ?? "", result.link.path(percentEncoded: true))
        #expect(try await fetch(result.link) == content)
        // The same link with its signature damaged is refused.
        let broken = URL(string: result.link.absoluteString.replacingOccurrences(of: "X-Amz-Signature=", with: "X-Amz-Signature=00"))!
        let (_, response) = try await URLSession.shared.data(from: broken)
        #expect((response as? HTTPURLResponse)?.statusCode != 200)
    }

    // MARK: WebDAV

    @Test func webDAVCreatesNestedFoldersAndTheLinkFetches() async throws {
        let secrets = InMemorySecretStore()
        let file = try makeFile(name: "dav-small.png", megabytes: 1)
        let content = try Data(contentsOf: file)
        let settings = WebDAVSettings(baseURL: URL(string: "http://127.0.0.1:19001/")!, username: "alice", keyPrefix: "n1/n 2/n3")
        let destination = UploadDestination(name: "live dav", fileNaming: .original, configuration: .webDAV(settings))
        try secrets.setSecret("wonderland", field: SecretField.webDAVPassword, of: destination.id)
        let result = try await uploader(secrets).upload(fileAt: file, to: destination, originalName: "微 x+y#z.png")
        print("LIVE dav link ->", result.link.absoluteString)
        #expect(try Data(contentsOf: lab.appending(path: "davroot/n1/n 2/n3/微 x+y#z.png")) == content)
        let basic = "Basic " + Data("alice:wonderland".utf8).base64EncodedString()
        #expect(try await fetch(result.link, headers: ["Authorization": basic]) == content)

        let wrong = UploadDestination(name: "w", configuration: .webDAV(settings))
        try secrets.setSecret("nope", field: SecretField.webDAVPassword, of: wrong.id)
        await #expect(throws: UploadError.authRejected(detail: nil)) { try await uploader(secrets).upload(fileAt: file, to: wrong) }
    }

    // MARK: Custom HTTP

    @Test func customHTTPMultipartAndBinaryThroughSxcuFiles() async throws {
        let secrets = InMemorySecretStore()
        let file = try makeFile(name: "http-small.png", megabytes: 1)
        let content = try Data(contentsOf: file)
        let multipart = #"{"Version":"16.1.0","Name":"recv","RequestURL":"http://127.0.0.1:19002/upload","Headers":{"Authorization":"Bearer tok123"},"Body":"MultipartFormData","FileFormName":"image","Arguments":{"album":"live"},"URL":"{json:data.link}"}"#
        let a = try ShareXImporter.importUploader(from: Data(multipart.utf8))
        for (field, value) in a.secrets { try secrets.setSecret(value, field: field, of: a.destination.id) }
        var destination = a.destination
        destination.fileNaming = .original
        let first = try await uploader(secrets).upload(fileAt: file, to: destination, originalName: "mp 微 x+y#z.png")
        print("LIVE http multipart link ->", first.link.absoluteString)
        #expect(try Data(contentsOf: lab.appending(path: "recv/mp 微 x+y#z.png")) == content)
        #expect(try await fetch(first.link) == content)

        let binary = #"{"Version":"16.1.0","RequestMethod":"PUT","RequestURL":"http://127.0.0.1:19002/put/{filename}","Headers":{"X-Token":"tok123"},"Body":"Binary","URL":"{json:data.link}"}"#
        let b = try ShareXImporter.importUploader(from: Data(binary.utf8))
        for (field, value) in b.secrets { try secrets.setSecret(value, field: field, of: b.destination.id) }
        var second = b.destination
        second.fileNaming = .original
        let result = try await uploader(secrets).upload(fileAt: file, to: second, originalName: "bin 微 x+y#z.png")
        print("LIVE http binary link ->", result.link.absoluteString)
        #expect(try Data(contentsOf: lab.appending(path: "recv/bin 微 x+y#z.png")) == content)
        #expect(try await fetch(result.link) == content)

        // A wrong token is the server's error, shown as such.
        try secrets.setSecret("Bearer wrong", field: SecretField.header("Authorization"), of: destination.id)
        do { _ = try await uploader(secrets).upload(fileAt: file, to: destination); Issue.record("accepted") }
        catch let error as UploadError { print("LIVE http wrong token ->", error); #expect(error == .authRejected(detail: nil)) }
    }

    // MARK: Large files

    /// The memory the process holds that is its own (Activity Monitor's "Memory"): file pages that the
    /// system merely keeps mapped count in `resident_size` but not here.
    private static func footprintBytes() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return result == KERN_SUCCESS ? UInt64(info.phys_footprint) : 0
    }

    private static func residentBytes() -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count) }
        }
        return result == KERN_SUCCESS ? UInt64(info.resident_size) : 0
    }

    struct Memory: Sendable {
        var footprintBaseline = 0.0, footprintPeak = 0.0, residentBaseline = 0.0, residentPeak = 0.0
        var footprintGrowth: Double { footprintPeak - footprintBaseline }
        var summary: String {
            String(format: "footprint %.0f -> peak %.0f MB, resident %.0f -> peak %.0f MB", footprintBaseline, footprintPeak, residentBaseline, residentPeak)
        }
    }

    /// Memory sampled every 20 ms while `body` runs.
    private func sampled<T: Sendable>(_ body: () async throws -> T) async rethrows -> (T, Memory) {
        let mb = 1_048_576.0
        let peaks = Mutex<(UInt64, UInt64)>((0, 0))
        let start = (Self.footprintBytes(), Self.residentBytes())
        let sampler = Task.detached {
            while !Task.isCancelled {
                let now = (Self.footprintBytes(), Self.residentBytes())
                peaks.withLock { $0 = (max($0.0, now.0), max($0.1, now.1)) }
                try? await Task.sleep(for: .milliseconds(20))
            }
        }
        defer { sampler.cancel() }
        let value = try await body()
        let peak = peaks.withLock { $0 }
        return (value, Memory(footprintBaseline: Double(start.0) / mb, footprintPeak: Double(peak.0) / mb, residentBaseline: Double(start.1) / mb, residentPeak: Double(peak.1) / mb))
    }

    @Test func aLargeFileUploadsToS3WithFlatMemory() async throws {
        let secrets = InMemorySecretStore()
        let file = try makeFile(name: "big.bin", megabytes: 230)
        let up = try uploader(secrets)
        let destination = try s3Destination(secrets, prefix: "big")
        let started = Date()
        let (result, memory) = try await sampled { try await up.upload(fileAt: file, to: destination, originalName: "big.bin") }
        print(String(format: "LIVE big s3 (230 MB): %.1fs, ", Date().timeIntervalSince(started)) + memory.summary)
        _ = result
        let stored = lab.appending(path: "s3root/bk/big/big.bin")
        #expect(try FileManager.default.attributesOfItem(atPath: stored.path())[.size] as? Int == (230 << 20) + 3)
        #expect(memory.footprintGrowth < 60, "footprint grew by \(memory.footprintGrowth) MB")
    }

    @Test func aLargeMultipartUploadKeepsMemoryFlatAndCancelsCleanly() async throws {
        let secrets = InMemorySecretStore()
        let file = try makeFile(name: "big2.bin", megabytes: 230)
        let json = #"{"Version":"16.1.0","RequestURL":"http://127.0.0.1:19002/upload","Headers":{"Authorization":"Bearer tok123"},"Body":"MultipartFormData","FileFormName":"f","URL":"{json:data.link}"}"#
        let imported = try ShareXImporter.importUploader(from: Data(json.utf8))
        for (field, value) in imported.secrets { try secrets.setSecret(value, field: field, of: imported.destination.id) }
        var destination = imported.destination
        destination.fileNaming = .original
        let up = try uploader(secrets)
        let temp = lab.appending(path: "tmp")

        let started = Date()
        let (result, memory) = try await sampled { try await up.upload(fileAt: file, to: destination, originalName: "big2.bin") }
        print(String(format: "LIVE big multipart (230 MB): %.1fs, ", Date().timeIntervalSince(started)) + memory.summary)
        _ = result
        #expect(memory.footprintGrowth < 60, "footprint grew by \(memory.footprintGrowth) MB")
        #expect(try FileManager.default.contentsOfDirectory(atPath: temp.path()).isEmpty)

        let huge = try makeFile(name: "huge.bin", megabytes: 900)
        try await cancelMidway(up, file: huge, to: destination, temp: temp, label: "multipart, 900 MB")
    }

    @Test func cancellingMidwayStopsAnS3UploadAndLeavesNothingBehind() async throws {
        let secrets = InMemorySecretStore()
        let file = try makeFile(name: "huge.bin", megabytes: 900)
        let up = try uploader(secrets)
        try await cancelMidway(up, file: file, to: try s3Destination(secrets, prefix: "cancel"), temp: lab.appending(path: "tmp"), label: "s3, 900 MB")
    }

    /// Cancels once 5% has been sent and checks the transfer stopped, with no temporary file and no lease left.
    private func cancelMidway(_ up: Uploader, file: URL, to destination: UploadDestination, temp: URL, label: String) async throws {
        let fraction = Mutex<Double>(0)
        let task = Task { try await up.upload(fileAt: file, to: destination, originalName: "cancelled.bin") { value in fraction.withLock { $0 = value } } }
        let deadline = Date().addingTimeInterval(120)
        while fraction.withLock({ $0 }) < 0.05, Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        let sent = fraction.withLock { $0 }
        #expect(up.resources.snapshot[.upload] == 1)
        let cancelledAt = Date()
        task.cancel()
        do { _ = try await task.value; Issue.record("the upload was not cancelled") }
        catch is CancellationError { print(String(format: "LIVE cancel %@: at %.0f%%, stopped in %.0f ms", label, sent * 100, Date().timeIntervalSince(cancelledAt) * 1000)) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: temp.path()).isEmpty)
        #expect(up.resources.isIdle)
        #expect(sent >= 0.05 && sent < 1)
    }
}
