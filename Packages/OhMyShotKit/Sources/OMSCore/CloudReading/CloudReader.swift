import CoreGraphics
import CoreText
import Foundation
import OSLog

/// What a cloud model read in a picture.
public struct CloudReading: Equatable, Sendable {
    /// The text, with tables as Markdown pipe tables and formulas as LaTeX between `$` or `$$`.
    public var text: String
    /// The model that answered, as the service names it (a fallback model when the service switched to one).
    public var model: String
    /// False when the model stopped at its length limit, before the end of the text.
    public var isComplete: Bool
    public var inputTokens: Int?
    public var outputTokens: Int?
    /// How many pieces the picture went as, and at what size (1 for its own pixels).
    public var pieces: Int
    public var scale: Double

    public init(text: String, model: String, isComplete: Bool, inputTokens: Int? = nil, outputTokens: Int? = nil, pieces: Int = 1, scale: Double = 1) {
        self.text = text
        self.model = model
        self.isComplete = isComplete
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.pieces = pieces
        self.scale = scale
    }
}

/// Sends a picture to a cloud model and reads the text it answers with, as it streams in.
///
/// Only ever asked by the person, for one picture at a time (Docs/ocr.md › Cloud models). Each reading holds an
/// `ActiveResources` lease and its own ephemeral `URLSession`, invalidated when the reading ends, so nothing is left
/// between readings. Cancelling the task that awaits `read` stops the request. Neither the key nor the text is ever
/// logged.
public final class CloudReader: Sendable {
    let secrets: any SecretStore
    let resources: ActiveResources
    let makeConfiguration: @Sendable () -> URLSessionConfiguration

    /// - Parameter sessionConfiguration: Builds each reading's session configuration; tests install a `URLProtocol`.
    public init(
        secrets: any SecretStore,
        resources: ActiveResources = .shared,
        sessionConfiguration: @escaping @Sendable () -> URLSessionConfiguration = CloudReader.defaultConfiguration
    ) {
        self.secrets = secrets
        self.resources = resources
        self.makeConfiguration = sessionConfiguration
    }

