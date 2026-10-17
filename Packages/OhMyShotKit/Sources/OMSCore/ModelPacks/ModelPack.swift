import Foundation

/// A set of files the app can download to read text it reads poorly on its own: a Core ML model and what goes
/// with it, its license among them.
///
/// Packs are listed in the app (`ModelPackCatalog`), never fetched from a server: what a pack is, where it comes
/// from, and what each file must hash to are fixed when the app is built. Each file is fetched from the first
/// mirror that answers, by its path under the mirror's base, and kept only if its size and SHA-256 match.
public struct ModelPack: Codable, Hashable, Identifiable, Sendable {
    /// Stable across versions: "ppocr-v6-small". Names the pack's folder.
    public let id: String
    /// Changes whenever any file does; a new version replaces the old one.
    public let version: String
    /// What the pack is for, for Settings: "Chinese and vertical text".
    public let name: String
    /// One sentence on what it improves.
    public let summary: String
    public let license: License
    /// The model as its authors published it, for the person to look at before downloading.
    public let original: URL
    /// The host's name, for "from Hugging Face" before the download starts.
    public let host: String
    /// Base addresses the files are fetched under, tried in order: the host first, then its mirrors. Each ends
    /// with "/" and names a fixed revision, so a file's content never changes under its address.
    public let mirrors: [URL]
    public let files: [File]

    public struct License: Codable, Hashable, Sendable {
        /// "Apache-2.0".
        public let name: String
        /// The pack's own file holding the license's text, and any notice and what was changed: shown before
        /// the download starts and kept with the files.
        public let file: String
        /// Where the license is published.
        public let url: URL

        public init(name: String, file: String, url: URL) {
            self.name = name
            self.file = file
            self.url = url
        }
    }

    public struct File: Codable, Hashable, Sendable {
        /// Relative to the mirror's base and to the pack's folder, with "/" between folders.
        public let path: String
        public let size: Int64
        /// Lowercase hexadecimal, 64 characters.
        public let sha256: String

        public init(path: String, size: Int64, sha256: String) {
            self.path = path
            self.size = size
            self.sha256 = sha256
        }
    }

    public init(
        id: String, version: String, name: String, summary: String, license: License, original: URL, host: String,
        mirrors: [URL], files: [File]
    ) {
        self.id = id
        self.version = version
        self.name = name
        self.summary = summary
        self.license = license
        self.original = original
        self.host = host
        self.mirrors = mirrors
        self.files = files
    }

    /// Every file's size, added up: what the download takes and the disk keeps.
    public var size: Int64 { files.reduce(0) { $0 + $1.size } }

    /// Why a pack can't be used as listed, or nil when it can. The catalog is part of the app, so these are
    /// mistakes in a build; checked anyway, since every path lands on the disk.
    public var problem: String? {
        guard Self.isName(id), Self.isName(version) else { return "id and version must be letters, digits, “.”, “-”, or “_”" }
        guard !mirrors.isEmpty else { return "no mirrors" }
        for mirror in mirrors where (mirror.scheme != "https" && !Self.isLocal(mirror)) || !mirror.absoluteString.hasSuffix("/") {
            return "mirror \(mirror.absoluteString) must be https and end with “/”"
        }
        guard !files.isEmpty else { return "no files" }
        var seen = Set<String>()
        for file in files {
            guard Self.isRelativePath(file.path) else { return "file path \(file.path) is not a plain relative path" }
            guard seen.insert(file.path).inserted else { return "file \(file.path) is listed twice" }
            guard file.size > 0 else { return "file \(file.path) has no size" }
            guard file.sha256.count == 64, file.sha256.allSatisfy({ $0.isHexDigit && !$0.isUppercase }) else {
                return "file \(file.path) has no lowercase SHA-256"
            }
        }
        guard seen.contains(license.file) else { return "the license file \(license.file) is not one of the files" }
        return nil
    }

    /// The address of `file` under `mirror`, each folder of its path percent-encoded.
    public func url(of file: File, at mirror: URL) -> URL {
        var url = mirror
        for component in file.path.split(separator: "/") {
            url.append(path: String(component), directoryHint: .notDirectory)
        }
        return url
    }

