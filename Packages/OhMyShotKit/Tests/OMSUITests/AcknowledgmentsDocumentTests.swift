import AppKit
import Testing
@testable import OMSUI

/// The notices file as the Acknowledgments sheet shows it.
struct AcknowledgmentsDocumentTests {
    private let document = AcknowledgmentsDocument.attributed("""
    <!-- Made by Scripts/acknowledgments.py. -->

    # Acknowledgments

    Built with the software below.

    ## Sparkle 2.10.0

    https://github.com/sparkle-project/Sparkle

    ```text
    Copyright (c) 2006-2013 Andy Matuschak.

    bspatch.c and bsdiff.c, from bsdiff 4.3 <http://www.daemonology.net/bsdiff/>:
    1. Redistributions of source code must retain the above copyright
       notice, this list of conditions and the following disclaimer.
    ## Not a heading, inside the license
    ```

    ### PocketFFT

    *In MLX Swift: Source/Cmlx/mlx/mlx/3rdparty/pocketfft.h*
    """)

    private func attributes(of text: String) throws -> [NSAttributedString.Key: Any] {
        let range = (document.string as NSString).range(of: text)
        try #require(range.location != NSNotFound, "no “\(text)”")
        return document.attributes(at: range.location, effectiveRange: nil)
    }

    @Test func theCommentTitleAndMarksAreLeftOut() {
        #expect(!document.string.contains("<!--"))
        #expect(!document.string.contains("# Acknowledgments"))
        #expect(!document.string.contains("```"))
        #expect(!document.string.contains("*In"))
        #expect(document.string.hasPrefix("Built with the software below.\nSparkle 2.10.0\n"))
    }

    @Test func aLicenseKeepsItsLinesInAMonospacedFace() throws {
        #expect(document.string.contains("bsdiff/>:\n1. Redistributions of source code must retain the above copyright\n   notice, this list"))
        let font = try #require(try attributes(of: "1. Redistributions")[.font] as? NSFont)
        #expect(font.isFixedPitch)
        #expect(try attributes(of: "## Not a heading")[.font] as? NSFont == font)
    }

    @Test func headingsAreSemiboldAndOriginsQuieter() throws {
        let heading = try #require(try attributes(of: "Sparkle 2.10.0")[.font] as? NSFont)
        #expect(NSFontManager.shared.weight(of: heading) > NSFontManager.shared.weight(of: .systemFont(ofSize: 13)))
        #expect(try attributes(of: "In MLX Swift")[.foregroundColor] as? NSColor == .secondaryLabelColor)
    }

    @Test func addressesAreLinksWithoutThePunctuationAroundThem() throws {
        #expect(try attributes(of: "https://github.com/sparkle-project/Sparkle")[.link] as? URL == URL(string: "https://github.com/sparkle-project/Sparkle"))
        #expect(try attributes(of: "http://www.daemonology.net")[.link] as? URL == URL(string: "http://www.daemonology.net/bsdiff/"))
        #expect(try attributes(of: "bspatch.c")[.link] == nil)
    }
}
