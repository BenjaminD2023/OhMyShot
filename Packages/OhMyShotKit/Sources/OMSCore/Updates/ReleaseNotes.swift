import Foundation

/// Release notes travel inside the signed app, so the welcome window works offline.
public enum ReleaseNotes {
    public static func section(in changelog: String, version: String) -> String? {
        let lines = changelog.components(separatedBy: .newlines)
        guard let start = lines.firstIndex(where: { $0 == "## [\(version)]" || $0.hasPrefix("## [\(version)] - ") }) else { return nil }
        let end = lines[(start + 1)...].firstIndex(where: { $0.hasPrefix("## [") }) ?? lines.endIndex
        let references = lines.filter { $0.hasPrefix("[") && $0.contains("]: ") }
        return (Array(lines[(start + 1)..<end]) + references).joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Resolve reference-style links as well as ordinary inline Markdown, using the whole document's definitions.
    public static func inline(_ text: String, referencesIn document: String) -> AttributedString {
        let definitions = document.components(separatedBy: .newlines).filter { $0.hasPrefix("[") && $0.contains("]: ") }.joined(separator: "\n")
        return (try? AttributedString(markdown: text + "\n\n" + definitions)) ?? AttributedString(text)
    }

    public static func shouldShow(previousBuild: String?, currentBuild: String) -> Bool {
        // A first launch has no baseline; the first release with this feature welcomes existing users too.
        guard let previousBuild else { return true }
        return currentBuild.compare(previousBuild, options: .numeric) == .orderedDescending
    }
}

/// Only the project's release assets may be routed through the first-party transport.
public enum UpdateTransport {
    public static let feed = URL(string: "https://www.ohmyshot.org/updates/appcast")!
    public static let fallbackFeed = URL(string: "https://github.com/MMFoundation/OhMyShot/releases/latest/download/appcast.xml")!

    public static func mirroredDownload(_ url: URL) -> URL? {
        guard url.scheme == "https", url.host == "github.com", url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil else { return nil }
        let parts = url.pathComponents
        guard parts.count == 7, parts[1].lowercased() == "mmfoundation", parts[2].lowercased() == "ohmyshot",
              parts[3] == "releases", parts[4] == "download",
              parts[5].range(of: #"^v\d+\.\d+\.\d+$"#, options: .regularExpression) != nil,
              parts[6] == "OhMyShot-\(parts[5].dropFirst()).zip" else { return nil }
        return URL(string: "https://www.ohmyshot.org/updates/download/\(parts[5])/\(parts[6])")
    }
}
