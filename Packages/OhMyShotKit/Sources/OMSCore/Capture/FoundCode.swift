import CoreGraphics
import Foundation

/// A QR code or barcode found in a selection, for the chip over it: what it says, whether it is a square of modules
/// (a QR code) or a row of bars, and where it lies in the picture it was found in, in pixels from the top-left corner.
public struct FoundCode: Sendable, Equatable {
    /// Structured interpretation of common QR/barcode payloads.
    public enum StructuredPayload: Equatable, Sendable {
        case wifi(ssid: String, password: String?, security: String?, hidden: Bool)
        case mailto(address: String, subject: String?, url: URL)
        case phone(number: String, url: URL)
        case contact(name: String?, organization: String?, phone: String?, email: String?, rawVCard: String)
        case web(URL)
    }

    public var payload: String
    public var isMatrix: Bool
    public var box: CGRect

    public init(payload: String, isMatrix: Bool, box: CGRect) {
        self.payload = payload
        self.isMatrix = isMatrix
        self.box = box
    }

    /// Structured payload parsed from `payload`, or `nil` for plain text / unrecognized formats.
    public var structured: StructuredPayload? {
        let trimmed = payload.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let wifi = Self.parseWiFi(trimmed) { return wifi }
        if let contact = Self.parseVCard(trimmed) { return contact }
        if let mailto = Self.parseMailto(trimmed) { return mailto }
        if let phone = Self.parsePhone(trimmed) { return phone }
        if let web = Self.parseWeb(trimmed) { return web }
        return nil
    }

    /// The web page the code points to, which is all a chip may open: a code can carry any URL scheme, and a picture
    /// is no reason to launch whatever app claims it. Nil for any other payload.
    public var webURL: URL? {
        if case .web(let url) = structured { return url }
        return nil
    }

    /// URL safe to open from a code action: strictly limited to allowlisted schemes (`http`, `https`, `mailto`, `tel`).
    public var openableURL: URL? {
        switch structured {
        case .web(let url):
            return url
        case .mailto(_, _, let url):
            return url
        case .phone(_, let url):
            return url
        case .wifi, .contact, nil:
            return nil
        }
    }

    /// Human-readable summary of the code for menus, lists, and VoiceOver.
    public var displaySummary: String {
        switch structured {
        case .wifi(let ssid, _, _, _):
            return String(localized: "Wi-Fi: \(ssid)", bundle: .module)
        case .mailto(let address, _, _):
            return String(localized: "Email: \(address)", bundle: .module)
        case .phone(let number, _):
            return String(localized: "Call: \(number)", bundle: .module)
        case .contact(let name, let organization, let phone, let email, _):
            if let label = name ?? organization ?? email ?? phone {
                return String(localized: "Contact: \(label)", bundle: .module)
            }
            return String(localized: "Contact Card", bundle: .module)
        case .web(let url):
            return url.absoluteString
        case nil:
            return payload
        }
    }

    /// Most useful value to copy directly for this code (e.g., Wi-Fi password when present else SSID; email address; phone number; else raw payload).
    public var primaryCopyValue: String {
        switch structured {
        case .wifi(let ssid, let password, _, _):
            if let password, !password.isEmpty { return password }
            return ssid
        case .mailto(let address, _, _):
            return address
        case .phone(let number, _):
            return number
        case .contact(_, _, _, _, let rawVCard):
            return rawVCard
        case .web, nil:
            return payload
        }
    }

    // MARK: Structured Parsers

