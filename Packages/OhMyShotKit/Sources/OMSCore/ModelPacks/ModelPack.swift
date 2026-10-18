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
    public static let packs: [ModelPack] = [ppocrV6Small, ppFormulaNetPlusL]

    /// PP-OCRv6 small, converted to Core ML by `Tools/model-packs/ppocr_pack.py` and published on Hugging Face
    /// (Docs/ocr.md › The L2 pack): the OCR panel and the history's search read Chinese and Japanese with it beside
    /// Vision (Docs/ocr.md › L2 beside L1). Version 2 applies the recognizer's last layer on the CPU (Docs/ocr.md › The
    /// recognizer's head on the CPU). Version 1 isn't read by this build; its folder goes when Settings › Tools next
    /// reads the packs (`ModelPackCenter.refresh`).
    public static let ppocrV6Small = ModelPack(
        id: "ppocr-v6-small", version: "2",
        name: String(localized: "Chinese and Japanese Text", bundle: .module),
        summary: String(
            localized: "PP-OCRv6 small, by PaddlePaddle: reads Chinese and Japanese more accurately than macOS alone, in the OCR panel and in History’s search.",
            bundle: .module
        ),
        license: .init(name: "Apache-2.0", file: "LICENSE.txt", url: URL(string: "https://www.apache.org/licenses/LICENSE-2.0")!),
        original: URL(string: "https://huggingface.co/PaddlePaddle/PP-OCRv6_small_rec_safetensors")!,
        host: "Hugging Face",
        mirrors: [
            URL(string: "https://huggingface.co/MoraxCheng/ohmyshot-ppocrv6-small-coreml/resolve/787b19abc12b19a2b3faa3258777a330036ef222/")!,
        ],
        files: [
            .init(path: "LICENSE.txt", size: 13_152, sha256: "c8e0ae636676938d6f308effebe902feec5c6c98db2a306e759f779e2500b0d2"),
            .init(path: "README.md", size: 3_405, sha256: "e3b3abd7866b789e1f90c052ba86031fdfc694a3aca64bc1011b7e27aafd979d"),
            .init(path: "characters.txt", size: 74_947, sha256: "b5f2bfe2bdd9448429e3e82b51c789775d9b42f2403d082b00662eb77e401c5d"),
            .init(path: "config.json", size: 1_573, sha256: "da718a051053ee52587156345219bb486c6173b58e280c1e613af1b7ef92c8f8"),
            .init(path: "det.mlpackage/Data/com.apple.CoreML/model.mlmodel", size: 149_812, sha256: "8ff7967a757094778b2d9904e92cebe57085ee1b41e835c9fe058f65583814e1"),
            .init(path: "det.mlpackage/Data/com.apple.CoreML/weights/weight.bin", size: 4_917_760, sha256: "760b5b4d71b54fae8521b0ed0e9e6472dbfc7dc4daba64127d0f5dd0e43c521f"),
            .init(path: "det.mlpackage/Manifest.json", size: 617, sha256: "51c190e89418bc3bd8d58eb9703a578be8db3ad85e056405169c7865ac9ab667"),
            .init(path: "head.bin", size: 4_527_820, sha256: "2e46ec25a70df159e08416387a955e29cf6417fe30430432d8fcc749363c70b0"),
            .init(path: "rec.mlpackage/Data/com.apple.CoreML/model.mlmodel", size: 125_026, sha256: "2cfe1669a442be5359e1c9b6c4b6241791725fb2254d1c19d0522d257c1fc386"),
            .init(path: "rec.mlpackage/Data/com.apple.CoreML/weights/weight.bin", size: 6_015_024, sha256: "e77f341e2272fb38cfc10e47e11983a457d7a1482a8f642a82247c4c8b552ba0"),
            .init(path: "rec.mlpackage/Manifest.json", size: 617, sha256: "7f9aac7a4737bead51fc016ebc1cceb14a694a44e64a7bac8ef0edc3dbfab11e"),
        ]
    )

    /// PP-FormulaNet_plus-L and PP-DocLayoutV3, converted to Core ML with 8-bit weights by
    /// `Tools/model-packs/formula_pack.py` and published on Hugging Face (Docs/ocr.md › The formula pack): the text
    /// Capture Text, the OCR panel, and Recognize Text in Image read holds each formula as LaTeX (Docs/ocr.md › Formulas
    /// among text), and Capture Formula copies the formula in a selection, read on the CPU in the text reader. Until it
    /// is installed, nothing but Settings › Tools mentions it. Version 2 adds the layout model; version 1's folder goes
    /// when Settings › Tools next reads the packs, the files the two share carried over to version 2's download
    /// (`ModelPackStore.removeUnused`).
    public static let ppFormulaNetPlusL = ModelPack(
        id: "pp-formulanet-plus-l", version: "2",
        name: String(localized: "Math Formulas", bundle: .module),
        summary: String(
            localized: "PP-FormulaNet_plus-L and PP-DocLayoutV3, by PaddlePaddle: recognized text holds each formula as LaTeX, and Capture Formula copies the formula you select.",
            bundle: .module
        ),
        license: .init(name: "Apache-2.0", file: "LICENSE.txt", url: URL(string: "https://www.apache.org/licenses/LICENSE-2.0")!),
        original: URL(string: "https://huggingface.co/PaddlePaddle/PP-FormulaNet_plus-L_safetensors")!,
        host: "Hugging Face",
        mirrors: [
            URL(string: "https://huggingface.co/MoraxCheng/ohmyshot-ppformulanet-plus-l-coreml/resolve/a994339cda5fe6ba90170981219395dfb025332b/")!,
        ],
        files: [
            .init(path: "LICENSE.txt", size: 13_357, sha256: "ba28caa1f2207e9975828cd4e3f657ca0f61399dde7de4b2ee7ec18aa35fa6c8"),
            .init(path: "README.md", size: 3_290, sha256: "eeb466a278c01fbf2eea70a340c24e8b8a90d49a3327e7d336bb29bbe452b268"),
            .init(path: "config.json", size: 1_068, sha256: "4c3cb1ebce4f5c5278abf381dd7bec0822c7cec1047bd88329df713d9346e1e2"),
            .init(path: "decoder.mlpackage/Data/com.apple.CoreML/model.mlmodel", size: 213_277, sha256: "65076981addc92d1408c7b6d06cfd7eded00d05f8fb2608f28cc5e6d97e55566"),
            .init(path: "decoder.mlpackage/Data/com.apple.CoreML/weights/weight.bin", size: 82_426_720, sha256: "7e3e7ea8340e989d2e0c2b0d0b81955e6c3a2a6da47a83c17bef2f7ed49d712c"),
            .init(path: "decoder.mlpackage/Manifest.json", size: 617, sha256: "109a0d931308b09a23c8914cfd12e6b56c3d033210c3e55ccdf2228a2c7d288a"),
            .init(path: "encoder.mlpackage/Data/com.apple.CoreML/model.mlmodel", size: 248_151, sha256: "001a7421192cd23aca54fe84ab83bfbad0184bc116d48f1b947da57a6237d762"),
            .init(path: "encoder.mlpackage/Data/com.apple.CoreML/weights/weight.bin", size: 101_601_728, sha256: "3c298327ddbbf36e713c5f11422121098eff897abd28918d978b3d2dc161b694"),
            .init(path: "encoder.mlpackage/Manifest.json", size: 617, sha256: "80b712d7f2fd957a5f504df05b50ca1eef829b92a4557e1be491d314f75b388d"),
            .init(path: "layout.mlpackage/Data/com.apple.CoreML/model.mlmodel", size: 504_449, sha256: "5a29516751c43bda726b44d53771038abe22d24519e69fda170ae41d5bb75c0e"),
            .init(path: "layout.mlpackage/Data/com.apple.CoreML/weights/weight.bin", size: 33_164_480, sha256: "6c86ccbdef3ff798bd6c3507a115c0f04469afaa48f8ca4b0365070153b595a8"),
            .init(path: "layout.mlpackage/Manifest.json", size: 617, sha256: "b844a26da844086b3f063cd077518c7d210531921a46cc71b814094bbaa80b3a"),
            .init(path: "tokens.txt", size: 424_069, sha256: "1ad57fdc1a3b0fa2545f9cd241f7caaffec92d73186afffcc3ec67547e2df321"),
        ]
    )
}
