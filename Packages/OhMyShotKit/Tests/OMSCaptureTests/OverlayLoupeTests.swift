import AppKit
import OMSCore
import Testing
@testable import OMSCapture

#if DEBUG
@MainActor
struct OverlayLoupeTests {
    private let size = CGSize(width: 800, height: 600)

    /// One marked physical pixel in a generated frame, including displays with negative origins.
    private func fixture(
        scale: Int = 2, origin: CGPoint = .zero, point: CGPoint = CGPoint(x: 400, y: 300)
    ) throws -> (display: DisplayInfo, frame: CapturedFrame, global: CGPoint) {
        let width = Int(size.width) * scale, height = Int(size.height) * scale
        let context = try #require(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let x = Int((point.x * CGFloat(scale)).rounded(.down))
        let y = Int(((size.height - point.y) * CGFloat(scale)).rounded(.down))
        context.setFillColor(CGColor(srgbRed: 18.0 / 255, green: 52.0 / 255, blue: 86.0 / 255, alpha: 1))
        context.fill(CGRect(x: x, y: height - y - 1, width: 1, height: 1))
        let image = try #require(context.makeImage())
        let display = DisplayInfo(
            id: origin.x < 0 ? 1 : 2, name: "Synthetic loupe screen", frame: CGRect(origin: origin, size: size),
            pixelSize: CGSize(width: width, height: height), backingScale: CGFloat(scale), maximumPotentialEDR: 1
        )
        return (
            display, CapturedFrame(image: image, hdrImage: nil, displayID: display.id, frame: display.frame),
            CGPoint(x: origin.x + point.x, y: origin.y + point.y)
        )
    }

    private func firstPress(on display: DisplayInfo, at point: CGPoint) -> SelectionModel {
        var selection = SelectionModel(bounds: display.frame, pixelsPerPoint: display.pixelsPerPoint)
        selection.begin(at: point)
        return selection
    }

    private func expectPickerHidden(_ view: OverlayView) {
        #expect(!view.debugPointerLayers.crosshair)
        #expect(view.debugPointerLayers.loupe == nil)
        #expect(view.debugPointerLayers.colorReading == nil)
    }

    private func contrastFixture(
        colors: [CGColor], scale: Int
    ) throws -> (display: DisplayInfo, frame: CapturedFrame, points: [CGPoint]) {
        let width = Int(size.width) * scale, height = Int(size.height) * scale
        let context = try #require(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(gray: 0.5, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let points = colors.indices.map { CGPoint(x: 100.5 + CGFloat($0) * 80, y: 300.5) }
        for (point, color) in zip(points, colors) {
            let x = Int((point.x * CGFloat(scale)).rounded(.down))
            let y = Int(((size.height - point.y) * CGFloat(scale)).rounded(.down))
            context.setFillColor(color)
            context.fill(CGRect(x: x - 8, y: height - y - 9, width: 17, height: 17))
        }
        let display = DisplayInfo(
            id: 2, name: "Synthetic contrast screen", frame: CGRect(origin: .zero, size: size),
            pixelSize: CGSize(width: width, height: height), backingScale: CGFloat(scale), maximumPotentialEDR: 1
        )
        let image = try #require(context.makeImage())
        return (display, CapturedFrame(image: image, hdrImage: nil, displayID: display.id, frame: display.frame), points)
    }

    @Test func captureAndAnnotationCenterTheLoupeOnTheSelectedPixelAtBothScales() throws {
        for scale in [1, 2] {
            let point = CGPoint(x: 250 + 0.5 / CGFloat(scale), y: 300 + 0.5 / CGFloat(scale))
            let fixture = try fixture(scale: scale, origin: CGPoint(x: -800, y: 100), point: point)
            for purpose in [OverlayController.Purpose.screenshot, .annotate] {
                let view = OverlayView(display: fixture.display)
                defer { view.clear() }
                view.reset(pointer: fixture.global, mode: .area, windows: [], showsToolbar: false, purpose: purpose)
                view.show(fixture.frame, frozen: true)
                let lens = try #require(view.debugPointerLayers.loupe)
                #expect(lens.midX == point.x && lens.midY == point.y)
                #expect(lens.size == CGSize(width: 75, height: 75))
                #expect(view.color(at: fixture.global)?.hex == "#123456")
                #expect(!view.debugPointerLayers.crosshair, "The lens center marks the target instead of a second crosshair")
                #expect(view.debugPointerLayers.colorReading != nil)
            }
        }
    }

