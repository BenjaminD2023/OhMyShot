import Foundation

/// Something in recognized text that can be acted on: a link, an email address, a phone number, a date,
/// or an address.
public struct DetectedItem: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case link
        case email
        case phone
        case date
        case address
    }

    public var kind: Kind
    /// Where it is in the text, in UTF-16 units.
    public var range: NSRange
    public var text: String
    /// What opening it means: the page, a new mail, a call.
    public var url: URL?
    public var date: Date?
}

/// Finds actionable items with the system's data detectors.
public enum TextDetector {
    public static func items(in text: String) -> [DetectedItem] {
        let types: NSTextCheckingResult.CheckingType = [.link, .phoneNumber, .date, .address]
        guard let detector = try? NSDataDetector(types: types.rawValue) else { return [] }
        let string = text as NSString
        return detector.matches(in: text, range: NSRange(location: 0, length: string.length)).compactMap { match in
            let matched = string.substring(with: match.range)
            switch match.resultType {
            case .link:
                // Only web and mail links: recognized text should never launch whatever app claims a scheme.
                guard let url = match.url, ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "") else { return nil }
                let kind: DetectedItem.Kind = url.scheme == "mailto" ? .email : .link
                return DetectedItem(kind: kind, range: match.range, text: matched, url: url)
            case .phoneNumber:
                let digits = (match.phoneNumber ?? matched).filter { $0.isNumber || $0 == "+" }
                return DetectedItem(kind: .phone, range: match.range, text: matched, url: URL(string: "tel:\(digits)"))
            case .date:
                return DetectedItem(kind: .date, range: match.range, text: matched, date: match.date)
            case .address:
                let query = matched.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
                return DetectedItem(kind: .address, range: match.range, text: matched, url: URL(string: "maps://?q=\(query)"))
            default:
                return nil
            }
        }
    }
}
