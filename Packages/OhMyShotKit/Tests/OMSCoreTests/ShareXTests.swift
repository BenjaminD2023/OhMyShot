import Foundation
import Testing
@testable import OMSCore

struct ShareXTemplateTests {
    private func evaluate(_ text: String, scope: ShareXTemplate.Scope = .response, response: UploadResponse? = nil, fileName: String = "a b.png", encode: Bool = true) throws -> String {
        try ShareXTemplate(text, scope: scope)
            .evaluate(.init(fileName: fileName, encodesFileName: encode, response: response, randomIndex: { _ in 1 }))
    }

    private let json = UploadResponse(
        status: 200,
        text: #"{"data":{"link":"https://i.example.com/x.png","id":"x1","n":3,"ok":true,"gone":null},"files":[{"url":"https://a/0"},{"url":"https://a/1"}]}"#,
        url: URL(string: "https://api.example.com/upload"),
        headers: ["Location": "https://example.com/loc"]
    )

    @Test func jsonPathsReadNamesIndexesAndKeys() throws {
        #expect(try evaluate("{json:data.link}", response: json) == "https://i.example.com/x.png")
        #expect(try evaluate("{json:$.data.link}", response: json) == "https://i.example.com/x.png")
        #expect(try evaluate("{json:files[1].url}", response: json) == "https://a/1")
        #expect(try evaluate("{json:files[-1].url}", response: json) == "https://a/1")
        #expect(try evaluate("{json:data['id']}", response: json) == "x1")
        #expect(try evaluate("{json:data.n}/{json:data.ok}", response: json) == "3/true")
        #expect(try evaluate("[{json:data.gone}][{json:data.nope}]", response: json) == "[][]")
        #expect(try evaluate("{json:{response}|data.id}", response: json) == "x1")
    }

    @Test func textAroundCallsAndTheOtherResponseFunctions() throws {
        #expect(try evaluate("https://cdn.example.com/{json:data.id}/{filename}", response: json) == "https://cdn.example.com/x1/a%20b.png")
        #expect(try evaluate("{responseurl}", response: json) == "https://api.example.com/upload")
        #expect(try evaluate("{header:location}", response: json) == "https://example.com/loc")
        #expect(try evaluate("{response}", response: UploadResponse(status: 200, text: "plain")) == "plain")
        #expect(try evaluate("{random:a|b|c}", scope: .request) == "b")
        #expect(try evaluate("Basic {base64:user:pass}", scope: .request) == "Basic dXNlcjpwYXNz")
        #expect(try evaluate("{filename}", scope: .request, encode: false) == "a b.png")
    }