    @Test func screenEdgesClipTheCenteredLensWhileKeepingItsColorReadingOnScreen() throws {
        for scale in [1, 2] {
            let halfPixel = 0.5 / CGFloat(scale)
            for point in [
                CGPoint(x: halfPixel, y: halfPixel), CGPoint(x: halfPixel, y: size.height - halfPixel),
                CGPoint(x: size.width - halfPixel, y: halfPixel),
                CGPoint(x: size.width - halfPixel, y: size.height - halfPixel),
            ] {
                let fixture = try fixture(scale: scale, point: point)
                let view = OverlayView(display: fixture.display)
                defer { view.clear() }
                view.reset(pointer: fixture.global, mode: .area, windows: [], showsToolbar: false)
                view.show(fixture.frame, frozen: true)
                let lens = try #require(view.debugPointerLayers.loupe)
                let reading = try #require(view.debugPointerLayers.colorReading)
                #expect(lens.midX == point.x && lens.midY == point.y)
                #expect(!view.bounds.contains(lens), "Keeping the lens on screen must not move it off the target")
                #expect(view.bounds.insetBy(dx: 6, dy: 6).contains(reading))
                #expect(view.color(at: fixture.global)?.hex == "#123456")
            }
        }
    }

    @Test func theFirstPressHidesThePickerBeforeTheSelectionHasAnySize() throws {
        let fixture = try fixture()
        for (purpose, allInOne) in [
            (OverlayController.Purpose.screenshot, false), (.screenshot, true), (.annotate, false),
        ] {
            let view = OverlayView(display: fixture.display)
            defer { view.clear() }
            view.reset(pointer: fixture.global, mode: .area, windows: [], showsToolbar: allInOne, purpose: purpose, allInOne: allInOne)
            view.show(fixture.frame, frozen: true)
            #expect(view.debugPointerLayers.loupe != nil)
            let selection = firstPress(on: fixture.display, at: fixture.global)
            #expect(selection.rect == nil)
            view.show(selection: selection, showsReading: false, isDragging: true)
            expectPickerHidden(view)
        }
    }

    @Test func lateFramesPointerMovementAndModeChangesCannotRestoreASuppressedPicker() throws {
        let fixture = try fixture()
        let view = OverlayView(display: fixture.display)
        defer { view.clear() }
        view.reset(pointer: fixture.global, mode: .area, windows: [], showsToolbar: false)
        var selection = firstPress(on: fixture.display, at: fixture.global)
        view.show(selection: selection, showsReading: false, isDragging: true)
        expectPickerHidden(view)
        view.show(fixture.frame, frozen: true)
        view.movePointer(to: CGPoint(x: fixture.global.x + 0.5, y: fixture.global.y - 0.5))
        expectPickerHidden(view)
        // A click too small to keep a selection still counts as the session's first press.
        selection.reset()
        view.show(selection: selection, showsReading: false, isDragging: false)
        view.switchMode(to: .window, windows: [])
        view.switchMode(to: .area, windows: [])
        view.movePointer(to: fixture.global)
        view.viewDidChangeEffectiveAppearance()
        view.simulate(pointer: fixture.global)
        expectPickerHidden(view)
    }

    @Test func theSharedFirstPressSuppressesThePickerOnOtherDisplaysToo() throws {
        let left = try fixture(origin: CGPoint(x: -800, y: 100))
        let right = try fixture(origin: CGPoint(x: 0, y: 100))
        let views = [OverlayView(display: left.display), OverlayView(display: right.display)]
        defer { views.forEach { $0.clear() } }
        for (view, frame) in zip(views, [left.frame, right.frame]) {
            view.reset(pointer: left.global, mode: .area, windows: [], showsToolbar: false)
            view.show(frame, frozen: true)
        }
        #expect(views[0].debugPointerLayers.loupe != nil)
        var selection = SelectionModel(bounds: left.display.frame.union(right.display.frame), pixelsPerPoint: 2)
        selection.begin(at: left.global)
        for view in views { view.show(selection: selection, showsReading: false, isDragging: true) }
        for view in views { view.movePointer(to: right.global) }
        for view in views { expectPickerHidden(view) }
    }

    @Test func aNewSessionRestoresTheCenteredPickerOnAReusedView() throws {
        let fixture = try fixture()
        let view = OverlayView(display: fixture.display)
        defer { view.clear() }
        view.reset(pointer: fixture.global, mode: .area, windows: [], showsToolbar: false, purpose: .annotate)
        view.show(fixture.frame, frozen: true)
        view.show(selection: firstPress(on: fixture.display, at: fixture.global), showsReading: false, isDragging: true)
        view.enterAnnotation()
        expectPickerHidden(view)
        view.clear()
        view.reset(pointer: fixture.global, mode: .area, windows: [], showsToolbar: false)
        view.show(fixture.frame, frozen: true)
        let lens = try #require(view.debugPointerLayers.loupe)
        #expect(lens.midX == fixture.global.x && lens.midY == fixture.global.y)
        #expect(view.debugPointerLayers.colorReading != nil)
    }

    @Test func standaloneColorPickingKeepsItsOffsetLensAndCrosshair() throws {
        let fixture = try fixture()
        let view = OverlayView(display: fixture.display)
        defer { view.clear() }
        view.reset(pointer: fixture.global, mode: .area, windows: [], showsToolbar: false, purpose: .color)
        view.show(fixture.frame, frozen: true)
        let lens = try #require(view.debugPointerLayers.loupe)
        let offset = Theme.Loupe.offset + Theme.Loupe.diameter / 2
        #expect(lens.midX == fixture.global.x + offset && lens.midY == fixture.global.y - offset)
        #expect(view.debugPointerLayers.crosshair)
        view.show(selection: firstPress(on: fixture.display, at: fixture.global), showsReading: false, isDragging: true)
        #expect(view.debugPointerLayers.loupe == lens && view.debugPointerLayers.colorReading != nil)
    }