    private static func parseWiFi(_ text: String) -> StructuredPayload? {
        guard text.count >= 5, text.prefix(5).lowercased() == "wifi:" else { return nil }
        let body = text.dropFirst(5)
        var ssid: String?
        var password: String?
        var security: String?
        var hidden = false

        for field in splitUnescaped(body, by: ";") where !field.isEmpty {
            guard let colon = field.firstIndex(of: ":") else { continue }
            let key = field[..<colon].uppercased()
            let value = unescapeWiFi(field[field.index(after: colon)...])
            switch key {
            case "S":
                if !value.isEmpty { ssid = value }
            case "P":
                password = value.isEmpty ? nil : value
            case "T":
                security = value.isEmpty ? nil : value
            case "H":
                let lower = value.lowercased()
                hidden = lower == "true" || lower == "1"
            default:
                break
            }
        }
        guard let ssid else { return nil }
        return .wifi(ssid: ssid, password: password, security: security, hidden: hidden)
    }

    private static func parseMailto(_ text: String) -> StructuredPayload? {
        guard text.count > 7, text.prefix(7).lowercased() == "mailto:" else { return nil }
        guard let components = URLComponents(string: text),
              components.scheme?.lowercased() == "mailto" else { return nil }
        let address = components.path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !address.isEmpty, let url = components.url ?? URL(string: text) else { return nil }
        let subject = components.queryItems?
            .first(where: { $0.name.lowercased() == "subject" })?
            .value
            .flatMap { $0.isEmpty ? nil : $0 }
        return .mailto(address: address, subject: subject, url: url)
    }

    private static func parsePhone(_ text: String) -> StructuredPayload? {
        guard text.count > 4, text.prefix(4).lowercased() == "tel:" else { return nil }
        let rawBody = String(text.dropFirst(4))
        let rawNumber = rawBody.split(separator: ";", maxSplits: 1).first.map(String.init) ?? rawBody
        let decoded = (rawNumber.removingPercentEncoding ?? rawNumber).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !decoded.isEmpty, decoded.contains(where: \.isNumber) else { return nil }
        let dialable = decoded.filter { $0.isNumber || "+-*#,".contains($0) }
        guard !dialable.isEmpty,
              let url = URL(string: "tel:\(dialable)"),
              url.scheme?.lowercased() == "tel" else { return nil }
        return .phone(number: decoded, url: url)
    }

