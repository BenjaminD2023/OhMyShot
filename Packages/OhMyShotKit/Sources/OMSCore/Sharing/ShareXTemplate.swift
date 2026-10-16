import Foundation

/// What a server answered, as the templates of a custom uploader see it.
public struct UploadResponse: Sendable {
    public var status: Int
    public var text: String
    /// The address the response came from, after any redirects.
    public var url: URL?
    public var headers: [String: String]

    public init(status: Int, text: String, url: URL? = nil, headers: [String: String] = [:]) {
        self.status = status
        self.text = text
        self.url = url
        self.headers = headers
    }

    func header(_ name: String) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }
}

public enum ShareXTemplateError: Error, LocalizedError, Equatable {
    case unsupportedFunction(String)
    case unavailableHere(function: String)
    case missingParameter(function: String)
    case strayCharacter(Character)
    case unterminated
    case unsupportedJSONPath(String)
    case invalidRegex(String)
    case responseNotJSON
    case responseNotXML
    case invalidXPath(String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedFunction(let name):
            String(localized: "The template uses {\(name)}, which OhMyShot doesn’t support.")
        case .unavailableHere(let name):
            String(localized: "{\(name)} reads the server’s answer, so it only works in the link, thumbnail, deletion and error templates.")
        case .missingParameter(let name):
            String(localized: "{\(name)} needs a value after the colon.")
        case .strayCharacter(let character):
            String(localized: "The template has a “\(String(character))” that isn’t part of a {function}. Write \\\(String(character)) to use it as text.")
        case .unterminated:
            String(localized: "The template has a { without a matching }.")
        case .unsupportedJSONPath(let path):
            String(localized: "The JSON path “\(path)” uses a form OhMyShot doesn’t support; only names, [0] indexes and ['name'] keys are.")
        case .invalidRegex(let pattern):
            String(localized: "The regular expression “\(pattern)” isn’t valid.")
        case .responseNotJSON:
            String(localized: "The server’s answer isn’t JSON, so {json:} can’t read it.")
        case .responseNotXML:
            String(localized: "The server’s answer isn’t XML, so {xml:} can’t read it.")
        case .invalidXPath(let path):
            String(localized: "The XPath “\(path)” isn’t valid.")
        }
    }
}

/// The text language of ShareX custom uploaders: literal text with `{function:parameter|parameter}` calls in it.
///
/// Written against ShareX's own parser (`ShareXSyntaxParser` and the functions beside it): `{`, `}` and `|` are
/// special, `:` after a function's name starts its parameters, `\` makes the next character literal, and a
/// parameter can hold calls of its own (`{json:{response}|data.link}`).
///
/// Supported: `{filename}`, `{random:a|b}`, `{base64:text}` anywhere; `{response}`, `{responseurl}`,
/// `{header:name}`, `{json:path}`, `{json:input|path}`, `{xml:xpath}`, `{xml:input|xpath}`,
/// `{regex:pattern}`, `{regex:pattern|group}`, `{regex:input|pattern|group}` in what reads the answer.
/// `{input}`, `{select:}`, `{inputbox:}` and `{outputbox:}` ask a person or carry text instead of a file and
/// are refused, as is every name ShareX does not have.
public struct ShareXTemplate: Equatable, Sendable {
    /// Where a template is used decides which functions it may call.
    public enum Scope: Sendable {
        /// The request: address, query, headers and form fields. There is no answer yet.
        case request
        /// The link, thumbnail, deletion address and error message, which read the answer.
        case response
    }

    indirect enum Node: Equatable, Sendable {
        case text(String)
        case call(name: String, parameters: [[Node]])
    }

    let nodes: [Node]
    public let source: String

    private static let requestFunctions: Set<String> = ["filename", "random", "base64"]
    private static let responseFunctions: Set<String> = requestFunctions.union(["response", "responseurl", "header", "json", "xml", "regex"])
    private static let refused: Set<String> = ["input", "select", "inputbox", "prompt", "outputbox"]

    /// Reads a template. Throws for a syntax error, a function that does not exist or is refused, or one
    /// used where it cannot work; a JSON path written out in the template is checked too.
    public init(_ text: String, scope: Scope) throws {
        var parser = Parser(characters: Array(text))
        let nodes = try parser.parseTopLevel()
        try Self.validate(nodes, scope: scope)
        self.nodes = nodes
        self.source = text
    }

