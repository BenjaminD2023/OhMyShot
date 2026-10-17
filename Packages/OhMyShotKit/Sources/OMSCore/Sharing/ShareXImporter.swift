import Foundation

public enum ShareXImportError: Error, LocalizedError, Equatable {
    case notAShareXFile
    case missingRequestURL
    case unsupportedMethod(String)
    case unsupportedBody(String)
    case missingFileFormName
    case notAFileUploader
    case deprecatedResponseType
    case template(field: String, error: ShareXTemplateError)

    public var errorDescription: String? {
        switch self {
        case .notAShareXFile:
            String(localized: "This isn’t a ShareX custom uploader (.sxcu) file.", bundle: .module)
        case .missingRequestURL:
            String(localized: "The uploader has no request URL.", bundle: .module)
        case .unsupportedMethod(let method):
            String(localized: "The uploader sends with \(method), which can’t carry a file. OhMyShot supports POST, PUT and PATCH.", bundle: .module)
        case .unsupportedBody(let body):
            String(localized: "The uploader sends its request as \(body), which doesn’t carry a file. OhMyShot supports MultipartFormData and Binary.", bundle: .module)
        case .missingFileFormName:
            String(localized: "The uploader sends a form but doesn’t say which field the file goes in (FileFormName).", bundle: .module)
        case .notAFileUploader:
            String(localized: "This uploader is for text or for shortening links, not for images or files.", bundle: .module)
        case .deprecatedResponseType:
            String(localized: "The uploader uses ShareX’s old “Headers” response type, which ShareX itself doesn’t support any more. Use {header:name} in its URL instead.", bundle: .module)
        case .template(let field, let error):
            String(localized: "\(field): \(error.localizedDescription)", bundle: .module)
        }
    }
}

/// What an imported `.sxcu` file turns into.
public struct ImportedUploader: Sendable {
    public var destination: UploadDestination
    /// The values of the query parameters, headers and form fields, to be kept in a `SecretStore` under the
    /// destination's id: `store.add(destination, secrets: secrets)`.
    public var secrets: [String: String]
    /// Things the person should know about, such as a file written for an older ShareX being converted.
    public var notes: [String]
}

/// Reads ShareX custom uploader files (`.sxcu`).
///
/// The field names and the conversion of older files follow ShareX's own `CustomUploaderItem`: a file with
/// no `Version` or one up to 12.3.1 is first given a body type from its request method and its `ResponseType`
/// folded into its URLs; one up to 13.7.1 then has its `$json:path$` syntax rewritten as `{json:path}`.
/// Anything that would make a link wrong rather than missing is refused here, not at upload time.
public enum ShareXImporter {
    public static func importUploader(from data: Data) throws -> ImportedUploader {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw ShareXImportError.notAShareXFile
        }
        func string(_ key: String) -> String {
            guard let value = root[key] else { return "" }
            return (value as? String) ?? ""
        }
        func table(_ key: String) -> [String: String] {
            guard let object = root[key] as? [String: Any] else { return [:] }
            return object.mapValues { value in
                if let text = value as? String { return text }
                if let number = value as? NSNumber { return number.stringValue }
                return ""
            }
        }

        var version = string("Version")
        var method = string("RequestMethod")
        if method.isEmpty { method = string("RequestType") }
        if method.isEmpty { method = "POST" }
        var requestURL = string("RequestURL")
        var parameters = table("Parameters")
        var headers = table("Headers")
        var arguments = table("Arguments")
        var bodyName = string("Body")
        var urlText = string("URL")
        var thumbnailText = string("ThumbnailURL")
        var deletionText = string("DeletionURL")
        var errorText = string("ErrorMessage")
        var notes: [String] = []

        // A query string in the address belongs with the parameters, in every version.
        if let question = requestURL.firstIndex(of: "?") {
            for pair in requestURL[requestURL.index(after: question)...].split(separator: "&") {
                let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                let name = String(parts[0]).removingPercentEncoding ?? String(parts[0])
                let value = parts.count > 1 ? (String(parts[1]).removingPercentEncoding ?? String(parts[1])) : ""
                if parameters[name] == nil, !name.isEmpty { parameters[name] = value }
            }
            requestURL = String(requestURL[..<question])
        }