    private static func parseVCard(_ text: String) -> StructuredPayload? {
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let upper = normalized.uppercased()
        guard upper.hasPrefix("BEGIN:VCARD"), upper.contains("END:VCARD") else { return nil }
        // Unfold RFC 6350 folded lines (CRLF/LF followed by a single space or horizontal tab).
        let unfolded = normalized
            .replacingOccurrences(of: "\n ", with: "")
            .replacingOccurrences(of: "\n\t", with: "")

        var formattedName: String?
        var structuredName: String?
        var organization: String?
        var phone: String?
        var email: String?

        for line in unfolded.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let rawHeader = line[..<colon]
            let rawValue = line[line.index(after: colon)...]
            var property = (rawHeader.split(separator: ";", maxSplits: 1).first.map(String.init) ?? "").uppercased()
            if let dot = property.lastIndex(of: ".") {
                property = String(property[property.index(after: dot)...])
            }
            switch property {
            case "FN":
                let val = unescapeVCard(rawValue).trimmingCharacters(in: .whitespacesAndNewlines)
                if formattedName == nil, !val.isEmpty { formattedName = val }
            case "N":
                if structuredName == nil {
                    let parts = splitUnescaped(rawValue, by: ";").map { unescapeVCard($0[...]).trimmingCharacters(in: .whitespacesAndNewlines) }
                    let family = parts.count > 0 ? parts[0] : ""
                    let given = parts.count > 1 ? parts[1] : ""
                    let additional = parts.count > 2 ? parts[2] : ""
                    let prefix = parts.count > 3 ? parts[3] : ""
                    let suffix = parts.count > 4 ? parts[4] : ""
                    let combined = [prefix, given, additional, family, suffix].filter { !$0.isEmpty }.joined(separator: " ")
                    if !combined.isEmpty { structuredName = combined }
                }
            case "ORG":
                if organization == nil {
                    let parts = splitUnescaped(rawValue, by: ";")
                        .map { unescapeVCard($0[...]).trimmingCharacters(in: .whitespacesAndNewlines) }
                        .filter { !$0.isEmpty }
                    if !parts.isEmpty { organization = parts.joined(separator: ", ") }
                }
            case "TEL":
                if phone == nil {
                    var val = unescapeVCard(rawValue).trimmingCharacters(in: .whitespacesAndNewlines)
                    if val.lowercased().hasPrefix("tel:") { val = String(val.dropFirst(4)) }
                    if !val.isEmpty { phone = val }
                }
            case "EMAIL":
                if email == nil {
                    let val = unescapeVCard(rawValue).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !val.isEmpty { email = val }
                }
            default:
                break
            }
        }
        return .contact(name: formattedName ?? structuredName, organization: organization, phone: phone, email: email, rawVCard: text)
    }

    private static func parseWeb(_ text: String) -> StructuredPayload? {
        guard let url = URL(string: text),
              let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              let host = url.host, !host.isEmpty else { return nil }
        return .web(url)
    }

    private static func splitUnescaped(_ text: Substring, by separator: Character) -> [String] {
        var fields: [String] = []
        var current = ""
        var escaped = false
        for ch in text {
            if escaped {
                current.append("\\")
                current.append(ch)
                escaped = false
            } else if ch == "\\" {
                escaped = true
            } else if ch == separator {
                fields.append(current)
                current = ""
            } else {
                current.append(ch)
            }
        }
        if escaped { current.append("\\") }
        fields.append(current)
        return fields
    }

    private static func unescapeWiFi(_ text: Substring) -> String {
        var out = ""
        var escaped = false
        for ch in text {
            if escaped {
                out.append(ch)
                escaped = false
            } else if ch == "\\" {
                escaped = true
            } else {
                out.append(ch)
            }
        }
        if escaped { out.append("\\") }
        return out
    }

    private static func unescapeVCard(_ text: Substring) -> String {
        var out = ""
        var escaped = false
        for ch in text {
            if escaped {
                switch ch {
                case "n", "N": out.append("\n")
                default: out.append(ch)
                }
                escaped = false
            } else if ch == "\\" {
                escaped = true
            } else {
                out.append(ch)
            }
        }
        if escaped { out.append("\\") }
        return out
    }
}

/// What a selection needs to put chips over the codes in it: whether Settings want them, and a way to find them in a
/// picture. Finding them takes a decoder the capture and annotation modules do not have, so the app supplies it.
public struct CodeFinder: Sendable {
    /// Asked before each look: whether selections show the codes in them now.
    public var isOn: @MainActor @Sendable () -> Bool
    /// The codes in a picture (boxes in its pixels, origin at the top left). Called off the main actor.
    public var find: @Sendable (CGImage) async -> [FoundCode]

    public init(isOn: @escaping @MainActor @Sendable () -> Bool, find: @escaping @Sendable (CGImage) async -> [FoundCode]) {
        self.isOn = isOn
        self.find = find
    }
}

/// The words the chips over a selection's codes use, kept here so in-place annotation and All-In-One's frame say the
/// same.
public enum CodeChipWording {
    public static var qrCode: String { String(localized: "QR Code", bundle: .module) }
    public static var barcode: String { String(localized: "Barcode", bundle: .module) }
    public static func codes(_ count: Int) -> String { String(localized: "\(count) Codes", bundle: .module) }
    public static var copy: String { String(localized: "Copy", bundle: .module) }
    public static var openLink: String { String(localized: "Open Link", bundle: .module) }
    public static var copied: String { String(localized: "Copied", bundle: .module) }
    /// What VoiceOver hears when the codes in a selection have been found.
    public static func found(_ count: Int) -> String {
        count == 1
            ? String(localized: "Found a code in the selection. Press Q to see what it says.", bundle: .module)
            : String(localized: "Found \(count) codes in the selection. Press Q to go through them.", bundle: .module)
    }
}
