import Foundation
import Testing
@testable import OMSCore

struct ReleaseNotesTests {
    @Test func extractsExactVersionAndReferences() {
        let notes = "## [Unreleased]\nFuture\n## [1.2.0] - 2026-11-07\n### Fixed\n- Read [more][docs].\n## [1.1.0]\nOld\n[docs]: https://www.ohmyshot.org"
        let result = ReleaseNotes.section(in: notes, version: "1.2.0")!
        #expect(result.contains("### Fixed"))
        #expect(result.contains("[docs]: https://www.ohmyshot.org"))
        #expect(!result.contains("Future"))
        #expect(!result.contains("Old"))
        #expect(ReleaseNotes.section(in: notes, version: "1.2") == nil)
    }

    @Test func translatedNotesMustMatchTheRequestedVersion() {
        let english = "## [1.2.0]\nNew features\n## [1.1.0]\nOld features"
        let chinese = "## [1.2.0]\n新功能\n## [1.1.0]\n旧功能"
        #expect(ReleaseNotes.localizedSection(chinese, fallback: english, version: "1.2.0") == "新功能")
        #expect(ReleaseNotes.localizedSection("## [1.1.0]\n旧功能", fallback: english, version: "1.2.0") == "New features")
        #expect(ReleaseNotes.localizedSection(nil, fallback: english, version: "1.2.0") == "New features")
        #expect(ReleaseNotes.localizedSection("## [1.2.0]\n", fallback: english, version: "1.2.0") == "New features")
        #expect(ReleaseNotes.localizedSection("## [1.2.0]\n\n## [1.1.0]\n旧功能\n[docs]: https://www.ohmyshot.org", fallback: english, version: "1.2.0") == "New features")
        #expect(ReleaseNotes.localizedSection("## [1.2.0]\n[docs]: https://www.ohmyshot.org", fallback: english, version: "1.2.0") == "New features")
    }

    @Test func resolvesChangelogReferenceLinks() {
        let text = ReleaseNotes.inline("Fixed capture. ([#20]; by [@fzlzjerry])", referencesIn: "[#20]: https://github.com/MMFoundation/OhMyShot/pull/20\n[@fzlzjerry]: https://github.com/fzlzjerry")
        #expect(text.runs.compactMap { $0.link }.count == 2)
        #expect(text.runs.compactMap { $0.link }.first?.absoluteString == "https://github.com/MMFoundation/OhMyShot/pull/20")
    }

    @Test func welcomeOncePerNewBuild() {
        #expect(ReleaseNotes.shouldShow(previousBuild: nil, currentBuild: "2"))
        #expect(ReleaseNotes.shouldShow(previousBuild: "2", currentBuild: "10"))
        #expect(!ReleaseNotes.shouldShow(previousBuild: "2", currentBuild: "2"))
        #expect(!ReleaseNotes.shouldShow(previousBuild: "10", currentBuild: "2"))
    }

    @Test func mirrorOnlyKnownReleaseArchives() {
        let url = URL(string: "https://github.com/MMFoundation/OhMyShot/releases/download/v0.2.0/OhMyShot-0.2.0.zip")!
        #expect(UpdateTransport.mirroredDownload(url)?.absoluteString == "https://www.ohmyshot.org/updates/download/v0.2.0/OhMyShot-0.2.0.zip")
        for invalid in [url.absoluteString.replacingOccurrences(of: "https:", with: "http:"), url.absoluteString + "?token=123", url.absoluteString.replacingOccurrences(of: "github.com", with: "evil.com"), url.absoluteString.replacingOccurrences(of: "OhMyShot-0.2.0.zip", with: "Other.zip")] {
            #expect(UpdateTransport.mirroredDownload(URL(string: invalid)!) == nil)
        }
    }
}
