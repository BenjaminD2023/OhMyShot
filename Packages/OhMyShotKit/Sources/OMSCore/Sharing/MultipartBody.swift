import Foundation

/// A `multipart/form-data` body written to a file.
///
/// The form fields come first and the file last, as ShareX sends them. The file is copied in chunks so a
/// recording of hundreds of megabytes never sits in memory, and the body is a file because
/// `uploadTask(fromFile:)` streams from disk.
enum MultipartBody {
    struct Written {
        let url: URL
        let boundary: String
        var contentType: String { "multipart/form-data; boundary=\(boundary)" }
    }

    /// The body's file is created in `directory`; the caller removes it when the request is done. A failure
    /// or a cancellation removes it here.
    @concurrent
    static func write(
        fields: [(name: String, value: String)],
        file: URL,
        formName: String,
        fileName: String,
        contentType: String,
        in directory: URL
    ) async throws -> Written {
        let boundary = "OhMyShot-" + UUID().uuidString
        let destination = directory.appending(path: "OhMyShot-upload-\(UUID().uuidString).multipart")
        guard FileManager.default.createFile(atPath: destination.path(percentEncoded: false), contents: nil) else {
            throw UploadError.fileUnreadable
        }
        do {
            let output = try FileHandle(forWritingTo: destination)
            defer { try? output.close() }
            var head = ""
            for field in fields {
                head += "--\(boundary)\r\nContent-Disposition: form-data; name=\"\(quoted(field.name))\"\r\n\r\n\(field.value)\r\n"
            }
            head += "--\(boundary)\r\nContent-Disposition: form-data; name=\"\(quoted(formName))\"; filename=\"\(quoted(fileName))\"\r\nContent-Type: \(contentType)\r\n\r\n"
            try output.write(contentsOf: Data(head.utf8))

            let input = try FileHandle(forReadingFrom: file)
            defer { try? input.close() }
            var finished = false
            while !finished {
                try Task.checkCancellation()
                // A pool per chunk, or every chunk stays in memory until the loop ends.
                try autoreleasepool {
                    guard let chunk = try input.read(upToCount: 1 << 20), !chunk.isEmpty else { finished = true; return }
                    try output.write(contentsOf: chunk)
                }
            }
            try output.write(contentsOf: Data("\r\n--\(boundary)--\r\n".utf8))
            return Written(url: destination, boundary: boundary)
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }

    /// A value inside a quoted header parameter: quotes and line breaks would end it early.
    static func quoted(_ text: String) -> String {
        text.replacingOccurrences(of: "\"", with: "%22")
            .replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: "\n", with: "")
    }
}
