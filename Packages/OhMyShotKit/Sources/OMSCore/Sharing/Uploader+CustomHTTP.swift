import Foundation
import OSLog

extension Uploader {
    func uploadWithCustomHTTP(
        _ fileURL: URL,
        size: Int64,
        name: String,
        destination: UploadDestination,
        settings: CustomHTTPSettings,
        transport: Transport
    ) async throws -> UploadResult {
        let request: URLRequest
        func invalid(_ error: ShareXTemplateError) -> UploadError {
            .invalidConfiguration(error.localizedDescription)
        }
        let plain = ShareXTemplate.Context(fileName: name)
        do {
            // The address with its file name encoded, then the query parameters after it.
            let address = try ShareXTemplate(settings.requestURL, scope: .request)
                .evaluate(ShareXTemplate.Context(fileName: name, encodesFileName: true))
            var text = address.trimmingCharacters(in: .whitespaces)
            if !text.contains("://") { text = "https://" + text }
            var query: [String] = []
            for parameter in settings.parameterNames {
                let value = try ShareXTemplate(try secret(SecretField.parameter(parameter), of: destination), scope: .request).evaluate(plain)
                query.append("\(SigV4Signer.encode(parameter))=\(SigV4Signer.encode(value))")
            }
            if !query.isEmpty { text += (text.contains("?") ? "&" : "?") + query.joined(separator: "&") }
            guard let url = URL(string: text), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https", url.host() != nil else {
                throw UploadError.invalidConfiguration(String(localized: "the request URL isn’t an http or https address"))
            }
            var built = URLRequest(url: url)
            built.httpMethod = settings.method.rawValue
            for header in settings.headerNames {
                let value = try ShareXTemplate(try secret(SecretField.header(header), of: destination), scope: .request).evaluate(plain)
                built.setValue(value, forHTTPHeaderField: header)
            }
            request = built
        } catch let error as ShareXTemplateError {
            throw invalid(error)
        }

        var sending = request
        var bodyFile = fileURL
        var temporary: URL?
        defer { if let temporary { try? FileManager.default.removeItem(at: temporary) } }

        switch settings.bodyType {
        case .binary:
            if sending.value(forHTTPHeaderField: "Content-Type") == nil {
                sending.setValue(Self.mimeType(of: fileURL), forHTTPHeaderField: "Content-Type")
            }
        case .multipartFormData:
            guard !settings.fileFormName.isEmpty else {
                throw UploadError.invalidConfiguration(String(localized: "the form field for the file has no name"))
            }
            var fields: [(name: String, value: String)] = []
            do {
                for argument in settings.argumentNames {
                    let template = try ShareXTemplate(try secret(SecretField.argument(argument), of: destination), scope: .request)
                    fields.append((argument, try template.evaluate(ShareXTemplate.Context(fileName: name))))
                }
            } catch let error as ShareXTemplateError {
                throw invalid(error)
            }
            let written = try await MultipartBody.write(
                fields: fields, file: fileURL, formName: settings.fileFormName, fileName: name,
                contentType: Self.mimeType(of: fileURL), in: temporaryDirectory
            )
            temporary = written.url
            bodyFile = written.url
            sending.setValue(written.contentType, forHTTPHeaderField: "Content-Type")
        }

        let response = try await transport.send(sending, body: bodyFile)
        let context = ShareXTemplate.Context(fileName: name, encodesFileName: true, response: response)

        guard (200..<300).contains(response.status) else {
            var message: String?
            if !settings.errorMessageTemplate.isEmpty,
               let template = try? ShareXTemplate(settings.errorMessageTemplate, scope: .response),
               let text = try? template.evaluate(context), !text.isEmpty {
                message = text
            }
            throw Self.failure(status: response.status, message: message)
        }

        func evaluated(_ source: String) throws -> String {
            guard !source.isEmpty else { return "" }
            do { return try ShareXTemplate(source, scope: .response).evaluate(context).trimmingCharacters(in: .whitespacesAndNewlines) }
            catch let error as ShareXTemplateError {
                // A template that cannot read the answer (it is not JSON) means no link, not a configuration error.
                Log.upload.error("Link template failed: \(String(describing: error), privacy: .public)")
                throw UploadError.linkMissing
            }
        }
        // An empty URL template means the whole answer is the link, as in ShareX.
        let linkText = settings.urlTemplate.isEmpty ? response.text.trimmingCharacters(in: .whitespacesAndNewlines) : try evaluated(settings.urlTemplate)
        guard let link = Self.webURL(linkText) else { throw UploadError.linkMissing }
        return UploadResult(
            link: link,
            deletionURL: Self.webURL(try evaluated(settings.deletionURLTemplate)),
            thumbnailURL: Self.webURL(try evaluated(settings.thumbnailURLTemplate)),
            fileName: name
        )
    }

    /// An address with an http or https scheme, or nil.
    static func webURL(_ text: String) -> URL? {
        guard !text.isEmpty, let url = URL(string: text), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https", url.host() != nil
        else { return nil }
        return url
    }
}
