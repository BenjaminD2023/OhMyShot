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

    /// Normalizes a user-supplied custom mirror base URL (must be `https://` with a non-empty host, no credentials,
    /// query, fragment, or parent-directory traversal), stripping any trailing slash. Returns nil when empty or invalid.
    public static func normalizedMirrorOrigin(_ raw: String?) -> URL? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, var components = URLComponents(string: trimmed) else { return nil }
        guard components.scheme?.lowercased() == "https",
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil
        else { return nil }
        components.scheme = "https"
        components.host = host.lowercased()
        var path = components.path
        while path.hasSuffix("/") { path.removeLast() }
        let segments = path.split(separator: "/")
        guard !segments.contains(".."), !segments.contains(".") else { return nil }
        components.path = path
        return components.url
    }

    /// The mirror base URLs to try in order. When `customMirror` is a valid `https://` origin (such as
    /// `https://hf-mirror.com`), any `https://huggingface.co/...` mirror is rewritten to try that mirror first,
    /// falling back to the original mirror(s).
    public func resolvedMirrors(customMirror: String?) -> [URL] {
        guard let origin = Self.normalizedMirrorOrigin(customMirror),
              let originComponents = URLComponents(url: origin, resolvingAgainstBaseURL: false)
        else { return mirrors }
        var resolved: [URL] = []
        for mirror in mirrors {
            guard mirror.scheme?.lowercased() == "https",
                  mirror.host()?.lowercased() == "huggingface.co",
                  var rewritten = URLComponents(url: mirror, resolvingAgainstBaseURL: false)
            else { continue }
            rewritten.scheme = originComponents.scheme
            rewritten.host = originComponents.host
            rewritten.port = originComponents.port
            let mirrorPath = rewritten.path.hasPrefix("/") ? rewritten.path : "/" + rewritten.path
            rewritten.path = originComponents.path + mirrorPath
            if let url = rewritten.url, url != mirror, !resolved.contains(url) {
                resolved.append(url)
            }
        }
        for mirror in mirrors where !resolved.contains(mirror) {
            resolved.append(mirror)
        }
        return resolved
    }

    /// Bundled fallback license text for offline or unreachable-host license preview before downloading.
    /// The pack's own `LICENSE.txt` is still downloaded and verified by SHA-256 during installation.
    public var fallbackLicenseText: String? {
        guard license.name == "Apache-2.0" else { return nil }
        let note = String(
            localized: "Note: Could not fetch this pack’s LICENSE.txt right now. Below is the standard Apache License 2.0 text. The pack’s own LICENSE.txt (including any author notices and modification notes) will still be downloaded and verified by SHA-256 during download.",
            bundle: .module
        )
        return note + "\n\n" + Self.apache2FallbackLicense
    }

    /// Standard Apache License, Version 2.0, bundled for offline preview when the pack's `LICENSE.txt` cannot be reached.
    public static let apache2FallbackLicense = """
    Apache License
    Version 2.0, January 2004
    https://www.apache.org/licenses/

    TERMS AND CONDITIONS FOR USE, REPRODUCTION, AND DISTRIBUTION

    1. Definitions.

    "License" shall mean the terms and conditions for use, reproduction, and distribution as defined by Sections 1 through 9 of this document.

    "Licensor" shall mean the copyright owner or entity authorized by the copyright owner that is granting the License.

    "Legal Entity" shall mean the union of the acting entity and all other entities that control, are controlled by, or are under common control with that entity. For the purposes of this definition, "control" means (i) the power, direct or indirect, to cause the direction or management of such entity, whether by contract or otherwise, or (ii) ownership of fifty percent (50%) or more of the outstanding shares, or (iii) beneficial ownership of such entity.

    "You" (or "Your") shall mean an individual or Legal Entity exercising permissions granted by this License.

    "Source" form shall mean the preferred form for making modifications, including but not limited to software source code, documentation source, and configuration files.

    "Object" form shall mean any form resulting from mechanical transformation or translation of a Source form, including but not limited to compiled object code, generated documentation, and conversions to other media types.

    "Work" shall mean the work of authorship, whether in Source or Object form, made available under the License, as indicated by a copyright notice that is included in or attached to the work.

    "Derivative Works" shall mean any work, whether in Source or Object form, that is based on (or derived from) the Work and for which the editorial revisions, annotations, elaborations, or other modifications represent, as a whole, an original work of authorship.

    "Contribution" shall mean any work of authorship, including the original version of the Work and any modifications or additions to that Work or Derivative Works thereof, that is intentionally submitted to Licensor for inclusion in the Work by the copyright owner or by an individual or Legal Entity authorized to submit on behalf of the copyright owner.

    "Contributor" shall mean Licensor and any individual or Legal Entity on behalf of whom a Contribution has been received by Licensor and subsequently incorporated within the Work.

    2. Grant of Copyright License. Subject to the terms and conditions of this License, each Contributor hereby grants to You a perpetual, worldwide, non-exclusive, no-charge, royalty-free, irrevocable copyright license to reproduce, prepare Derivative Works of, publicly display, publicly perform, sublicense, and distribute the Work and such Derivative Works in Source or Object form.

    3. Grant of Patent License. Subject to the terms and conditions of this License, each Contributor hereby grants to You a perpetual, worldwide, non-exclusive, no-charge, royalty-free, irrevocable (except as stated in this section) patent license to make, have made, use, offer to sell, sell, import, and otherwise transfer the Work.

    4. Redistribution. You may reproduce and distribute copies of the Work or Derivative Works thereof in any medium, with or without modifications, and in Source or Object form, provided that You meet the following conditions:

    (a) You must give any other recipients of the Work or Derivative Works a copy of this License; and

    (b) You must cause any modified files to carry prominent notices stating that You changed the files; and

    (c) You must retain, in the Source form of any Derivative Works that You distribute, all copyright, patent, trademark, and attribution notices from the Source form of the Work, excluding those notices that do not pertain to any part of the Derivative Works; and

    (d) If the Work includes a "NOTICE" text file as part of its distribution, then any Derivative Works that You distribute must include a readable copy of the attribution notices contained within such NOTICE file.

    5. Submission of Contributions. Unless You explicitly state otherwise, any Contribution intentionally submitted for inclusion in the Work by You to the Licensor shall be under the terms and conditions of this License, without any additional terms or conditions.

    6. Trademarks. This License does not grant permission to use the trade names, trademarks, service marks, or product names of the Licensor, except as required for reasonable and customary use in describing the origin of the Work and reproducing the content of the NOTICE file.

    7. Disclaimer of Warranty. Unless required by applicable law or agreed to in writing, Licensor provides the Work (and each Contributor provides its Contributions) on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied, including, without limitation, any warranties or conditions of TITLE, NON-INFRINGEMENT, MERCHANTABILITY, or FITNESS FOR A PARTICULAR PURPOSE. You are solely responsible for determining the appropriateness of using or redistributing the Work and assume any risks associated with Your exercise of permissions under this License.

    8. Limitation of Liability. In no event and under no legal theory, whether in tort (including negligence), contract, or otherwise, unless required by applicable law (such as deliberate and grossly negligent acts) or agreed to in writing, shall any Contributor be liable to You for damages, including any direct, indirect, special, incidental, or consequential damages of any character arising as a result of this License or out of the use or inability to use the Work.

    9. Accepting Warranty or Additional Liability. While redistributing the Work or Derivative Works thereof, You may choose to offer, and charge a fee for, acceptance of support, warranty, indemnity, or other liability obligations and/or rights consistent with this License.
    """

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
    /// A listed pack shows in Settings › Text. With nothing here, nothing in the app mentions packs.
    public static let packs: [ModelPack] = [ppocrV6Small, ppFormulaNetPlusL, paddleOCRVL]

    /// PP-OCRv6 small, converted to Core ML by `Tools/model-packs/ppocr_pack.py` and published on Hugging Face
    /// (Docs/ocr.md › The L2 pack): the OCR panel and the history's search read Chinese and Japanese with it beside
    /// Vision (Docs/ocr.md › L2 beside L1). Version 2 applies the recognizer's last layer on the CPU (Docs/ocr.md › The
    /// recognizer's head on the CPU). Version 1 isn't read by this build; its folder goes when Settings › Text next
    /// reads the packs (`ModelPackCenter.refresh`).
    public static let ppocrV6Small = ModelPack(
        id: "ppocr-v6-small", version: "2",
        name: String(localized: "Chinese and Japanese Text", bundle: .module),
        summary: String(
            localized: "PP-OCRv6 small, by PaddlePaddle: reads Chinese and Japanese more accurately than macOS alone, in Recognized Text and in Capture History’s search.",
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
    /// is installed, nothing but Settings › Text mentions it. Version 2 adds the layout model; version 1's folder goes
    /// when Settings › Text next reads the packs, the files the two share carried over to version 2's download
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

    /// PaddleOCR-VL-1.6 on MLX with 8-bit weights, and PP-DocLayoutV3 (the formula pack's file), made by
    ///  and published on Hugging Face (Docs/ocr.md › The VLM pack): the text Capture Text,
    /// the OCR panel, and Recognize Text in Image read holds the tables and charts in a picture a row a line, read in the
    /// text reader (Packages/OhMyShotVLM), and the panel shows them as tables. Until it is installed, nothing but
    /// Settings › Text mentions it.
    public static let paddleOCRVL = ModelPack(
        id: "paddleocr-vl-1.6", version: "1",
        name: String(localized: "Tables and Charts", bundle: .module),
        summary: String(
            localized: "PaddleOCR-VL-1.6 and PP-DocLayoutV3, by PaddlePaddle: recognized text holds each table and chart as rows you can paste into a spreadsheet. Reading one takes about 2.6 GB of memory.",
            bundle: .module
        ),
        license: .init(name: "Apache-2.0", file: "LICENSE.txt", url: URL(string: "https://www.apache.org/licenses/LICENSE-2.0")!),
        original: URL(string: "https://huggingface.co/PaddlePaddle/PaddleOCR-VL-1.6")!,
        host: "Hugging Face",
        mirrors: [
            URL(string: "https://huggingface.co/MoraxCheng/ohmyshot-paddleocr-vl-1.6-mlx/resolve/59c48a3af69917b4baa5468ae5aa43b22ec51e52/")!,
        ],
        files: [
            .init(path: "LICENSE.txt", size: 12_820, sha256: "439061fae6525b51c683e74f725b072110e7d1c0172f533dc2aaedc414730192"),
            .init(path: "README.md", size: 3_013, sha256: "1f860c7e030748d80732676f6ed74a5b14846460765c5058bfa1bba805e524ef"),
            .init(path: "config.json", size: 2_676, sha256: "45b2be187cfff706db3f67e959020f99223a131baceb6af2f9a4c932999d726f"),
            .init(path: "layout.json", size: 256, sha256: "2f89e2ae42f686cd6a6a99bd5985267f1cfe97bf83fee4adf03d44453731290d"),
            .init(path: "layout.mlpackage/Data/com.apple.CoreML/model.mlmodel", size: 504_449, sha256: "5a29516751c43bda726b44d53771038abe22d24519e69fda170ae41d5bb75c0e"),
            .init(path: "layout.mlpackage/Data/com.apple.CoreML/weights/weight.bin", size: 33_164_480, sha256: "6c86ccbdef3ff798bd6c3507a115c0f04469afaa48f8ca4b0365070153b595a8"),
            .init(path: "layout.mlpackage/Manifest.json", size: 617, sha256: "b844a26da844086b3f063cd077518c7d210531921a46cc71b814094bbaa80b3a"),
            .init(path: "model.safetensors", size: 1_088_866_630, sha256: "3abce24b6c447cce0e56ae9fd7464d507c4b288080bdc92526a07668c3a0a0e7"),
            .init(path: "prompts.json", size: 705, sha256: "cda18d25b83d00028630edcaf2a824fe603d251f876dd7adfc455c143d5b7d4b"),
            .init(path: "vocabulary.json", size: 1_099_459, sha256: "55b3ac02fbe7e643b4edb10c172712be5e6acceba40126d18fd23aa25b91f15a"),
        ]
    )
}
