import AppKit
import CoreGraphics
import Foundation
import OMSCore
import Testing
@testable import OMSUI

/// A screenshot card's menu offers the codes found in its picture: looked for the first time the pointer rests on the
/// card, or it takes the keyboard, never before; each code once, a web address to open, anything else to copy.
@MainActor
struct CardCodeMenuTests {
    private func card() throws -> CaptureCardView {
        let context = try #require(CGContext(
            data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        let item = QuickAccessItem(
            id: UUID(), fileURL: URL(filePath: "/tmp/none.png"), thumbnail: try #require(context.makeImage()),
            pixelWidth: 1200, pixelHeight: 800, displayID: 0
        )
        let card = CaptureCardView(item: item, size: .medium)
        card.frame = CGRect(x: 0, y: 0, width: 220, height: 147)
        return card
    }

    private func rightClick() throws -> NSEvent {
        try #require(NSEvent.mouseEvent(
            with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
            eventNumber: 0, clickCount: 1, pressure: 1
        ))
    }

    /// The codes the menu offers, by what they say, and which of them open a page.
    private func offered(by card: CaptureCardView) throws -> [(payload: String, opens: Bool)] {
        let menu = try #require(card.menu(for: try rightClick()))
        return menu.items.compactMap { item in
            guard let payload = item.representedObject as? String, item.action == Selector(("codeClicked:")) else { return nil }
            return (payload, payload.hasPrefix("https://"))
        }
    }

    @Test func theMenuOffersEachCodeOnceAfterThePointerRestsOnTheCard() async throws {
        let card = try card()
        let looks = Looks()
        card.lookForCodes {
            await looks.count()
            return [
                FoundCode(payload: "https://example.com/a", isMatrix: true, box: .zero),
                FoundCode(payload: "4006381333931", isMatrix: false, box: .zero),
                FoundCode(payload: "https://example.com/a", isMatrix: true, box: CGRect(x: 10, y: 10, width: 5, height: 5)),
            ]
        }
        // Not looked for yet: a card nobody touches never decodes its picture.
        try await Task.sleep(for: .milliseconds(30))
        #expect(await looks.times == 0)
        #expect(try offered(by: card).isEmpty)

        card.setHovering(true)
        for _ in 0..<100 where card.foundCodes.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
        let codes = try offered(by: card)
        #expect(codes.map(\.payload) == ["https://example.com/a", "4006381333931"])
        // Hovered again, or taking the keyboard, it does not look twice.
        card.setHovering(false)
        card.setHovering(true)
        card.isSelected = true
        try await Task.sleep(for: .milliseconds(30))
        #expect(await looks.times == 1)
    }

    @Test func aCardDrivenFromTheKeyboardLooksAsItTakesTheKeys() async throws {
        let card = try card()
        card.lookForCodes { [FoundCode(payload: "ticket 4821", isMatrix: true, box: .zero)] }
        card.isSelected = true
        for _ in 0..<100 where card.foundCodes.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(try offered(by: card).map(\.payload) == ["ticket 4821"])
    }
}

/// How many times a card looked for codes.
private actor Looks {
    var times = 0
    func count() { times += 1 }
}
