import CoreGraphics
import Testing
@testable import OMSCore

struct ScreenColorTests {
    @Test func sRGBNotations() throws {
        let color = try #require(ScreenColor(srgbRed: 0.2, green: 0.4, blue: 1))
        #expect(color.hex == "#3366FF")
        #expect(color.rgb == "rgb(51, 102, 255)")
        #expect(color.hsl == "hsl(225, 100%, 60%)")
        #expect(color.isInSRGB)
    }

    @Test func oklchMatchesCSSColor4() throws {
        // CSS Color 4: rgb(255 0 0) is oklch(62.8% 0.2577 29.23).
        let red = try #require(ScreenColor(srgbRed: 1, green: 0, blue: 0))
        let (lightness, chroma, hue) = red.oklchComponents
        #expect(abs(lightness - 0.62796) < 0.0005)
        #expect(abs(chroma - 0.25768) < 0.0005)
        #expect(abs(hue - 29.23) < 0.05)
        #expect(red.oklch == "oklch(62.8% 0.258 29.2)")
        #expect(try #require(ScreenColor(srgbRed: 1, green: 1, blue: 1)).oklch == "oklch(100% 0 0)")
        #expect(try #require(ScreenColor(srgbRed: 0, green: 0, blue: 0)).oklch == "oklch(0% 0 0)")
    }

    @Test func displayP3() throws {
        // sRGB red in Display P3.
        let red = try #require(ScreenColor(srgbRed: 1, green: 0, blue: 0))
        #expect(abs(red.p3Red - 0.9175) < 0.002 && abs(red.p3Green - 0.2003) < 0.002 && abs(red.p3Blue - 0.1386) < 0.002)
        #expect(red.displayP3 == "color(display-p3 0.917 0.2 0.139)")
        // Display P3's red lies outside sRGB: its sRGB notations clamp, its OKLCH does not.
        let p3Red = try #require(ScreenColor(CGColor(colorSpace: CGColorSpace(name: CGColorSpace.displayP3)!, components: [1, 0, 0, 1])!))
        #expect(!p3Red.isInSRGB)
        #expect(p3Red.hex == "#FF0000")
        let (lightness, chroma, _) = p3Red.oklchComponents
        #expect(abs(lightness - 0.649) < 0.005)
        #expect(abs(chroma - 0.2995) < 0.005)
    }

    @Test func wcagContrast() throws {
        let white = try #require(ScreenColor(srgbRed: 1, green: 1, blue: 1))
        let black = try #require(ScreenColor(srgbRed: 0, green: 0, blue: 0))
        #expect(abs(white.wcagContrast(with: black) - 21) < 0.001)
        // #767676 is the lightest gray that passes AA on white; #777777 just fails.
        let passing = try #require(ScreenColor(srgbRed: 118.0 / 255, green: 118.0 / 255, blue: 118.0 / 255))
        let failing = try #require(ScreenColor(srgbRed: 119.0 / 255, green: 119.0 / 255, blue: 119.0 / 255))
        #expect(passing.wcagContrast(with: white) >= 4.5)
        #expect(failing.wcagContrast(with: white) < 4.5)
        // Read rounded down, so the failing gray never shows as 4.5:1.
        #expect(ScreenColor.ratioText(failing.wcagContrast(with: white)) == "4.4:1")
        #expect(ScreenColor.ratioText(21) == "21:1")
    }

    @Test func apcaMatchesItsReferenceValues() throws {
        let gray = try #require(ScreenColor(srgbRed: 136.0 / 255, green: 136.0 / 255, blue: 136.0 / 255))
        let white = try #require(ScreenColor(srgbRed: 1, green: 1, blue: 1))
        // APCA-W3's examples: #888 text on #fff, and #fff text on #888.
        #expect(abs(ScreenColor.apcaContrast(text: gray, background: white) - 63.056) < 0.1)
        #expect(abs(ScreenColor.apcaContrast(text: white, background: gray) + 68.541) < 0.1)
        #expect(ScreenColor.apcaContrast(text: white, background: white) == 0)
    }
}