    /// Letters, digits, ".", "-", "_"; not "." or "..".
    static func isName(_ text: String) -> Bool {
        !text.isEmpty && text != "." && text != ".."
            && text.unicodeScalars.allSatisfy { ($0.isASCII && CharacterSet.alphanumerics.contains($0)) || ".-_".unicodeScalars.contains($0) }
    }

    /// Folders and a file name joined by "/", each a name of its own: nothing absolute, empty, ".", or "..".
    static func isRelativePath(_ path: String) -> Bool {
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        return !components.isEmpty && components.allSatisfy { component in
            !component.isEmpty && component != "." && component != ".." && !component.contains("\\") && !component.hasPrefix("~")
        }
    }

    /// A mirror on this Mac, which scripted checks of Debug builds serve packs from over plain HTTP.
    static func isLocal(_ url: URL) -> Bool {
        #if DEBUG
        url.scheme == "http" && (url.host() == "127.0.0.1" || url.host() == "localhost")
        #else
        false
        #endif
    }
}

/// The packs this build of the app offers.
public enum ModelPackCatalog {
    /// A listed pack shows in Settings › Tools. With nothing here, nothing in the app mentions packs.
    public static let packs: [ModelPack] = [ppocrV6Small]

    /// PP-OCRv6 small, converted to Core ML by `Tools/model-packs/ppocr_pack.py` and published on Hugging Face
    /// (Docs/ocr.md › The L2 pack): the OCR panel and the history's search read Chinese and Japanese with it beside
    /// Vision (Docs/ocr.md › L2 beside L1).
    public static let ppocrV6Small = ModelPack(
        id: "ppocr-v6-small", version: "1",
        name: "Chinese and Japanese Text",
        summary: "PP-OCRv6 small, by PaddlePaddle: reads Chinese and Japanese more accurately than macOS alone, in the OCR panel and in History’s search.",
        license: .init(name: "Apache-2.0", file: "LICENSE.txt", url: URL(string: "https://www.apache.org/licenses/LICENSE-2.0")!),
        original: URL(string: "https://huggingface.co/PaddlePaddle/PP-OCRv6_small_rec_safetensors")!,
        host: "Hugging Face",
        mirrors: [
            URL(string: "https://huggingface.co/MoraxCheng/ohmyshot-ppocrv6-small-coreml/resolve/f163489663ba2ef788f3389c61d21c7308cc554d/")!,
        ],
        files: [
            .init(path: "LICENSE.txt", size: 12_908, sha256: "5f7fc4aa305806b58f7af85ebf9e53e6606c123ca072fd4a2c191d28be171b24"),
            .init(path: "README.md", size: 2_755, sha256: "5651210cd5fae52ce84b66769b10a472b0ea5ce870b62200879a504456fddb8a"),
            .init(path: "characters.txt", size: 74_947, sha256: "b5f2bfe2bdd9448429e3e82b51c789775d9b42f2403d082b00662eb77e401c5d"),
            .init(path: "config.json", size: 1_454, sha256: "532d3b8de4a7db91b44d6060d94b7af230e499220b9bf7d30cd44a59e2967844"),
            .init(path: "det.mlpackage/Data/com.apple.CoreML/model.mlmodel", size: 149_812, sha256: "8ff7967a757094778b2d9904e92cebe57085ee1b41e835c9fe058f65583814e1"),
            .init(path: "det.mlpackage/Data/com.apple.CoreML/weights/weight.bin", size: 4_917_760, sha256: "760b5b4d71b54fae8521b0ed0e9e6472dbfc7dc4daba64127d0f5dd0e43c521f"),
            .init(path: "det.mlpackage/Manifest.json", size: 617, sha256: "51c190e89418bc3bd8d58eb9703a578be8db3ad85e056405169c7865ac9ab667"),
            .init(path: "rec.mlpackage/Data/com.apple.CoreML/model.mlmodel", size: 125_785, sha256: "b7eea06ca12d55de352406e8154fd5766d035e2a44c72a7e88be34ddf4d9fd47"),
            .init(path: "rec.mlpackage/Data/com.apple.CoreML/weights/weight.bin", size: 10_543_020, sha256: "737e0cf4201e3d9af0f94a8ced930d0957387c5f97947468f18da5ed89d11f61"),
            .init(path: "rec.mlpackage/Manifest.json", size: 617, sha256: "ff90ccc14f03204f7684eb7213feaf9faf509395dd18bc9758b6a738b6455986"),
        ]
    )
}