    /// No cookies, no cache. A model may think for a while before its first word, and Anthropic's stream sends a ping
    /// meanwhile, but not every service does: three minutes without a byte ends the reading.
    public static func defaultConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.waitsForConnectivity = false
        configuration.timeoutIntervalForRequest = 180
        configuration.timeoutIntervalForResource = 600
        return configuration
    }

    /// The most a reading asks the model to write: room for a dense page and its tables (non-streaming code is told to
    /// keep under about 16,000 so it never meets an HTTP timeout; this streams, but needs no more).
    static let maxTokens = 16_000

    /// Reads the text in `image` with `model`.
    ///
    /// - Parameters:
    ///   - joinsLines: The lines of each paragraph joined, as Capture Text, Joining Lines asks; else the picture's line
    ///     breaks kept.
    ///   - progress: Told how many characters have come so far, at most ten times a second, on a background queue.
    /// - Throws: `CloudReadingError`, or `CancellationError` when the calling task is cancelled.
    @concurrent
    public func read(
        _ image: CGImage,
        with model: CloudModel,
        joinsLines: Bool = false,
        progress: (@Sendable (Int) -> Void)? = nil
    ) async throws -> CloudReading {
        let key = secrets.secret(CloudModelStore.keyField, of: model.id)
        if let issue = model.issue(hasKey: key != nil) {
            throw model.needsKey && key == nil && model.issue(hasKey: true) == nil ? CloudReadingError.keyMissing : CloudReadingError.notSetUp(issue)
        }
        guard let endpoint = model.endpoint, let host = endpoint.host() else { throw CloudReadingError.notSetUp("") }

        let prepared: CloudPicture.Prepared
        do {
            prepared = try CloudPicture.prepare(image, limits: .of(model.kind))
        } catch {
            throw CloudReadingError.pictureUnusable
        }
        let pieces = prepared.pieces
        let request = try Self.request(for: model, endpoint: endpoint, key: key, pieces: pieces, joinsLines: joinsLines)
        try Task.checkCancellation()

        let lease = resources.acquire(.cloudReading)
        defer { lease.end() }
        let session = URLSession(configuration: makeConfiguration())
        defer { session.invalidateAndCancel() }

        let started = ContinuousClock.now
        let bytes = pieces.reduce(0) { $0 + $1.data.count }
        Log.cloud.notice("Cloud reading at \(host, privacy: .public) with \(model.model, privacy: .public) started: \(pieces.count, privacy: .public) pieces, \(bytes, privacy: .public) bytes, scale \(prepared.scale, privacy: .public)")
        do {
            let (stream, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse else { throw CloudReadingError.unexpectedAnswer }
            guard (200..<300).contains(http.statusCode) else {
                var body = Data()
                for try await byte in stream {
                    body.append(byte)
                    if body.count >= 64 * 1024 { break }
                }
                throw CloudReadingError.from(status: http.statusCode, body: body)
            }
            var answer = CloudAnswer(kind: model.kind, requestedModel: model.model)
            var reported = ContinuousClock.now
            for try await line in stream.lines {
                guard try answer.take(line: line) else { break }
                if let progress, ContinuousClock.now - reported >= .milliseconds(100) {
                    reported = ContinuousClock.now
                    progress(answer.text.count)
                }
            }
            let reading = try answer.reading(pieces: pieces.count, scale: prepared.scale)
            Log.cloud.notice("Cloud reading at \(host, privacy: .public) answered by \(reading.model, privacy: .public): \(reading.text.count, privacy: .public) characters, complete \(reading.isComplete, privacy: .public), tokens \(reading.inputTokens ?? -1, privacy: .public) in and \(reading.outputTokens ?? -1, privacy: .public) out, in \(String(describing: ContinuousClock.now - started), privacy: .public)")
            return reading
        } catch {
            let mapped = CloudReadingError.from(error, host: host)
            if mapped is CancellationError {
                Log.cloud.notice("Cloud reading at \(host, privacy: .public) cancelled")
            } else {
                let reason = (mapped as? CloudReadingError)?.logDescription ?? String(describing: type(of: mapped))
                Log.cloud.error("Cloud reading at \(host, privacy: .public) failed: \(reason, privacy: .public)")
            }
            throw mapped
        }
    }

    // MARK: The request

    /// What the model is asked: the whole text once, as written, with structure only where the picture has it.
    static func instruction(pieces: Int, joinsLines: Bool = false) -> String {
        var lines: [String] = []
        if pieces > 1 {
            lines.append("The \(pieces) pictures above are consecutive parts of one tall picture, top to bottom. Each part overlaps the next by a few lines, so text at a join appears in both: write it once.")
        }
        if joinsLines {
            lines.append("Transcribe all the text in the picture, in reading order, exactly as written. Keep its language, spelling, and punctuation. Join the lines of each paragraph into one line, keeping the breaks between paragraphs, headings, list items, table rows, and lines of code. Don’t translate, correct, summarize, or describe it.")
        } else {
            lines.append("Transcribe all the text in the picture, in reading order, exactly as written. Keep its language, spelling, punctuation, and line breaks. Don’t translate, correct, summarize, or describe it.")
        }
        lines.append("Write tables as Markdown pipe tables, mathematical formulas as LaTeX between $ and $ (between $$ and $$ for a formula on a line of its own), and code with its indentation. Use no other Markdown.")
        lines.append("Answer with the transcription only, with nothing before or after it. If the picture has no text, answer with nothing.")
        return lines.joined(separator: "\n")
    }

    /// Anthropic's models that take an effort; a lower one makes a transcription quicker (not measured for reading).
    private static let effortModels = ["claude-fable-5", "claude-mythos-5", "claude-opus-5", "claude-sonnet-5", "claude-haiku-5", "claude-opus-4-8", "claude-opus-4-7", "claude-opus-4-6", "claude-sonnet-4-6"]

    /// The models Anthropic's server-side fallback takes in its "default" form, on its own API only: a declined reading
    /// is read again by another model instead of coming back refused.
    private static let fallbackModels: Set<String> = ["claude-fable-5-1", "claude-opus-5-5", "claude-opus-5", "claude-sonnet-5-5"]
    static let fallbackBeta = "server-side-fallback-2026-07-01"

    static func request(for model: CloudModel, endpoint: URL, key: String?, pieces: [CloudPicture.Piece], joinsLines: Bool = false) throws -> URLRequest {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        let instruction = instruction(pieces: pieces.count, joinsLines: joinsLines)
        let identifier = model.model.trimmingCharacters(in: .whitespaces)
        var body: [String: Any]
        switch model.kind {
        case .openAICompatible:
            if let key, !key.isEmpty { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
            var content: [[String: Any]] = []
            for (index, piece) in pieces.enumerated() {
                if pieces.count > 1 { content.append(["type": "text", "text": "Part \(index + 1) of \(pieces.count):"]) }
                content.append(["type": "image_url", "image_url": ["url": "data:\(piece.mediaType);base64,\(piece.data.base64EncodedString())"]])
            }
            content.append(["type": "text", "text": instruction])
            // No length limit and no temperature: services name the first differently and some models refuse the second.
            body = ["model": identifier, "stream": true, "messages": [["role": "user", "content": content]]]
        case .anthropic:
            if let key, !key.isEmpty { request.setValue(key, forHTTPHeaderField: "x-api-key") }
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            var content: [[String: Any]] = []
            for (index, piece) in pieces.enumerated() {
                if pieces.count > 1 { content.append(["type": "text", "text": "Part \(index + 1) of \(pieces.count):"]) }
                content.append(["type": "image", "source": ["type": "base64", "media_type": piece.mediaType, "data": piece.data.base64EncodedString()]])
            }
            content.append(["type": "text", "text": instruction])
            // No thinking setting, temperature, or prefill: current models refuse each.
            body = ["model": identifier, "max_tokens": maxTokens, "stream": true, "messages": [["role": "user", "content": content]]]
            if effortModels.contains(where: identifier.hasPrefix) {
                body["output_config"] = ["effort": "low"]
            }
            if fallbackModels.contains(identifier), endpoint.host()?.lowercased() == "api.anthropic.com" {
                body["fallbacks"] = "default"
                request.setValue(fallbackBeta, forHTTPHeaderField: "anthropic-beta")
            }
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys, .withoutEscapingSlashes])
        return request
    }
}