    private static func validate(_ nodes: [Node], scope: Scope) throws {
        for node in nodes {
            guard case .call(let rawName, let parameters) = node else { continue }
            let name = rawName.lowercased()
            if refused.contains(name) || !responseFunctions.contains(name) {
                throw ShareXTemplateError.unsupportedFunction(rawName)
            }
            if scope == .request, !requestFunctions.contains(name) {
                throw ShareXTemplateError.unavailableHere(function: name)
            }
            let minimum = ["random": 2, "base64": 1, "header": 1, "json": 1, "xml": 1, "regex": 1][name] ?? 0
            if parameters.count < minimum { throw ShareXTemplateError.missingParameter(function: name) }
            for parameter in parameters { try validate(parameter, scope: scope) }
            if name == "json", let path = literalText(parameters.count > 1 ? parameters[1] : parameters[0]) {
                _ = try JSONPath(path)
            }
            if name == "regex", let pattern = literalText(parameters.count > 2 ? parameters[1] : parameters[0]) {
                guard (try? NSRegularExpression(pattern: pattern)) != nil else { throw ShareXTemplateError.invalidRegex(pattern) }
            }
        }
    }

    /// The text of a parameter that has no calls in it, or nil when it depends on the answer.
    private static func literalText(_ nodes: [Node]) -> String? {
        var text = ""
        for node in nodes {
            guard case .text(let part) = node else { return nil }
            text += part
        }
        return text
    }

    // MARK: Evaluating

    public struct Context: Sendable {
        public var fileName: String
        /// Whether `{filename}` is percent-encoded, as it is in addresses.
        public var encodesFileName: Bool
        public var response: UploadResponse?
        public var randomIndex: @Sendable (Int) -> Int

        public init(
            fileName: String,
            encodesFileName: Bool = false,
            response: UploadResponse? = nil,
            randomIndex: @escaping @Sendable (Int) -> Int = { Int.random(in: 0..<$0) }
        ) {
            self.fileName = fileName
            self.encodesFileName = encodesFileName
            self.response = response
            self.randomIndex = randomIndex
        }
    }

    public func evaluate(_ context: Context) throws -> String {
        try Self.evaluate(nodes, context)
    }

    private static func evaluate(_ nodes: [Node], _ context: Context) throws -> String {
        var out = ""
        for node in nodes {
            switch node {
            case .text(let text):
                out += text
            case .call(let rawName, let parameterNodes):
                let parameters = try parameterNodes.map { try evaluate($0, context) }
                out += try call(rawName.lowercased(), parameters, context) ?? ""
            }
        }
        return out
    }

    private static func call(_ name: String, _ p: [String], _ context: Context) throws -> String? {
        let response = context.response ?? UploadResponse(status: 0, text: "")
        switch name {
        case "filename":
            return context.encodesFileName ? SigV4Signer.encode(context.fileName) : context.fileName
        case "random":
            return p[context.randomIndex(p.count)]
        case "base64":
            return p[0].isEmpty ? nil : Data(p[0].utf8).base64EncodedString()
        case "response":
            return response.text
        case "responseurl":
            return response.url?.absoluteString
        case "header":
            return response.header(p[0])
        case "json":
            let (input, path) = p.count > 1 ? (p[0], p[1]) : (response.text, p[0])
            guard !input.isEmpty, !path.isEmpty else { return nil }
            return try JSONPath(path).select(in: input)
        case "xml":
            let (input, path) = p.count > 1 ? (p[0], p[1]) : (response.text, p[0])
            guard !input.isEmpty, !path.isEmpty else { return nil }
            return try xmlValue(input, path)
        case "regex":
            return try regexValue(p, response: response)
        default:
            throw ShareXTemplateError.unsupportedFunction(name)
        }
    }

    private static func xmlValue(_ input: String, _ path: String) throws -> String? {
        guard let document = try? XMLDocument(xmlString: input, options: []) else { throw ShareXTemplateError.responseNotXML }
        guard let nodes = try? document.nodes(forXPath: path) else { throw ShareXTemplateError.invalidXPath(path) }
        return nodes.first?.stringValue
    }

    private static func regexValue(_ p: [String], response: UploadResponse) throws -> String? {
        let input: String, pattern: String, group: String
        if p.count > 2 {
            (input, pattern, group) = (p[0], p[1], p[2])
        } else {
            (input, pattern, group) = (response.text, p[0], p.count > 1 ? p[1] : "")
        }
        guard !input.isEmpty, !pattern.isEmpty else { return nil }
        guard let expression = try? NSRegularExpression(pattern: pattern) else { throw ShareXTemplateError.invalidRegex(pattern) }
        let whole = NSRange(input.startIndex..., in: input)
        guard let match = expression.firstMatch(in: input, range: whole) else { return nil }
        var range = match.range
        if !group.isEmpty {
            range = Int(group).map { $0 < match.numberOfRanges ? match.range(at: $0) : NSRange(location: NSNotFound, length: 0) }
                ?? (pattern.contains("(?<\(group)>") ? match.range(withName: group) : NSRange(location: NSNotFound, length: 0))
        }
        guard range.location != NSNotFound, let swiftRange = Range(range, in: input) else { return nil }
        return String(input[swiftRange])
    }

    // MARK: Parser

    /// ShareX's `ShareXSyntaxParser.Parse`, with a stray `}` or `|` outside a call reported rather than
    /// silently ending the text.
    private struct Parser {
        let characters: [Character]
        var position = 0

