import CoreGraphics
import Foundation
import Synchronization
import Testing
@testable import OMSCore

/// Answers requests to a host with a status and a body delivered in pieces cut at the byte offsets given, as a
/// stream arrives in packets that split its lines anywhere.
final class CloudStubProtocol: URLProtocol, @unchecked Sendable {
    struct Answer: Sendable {
        var status: Int
        var body: String
        var cuts: [Int] = []
    }

    private static let answers = Mutex<[String: Answer]>([:])
    private static let seen = Mutex<[String: [URLRequest]]>([:])
    private static let bodies = Mutex<[String: [Data]]>([:])

    static func install(host: String, _ answer: Answer) {
        answers.withLock { $0[host] = answer }
        seen.withLock { $0[host] = [] }
        bodies.withLock { $0[host] = [] }
    }

    static func requests(host: String) -> [(request: URLRequest, body: Data)] {
        let requests = seen.withLock { $0[host] ?? [] }
        let datas = bodies.withLock { $0[host] ?? [] }
        return Array(zip(requests, datas))
    }

    static func configuration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CloudStubProtocol.self]
        return configuration
    }

    override class func canInit(with request: URLRequest) -> Bool { answers.withLock { $0[request.url?.host() ?? ""] != nil } }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var body = request.httpBody ?? Data()
        if body.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                body.append(buffer, count: count)
            }
            stream.close()
        }
        let url = request.url!
        let host = url.host() ?? ""
        Self.seen.withLock { $0[host, default: []].append(request) }
        Self.bodies.withLock { $0[host, default: []].append(body) }
        // Status 0: never answers, as a model still thinking, until the request is stopped.
        guard let answer = Self.answers.withLock({ $0[host] }), answer.status != 0 else { return }
        let response = HTTPURLResponse(url: url, statusCode: answer.status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "text/event-stream"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        let data = Data(answer.body.utf8)
        var start = 0
        for cut in answer.cuts.sorted() where cut > start && cut < data.count {
            client?.urlProtocol(self, didLoad: data.subdata(in: start..<cut))
            start = cut
        }
        client?.urlProtocol(self, didLoad: data.subdata(in: start..<data.count))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

struct CloudModelTests {
    @Test func endpointsFollowEachProtocol() {
        func endpoint(_ kind: CloudModel.Kind, _ address: String) -> String? {
            CloudModel(kind: kind, name: "x", address: address, model: "m").endpoint?.absoluteString
        }
        #expect(endpoint(.openAICompatible, "https://api.openai.com/v1") == "https://api.openai.com/v1/chat/completions")
        #expect(endpoint(.openAICompatible, " https://api.openai.com/v1/ ") == "https://api.openai.com/v1/chat/completions")
        #expect(endpoint(.openAICompatible, "https://open.bigmodel.cn/api/paas/v4") == "https://open.bigmodel.cn/api/paas/v4/chat/completions")
        #expect(endpoint(.openAICompatible, "https://x.test/v1/chat/completions") == "https://x.test/v1/chat/completions")
        #expect(endpoint(.openAICompatible, "http://localhost:11434/v1") == "http://localhost:11434/v1/chat/completions")
        #expect(endpoint(.anthropic, "https://api.anthropic.com") == "https://api.anthropic.com/v1/messages")
        #expect(endpoint(.anthropic, "https://api.anthropic.com/") == "https://api.anthropic.com/v1/messages")
        #expect(endpoint(.anthropic, "https://proxy.test/anthropic/v1") == "https://proxy.test/anthropic/v1/messages")
        #expect(endpoint(.anthropic, "https://proxy.test/v1/messages") == "https://proxy.test/v1/messages")
        #expect(endpoint(.openAICompatible, "api.openai.com/v1") == nil)
        #expect(endpoint(.openAICompatible, "ftp://x.test") == nil)
        #expect(endpoint(.openAICompatible, "") == nil)
    }

    @Test func plainHTTPIsOnlyForThisMacAndTheLocalNetwork() {
        func issue(_ address: String, kind: CloudModel.Kind = .openAICompatible, hasKey: Bool = false) -> String? {
            CloudModel(kind: kind, name: "x", address: address, model: "m").issue(hasKey: hasKey)
        }
        #expect(issue("http://localhost:11434/v1") == nil)
        #expect(issue("http://127.0.0.1:1234/v1") == nil)
        #expect(issue("http://192.168.1.20:11434/v1") == nil)
        #expect(issue("http://[::1]:8080/v1") == nil)
        #expect(issue("http://studio.local:11434/v1") == nil)
        #expect(issue("http://10.0.0.8:8080/v1") == nil)
        #expect(issue("http://172.20.1.2:8080/v1") == nil)
        #expect(issue("http://[fd12:3456::1]:8080/v1") == nil)
        // An address on the internet, even written as numbers, needs https.
        #expect(issue("http://203.0.113.5/v1", hasKey: true) != nil)
        #expect(issue("http://172.32.0.1/v1", hasKey: true) != nil)
        #expect(issue("http://[2001:db8::1]/v1", hasKey: true) != nil)
        #expect(CloudModel(kind: .openAICompatible, name: "x", address: "https://203.0.113.5/v1", model: "m").needsKey)
        #expect(issue("http://api.example.com/v1", hasKey: true) != nil)
        #expect(issue("https://api.example.com/v1", hasKey: true) == nil)
        // A service on the internet needs a key; one on this Mac doesn't, unless it's Anthropic's protocol.
        #expect(issue("https://api.example.com/v1") != nil)
        #expect(issue("http://localhost:8080", kind: .anthropic) != nil)
        // A model without a name is called by its host.
        #expect(CloudModel(kind: .openAICompatible, name: " ", address: "https://a.test/v1", model: "m").issue(hasKey: true) == nil)
        #expect(CloudModel(kind: .openAICompatible, name: " ", address: "https://a.test/v1", model: "m").displayName == "a.test")
        #expect(CloudModel(kind: .openAICompatible, name: "a", address: "https://a.test/v1", model: " ").issue(hasKey: true) != nil)
    }

    @Test func presetsAreFilledInAsTheirServicesDocumentThem() {
        let claude = CloudModel.Preset.anthropic.makeModel()
        #expect(claude.kind == .anthropic)
        #expect(claude.endpoint?.absoluteString == "https://api.anthropic.com/v1/messages")
        #expect(claude.model == "claude-opus-5-5")
        #expect(CloudModel.Preset.qwen.makeModel().endpoint?.absoluteString == "https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions")
        let ollama = CloudModel.Preset.ollama.makeModel()
        #expect(ollama.isLocal && !ollama.needsKey)
        #expect(CloudModel.Preset.other.makeModel().name.isEmpty)
        #expect(CloudModel.Preset.qwen.makeModel().preset == .qwen)
        #expect(CloudReader.instruction(pieces: 1, joinsLines: true).contains("Join the lines of each paragraph"))
        #expect(!CloudReader.instruction(pieces: 1).contains("Join the lines"))
    }
}

struct CloudPictureTests {
    private func picture(width: Int, height: Int) throws -> CGImage {
        let context = try #require(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        for row in stride(from: 10, to: height, by: 40) { context.fill(CGRect(x: 10, y: row, width: width / 2, height: 12)) }
        return try #require(context.makeImage())
    }

    @Test func aSmallPictureGoesWholeAtItsOwnSize() {
        let plan = CloudPicture.plan(width: 1200, height: 800, limits: .anthropic)
        #expect(plan.scale == 1)
        #expect(plan.pieces == [0...799])
        // Never enlarged.
        #expect(CloudPicture.plan(width: 90, height: 40, limits: .openAICompatible).scale == 1)
    }

    @Test func aWidePictureIsMadeNoWiderThanTheServiceReads() {
        let plan = CloudPicture.plan(width: 5152, height: 1000, limits: .anthropic)
        #expect(plan.scale == 0.5)
        #expect(plan.pieces.count == 1)
    }

    @Test func aTallPictureIsCutIntoOverlappingPieces() {
        let limits = CloudPicture.Limits.anthropic
        let plan = CloudPicture.plan(width: 1600, height: 9000, limits: limits)
        #expect(plan.scale == 1)
        // 4784 patches of 28 × 28 over 1600 columns: at most 2344 rows a piece.
        let tallest = limits.pixels / 1600
        #expect(plan.pieces.count == 4)
        #expect(plan.pieces.first?.lowerBound == 0)
        #expect(plan.pieces.last?.upperBound == 8999)
        for piece in plan.pieces { #expect(piece.count <= tallest) }
        for (one, next) in zip(plan.pieces, plan.pieces.dropFirst()) {
            #expect(one.upperBound - next.lowerBound + 1 >= limits.overlap)
        }
    }

    @Test func aPictureNeedingTooManyPiecesIsMadeSmaller() {
        let limits = CloudPicture.Limits(longEdge: 1000, pixels: 1000 * 500, pieces: 3, bytes: 1_000_000, overlap: 20, requestBytes: 10_000_000)
        let plan = CloudPicture.plan(width: 1000, height: 8000, limits: limits)
        #expect(plan.pieces.count <= 3)
        #expect(plan.scale < 1)
        #expect(plan.pieces.last?.upperBound == 7999)
    }

    @Test func piecesAreDrawnAndEncoded() throws {
        let image = try picture(width: 800, height: 3000)
        let limits = CloudPicture.Limits(longEdge: 1200, pixels: 800 * 1200, pieces: 8, bytes: 5_000_000, overlap: 32, requestBytes: 20_000_000)
        let prepared = try CloudPicture.prepare(image, limits: limits)
        #expect(prepared.scale == 1)
        let pieces = prepared.pieces
        #expect(pieces.count == 3)
        for piece in pieces {
            #expect(piece.mediaType == "image/png")
            #expect(piece.width == 800)
            #expect(piece.height <= 1200)
            #expect(piece.data.starts(with: [0x89, 0x50, 0x4E, 0x47]))
        }
    }
}

extension CloudPictureTests {
    /// Noise, which PNG can't make smaller.
    private func noise(width: Int, height: Int) throws -> CGImage {
        var generator = SystemRandomNumberGenerator()
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for index in stride(from: 0, to: bytes.count, by: 4) {
            bytes[index] = UInt8.random(in: 0...255, using: &generator)
            bytes[index + 1] = UInt8.random(in: 0...255, using: &generator)
            bytes[index + 2] = UInt8.random(in: 0...255, using: &generator)
        }
        let provider = try #require(CGDataProvider(data: Data(bytes) as CFData))
        return try #require(CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        ))
    }

    @Test func piecesOverTheRequestsSizeGoAsJPEGThenSmaller() throws {
        let image = try noise(width: 600, height: 1800)
        let limits = CloudPicture.Limits(longEdge: 1000, pixels: 600 * 700, pieces: 8, bytes: 5_000_000, overlap: 32, requestBytes: 900_000)
        let prepared = try CloudPicture.prepare(image, limits: limits)
        let carried = prepared.pieces.reduce(0) { $0 + ($1.data.count + 2) / 3 * 4 }
        #expect(carried <= limits.requestBytes)
        #expect(prepared.pieces.allSatisfy { $0.mediaType == "image/jpeg" })
        // As PNG the noise is 4.3 MB; as JPEG at 0.92 still over 0.9 MB: it was made smaller too.
        #expect(prepared.scale < 1)
    }
}

struct CloudAnswerTests {
    private func lines(_ text: String) -> [String] {
        text.components(separatedBy: "\n")
    }

    @Test func chatCompletionChunksMakeTheText() throws {
        var answer = CloudAnswer(kind: .openAICompatible, requestedModel: "asked")
        let stream = """
        : keep-alive

        data: {"model":"qwen3-vl-plus","choices":[{"delta":{"role":"assistant","reasoning_content":"thinking…"}}]}

        data: {"model":"qwen3-vl-plus","choices":[{"delta":{"content":"由此"}}]}

        data: {"choices":[{"delta":{"content":" $x^2$\\n| a | b |"},"finish_reason":null}]}

        data: {"choices":[{"delta":{},"finish_reason":"stop"}],"usage":{"prompt_tokens":1200,"completion_tokens":34}}

        data: [DONE]
        """
        var ended = false
        for line in lines(stream) where !ended { ended = !(try answer.take(line: line)) }
        #expect(ended)
        let reading = try answer.reading(pieces: 1, scale: 1)
        #expect(reading.text == "由此 $x^2$\n| a | b |")
        #expect(reading.model == "qwen3-vl-plus")
        #expect(reading.isComplete)
        #expect(reading.inputTokens == 1200 && reading.outputTokens == 34)
    }

    @Test func aChunkCutAtItsLengthLimitIsIncomplete() throws {
        var answer = CloudAnswer(kind: .openAICompatible, requestedModel: "m")
        _ = try answer.take(line: #"data: {"choices":[{"delta":{"content":"abc"},"finish_reason":"length"}]}"#)
        let reading = try answer.reading(pieces: 1, scale: 1)
        #expect(!reading.isComplete)
        #expect(reading.model == "m")
    }

    @Test func anErrorInTheChunksIsTheServicesMessage() {
        var answer = CloudAnswer(kind: .openAICompatible, requestedModel: "m")
        #expect(throws: CloudReadingError.service(status: 200, message: "model does not support images")) {
            try answer.take(line: #"data: {"error":{"message":"model does not support images","type":"invalid_request_error"}}"#)
        }
    }

    @Test func messagesEventsMakeTheTextAndSkipThinking() throws {
        var answer = CloudAnswer(kind: .anthropic, requestedModel: "claude-opus-5-5")
        let stream = """
        event: message_start
        data: {"type":"message_start","message":{"id":"msg_1","model":"claude-opus-5-5","usage":{"input_tokens":2691,"output_tokens":1}}}

        event: content_block_start
        data: {"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":""}}

        event: content_block_delta
        data: {"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":""}}

        event: content_block_delta
        data: {"type":"content_block_delta","index":0,"delta":{"type":"signature_delta","signature":"abc"}}

        event: ping
        data: {"type":"ping"}

        event: content_block_start
        data: {"type":"content_block_start","index":1,"content_block":{"type":"text","text":""}}

        event: content_block_delta
        data: {"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"Hello, "}}

        event: content_block_delta
        data: {"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"世界"}}

        event: message_delta
        data: {"type":"message_delta","delta":{"stop_reason":"end_turn","stop_sequence":null},"usage":{"output_tokens":12}}

        event: message_stop
        data: {"type":"message_stop"}
        """
        var ended = false
        for line in lines(stream) where !ended { ended = !(try answer.take(line: line)) }
        #expect(ended)
        let reading = try answer.reading(pieces: 2, scale: 0.5)
        #expect(reading.text == "Hello, 世界")
        #expect(reading.isComplete)
        #expect(reading.inputTokens == 2691 && reading.outputTokens == 12)
        #expect(reading.pieces == 2 && reading.scale == 0.5)
    }

    @Test func aFallbackNamesTheModelThatAnswered() throws {
        var answer = CloudAnswer(kind: .anthropic, requestedModel: "claude-opus-5-5")
        _ = try answer.take(line: #"data: {"type":"message_start","message":{"model":"claude-opus-5-5","usage":{"input_tokens":10}}}"#)
        _ = try answer.take(line: #"data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"ab"}}"#)
        _ = try answer.take(line: #"data: {"type":"content_block_start","index":1,"content_block":{"type":"fallback","from":{"model":"claude-opus-5-5"},"to":{"model":"claude-opus-4-8"}}}"#)
        _ = try answer.take(line: #"data: {"type":"content_block_delta","index":2,"delta":{"type":"text_delta","text":"cd"}}"#)
        _ = try answer.take(line: #"data: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":4}}"#)
        let reading = try answer.reading(pieces: 1, scale: 1)
        #expect(reading.text == "abcd")
        #expect(reading.model == "claude-opus-4-8")
    }

    @Test func aRefusalAndALengthStopAreSaid() throws {
        var refused = CloudAnswer(kind: .anthropic, requestedModel: "m")
        _ = try refused.take(line: #"data: {"type":"message_delta","delta":{"stop_reason":"refusal","stop_details":{"type":"refusal","category":"cyber","explanation":"Declined."}}}"#)
        #expect(throws: CloudReadingError.refused("Declined.")) { try refused.reading(pieces: 1, scale: 1) }

        var long = CloudAnswer(kind: .anthropic, requestedModel: "m")
        _ = try long.take(line: #"data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"a"}}"#)
        _ = try long.take(line: #"data: {"type":"message_delta","delta":{"stop_reason":"max_tokens"},"usage":{"output_tokens":16000}}"#)
        #expect(try !long.reading(pieces: 1, scale: 1).isComplete)
    }

    @Test func anErrorEventMidStreamIsThrown() {
        var answer = CloudAnswer(kind: .anthropic, requestedModel: "m")
        #expect(throws: CloudReadingError.overloaded("Overloaded")) {
            try answer.take(line: #"data: {"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#)
        }
    }

    @Test func aStreamThatEndsWithoutAWordIsUnexpected() {
        let answer = CloudAnswer(kind: .anthropic, requestedModel: "m")
        #expect(throws: CloudReadingError.unexpectedAnswer) { try answer.reading(pieces: 1, scale: 1) }
        var garbage = CloudAnswer(kind: .openAICompatible, requestedModel: "m")
        #expect(throws: CloudReadingError.unexpectedAnswer) { try garbage.take(line: "data: <html>") }
    }

    @Test func aFenceAroundEverythingIsTakenOff() {
        #expect(CloudAnswer.unwrapped("```markdown\n| a |\n|---|\n```\n") == "| a |\n|---|")
        #expect(CloudAnswer.unwrapped("\n\nline\n\n") == "line")
        // Code inside the text keeps its fences.
        #expect(CloudAnswer.unwrapped("```swift\nlet a = 1\n```") == "```swift\nlet a = 1\n```")
        #expect(CloudAnswer.unwrapped("```\na\n```\ntext\n```\nb\n```") == "```\na\n```\ntext\n```\nb\n```")
    }

    @Test func errorBodiesGiveTheServicesMessage() {
        #expect(CloudReadingError.from(status: 401, body: Data(#"{"type":"error","error":{"type":"authentication_error","message":"invalid x-api-key"}}"#.utf8)) == .keyRejected("invalid x-api-key"))
        #expect(CloudReadingError.from(status: 404, body: Data(#"{"error":"model \"llava\" not found"}"#.utf8)) == .notFound(#"model "llava" not found"#))
        #expect(CloudReadingError.from(status: 429, body: Data()) == .rateLimited(nil))
        #expect(CloudReadingError.from(status: 529, body: Data()) == .overloaded(nil))
        #expect(CloudReadingError.from(status: 400, body: Data("<html>bad</html>".utf8)) == .service(status: 400, message: nil))
        #expect(CloudReadingError.from(status: 500, body: Data("upstream timed out".utf8)) == .service(status: 500, message: "upstream timed out"))
    }
}

struct CloudReaderTests {
    private func picture() throws -> CGImage {
        let context = try #require(CGContext(
            data: nil, width: 64, height: 32, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 32))
        return try #require(context.makeImage())
    }

    private func json(_ data: Data) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test func anthropicRequestsCarryTheKeyThePictureAndTheFallback() async throws {
        let host = "api.anthropic.com"
        let secrets = InMemorySecretStore()
        let resources = ActiveResources()
        let reader = CloudReader(secrets: secrets, resources: resources, sessionConfiguration: CloudStubProtocol.configuration)
        let model = CloudModel(kind: .anthropic, name: "Claude", address: "https://api.anthropic.com", model: "claude-opus-5-5")
        try secrets.setSecret("sk-ant-test", field: CloudModelStore.keyField, of: model.id)
        let body = """
        event: message_start
        data: {"type":"message_start","message":{"model":"claude-opus-5-5","usage":{"input_tokens":70}}}

        event: content_block_delta
        data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Read me"}}

        event: message_delta
        data: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":3}}

        event: message_stop
        data: {"type":"message_stop"}

        """
        // Cut inside a line, inside a UTF-8 sequence's line, and between lines.
        CloudStubProtocol.install(host: host, .init(status: 200, body: body, cuts: [7, 50, 131, 132, 200]))

        let reading = try await reader.read(try picture(), with: model)
        #expect(reading.text == "Read me")
        #expect(reading.model == "claude-opus-5-5")
        #expect(resources.isIdle)

        let sent = try #require(CloudStubProtocol.requests(host: host).first)
        #expect(sent.request.url?.absoluteString == "https://api.anthropic.com/v1/messages")
        #expect(sent.request.value(forHTTPHeaderField: "x-api-key") == "sk-ant-test")
        #expect(sent.request.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")
        #expect(sent.request.value(forHTTPHeaderField: "anthropic-beta") == "server-side-fallback-2026-07-01")
        #expect(sent.request.value(forHTTPHeaderField: "Authorization") == nil)
        let sentBody = try json(sent.body)
        #expect(sentBody["model"] as? String == "claude-opus-5-5")
        #expect(sentBody["max_tokens"] as? Int == 16_000)
        #expect(sentBody["stream"] as? Bool == true)
        #expect(sentBody["fallbacks"] as? String == "default")
        #expect((sentBody["output_config"] as? [String: Any])?["effort"] as? String == "low")
        #expect(sentBody["thinking"] == nil && sentBody["temperature"] == nil)
        let content = try #require(((sentBody["messages"] as? [[String: Any]])?.first)?["content"] as? [[String: Any]])
        #expect(content.count == 2)
        let source = try #require(content[0]["source"] as? [String: Any])
        #expect(content[0]["type"] as? String == "image")
        #expect(source["media_type"] as? String == "image/png")
        #expect(Data(base64Encoded: source["data"] as? String ?? "")?.starts(with: [0x89, 0x50]) == true)
        #expect((content[1]["text"] as? String)?.contains("Transcribe all the text") == true)
    }

    @Test func noFallbackForOtherModelsOrAddresses() throws {
        let piece = CloudPicture.Piece(data: Data([1]), mediaType: "image/png", width: 1, height: 1)
        for (model, address) in [("claude-haiku-5-5", "https://api.anthropic.com"), ("claude-opus-5-5", "https://proxy.test")] {
            let cloud = CloudModel(kind: .anthropic, name: "c", address: address, model: model)
            let request = try CloudReader.request(for: cloud, endpoint: cloud.endpoint!, key: "k", pieces: [piece])
            let body = try json(request.httpBody!)
            #expect(body["fallbacks"] == nil)
            #expect(request.value(forHTTPHeaderField: "anthropic-beta") == nil)
        }
        // An older model takes no effort.
        let old = CloudModel(kind: .anthropic, name: "c", address: "https://api.anthropic.com", model: "claude-haiku-4-5")
        let request = try CloudReader.request(for: old, endpoint: old.endpoint!, key: "k", pieces: [piece])
        #expect(try json(request.httpBody!)["output_config"] == nil)
    }

    @Test func chatCompletionRequestsCarryABearerKeyAndEveryPieceInOrder() throws {
        let pieces = (1...3).map { CloudPicture.Piece(data: Data([UInt8($0)]), mediaType: $0 == 2 ? "image/jpeg" : "image/png", width: 1, height: 1) }
        let model = CloudModel(kind: .openAICompatible, name: "Qwen", address: "https://dashscope.aliyuncs.com/compatible-mode/v1", model: "qwen3-vl-plus")
        let request = try CloudReader.request(for: model, endpoint: model.endpoint!, key: "sk-test", pieces: pieces)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer sk-test")
        #expect(request.value(forHTTPHeaderField: "x-api-key") == nil)
        let body = try json(request.httpBody!)
        #expect(body["max_tokens"] == nil && body["temperature"] == nil)
        let content = try #require(((body["messages"] as? [[String: Any]])?.first)?["content"] as? [[String: Any]])
        // "Part n of 3:", the piece, three times, then the instruction.
        #expect(content.count == 7)
        #expect(content[0]["text"] as? String == "Part 1 of 3:")
        #expect((content[3]["image_url"] as? [String: Any])?["url"] as? String == "data:image/jpeg;base64,Ag==")
        #expect((content[6]["text"] as? String)?.hasPrefix("The 3 pictures above are consecutive parts") == true)

        // A service on this Mac with no key gets no Authorization header.
        let local = CloudModel(kind: .openAICompatible, name: "Ollama", address: "http://localhost:11434/v1", model: "llava")
        #expect(try CloudReader.request(for: local, endpoint: local.endpoint!, key: nil, pieces: pieces).value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test func errorsAndAMissingKeyAreSaid() async throws {
        let host = "errors.test"
        let secrets = InMemorySecretStore()
        let resources = ActiveResources()
        let reader = CloudReader(secrets: secrets, resources: resources, sessionConfiguration: CloudStubProtocol.configuration)
        let model = CloudModel(kind: .openAICompatible, name: "E", address: "https://\(host)/v1", model: "m")
        await #expect(throws: CloudReadingError.keyMissing) { try await reader.read(try picture(), with: model) }

        try secrets.setSecret("bad", field: CloudModelStore.keyField, of: model.id)
        CloudStubProtocol.install(host: host, .init(status: 401, body: #"{"error":{"message":"Incorrect API key provided","type":"invalid_request_error"}}"#))
        await #expect(throws: CloudReadingError.keyRejected("Incorrect API key provided")) { try await reader.read(try picture(), with: model) }
        #expect(resources.isIdle)
    }

    @Test func cancellingStopsTheReading() async throws {
        let host = "silent.test"
        let secrets = InMemorySecretStore()
        let resources = ActiveResources()
        let reader = CloudReader(secrets: secrets, resources: resources, sessionConfiguration: CloudStubProtocol.configuration)
        let model = CloudModel(kind: .openAICompatible, name: "S", address: "https://\(host)/v1", model: "m")
        try secrets.setSecret("k", field: CloudModelStore.keyField, of: model.id)
        CloudStubProtocol.install(host: host, .init(status: 0, body: ""))
        let image = try picture()
        let task = Task { try await reader.read(image, with: model) }
        try await Task.sleep(for: .milliseconds(300))
        #expect(resources.snapshot[.cloudReading] == 1)
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(resources.isIdle)
    }
}

@MainActor
struct CloudModelStoreTests {
    private func makeStore() throws -> (CloudModelStore, UserDefaults, InMemorySecretStore, () -> Void) {
        let suite = "OMSCoreTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let secrets = InMemorySecretStore()
        return (CloudModelStore(defaults: defaults, secrets: secrets), defaults, secrets, { defaults.removePersistentDomain(forName: suite) })
    }

    @Test func theModelIsKeptWithoutItsKey() throws {
        let (store, defaults, secrets, cleanup) = try makeStore()
        defer { cleanup() }
        #expect(store.model == nil && store.usableModel == nil)
        store.choose(.anthropic)
        let claude = try #require(store.model)
        #expect(claude.model == "claude-opus-5-5")
        // Without its key it can't read yet.
        #expect(store.usableModel == nil)
        try store.setKey("sk-ant-secret")
        #expect(store.hasKey)
        #expect(store.usableModel == claude)
        let saved = String(decoding: try #require(defaults.data(forKey: "cloudModel")), as: UTF8.self)
        #expect(saved.contains("claude-opus-5-5"))
        #expect(!saved.contains("sk-ant-secret"))

        // Edited, it keeps its key; an empty key keeps the saved one.
        var edited = claude
        edited.model = "claude-sonnet-5-5"
        store.update(edited)
        try store.setKey("  ")
        #expect(secrets.secret(CloudModelStore.keyField, of: claude.id) == "sk-ant-secret")
        #expect(CloudModelStore(defaults: defaults, secrets: secrets).model == edited)
    }

    @Test func anotherServiceOrOffTakesTheKeyAway() throws {
        let (store, defaults, secrets, cleanup) = try makeStore()
        defer { cleanup() }
        store.choose(.anthropic)
        try store.setKey("k1")
        store.readsInPanel = true
        store.readsCaptureText = true
        store.choose(.qwen)
        #expect(store.model?.model == "qwen3-vl-plus")
        #expect(secrets.count == 0)
        #expect(store.readsCaptureText)
        try store.setKey("k2")
        store.choose(nil)
        #expect(store.model == nil)
        #expect(secrets.count == 0)
        #expect(!store.readsInPanel && !store.readsCaptureText)
        let reopened = CloudModelStore(defaults: defaults, secrets: secrets)
        #expect(reopened.model == nil && !reopened.readsCaptureText)
    }

    @Test func theFirstCutsModelUsedLastIsKeptWithItsKey() throws {
        let suite = "OMSCoreTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let secrets = InMemorySecretStore()
        let claude = CloudModel(kind: .anthropic, name: "Claude", address: "https://api.anthropic.com", model: "claude-opus-5-5")
        let qwen = CloudModel(kind: .openAICompatible, name: "Qwen", address: "https://dashscope.aliyuncs.com/compatible-mode/v1", model: "qwen3-vl-plus")
        defaults.set(try JSONEncoder().encode([qwen, claude]), forKey: "cloudModels")
        defaults.set(claude.id.uuidString, forKey: "cloudModelPreferred")
        defaults.set(["\(claude.id.uuidString) api.anthropic.com"], forKey: "cloudModelsAgreed")
        try secrets.setSecret("sk-ant", field: CloudModelStore.keyField, of: claude.id)
        try secrets.setSecret("sk-qwen", field: CloudModelStore.keyField, of: qwen.id)

        let store = CloudModelStore(defaults: defaults, secrets: secrets)
        #expect(store.model?.id == claude.id)
        #expect(store.model?.preset == .anthropic)
        #expect(store.hasKey)
        #expect(store.usableModel != nil)
        #expect(secrets.count == 1)
        #expect(defaults.object(forKey: "cloudModels") == nil && defaults.object(forKey: "cloudModelPreferred") == nil && defaults.object(forKey: "cloudModelsAgreed") == nil)
        // Opened again, it stays as it is.
        #expect(CloudModelStore(defaults: defaults, secrets: secrets).model?.id == claude.id)
        #expect(CloudModelStore.preset(of: qwen) == .qwen)
        #expect(CloudModelStore.preset(of: CloudModel(kind: .openAICompatible, name: "", address: "https://openrouter.ai/api/v1", model: "m")) == .other)
    }

    @Test func captureTextReadsWithItOnlyWhenAskedAndReady() throws {
        let (store, _, _, cleanup) = try makeStore()
        defer { cleanup() }
        store.choose(.ollama)
        // Its model's name is the person's to give; then, on this Mac, it needs no key.
        #expect(store.usableModel == nil)
        var ollama = try #require(store.model)
        ollama.model = "qwen2.5vl"
        store.update(ollama)
        #expect(store.usableModel != nil)
        #expect(store.captureTextModel == nil)
        store.readsCaptureText = true
        #expect(store.captureTextModel?.name == "Ollama")
    }
}
