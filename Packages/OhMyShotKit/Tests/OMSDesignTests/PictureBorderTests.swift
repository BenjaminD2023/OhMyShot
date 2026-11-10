import CoreGraphics
import OMSDesign
import Testing

/// A picture's edge: the quiet hairline, or the contrast hairline under Increase Contrast, in every place a picture is
/// shown as content (Quick Access, the editor, Recognized Text).
struct PictureBorderTests {
    @Test func theQuietEdgeIsHalfAPointAndFaint() {
        #expect(Theme.PictureBorder.width(contrast: false) == 0.5)
        #expect(Theme.PictureBorder.color(dark: false, contrast: false).alpha == 0.10)
        #expect(Theme.PictureBorder.color(dark: true, contrast: false).alpha == 0.16)
    }

    @Test func increaseContrastTakesTheContrastHairline() {
        #expect(Theme.PictureBorder.width(contrast: true) == 1)
        for dark in [false, true] {
            #expect(Theme.PictureBorder.color(dark: dark, contrast: true) == Theme.Material.edge(dark: dark, contrast: true))
        }
    }

    @Test func chipFillsFirmUpUnderIncreaseContrast() {
        // The recording bar's buttons take these steps rather than doubling the base ones.
        #expect(Theme.ChipFill.hover(dark: true, contrast: true) == 0.16)
        #expect(Theme.ChipFill.selected(dark: true, contrast: true) == 0.28)
        #expect(Theme.ChipFill.hover(dark: false, contrast: true) == 0.09)
    }
}