        init(characters: [Character]) { self.characters = characters }

        mutating func parseTopLevel() throws -> [Node] {
            let nodes = try parse(isFunction: false)
            if position < characters.count { throw ShareXTemplateError.strayCharacter(characters[position]) }
            return nodes
        }

        /// Reads until an unescaped `}` or `|`, leaving `position` on it. Inside a call's name, a `:` hands
        /// over to its parameters.
        private mutating func parse(isFunction: Bool) throws -> [Node] {
            var nodes: [Node] = []
            var text = ""
            var escaped = false

            func flush() {
                if !text.isEmpty { nodes.append(.text(text)); text = "" }
            }

            while position < characters.count {
                let c = characters[position]
                if !escaped {
                    if c == "{" {
                        position += 1
                        flush()
                        let call = try parse(isFunction: true)
                        guard position < characters.count else { throw ShareXTemplateError.unterminated }
                        position += 1 // past the closing brace
                        nodes += call
                        continue
                    } else if c == "}" || c == "|" {
                        break
                    } else if c == "\\" {
                        escaped = true
                        position += 1
                        continue
                    } else if isFunction && c == ":" {
                        var parameters: [[Node]] = []
                        repeat {
                            position += 1
                            parameters.append(try parse(isFunction: false))
                        } while position < characters.count && characters[position] == "|"
                        guard position < characters.count, characters[position] == "}" else { throw ShareXTemplateError.unterminated }
                        return [.call(name: text.trimmingCharacters(in: .whitespaces), parameters: parameters)]
                    }
                }
                escaped = false
                text.append(c)
                position += 1
            }
            if isFunction {
                guard position < characters.count, characters[position] == "}" else { throw ShareXTemplateError.unterminated }
                return [.call(name: text.trimmingCharacters(in: .whitespaces), parameters: [])]
            }
            flush()
            return nodes
        }
    }
}

// MARK: JSON path

/// The part of JSONPath that link templates use: `data.link`, `files[0].url`, `$.data['link']`, `items[-1]`.
/// Filters, wildcards and recursive descent are not supported and are reported, not guessed at.
struct JSONPath: Equatable {
    enum Step: Equatable {
        case key(String)
        case index(Int)
    }

    let steps: [Step]
    let text: String

    init(_ path: String) throws {
        text = path
        var chars = Array(path)
        if chars.first == "$" { chars.removeFirst() }
        var steps: [Step] = []
        var i = 0
        var expectName = true
        while i < chars.count {
            let c = chars[i]
            if c == "." {
                if i + 1 < chars.count, chars[i + 1] == "." { throw ShareXTemplateError.unsupportedJSONPath(path) }
                i += 1
                expectName = true
            } else if c == "[" {
                guard let close = chars[i...].firstIndex(of: "]") else { throw ShareXTemplateError.unsupportedJSONPath(path) }
                let inner = String(chars[(i + 1)..<close])
                if let index = Int(inner) {
                    steps.append(.index(index))
                } else if inner.count >= 2, let q = inner.first, q == "'" || q == "\"", inner.last == q {
                    steps.append(.key(String(inner.dropFirst().dropLast())))
                } else {
                    throw ShareXTemplateError.unsupportedJSONPath(path)
                }
                i = close + 1
                expectName = false
            } else {
                guard expectName || steps.isEmpty else { throw ShareXTemplateError.unsupportedJSONPath(path) }
                var name = ""
                while i < chars.count, chars[i] != ".", chars[i] != "[" {
                    name.append(chars[i])
                    i += 1
                }
                if name.contains("*") || name.contains("?") || name.contains("(") || name.contains("@") {
                    throw ShareXTemplateError.unsupportedJSONPath(path)
                }
                steps.append(.key(name))
                expectName = false
            }
        }
        self.steps = steps
    }

    /// The value as text, or nil when the path leads nowhere or to `null`.
    func select(in json: String) throws -> String? {
        guard let data = json.data(using: .utf8),
              var value = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        else { throw ShareXTemplateError.responseNotJSON }
        for step in steps {
            switch step {
            case .key(let key):
                guard let object = value as? [String: Any], let next = object[key] else { return nil }
                value = next
            case .index(let index):
                guard let array = value as? [Any] else { return nil }
                let resolved = index < 0 ? array.count + index : index
                guard array.indices.contains(resolved) else { return nil }
                value = array[resolved]
            }
        }
        switch value {
        case is NSNull:
            return nil
        case let string as String:
            return string
        case let number as NSNumber:
            return CFGetTypeID(number) == CFBooleanGetTypeID() ? (number.boolValue ? "true" : "false") : number.stringValue
        default:
            // An object or array: its JSON, as ShareX's token.ToString() gives.
            guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]) else { return nil }
            return String(data: data, encoding: .utf8)
        }
    }
}
