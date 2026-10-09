import AppKit
import VisionKit

/// Reads the text in picture pins for Live Text, as Preview does: VisionKit's analysis of a pin's picture,
/// asked for the first time the pointer comes to the pin. One analyzer serves every pin and goes with the
/// last of them.
@MainActor
final class PinTextReader {
    private var analyzer: ImageAnalyzer?

    /// The text and codes VisionKit finds in `image`; nil when it finds none or cannot run here.
    func read(_ image: CGImage) async -> ImageAnalysis? {
        guard ImageAnalyzer.isSupported else { return nil }
        let analyzer = analyzer ?? ImageAnalyzer()
        self.analyzer = analyzer
        // No locales: VisionKit then follows the preferred languages and reads Chinese all the same,
        // where naming Chinese first turned the brackets of code full-width.
        let configuration = ImageAnalyzer.Configuration([.text, .machineReadableCode])
        guard
            let analysis = try? await analyzer.analyze(image, orientation: .up, configuration: configuration),
            analysis.hasResults(for: .text) || analysis.hasResults(for: .machineReadableCode)
        else { return nil }
        return analysis
    }

    /// Lets the analyzer and what it loaded go, with the last pin.
    func release() {
        analyzer = nil
    }
}

extension ImageAnalysisOverlayView {
    /// `point`, in `view`'s coordinates, as VisionKit's hit queries (`hasText(at:)` and the like) take it:
    /// from the overlay's top left, although the overlay is not flipped (macOS 27).
    func analysisPoint(_ point: CGPoint, from view: NSView) -> CGPoint {
        let local = convert(point, from: view)
        return isFlipped ? local : CGPoint(x: local.x, y: bounds.height - local.y)
    }
}