/// The streamed answer, put together line by line from the service's server-sent events.
///
/// Both protocols put each event's JSON on one `data:` line, which is all that is read: event names, comments, and
/// the blank lines between events carry nothing the JSON doesn't.
struct CloudAnswer {
    let kind: CloudModel.Kind
    private(set) var text = ""
    private(set) var model: String
    private(set) var stop: Stop?
    private(set) var inputTokens: Int?
    private(set) var outputTokens: Int?

    enum Stop: Equatable {
        case finished
        case length
        case refused(String?)
    }

    init(kind: CloudModel.Kind, requestedModel: String) {
        self.kind = kind
        model = requestedModel
    }

    /// Takes one line of the stream. Returns false once the stream says it is done.
    mutating func take(line: String) throws -> Bool {
        guard line.hasPrefix("data:") else { return true }
        var payload = line.dropFirst(5)
        if payload.first == " " { payload = payload.dropFirst() }
        if payload == "[DONE]" { return false }
        guard let object = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any] else {
            throw CloudReadingError.unexpectedAnswer
        }
        switch kind {
        case .openAICompatible: try takeChunk(object)
        case .anthropic: return try takeEvent(object)
        }
        return true
    }

    /// A Chat Completions chunk: `choices[0].delta.content`, and once its `finish_reason`.
    private mutating func takeChunk(_ chunk: [String: Any]) throws {
        if let error = chunk["error"] {
            let message = (error as? [String: Any])?["message"] as? String ?? error as? String
            throw CloudReadingError.service(status: 200, message: message)
        }
        if let name = chunk["model"] as? String, !name.isEmpty { model = name }
        if let usage = chunk["usage"] as? [String: Any] {
            inputTokens = usage["prompt_tokens"] as? Int ?? inputTokens
            outputTokens = usage["completion_tokens"] as? Int ?? outputTokens
        }
        guard let choice = (chunk["choices"] as? [[String: Any]])?.first else { return }
        if let delta = choice["delta"] as? [String: Any] {
            // A reasoning model's thoughts come as `reasoning_content` or `reasoning`, which aren't the answer.
            if let content = delta["content"] as? String {
                text += content
            } else if let parts = delta["content"] as? [[String: Any]] {
                for part in parts where part["type"] as? String == "text" {
                    text += part["text"] as? String ?? ""
                }
            }
        }
        switch choice["finish_reason"] as? String {
        case "stop"?: stop = .finished
        case "length"?: stop = .length
        case "content_filter"?: stop = .refused(nil)
        default: break
        }
    }

    /// An event of Anthropic's Messages stream. Returns false at `message_stop`.
    private mutating func takeEvent(_ event: [String: Any]) throws -> Bool {
        switch event["type"] as? String {
        case "message_start":
            let message = event["message"] as? [String: Any]
            if let name = message?["model"] as? String, !name.isEmpty { model = name }
            if let usage = message?["usage"] as? [String: Any] { inputTokens = usage["input_tokens"] as? Int }
        case "content_block_start":
            let block = event["content_block"] as? [String: Any]
            switch block?["type"] as? String {
            case "text":
                text += block?["text"] as? String ?? ""
            case "fallback":
                // The service went on with another model; what came before stays part of the answer.
                if let name = (block?["to"] as? [String: Any])?["model"] as? String { model = name }
            default:
                break
            }
        case "content_block_delta":
            let delta = event["delta"] as? [String: Any]
            // Thinking and its signature aren't the answer.
            if delta?["type"] as? String == "text_delta" { text += delta?["text"] as? String ?? "" }
        case "message_delta":
            let delta = event["delta"] as? [String: Any]
            switch delta?["stop_reason"] as? String {
            case "end_turn"?, "stop_sequence"?: stop = .finished
            case "max_tokens"?: stop = .length
            case "refusal"?:
                let details = delta?["stop_details"] as? [String: Any] ?? event["stop_details"] as? [String: Any]
                stop = .refused(details?["explanation"] as? String)
            default: break
            }
            if let usage = event["usage"] as? [String: Any], let output = usage["output_tokens"] as? Int { outputTokens = output }
        case "message_stop":
            return false
        case "error":
            let error = event["error"] as? [String: Any]
            let message = error?["message"] as? String
            switch error?["type"] as? String {
            case "overloaded_error"?: throw CloudReadingError.overloaded(message)
            case "rate_limit_error"?: throw CloudReadingError.rateLimited(message)
            case "authentication_error"?, "permission_error"?: throw CloudReadingError.keyRejected(message)
            case "not_found_error"?: throw CloudReadingError.notFound(message)
            default: throw CloudReadingError.service(status: 200, message: message)
            }
        default:
            break
        }
        return true
    }

    /// The reading, once the stream has ended.
    func reading(pieces: Int, scale: Double) throws -> CloudReading {
        if case .refused(let detail) = stop { throw CloudReadingError.refused(detail) }
        // A stream that ended without saying why was cut off, unless text came and the service never says (some
        // local servers end with [DONE] alone).
        guard stop != nil || !text.isEmpty else { throw CloudReadingError.unexpectedAnswer }
        return CloudReading(
            text: Self.unwrapped(text), model: model, isComplete: stop != .length,
            inputTokens: inputTokens, outputTokens: outputTokens, pieces: pieces, scale: scale
        )
    }

    /// The text without a code fence the model put around all of it, and without blank lines at its ends.
    static func unwrapped(_ text: String) -> String {
        var lines = text.components(separatedBy: "\n")
        while let first = lines.first, first.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeFirst() }
        while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeLast() }
        if lines.count >= 2,
           let first = lines.first?.trimmingCharacters(in: .whitespaces), first.hasPrefix("```"),
           ["", "text", "plaintext", "markdown", "md"].contains(first.dropFirst(3).lowercased()),
           lines.last?.trimmingCharacters(in: .whitespaces) == "```",
           !lines.dropFirst().dropLast().contains(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("```") }) {
            lines = Array(lines.dropFirst().dropLast())
        }
        return lines.joined(separator: "\n")
    }
}