        if version.isEmpty || compare(version, "12.3.1") <= 0 {
            if method.uppercased() == "POST" {
                bodyName = "MultipartFormData"
            } else {
                bodyName = "None"
                for (name, value) in arguments where parameters[name] == nil { parameters[name] = value }
                arguments = [:]
            }
            switch string("ResponseType") {
            case "RedirectionURL":
                if urlText.isEmpty { urlText = "$responseurl$" }
                urlText = urlText.replacingOccurrences(of: "$response$", with: "$responseurl$")
                thumbnailText = thumbnailText.replacingOccurrences(of: "$response$", with: "$responseurl$")
                deletionText = deletionText.replacingOccurrences(of: "$response$", with: "$responseurl$")
            case "LocationHeader":
                if urlText.isEmpty { urlText = "$header:Location$" }
                urlText = urlText.replacingOccurrences(of: "$response$", with: "$header:Location$")
                thumbnailText = thumbnailText.replacingOccurrences(of: "$response$", with: "$header:Location$")
                deletionText = deletionText.replacingOccurrences(of: "$response$", with: "$header:Location$")
            case "Headers":
                throw ShareXImportError.deprecatedResponseType
            default:
                break
            }
            version = "13.7.1"
            notes.append(String(localized: "Converted from a file written for an older ShareX.", bundle: .module))
        }
        if compare(version, "13.7.1") <= 0 {
            if notes.isEmpty { notes.append(String(localized: "Converted from a file written for an older ShareX.", bundle: .module)) }
            requestURL = migrateOldSyntax(requestURL)
            parameters = parameters.mapValues(migrateOldSyntax)
            arguments = arguments.mapValues(migrateOldSyntax)
            headers = headers.mapValues(migrateOldSyntax)
            urlText = migrateOldSyntax(urlText)
            thumbnailText = migrateOldSyntax(thumbnailText)
            deletionText = migrateOldSyntax(deletionText)
            errorText = migrateOldSyntax(errorText)
        }
        return try build(
            root: root, name: string("Name"), method: method, requestURL: requestURL, parameters: parameters,
            headers: headers, arguments: arguments, bodyName: bodyName, fileFormName: string("FileFormName"),
            url: urlText, thumbnail: thumbnailText, deletion: deletionText, error: errorText, notes: notes
        )
    }

    public static func importUploader(fromFileAt url: URL) throws -> ImportedUploader {
        try importUploader(from: Data(contentsOf: url))
    }

    private static func build(
        root: [String: Any], name: String, method: String, requestURL: String,
        parameters: [String: String], headers: [String: String], arguments: [String: String],
        bodyName: String, fileFormName: String, url: String, thumbnail: String, deletion: String,
        error: String, notes: [String]
    ) throws -> ImportedUploader {
        guard !requestURL.trimmingCharacters(in: .whitespaces).isEmpty else { throw ShareXImportError.missingRequestURL }

        // DestinationType is a set of flags, written as "ImageUploader, FileUploader" or as a number.
        if let type = root["DestinationType"] {
            let text = (type as? String) ?? ""
            let number = (type as? NSNumber)?.intValue
            let forFiles = number.map { $0 == 0 || $0 & 0b101 != 0 }
                ?? (text.isEmpty || text == "None" || text.contains("ImageUploader") || text.contains("FileUploader"))
            if !forFiles { throw ShareXImportError.notAFileUploader }
        }

        guard let httpMethod = CustomHTTPSettings.Method(rawValue: method.uppercased()) else {
            throw ShareXImportError.unsupportedMethod(method.uppercased())
        }
        let bodyType: CustomHTTPSettings.BodyType
        switch bodyName.isEmpty ? "None" : bodyName {
        case "MultipartFormData": bodyType = .multipartFormData
        case "Binary": bodyType = .binary
        case let other: throw ShareXImportError.unsupportedBody(other)
        }
        if bodyType == .multipartFormData, fileFormName.isEmpty { throw ShareXImportError.missingFileFormName }

        func request(_ field: String, _ text: String) throws {
            do { _ = try ShareXTemplate(text, scope: .request) } catch let e as ShareXTemplateError {
                throw ShareXImportError.template(field: field, error: e)
            }
        }
        func response(_ field: String, _ text: String) throws {
            do { _ = try ShareXTemplate(text, scope: .response) } catch let e as ShareXTemplateError {
                throw ShareXImportError.template(field: field, error: e)
            }
        }
        try request("RequestURL", requestURL)
        for (key, value) in parameters { try request("Parameters.\(key)", value) }
        for (key, value) in headers { try request("Headers.\(key)", value) }
        for (key, value) in arguments { try request("Arguments.\(key)", value) }
        try response("URL", url)
        try response("ThumbnailURL", thumbnail)
        try response("DeletionURL", deletion)
        try response("ErrorMessage", error)

        let settings = CustomHTTPSettings(
            method: httpMethod,
            requestURL: requestURL.trimmingCharacters(in: .whitespaces),
            parameterNames: parameters.keys.sorted(),
            headerNames: headers.keys.sorted(),
            bodyType: bodyType,
            fileFormName: fileFormName,
            argumentNames: bodyType == .multipartFormData ? arguments.keys.sorted() : [],
            urlTemplate: url,
            deletionURLTemplate: deletion,
            thumbnailURLTemplate: thumbnail,
            errorMessageTemplate: error
        )
        var secrets: [String: String] = [:]
        for (key, value) in parameters { secrets[SecretField.parameter(key)] = value }
        for (key, value) in headers { secrets[SecretField.header(key)] = value }
        if bodyType == .multipartFormData {
            for (key, value) in arguments { secrets[SecretField.argument(key)] = value }
        }

        var displayName = name
        if displayName.isEmpty {
            displayName = URL(string: requestURL.replacingOccurrences(of: "{", with: "").replacingOccurrences(of: "}", with: ""))?.host ?? String(localized: "Custom uploader", bundle: .module)
        }
        let destination = UploadDestination(name: displayName, configuration: .customHTTP(settings))
        return ImportedUploader(destination: destination, secrets: secrets, notes: notes)
    }

    // MARK: Older files

    /// ShareX's `MigrateOldSyntax`: `$json:path$` becomes `{json:path}` and a literal brace is escaped. One
    /// difference: a backslash keeps the character after it as text, where ShareX's conversion drops it.
    static func migrateOldSyntax(_ text: String) -> String {
        guard !text.isEmpty else { return text }
        var out = ""
        var opening = true
        var escaped = false
        for character in text {
            if escaped {
                escaped = false
                if character == "{" || character == "}" || character == "|" || character == "\\" { out.append("\\") }
                out.append(character)
            } else if character == "\\" {
                escaped = true
            } else if character == "$" {
                out.append(opening ? "{" : "}")
                opening.toggle()
            } else {
                if character == "{" || character == "}" { out.append("\\") }
                out.append(character)
            }
        }
        return out
    }

    /// Compares dotted versions number by number; a missing part counts as zero.
    static func compare(_ a: String, _ b: String) -> Int {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }
        let y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let p = i < x.count ? x[i] : 0
            let q = i < y.count ? y[i] : 0
            if p != q { return p < q ? -1 : 1 }
        }
        return 0
    }
}