    @Test func regexAndXML() throws {
        let page = UploadResponse(status: 200, text: #"<a href="https://x/y.png">y</a>"#)
        #expect(try evaluate(#"{regex:href="(.+?)"|1}"#, response: page) == "https://x/y.png")
        #expect(try evaluate(#"{regex:href="(?<u>.+?)"|u}"#, response: page) == "https://x/y.png")
        #expect(try evaluate(#"{regex:{response}|href="(.+?)"|1}"#, response: page) == "https://x/y.png")
        #expect(try evaluate(#"{regex:nothing here}"#, response: page) == "")
        let xml = UploadResponse(status: 200, text: "<r><file><url>https://x/1</url></file></r>")
        #expect(try evaluate("{xml:/r/file/url}", response: xml) == "https://x/1")
    }

    @Test func escapesKeepSpecialCharactersAsText() throws {
        #expect(try evaluate(#"\{literal\} a\|b \\"#, response: json) == #"{literal} a|b \"#)
    }

    @Test func unsupportedFunctionsAreRefusedWhenTheTemplateIsRead() {
        for text in ["{input}", "{select:a|b}", "{inputbox:Title}", "{outputbox:Hi}", "{prompt:x}", "{nonsense:1}", "{JSON2:x}"] {
            #expect(throws: ShareXTemplateError.self, "\(text)") { try ShareXTemplate(text, scope: .response) }
        }
    }

    @Test func answerFunctionsAreRefusedInTheRequest() {
        #expect(throws: ShareXTemplateError.unavailableHere(function: "json")) { try ShareXTemplate("{json:a}", scope: .request) }
        #expect(throws: ShareXTemplateError.unavailableHere(function: "response")) { try ShareXTemplate("{response}", scope: .request) }
    }

    @Test func syntaxErrorsAndUnsupportedPathsAreReported() {
        #expect(throws: ShareXTemplateError.unterminated) { try ShareXTemplate("{json:a", scope: .response) }
        #expect(throws: ShareXTemplateError.self) { try ShareXTemplate("a } b", scope: .response) }
        #expect(throws: ShareXTemplateError.self) { try ShareXTemplate("a | b", scope: .response) }
        #expect(throws: ShareXTemplateError.unsupportedJSONPath("items[*].url")) { try ShareXTemplate("{json:items[*].url}", scope: .response) }
        #expect(throws: ShareXTemplateError.unsupportedJSONPath("..url")) { try ShareXTemplate("{json:..url}", scope: .response) }
        #expect(throws: ShareXTemplateError.missingParameter(function: "json")) { try ShareXTemplate("{json}", scope: .response) }
        #expect(throws: ShareXTemplateError.self) { try ShareXTemplate("{regex:(}", scope: .response) }
    }

    @Test func aJsonTemplateOnAnHtmlAnswerSaysSo() throws {
        let html = UploadResponse(status: 200, text: "<html>")
        #expect(throws: ShareXTemplateError.responseNotJSON) { try evaluate("{json:a}", response: html) }
    }
}

struct ShareXImporterTests {
    /// An Imgur-style uploader in the current format.
    static let imgur = #"""
    {
      "Version": "16.1.0",
      "Name": "Imgur-like",
      "DestinationType": "ImageUploader, FileUploader",
      "RequestMethod": "POST",
      "RequestURL": "https://api.example.com/3/image?album=abc",
      "Headers": { "Authorization": "Client-ID 0123456789" },
      "Body": "MultipartFormData",
      "Arguments": { "title": "Screenshot {filename}" },
      "FileFormName": "image",
      "URL": "{json:data.link}",
      "ThumbnailURL": "https://i.example.com/{json:data.id}m.png",
      "DeletionURL": "https://example.com/delete/{json:data.deletehash}",
      "ErrorMessage": "{json:data.error}"
    }
    """#

    /// A binary PUT to a storage address.
    static let binaryPut = #"""
    {
      "Version": "15.0.0",
      "DestinationType": "FileUploader",
      "RequestMethod": "PUT",
      "RequestURL": "http://127.0.0.1:9/put/{filename}",
      "Headers": { "X-Token": "s3cret" },
      "Body": "Binary",
      "URL": "http://127.0.0.1:9/f/{filename}"
    }
    """#

    /// A file from before ShareX 13.7.2: `$...$` syntax, `RequestType`, no Body.
    static let old = #"""
    {
      "Name": "Old host",
      "RequestType": "POST",
      "RequestURL": "https://old.example.com/up?key=KEY123",
      "FileFormName": "file",
      "Arguments": { "token": "T0KEN", "name": "$filename$" },
      "ResponseType": "Text",
      "URL": "http://old.example.com/$json:file.url$",
      "ThumbnailURL": "$json:file.thumb$",
      "DeletionURL": "$response$"
    }
    """#

    @Test func aCurrentUploaderImports() throws {
        let imported = try ShareXImporter.importUploader(from: Data(Self.imgur.utf8))
        #expect(imported.destination.name == "Imgur-like")
        guard case .customHTTP(let settings) = imported.destination.configuration else { Issue.record("not custom HTTP"); return }
        #expect(settings.method == .post)
        #expect(settings.requestURL == "https://api.example.com/3/image")
        #expect(settings.parameterNames == ["album"])
        #expect(settings.headerNames == ["Authorization"])
        #expect(settings.argumentNames == ["title"])
        #expect(settings.bodyType == .multipartFormData)
        #expect(settings.fileFormName == "image")
        #expect(settings.urlTemplate == "{json:data.link}")
        #expect(imported.notes.isEmpty)
        // Values are secrets; the model keeps only names.
        #expect(imported.secrets[SecretField.header("Authorization")] == "Client-ID 0123456789")
        #expect(imported.secrets[SecretField.parameter("album")] == "abc")
        #expect(imported.secrets[SecretField.argument("title")] == "Screenshot {filename}")
        let encoded = String(decoding: try JSONEncoder().encode(imported.destination), as: UTF8.self)
        #expect(!encoded.contains("Client-ID") && !encoded.contains("0123456789"))
    }

    @Test func aBinaryPutImports() throws {
        let imported = try ShareXImporter.importUploader(from: Data(Self.binaryPut.utf8))
        guard case .customHTTP(let settings) = imported.destination.configuration else { Issue.record("not custom HTTP"); return }
        #expect(settings.method == .put)
        #expect(settings.bodyType == .binary)
        #expect(settings.argumentNames.isEmpty)
        #expect(imported.destination.name == "127.0.0.1")
    }

    @Test func anOldFileIsConverted() throws {
        let imported = try ShareXImporter.importUploader(from: Data(Self.old.utf8))
        guard case .customHTTP(let settings) = imported.destination.configuration else { Issue.record("not custom HTTP"); return }
        #expect(settings.bodyType == .multipartFormData)
        #expect(settings.method == .post)
        #expect(settings.requestURL == "https://old.example.com/up")
        #expect(settings.parameterNames == ["key"])
        #expect(settings.urlTemplate == "http://old.example.com/{json:file.url}")
        #expect(settings.thumbnailURLTemplate == "{json:file.thumb}")
        #expect(settings.deletionURLTemplate == "{response}")
        #expect(imported.secrets[SecretField.argument("name")] == "{filename}")
        #expect(!imported.notes.isEmpty)
    }

    @Test func oldRedirectResponseTypesFoldIntoTheUrls() throws {
        let file = #"{"RequestType":"POST","RequestURL":"https://h/up","FileFormName":"f","ResponseType":"RedirectionURL"}"#
        let imported = try ShareXImporter.importUploader(from: Data(file.utf8))
        guard case .customHTTP(let settings) = imported.destination.configuration else { return }
        #expect(settings.urlTemplate == "{responseurl}")
        let location = #"{"RequestType":"POST","RequestURL":"https://h/up","FileFormName":"f","ResponseType":"LocationHeader","URL":"$response$/x"}"#
        guard case .customHTTP(let second) = try ShareXImporter.importUploader(from: Data(location.utf8)).destination.configuration else { return }
        #expect(second.urlTemplate == "{header:Location}/x")
    }

    @Test func oldSyntaxEscapesBracesAndKeepsEscapedText() {
        #expect(ShareXImporter.migrateOldSyntax("a{b}$json:x$ \\$") == "a\\{b\\}{json:x} $")
        #expect(ShareXImporter.compare("13.7.1", "13.7.1") == 0)
        #expect(ShareXImporter.compare("12.3", "12.3.1") < 0)
        #expect(ShareXImporter.compare("16.1.0", "13.7.1") > 0)
    }

    @Test func unsupportedThingsAreRefusedWithAReason() {
        func attempt(_ json: String) -> ShareXImportError? {
            do { _ = try ShareXImporter.importUploader(from: Data(json.utf8)); return nil }
            catch { return error as? ShareXImportError }
        }
        let base = #""Version":"16.1.0","RequestURL":"https://h/up","FileFormName":"f""#
        #expect(attempt("not json") == .notAShareXFile)
        #expect(attempt(#"{"Version":"16.1.0"}"#) == .missingRequestURL)
        #expect(attempt("{\(base),\"Body\":\"JSON\",\"Data\":\"{}\"}") == .unsupportedBody("JSON"))
        #expect(attempt("{\(base),\"Body\":\"FormURLEncoded\"}") == .unsupportedBody("FormURLEncoded"))
        #expect(attempt("{\(base),\"Body\":\"None\"}") == .unsupportedBody("None"))
        #expect(attempt("{\(base),\"Body\":\"MultipartFormData\",\"RequestMethod\":\"GET\"}") == .unsupportedMethod("GET"))
        #expect(attempt(#"{"Version":"16.1.0","RequestURL":"https://h/up","Body":"MultipartFormData"}"#) == .missingFileFormName)
        #expect(attempt("{\(base),\"Body\":\"MultipartFormData\",\"DestinationType\":\"URLShortener\"}") == .notAFileUploader)
        #expect(attempt("{\(base),\"Body\":\"MultipartFormData\",\"URL\":\"{input}\"}") == .template(field: "URL", error: .unsupportedFunction("input")))
        #expect(attempt("{\(base),\"Body\":\"MultipartFormData\",\"URL\":\"{json:a[?(@.x)]}\"}") != nil)
        #expect(attempt("{\(base),\"Body\":\"MultipartFormData\",\"Headers\":{\"X\":\"{json:a}\"}}") == .template(field: "Headers.X", error: .unavailableHere(function: "json")))
        #expect(attempt(#"{"RequestType":"POST","RequestURL":"https://h/up","FileFormName":"f","ResponseType":"Headers"}"#) == .deprecatedResponseType)
    }
}