public extension CloudReader {
    /// The words the test picture shows, which a model that reads pictures gives back.
    static let testText = "Hello from OhMyShot 7421"

    /// A small picture of `testText`, black on white at twice the size it would have on screen, for Settings' Test.
    static func testPicture() -> CGImage? {
        let width = 640, height = 120
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let font = CTFontCreateUIFontForLanguage(.system, 40, nil) ?? CTFontCreateWithName("Helvetica" as CFString, 40, nil)
        let attributes: [NSAttributedString.Key: Any] = [NSAttributedString.Key(kCTFontAttributeName as String): font, NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1)]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: testText, attributes: attributes))
        let bounds = CTLineGetBoundsWithOptions(line, .useOpticalBounds)
        context.textPosition = CGPoint(x: (CGFloat(width) - bounds.width) / 2 - bounds.minX, y: (CGFloat(height) - bounds.height) / 2 - bounds.minY)
        CTLineDraw(line, context)
        return context.makeImage()
    }

    /// Whether a model's answer to the test picture holds its words: the number and the app's name, whatever the
    /// spacing and case.
    static func answersTest(_ text: String) -> Bool {
        let compact = text.lowercased().filter { !$0.isWhitespace }
        return compact.contains("7421") && compact.contains("ohmyshot")
    }
}
