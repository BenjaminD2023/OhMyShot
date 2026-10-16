import CryptoKit
import Foundation
import OSLog
import Synchronization

extension Uploader {
    /// Files over `multipartThreshold` go to S3 in parts: CreateMultipartUpload, one UploadPart per piece of
    /// the file, CompleteMultipartUpload. Each piece is copied from the file to a temporary file (hashed as
    /// it is copied) and sent from there, so memory stays flat whatever the size, and a part that fails does
    /// not send the whole file again. Cancelling or failing aborts the upload so the server does not keep
    /// the parts that were sent.
    func uploadToS3InParts(
        _ fileURL: URL,
        size: Int64,
        address: S3ObjectAddress,
        signer: SigV4Signer,
        settings: S3Settings,
        transport: Transport
    ) async throws {
        // S3 allows 10,000 parts: pieces grow with the file so a very large one still fits.
        let partSize = max(multipartPartSize, (size / 9_000 + 1_048_575) / 1_048_576 * 1_048_576)
        let partCount = Int((size + partSize - 1) / partSize)

        var create = try s3Request(
            "POST", address, query: [("uploads", "")], signer: signer, settings: settings, payloadHash: SigV4Signer.emptyPayloadHash
        )
        create.setValue(Self.mimeType(of: fileURL), forHTTPHeaderField: "Content-Type")
        let created = try await transport.send(create)
        try Self.requireS3Success(created)
        guard let uploadID = Self.xmlValue("UploadId", in: created.text), !uploadID.isEmpty else {
            throw UploadError.server(status: created.status, message: String(localized: "the server didn’t start a multipart upload"))
        }
        Log.upload.notice("Multipart upload started, \(partCount, privacy: .public) parts")

        do {
            var etags: [String] = []
            let progress = PartProgress(total: size, report: transport.progress)
            for index in 0..<partCount {
                try Task.checkCancellation()
                let offset = Int64(index) * partSize
                let length = min(partSize, size - offset)
                let piece = temporaryDirectory.appending(path: "OhMyShot-part-\(UUID().uuidString)")
                defer { try? FileManager.default.removeItem(at: piece) }
                let hash = try await Self.copyRange(of: fileURL, offset: UInt64(offset), length: length, to: piece)

                let request = try s3Request(
                    "PUT", address, query: [("partNumber", String(index + 1)), ("uploadId", uploadID)],
                    sendsACL: false, signer: signer, settings: settings, payloadHash: hash
                )
                let partTransport = Transport(session: transport.session, progress: progress.reporter(done: offset, length: length))
                let sent = try await partTransport.send(request, body: piece)
                try Self.requireS3Success(sent)
                // A part's own progress can end short of its last bytes; the part being done settles it.
                progress.reporter(done: offset, length: length)?(1)
                guard let etag = sent.header("ETag") else {
                    throw UploadError.server(status: sent.status, message: String(localized: "the server didn’t say it kept part \(index + 1)"))
                }
                etags.append(etag)
            }

            let body = Data((
                "<CompleteMultipartUpload>"
                    + etags.enumerated().map { "<Part><PartNumber>\($0.offset + 1)</PartNumber><ETag>\($0.element)</ETag></Part>" }.joined()
                    + "</CompleteMultipartUpload>"
            ).utf8)
            var complete = try s3Request(
                "POST", address, query: [("uploadId", uploadID)], sendsACL: false, signer: signer, settings: settings,
                payloadHash: SigV4Signer.hex(SHA256.hash(data: body))
            )
            complete.httpBody = body
            complete.setValue("application/xml", forHTTPHeaderField: "Content-Type")
            let finished = try await transport.send(complete)
            try Self.requireS3Success(finished)
            // S3 can answer 200 and still say the upload failed, in the body.
            if finished.text.contains("<Error>") { throw Self.s3Failure(UploadResponse(status: 500, text: finished.text)) }
        } catch {
            await abortMultipartUpload(address: address, uploadID: uploadID, signer: signer, settings: settings, transport: transport)
            throw error
        }
    }

    /// Tells the server to throw away the parts of an upload that will not be finished. Runs outside the
    /// cancelled task so it is sent even when the upload was cancelled, and gives up quickly: a server that
    /// is gone has nothing to clean.
    private func abortMultipartUpload(address: S3ObjectAddress, uploadID: String, signer: SigV4Signer, settings: S3Settings, transport: Transport) async {
        guard var request = try? s3Request(
            "DELETE", address, query: [("uploadId", uploadID)], sendsACL: false, signer: signer, settings: settings,
            payloadHash: SigV4Signer.emptyPayloadHash
        ) else { return }
        request.timeoutInterval = 15
        let quiet = Transport(session: transport.session, progress: nil)
        let status = await Task { try? await quiet.send(request).status }.value
        Log.upload.notice("Multipart upload aborted, answer \(status ?? 0, privacy: .public)")
    }

    /// Copies `length` bytes from `offset` into a new file, a megabyte at a time, and gives their SHA-256.
    @concurrent
    static func copyRange(of source: URL, offset: UInt64, length: Int64, to destination: URL) async throws -> String {
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        guard FileManager.default.createFile(atPath: destination.path(percentEncoded: false), contents: nil) else { throw UploadError.fileUnreadable }
        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }
        try input.seek(toOffset: offset)
        var hasher = SHA256()
        var remaining = length
        while remaining > 0 {
            try Task.checkCancellation()
            // A pool per chunk: without it the chunks stay alive until the loop ends, which is the whole part.
            try autoreleasepool {
                guard let chunk = try input.read(upToCount: Int(min(remaining, 1 << 20))), !chunk.isEmpty else {
                    throw UploadError.fileUnreadable
                }
                hasher.update(data: chunk)
                try output.write(contentsOf: chunk)
                remaining -= Int64(chunk.count)
            }
        }
        return SigV4Signer.hex(hasher.finalize())
    }

    /// What `<tag>…</tag>` holds in an XML answer.
    static func xmlValue(_ tag: String, in body: String) -> String? {
        guard let open = body.range(of: "<\(tag)>"), let close = body.range(of: "</\(tag)>", range: open.upperBound..<body.endIndex) else { return nil }
        return String(body[open.upperBound..<close.lowerBound])
    }
}

/// Turns each part's own progress into the whole file's, a hundredth at a time.
private final class PartProgress: Sendable {
    private let total: Int64
    private let report: (@Sendable (Double) -> Void)?
    private let last = Mutex<Double>(-1)

    init(total: Int64, report: (@Sendable (Double) -> Void)?) {
        self.total = total
        self.report = report
    }

    /// The reporter for a part of `length` bytes that starts `done` bytes into the file; the part reports 0...1.
    func reporter(done: Int64, length: Int64) -> (@Sendable (Double) -> Void)? {
        guard let report else { return nil }
        let total = Double(total)
        return { [self] fraction in
            let overall = min(1, (Double(done) + fraction * Double(length)) / total)
            let due = self.last.withLock { last in
                guard overall - last >= 0.01 else { return false }
                last = overall
                return true
            }
            if due { report(overall) }
        }
    }
}