    @Test func reusedViewsApplyEverySizeAndRestoreTheStandaloneColorLens() throws {
        let fixture = try fixture()
        let view = OverlayView(display: fixture.display)
        defer { view.clear() }
        for size in [CaptureLoupeSize.large, .small, .medium] {
            view.reset(pointer: fixture.global, mode: .area, windows: [], showsToolbar: false, captureLoupeSize: size)
            view.show(fixture.frame, frozen: true)
            let lens = try #require(view.debugPointerLayers.loupe)
            #expect(lens.size == CGSize(width: size.diameter, height: size.diameter))
            #expect(lens.midX == fixture.global.x && lens.midY == fixture.global.y)
            #expect(view.color(at: fixture.global)?.hex == "#123456")
        }
        view.reset(pointer: fixture.global, mode: .area, windows: [], showsToolbar: false, purpose: .color, captureLoupeSize: .small)
        view.show(fixture.frame, frozen: true)
        #expect(view.debugPointerLayers.loupe?.width == Theme.Loupe.diameter)
        #expect(view.debugPointerLayers.crosshair)
    }

    @Test func selectedPixelContrastFollowsDarkLightAndSaturatedPixelsAcrossAppearanceChanges() throws {
        let samples: [(color: CGColor, pixel: String, stroke: String)] = [
            (CGColor(gray: 0, alpha: 1), "#000000", "#FFFFFF"),
            (CGColor(gray: 1, alpha: 1), "#FFFFFF", "#000000"),
            // Saturated red and blue need opposite strokes despite the same average RGB value.
            (CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1), "#FF0000", "#000000"),
            (CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1), "#0000FF", "#FFFFFF"),
            (CGColor(srgbRed: 0, green: 1, blue: 0, alpha: 1), "#00FF00", "#000000"),
        ]
        for scale in [1, 2] {
            let fixture = try contrastFixture(colors: samples.map(\.color), scale: scale)
            for purpose in [OverlayController.Purpose.screenshot, .annotate, .color] {
                let view = OverlayView(display: fixture.display)
                defer { view.clear() }
                view.reset(pointer: fixture.points[0], mode: .area, windows: [], showsToolbar: false, purpose: purpose)
                view.show(fixture.frame, frozen: true)
                for (point, sample) in zip(fixture.points, samples) {
                    view.movePointer(to: point)
                    for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                        view.appearance = NSAppearance(named: appearance)
                        // An appearance refresh must keep the target's contrast without another move.
                        view.viewDidChangeEffectiveAppearance()
                        let colors = view.debugLoupeCenterColors
                        #expect(colors.stroke.flatMap { ScreenColor($0) }?.hex == sample.stroke)
                        let opposite = sample.stroke == "#FFFFFF" ? "#000000" : "#FFFFFF"
                        #expect(colors.outline.flatMap { ScreenColor($0) }?.hex == opposite)
                        #expect(colors.outlineVisible)
                        #expect(view.color(at: point)?.hex == sample.pixel, "Styling must preserve the raw sampled color")
                    }
                }
            }
        }
    }

    @Test func reusedPickerSessionsResetContrastAndOtherModesRestoreTheirAccent() throws {
        let fixture = try contrastFixture(colors: [CGColor(gray: 0, alpha: 1), CGColor(gray: 1, alpha: 1)], scale: 2)
        let view = OverlayView(display: fixture.display)
        defer { view.clear() }
        for (index, purpose) in [
            OverlayController.Purpose.screenshot, .annotate, .color, .record, .scroll, .screenshot,
        ].enumerated() {
            let point = fixture.points[index % 2]
            let isPicker = purpose == .screenshot || purpose == .annotate || purpose == .color
            view.reset(pointer: point, mode: .area, windows: [], showsToolbar: false, purpose: purpose)
            if isPicker {
                #expect(view.debugLoupeCenterColors.stroke.flatMap { ScreenColor($0) }?.hex == "#FFFFFF",
                        "A fresh session has no sampled pixel until its new frame arrives")
            }
            view.show(fixture.frame, frozen: true)
            view.switchMode(to: .window, windows: [])
            view.switchMode(to: .area, windows: [])
            view.viewDidChangeEffectiveAppearance()
            let expected = isPicker
                ? (index % 2 == 0 ? "#FFFFFF" : "#000000")
                : ScreenColor(Theme.cgColor(.controlAccentColor, for: view.effectiveAppearance))?.hex
            #expect(view.debugLoupeCenterColors.stroke.flatMap { ScreenColor($0) }?.hex == expected)
            #expect(view.debugLoupeCenterColors.outlineVisible == isPicker)
            #expect(view.color(at: point)?.hex == (index % 2 == 0 ? "#000000" : "#FFFFFF"))
        }
    }
}
#endif
