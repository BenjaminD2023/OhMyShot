import Foundation

/// What the Share extension asks of the app once it has put the pictures a person shared in the Share Inbox:
/// `<scheme>://share?id=<batch>&action=annotate` (or `pin`).
///
/// It is not one of the CleanShot-compatible commands and is kept out of `AutomationCommand`: choosing
/// OhMyShot in a Share menu is the approval, so it does not go through the automation gate, and Settings'
/// Automation switch does not turn it off. The URL carries no path; the batch is a name the app looks up in
/// its own inbox (see `ShareInbox`), and nothing else can be reached through it.
public struct ShareHandoff: Equatable, Sendable {
    public enum Action: String, Sendable, CaseIterable {
        /// Open each picture in the editor.
        case annotate
        /// Pin each picture to the screen.
        case pin
    }

    public static let host = "share"

    public let batch: UUID
    public let action: Action

    public init(batch: UUID, action: Action) {
        self.batch = batch
        self.action = action
    }

    public func url(scheme: String) -> URL {
        var components = URLComponents()
        components.scheme = scheme
        components.host = Self.host
        components.queryItems = [URLQueryItem(name: "id", value: batch.uuidString), URLQueryItem(name: "action", value: action.rawValue)]
        return components.url ?? URL(string: "\(scheme)://\(Self.host)")!
    }

    /// Whether `url` is a hand-over, whatever else is wrong with it.
    public static func isHandoff(_ url: URL, scheme: String) -> Bool {
        url.scheme?.lowercased() == scheme.lowercased() && url.host(percentEncoded: false)?.lowercased() == host
    }

    public static func parse(_ url: URL, scheme: String) -> Result<ShareHandoff, AutomationURLError> {
        guard url.scheme?.lowercased() == scheme.lowercased() else { return .failure(.wrongScheme(url.scheme)) }
        guard isHandoff(url, scheme: scheme) else { return .failure(.unknownCommand(url.host(percentEncoded: false) ?? "")) }
        var parameters: [String: String] = [:]
        for item in URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [] {
            parameters[item.name.lowercased()] = item.value ?? ""
        }
        guard let rawID = parameters["id"] else { return .failure(.missingParameter("id")) }
        guard let batch = UUID(uuidString: rawID) else { return .failure(.invalidParameter(name: "id", value: rawID)) }
        guard let rawAction = parameters["action"] else { return .failure(.missingParameter("action")) }
        guard let action = Action(rawValue: rawAction.lowercased()) else {
            return .failure(.invalidParameter(name: "action", value: rawAction))
        }
        return .success(ShareHandoff(batch: batch, action: action))
    }
}
