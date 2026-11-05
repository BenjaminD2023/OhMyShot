import Foundation

/// Which build of the app this is: its bundle identifier, which a debug build has apart from a release build, so the
/// two keep their own folders, settings, keychain items, and log, and never read each other's.
public enum AppIdentity {
    public static let bundleIdentifier = Bundle.main.bundleIdentifier ?? "io.github.fzlzjerry.ohmyshot"

    /// The name the app goes by in windows' titles and menus: a debug build's says so ("OhMyShot Dev").
    public static var displayName: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "OhMyShot"
    }
}

/// The app's own folders, named by its bundle identifier: in Application Support, what it keeps (the history, the
/// uploads, the model packs, recordings in progress, the Share inbox); in Caches, what it can make again.
public enum AppFolders {
    public static var support: URL {
        URL.applicationSupportDirectory.appending(path: AppIdentity.bundleIdentifier, directoryHint: .isDirectory)
    }

    public static var caches: URL {
        URL.cachesDirectory.appending(path: AppIdentity.bundleIdentifier, directoryHint: .isDirectory)
    }
}

extension JSONEncoder {
    /// How the app writes the records it keeps in its folders (a capture's sidecar in the history, the uploads, a
    /// model pack's receipt): dates in ISO 8601, pretty-printed with sorted keys for whoever opens one.
    public static var records: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}

extension JSONDecoder {
    /// How the app reads the records it keeps: dates in ISO 8601, as `JSONEncoder.records` writes them.
    public static var records: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
