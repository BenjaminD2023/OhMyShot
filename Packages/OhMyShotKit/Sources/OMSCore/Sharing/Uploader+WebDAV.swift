import Foundation

extension Uploader {
    func uploadToWebDAV(
        _ fileURL: URL,
        name: String,
        destination: UploadDestination,
        settings: WebDAVSettings,
        transport: Transport
    ) async throws -> UploadResult {
        guard let scheme = settings.baseURL.scheme?.lowercased(), scheme == "http" || scheme == "https", settings.baseURL.host() != nil else {
            throw UploadError.invalidConfiguration(String(localized: "the WebDAV address isn’t an http or https address", bundle: .module))
        }
        let password = (try? secret(SecretField.webDAVPassword, of: destination)) ?? ""
        let credentials = Data("\(settings.username):\(password)".utf8).base64EncodedString()

        let base = settings.baseURL.absoluteString.hasSuffix("/") ? String(settings.baseURL.absoluteString.dropLast()) : settings.baseURL.absoluteString
        let folders = Self.normalizedFolder(settings.keyPrefix).split(separator: "/").map(String.init)
        let relativeKey = (folders + [name]).joined(separator: "/")
        guard let target = URL(string: "\(base)/\(SigV4Signer.encodePath(relativeKey))") else {
            throw UploadError.invalidConfiguration(String(localized: "the WebDAV address isn’t an address", bundle: .module))
        }

        func request(_ method: String, _ url: URL) -> URLRequest {
            var request = URLRequest(url: url)
            request.httpMethod = method
            request.setValue("Basic \(credentials)", forHTTPHeaderField: "Authorization")
            return request
        }
        func put() -> URLRequest {
            var put = request("PUT", target)
            put.setValue(Self.mimeType(of: fileURL), forHTTPHeaderField: "Content-Type")
            return put
        }

        var response = try await transport.send(put(), body: fileURL)
        // Most servers answer 409 when a folder above the file is missing: make each, then try once more.
        if response.status == 409, !folders.isEmpty {
            var path = ""
            for folder in folders {
                path += (path.isEmpty ? "" : "/") + SigV4Signer.encode(folder)
                guard let folderURL = URL(string: "\(base)/\(path)/") else { continue }
                let made = try await transport.send(request("MKCOL", folderURL))
                // 201 made it; 405 means it was already there.
                guard made.status == 201 || made.status == 405 || (200..<300).contains(made.status) else {
                    throw Self.failure(status: made.status, message: nil)
                }
            }
            response = try await transport.send(put(), body: fileURL)
        }
        guard response.status == 201 || response.status == 204 || response.status == 200 else {
            if response.status == 507 { throw UploadError.server(status: 507, message: String(localized: "the server is out of space", bundle: .module)) }
            throw Self.failure(status: response.status, message: nil)
        }

        let link: URL
        if let publicBase = settings.publicBaseURL {
            link = try Self.publicLink(base: publicBase, key: relativeKey, fallback: target)
        } else {
            link = target
        }
        return UploadResult(link: link, fileName: name, remoteKey: relativeKey)
    }

    func deleteFromWebDAV(key: String, destination: UploadDestination, settings: WebDAVSettings, transport: Transport) async throws {
        guard let scheme = settings.baseURL.scheme?.lowercased(), scheme == "http" || scheme == "https", settings.baseURL.host() != nil else {
            throw UploadError.invalidConfiguration(String(localized: "the WebDAV address isn’t an http or https address", bundle: .module))
        }
        let password = (try? secret(SecretField.webDAVPassword, of: destination)) ?? ""
        let credentials = Data("\(settings.username):\(password)".utf8).base64EncodedString()
        let base = settings.baseURL.absoluteString.hasSuffix("/") ? String(settings.baseURL.absoluteString.dropLast()) : settings.baseURL.absoluteString
        guard let target = URL(string: "\(base)/\(SigV4Signer.encodePath(key))") else {
            throw UploadError.invalidConfiguration(String(localized: "the WebDAV address isn’t an address", bundle: .module))
        }
        var request = URLRequest(url: target)
        request.httpMethod = "DELETE"
        request.setValue("Basic \(credentials)", forHTTPHeaderField: "Authorization")
        let response = try await transport.send(request)
        // 404: someone already removed it.
        guard (200..<300).contains(response.status) || response.status == 404 else {
            throw Self.failure(status: response.status, message: nil)
        }
    }
}
