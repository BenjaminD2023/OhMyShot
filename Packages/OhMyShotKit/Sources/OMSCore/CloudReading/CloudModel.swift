import Foundation

/// A model the person reads pictures with at a service they have an account with: the OCR panel's Read with…, for
/// what Vision and the model packs read poorly or not at all, such as handwriting and dense tables (L4,
/// Docs/ocr.md › Cloud models).
///
/// What is saved in the defaults. The service's key is in the Keychain (`CloudModelStore`), never here.
public struct CloudModel: Codable, Hashable, Identifiable, Sendable {
    /// The protocol the service speaks.
    public enum Kind: String, Codable, CaseIterable, Sendable {
        /// Chat Completions with an `image_url` part, which OpenAI, Alibaba Cloud's Qwen, Ollama, LM Studio, and many
        /// others accept.
        case openAICompatible
        /// Anthropic's Messages API.
        case anthropic
    }

    public var id: UUID
    public var kind: Kind
    /// What the person calls it: the panel's button reads "Read with" and this.
    public var name: String
    /// The service's address as its documentation gives it, with its version: "https://api.openai.com/v1".
    public var address: String
    /// The model's identifier at the service.
    public var model: String

    public init(id: UUID = UUID(), kind: Kind, name: String, address: String, model: String) {
        self.id = id
        self.kind = kind
        self.name = name
        self.address = address
        self.model = model
    }

    /// The address requests go to: Chat Completions under the address given, or Anthropic's Messages. Nil when the
    /// address isn't an http or https URL with a host.
    public var endpoint: URL? {
        guard var components = URLComponents(string: address.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = components.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let host = components.host, !host.isEmpty
        else { return nil }
        var path = components.path
        while path.hasSuffix("/") { path.removeLast() }
        switch kind {
        case .openAICompatible:
            // The address carries its version ("/v1", "/compatible-mode/v1", "/api/paas/v4"): nothing is added to it.
            if !path.hasSuffix("/chat/completions") { path += "/chat/completions" }
        case .anthropic:
            if path.hasSuffix("/messages") {
            } else if path.hasSuffix("/v1") {
                path += "/messages"
            } else {
                path += "/v1/messages"
            }
        }
        components.path = path
        components.query = nil
        components.fragment = nil
        return components.url
    }

    /// The host pictures are sent to, as the panel names it before sending: "api.anthropic.com".
    public var host: String? {
        endpoint?.host()
    }

    /// Whether the service runs on this Mac or a private network, where a plain `http://` address is allowed and a
    /// key is often not needed.
    public var isLocal: Bool {
        guard let host = endpoint?.host() else { return false }
        return Self.isLocal(host: host)
    }

    /// This Mac or a private network: `localhost`, `.local` names, and addresses in the loopback, private, and
    /// link-local ranges. An address on the internet written as numbers is not.
    static func isLocal(host: String) -> Bool {
        let host = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if host == "localhost" || host.hasSuffix(".localhost") || host.hasSuffix(".local") { return true }
        if host.contains(":") {
            // IPv6: the loopback, unique local (fc00::/7), and link-local (fe80::/10) addresses.
            if host == "::1" { return true }
            guard let first = host.split(separator: ":", omittingEmptySubsequences: false).first, let word = UInt16(first, radix: 16) else { return false }
            return word & 0xFE00 == 0xFC00 || word & 0xFFC0 == 0xFE80
        }
        let parts = host.split(separator: ".", omittingEmptySubsequences: false).compactMap { UInt8($0) }
        guard parts.count == 4, host.split(separator: ".", omittingEmptySubsequences: false).count == 4 else { return false }
        switch (parts[0], parts[1]) {
        case (127, _), (10, _), (192, 168), (169, 254): return true
        case (172, 16...31): return true
        default: return false
        }
    }

    /// Whether requests carry a key. A service on this Mac or the local network (Ollama, LM Studio) usually takes none.
    public var needsKey: Bool {
        kind == .anthropic || !isLocal
    }

    /// Why the model can't be used as it is, in a sentence for the person; nil when it can.
    public func issue(hasKey: Bool) -> String? {
        if name.trimmingCharacters(in: .whitespaces).isEmpty {
            return String(localized: "Give it a name.", bundle: .module)
        }
        guard let endpoint else {
            return String(localized: "The address must start with https://.", bundle: .module)
        }
        if endpoint.scheme?.lowercased() == "http", !isLocal {
            return String(localized: "Use https:// for a service on the internet. Plain http:// works only on this Mac or your local network.", bundle: .module)
        }
        if model.trimmingCharacters(in: .whitespaces).isEmpty {
            return String(localized: "Enter the model’s name, as the service lists it.", bundle: .module)
        }
        if needsKey, !hasKey {
            return String(localized: "Enter the API key.", bundle: .module)
        }
        return nil
    }
}

public extension CloudModel {
    /// The services the Add menu starts from, each filled in as its documentation gives it (checked 2026-10-18).
    /// Anything else that speaks Chat Completions starts from `other`.
    enum Preset: String, CaseIterable, Identifiable, Sendable {
        case anthropic
        case openAI
        case qwen
        case ollama
        case other

        public var id: String { rawValue }

        public var kind: Kind {
            self == .anthropic ? .anthropic : .openAICompatible
        }

        /// The menu item, and the name a new model starts with.
        public var title: String {
            switch self {
            case .anthropic: "Claude"
            case .openAI: "OpenAI"
            case .qwen: "Qwen"
            case .ollama: "Ollama"
            case .other: String(localized: "Other OpenAI-Compatible Service", bundle: .module)
            }
        }

        public var address: String {
            switch self {
            case .anthropic: "https://api.anthropic.com"
            case .openAI: "https://api.openai.com/v1"
            // Alibaba Cloud Model Studio's Beijing address; other regions and workspaces have their own.
            case .qwen: "https://dashscope.aliyuncs.com/compatible-mode/v1"
            case .ollama: "http://localhost:11434/v1"
            case .other: ""
            }
        }

        /// A model to start with where the service's documentation names one that reads pictures.
        public var model: String {
            switch self {
            case .anthropic: "claude-opus-5-5"
            case .qwen: "qwen3-vl-plus"
            case .openAI, .ollama, .other: ""
            }
        }

        public func makeModel() -> CloudModel {
            CloudModel(kind: kind, name: self == .other ? "" : title, address: address, model: model)
        }
    }
}
