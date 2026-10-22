import CoreGraphics
import Foundation
import Vision

/// An explicit recovery model for an isolated reader process. It must not run beside a stalled
/// current-model request in the app: Apple's native initialization can block both in one process.
enum CompatibilityTextRecognition {
    /// Nil leaves the current recognizer in charge when revision 2 cannot preserve the language
    /// configuration. Automatic language detection is a no-op before revision 3.
    @concurrent
    static func recognize(_ source: RecognizeTextRequest, on image: CGImage) async throws -> [RecognizedTextObservation]? {
        try Task.checkCancellation()
        guard !source.automaticallyDetectsLanguage, !source.recognitionLanguages.isEmpty else { return nil }
        let request = VNRecognizeTextRequest()
        // An intentional recovery path, chosen only by the isolated reader and only for supported
        // languages. The default revision shares the current Swift request's native model failure.
        request.revision = 2
        request.recognitionLevel = source.recognitionLevel == .accurate ? .accurate : .fast
        let requested = recoveryLanguages(source.recognitionLanguages, accurate: source.recognitionLevel == .accurate)
        guard let languages = compatibleLanguages(
            requested, supported: try request.supportedRecognitionLanguages(),
            automaticallyDetectsLanguage: source.automaticallyDetectsLanguage
        ) else { return nil }
        request.recognitionLanguages = languages
        request.usesLanguageCorrection = source.usesLanguageCorrection
        request.customWords = source.customWords
        let input: CGImage
        if source.regionOfInterest == .fullImage {
            input = image
        } else {
            // Cropping makes observations, including glyph boxes, relative to the ROI, matching
            // VisionPipeline's current-request coordinate conversion back into the original image.
            guard let cropped = image.cropping(to: cropRect(for: source.regionOfInterest, in: CGSize(width: image.width, height: image.height))) else {
                throw OCRError.unreadableImage
            }
            input = cropped
        }
        request.minimumTextHeight = source.minimumTextHeightFraction * Float(image.height) / Float(input.height)
        let cancellable = CancellableRequest(request)
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try VNImageRequestHandler(cgImage: input).perform([request])
            try Task.checkCancellation()
            return (request.results ?? []).map(RecognizedTextObservation.init)
        } onCancel: {
            cancellable.request.cancel()
        }
    }

    static func recoveryLanguages(_ languages: [Locale.Language], accurate: Bool) -> [String] {
        let requested = languages.map(\.minimalIdentifier)
        // The separate Latin model can hit the same native compilation failure even at revision 2.
        // The bilingual accurate model also reads English, without initializing that Latin backend.
        if accurate, requested == [Locale.Language(identifier: "en-US").minimalIdentifier] {
            return ["zh-Hans", "en-US"]
        }
        return requested
    }

    /// Keep priority and script distinctions while mapping aliases to identifiers Vision supports.
    static func compatibleLanguages(_ requested: [String], supported: [String], automaticallyDetectsLanguage: Bool) -> [String]? {
        guard !automaticallyDetectsLanguage, !requested.isEmpty else { return nil }
        let available = Dictionary(supported.map { (Locale.Language(identifier: $0).minimalIdentifier, $0) }, uniquingKeysWith: { first, _ in first })
        var languages: [String] = []
        for language in requested {
            guard let supported = available[Locale.Language(identifier: language).minimalIdentifier] else { return nil }
            languages.append(supported)
        }
        return languages
    }

    static func cropRect(for region: NormalizedRect, in size: CGSize) -> CGRect {
        region.toImageCoordinates(size, origin: .upperLeft)
    }

    /// Configuration and results remain on the worker; VNRequest permits cancellation from another
    /// thread, which is the sole concurrent access.
    private final class CancellableRequest: @unchecked Sendable {
        let request: VNRecognizeTextRequest
        init(_ request: VNRecognizeTextRequest) { self.request = request }
    }
}
