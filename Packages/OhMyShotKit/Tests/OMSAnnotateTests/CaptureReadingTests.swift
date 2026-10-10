import CoreGraphics
import Foundation
import Testing
@testable import OMSAnnotate

nonisolated private let suggestion = RedactionSuggestion(rect: CGRect(x: 100, y: 20, width: 200, height: 30), label: "Email address")
nonisolated private let line = TextLine(rect: CGRect(x: 100, y: 100, width: 300, height: 30), words: [100...200, 215...400])

@MainActor
@Suite(.serialized)
struct CaptureReadingTests {
    /// A session over a blank capture of `width` × `height` pixels whose readings note which tool asks
    /// which of them, and how large a picture each reads.
    private func makeSession(asks: ReadingAsks, width: Int = 600, height: Int = 300) -> AnnotationSession {
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        let session = AnnotationSession(image: context.makeImage()!, scale: 1, tool: .arrow)
        session.undoManager.groupsByEvent = false
        session.textReader = { image in
            let reading = UUID()
            let size = CGSize(width: image.width, height: image.height)
            return CaptureReading(
                redactionSuggestions: {
                    await asks.record(.redactionSuggestions, of: reading, sized: size)
                    return [suggestion]
                },
                textLines: {
                    await asks.record(.textLines, of: reading, sized: size)
                    return [line]
                }
            )
        }
        return session
    }

    /// Waits, briefly, for the tool in hand to have what it reads.
    private func waitForReading(_ session: AnnotationSession) async {
        for _ in 0..<100 where session.isReadingForTool
            || (session.tool == .redact && session.redactionSuggestions.isEmpty)
            || (session.tool == .highlighter && session.textLines.isEmpty) {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    private func change(_ session: AnnotationSession, _ actionName: String, _ edit: (inout AnnotationDocument) -> Void) {
        var document = session.document
        edit(&document)
        session.undoManager.beginUndoGrouping()
        session.commit(document, actionName: actionName)
        session.undoManager.endUndoGrouping()
    }

    @Test func theRedactionToolAndTheHighlighterShareOneReading() async {
        let asks = ReadingAsks()
        let session = makeSession(asks: asks)
        session.tool = .redact
        await waitForReading(session)
        session.tool = .highlighter
        await waitForReading(session)
        #expect(session.redactionSuggestions == [suggestion])
        #expect(session.textLines == [line])
        #expect(await asks.tools == [.redactionSuggestions, .textLines])
        #expect(await asks.readings == 1)
    }

    @Test func toolsPickedBeforeTheReadingIsInShareItToo() async {
        let asks = ReadingAsks()
        let session = makeSession(asks: asks)
        session.tool = .highlighter
        session.tool = .redact
        await waitForReading(session)
        for _ in 0..<100 where session.isFindingTextLines { try? await Task.sleep(for: .milliseconds(10)) }
        #expect(Set(await asks.tools) == [.redactionSuggestions, .textLines])
        #expect(await asks.readings == 1)
    }

    @Test func aCropWithinWhatWasReadKeepsTheReading() async {
        let asks = ReadingAsks()
        let session = makeSession(asks: asks)
        session.tool = .redact
        await waitForReading(session)
        change(session, "Crop") { $0.canvas = CGRect(x: 0, y: 60, width: 400, height: 140) }
        session.tool = .highlighter
        await waitForReading(session)
        #expect(await asks.readings == 1)
    }

    @Test func aCanvasMovedPastWhatWasReadIsReadAnew() async {
        // As in place: a 200 × 100 area of a 2000 × 1000 screen, read with 160 px around it.
        let asks = ReadingAsks()
        let session = makeSession(asks: asks, width: 2000, height: 1000)
        change(session, "Crop") { $0.canvas = CGRect(x: 1000, y: 500, width: 200, height: 100) }
        session.tool = .redact
        await waitForReading(session)
        change(session, "Move") { $0.canvas = CGRect(x: 100, y: 100, width: 200, height: 100) }
        session.tool = .highlighter
        await waitForReading(session)
        #expect(await asks.readings == 2)
        #expect(await asks.sizes == [CGSize(width: 520, height: 420), CGSize(width: 460, height: 360)])
        // Found where it is in the new reading, which starts at the picture's corner.
        #expect(session.textLines == [line])
    }

    @Test func aPictureCombinedAfterwardsIsReadAnewForBoth() async {
        let asks = ReadingAsks()
        let session = makeSession(asks: asks)
        session.tool = .redact
        await waitForReading(session)
        change(session, "Add Image") {
            $0.items.append(Annotation(
                shape: .image(PlacedImage(rect: CGRect(x: 100, y: 100, width: 50, height: 50), name: "absent.png")),
                style: Style(color: .black, lineWidth: 0, shadow: false)
            ))
        }
        // Read again for the tool in hand, and the highlighter's lines come from that reading.
        await waitForReading(session)
        session.tool = .highlighter
        await waitForReading(session)
        #expect(await asks.tools == [.redactionSuggestions, .redactionSuggestions, .textLines])
        #expect(await asks.readings == 2)
        #expect(await asks.readingOfLast == asks.readingAt(1))
    }
}

/// Which tool asked which reading, and how large a picture each reading read, from any task.
actor ReadingAsks {
    nonisolated enum Tool: Hashable, Sendable {
        case redactionSuggestions
        case textLines
    }

    private var asks: [(tool: Tool, reading: UUID, size: CGSize)] = []

    func record(_ tool: Tool, of reading: UUID, sized size: CGSize) {
        asks.append((tool, reading, size))
    }

    var tools: [Tool] { asks.map(\.tool) }
    /// How many readings were asked.
    var readings: Int { Set(asks.map(\.reading)).count }
    /// The size of each reading's picture, in the order they were first asked.
    var sizes: [CGSize] {
        var seen: Set<UUID> = []
        return asks.filter { seen.insert($0.reading).inserted }.map(\.size)
    }

    var readingOfLast: UUID? { asks.last?.reading }

    func readingAt(_ index: Int) -> UUID? {
        asks.indices.contains(index) ? asks[index].reading : nil
    }
}
