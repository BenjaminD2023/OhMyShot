import AppKit
import Testing
@testable import OMSDesign

/// The chips over a selection's codes: where they stand, how the same code twice and too many codes show, and which
/// presses they take. Nothing is shown.
@MainActor
struct CodeChipsViewTests {
    private let wording = CodeChipsView.Wording(
        qrCode: "QR Code", barcode: "Barcode", codes: { "\($0) Codes" }, copy: "Copy", openLink: "Open Link", copied: "Copied"
    )
    private let area = CGRect(x: 100, y: 100, width: 600, height: 400)

    private func view() -> (CodeChipsView, NSWindow) {
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1000, height: 800), styleMask: [.borderless], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let view = CodeChipsView(wording: wording)
        view.frame = window.contentView!.bounds
        window.contentView!.addSubview(view)
        return (view, window)
    }

    /// What a press at `point` (the chips' own flipped points) reaches, asked as the window asks: in the superview's
    /// points.
    private func hit(_ chips: CodeChipsView, at point: CGPoint) -> NSView? {
        chips.hitTest(chips.convert(point, to: chips.superview))
    }

    private func qr(_ payload: String, at origin: CGPoint) -> CodeChipsView.Code {
        CodeChipsView.Code(box: CGRect(origin: origin, size: CGSize(width: 80, height: 80)), isMatrix: true, payload: payload, link: URL(string: payload))
    }

    @Test func aQRCodesChipStandsOnItsTopRightCornerAndABarcodesBesideIt() throws {
        let (chips, window) = view()
        defer { window.close() }
        let bars = CodeChipsView.Code(box: CGRect(x: 300, y: 400, width: 160, height: 50), isMatrix: false, payload: "4006381333931", link: nil)
        chips.show([qr("https://example.com", at: CGPoint(x: 200, y: 200)), bars], in: area)
        let frames = chips.debugChipFrames
        #expect(frames.count == 2)
        // Half over the QR code's top-right corner, reaching outside it.
        #expect(frames[0].midX == 280 && frames[0].midY == 200)
        // Clear of the barcode's bars, on its middle.
        #expect(frames[1].minX >= 460 && frames[1].midY == 425)
    }

    @Test func theSameCodeTwiceIsOneChipAndTooManyCodesAreOne() {
        let (chips, window) = view()
        defer { window.close() }
        chips.show([qr("A", at: CGPoint(x: 200, y: 200)), qr("A", at: CGPoint(x: 400, y: 200))], in: area)
        #expect(chips.chipCount == 1 && chips.shownPayloads == ["A"])

        let many = (0..<6).map { qr("code \($0)", at: CGPoint(x: 120 + CGFloat($0) * 90, y: 300)) }
        chips.show(many, in: area)
        #expect(chips.chipCount == 1 && chips.shownPayloads.count == 6)
        // In the selection's top-right corner.
        let frame = chips.debugChipFrames[0]
        #expect(frame.maxX <= area.maxX - 8 + 0.5 && frame.minY == area.minY + 8)
    }

    @Test func overlappingChipsStepOutOfEachOthersWay() {
        let (chips, window) = view()
        defer { window.close() }
        chips.show([qr("A", at: CGPoint(x: 200, y: 200)), qr("B", at: CGPoint(x: 202, y: 202))], in: area)
        let frames = chips.debugChipFrames
        #expect(frames.count == 2 && !frames[0].intersects(frames[1]))
    }

    /// Only the chips take presses; once a card is open, a press anywhere only closes it.
    @Test func pressesFallThroughExceptOnChipsOrWhileACardIsOpen() throws {
        let (chips, window) = view()
        defer { window.close() }
        chips.show([qr("https://example.com", at: CGPoint(x: 200, y: 200))], in: area)
        #expect(hit(chips, at: CGPoint(x: 600, y: 600)) == nil)
        let chip = try #require(chips.debugChipFrames.first)
        #expect(hit(chips, at: CGPoint(x: chip.midX, y: chip.midY)) != nil)

        chips.debugOpenCard(for: "https://example.com")
        #expect(chips.isShowingCard && chips.debugCardFrame != nil)
        #expect(hit(chips, at: CGPoint(x: 600, y: 600)) === chips)
        chips.dismissCard()
        #expect(!chips.isShowingCard)
        #expect(hit(chips, at: CGPoint(x: 600, y: 600)) == nil)

        chips.clear()
        #expect(chips.chipCount == 0)
    }

    /// A code drawn tight into the selection's corner keeps its chip off the corner handle, inside the code's corner.
    @Test func aChipLeavesTheSelectionsCornerHandleFree() throws {
        let (chips, window) = view()
        defer { window.close() }
        chips.show([qr("A", at: CGPoint(x: area.maxX - 80, y: area.minY))], in: area)
        let frame = try #require(chips.debugChipFrames.first)
        let corner = CGRect(x: area.maxX - 14, y: area.minY - 14, width: 28, height: 28)
        #expect(!frame.intersects(corner))
        #expect(CGRect(x: area.maxX - 80, y: area.minY, width: 80, height: 80).contains(frame))
    }

    /// The keyboard opens the codes' cards one after another, and a card that closes says so.
    @Test func theKeyboardGoesThroughTheCardsAndClosingSaysSo() {
        let (chips, window) = view()
        defer { window.close() }
        var closed = 0
        chips.onCardClosed = { closed += 1 }
        chips.show([qr("A", at: CGPoint(x: 200, y: 200)), qr("B", at: CGPoint(x: 400, y: 200))], in: area)
        #expect(chips.openNextCard() && chips.isShowingCard)
        #expect(chips.openNextCard() && chips.isShowingCard)
        #expect(closed == 0, "Going on to the next card keeps the keyboard with the cards")
        chips.dismissCard()
        #expect(closed == 1)
        chips.clear()
        #expect(!chips.openNextCard())
    }

    @Test func longPayloadsAreShortenedInTheMiddle() {
        let text = String(repeating: "a", count: 50) + String(repeating: "z", count: 50)
        let short = CodeChipsView.shortened(text, to: 30)
        #expect(short.count == 30 && short.hasPrefix("aaaa") && short.hasSuffix("zzzz") && short.contains("…"))
        #expect(CodeChipsView.shortened("line\nbreak", to: 30) == "line break")
    }
}
