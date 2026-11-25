import AppKit
import CoreGraphics
import Foundation
import Testing
@testable import OMSAnnotate

/// The kept-color chips in the style capsule, pressed directly: nothing is shown on screen.
@MainActor
@Suite(.serialized)
struct KeptColorChipTests {
    private let scratch = ScratchDefaults()

    /// On the 8-bit steps colors are kept at.
    private let kept = RGBA(red: 32.0 / 255, green: 64.0 / 255, blue: 128.0 / 255)

    private func makeCapsule(keeping colors: [RGBA] = []) -> StyleCapsule {
        let saved = SavedColors(defaults: scratch.make())
        for color in colors { saved.add(color) }
        let capsule = StyleCapsule()
        capsule.savedColors = saved
        return capsule
    }

    private func chips(in capsule: StyleCapsule, labeled label: String) -> [CapsuleChip] {
        func walk(_ view: NSView) -> [CapsuleChip] {
            (view as? CapsuleChip).map { [$0] } ?? view.subviews.flatMap(walk)
        }
        return walk(capsule).filter { $0.accessibilityLabel() == label }
    }

    @Test func aColorOfOneIsKeptFromItsPlusChip() throws {
        let capsule = makeCapsule()
        var settings = ToolSettings.defaults(for: .arrow)
        settings.color = RGBA(red: 0.31, green: 0.42, blue: 0.53)
        capsule.show(kind: .arrow, settings: settings, hasSelection: false)
        let plus = try #require(chips(in: capsule, labeled: "Save Color").first)
        #expect(plus.isEnabled)
        plus.performClick(nil)
        #expect(capsule.savedColors.colors == [SavedColors.stored(settings.color)])
    }

    @Test func aFullRowKeepsNoMoreFromADimmedPlusChip() throws {
        let capsule = makeCapsule(keeping: (0..<SavedColors.limit).map { RGBA(red: Double($0 * 16) / 255, green: 0.5, blue: 0.25) })
        var settings = ToolSettings.defaults(for: .arrow)
        settings.color = RGBA(red: 0.31, green: 0.42, blue: 0.53)
        capsule.show(kind: .arrow, settings: settings, hasSelection: false)
        let plus = try #require(chips(in: capsule, labeled: "Save Color").first)
        #expect(!plus.isEnabled && plus.toolTip == "Remove a saved color to make room.")
        plus.performClick(nil)
        #expect(capsule.savedColors.colors.count == SavedColors.limit)
    }

    @Test func aKeptColorIsChosenAgainWithOneClick() throws {
        let capsule = makeCapsule(keeping: [kept])
        var settings = ToolSettings.defaults(for: .arrow)
        capsule.show(kind: .arrow, settings: settings, hasSelection: false)
        var changes: [String] = []
        capsule.onChange = { name, change in
            changes.append(name)
            change(&settings)
        }
        let chip = try #require(chips(in: capsule, labeled: "Saved Color").first)
        chip.performClick(nil)
        #expect(settings.color == kept && changes == ["Color"])
    }

    @Test func aKeptColorIsRemovedFromItsMenuOrWithVoiceOver() throws {
        let capsule = makeCapsule(keeping: [kept, RGBA(red: 0.5, green: 0.25, blue: 0.125)])
        capsule.show(kind: .arrow, settings: ToolSettings.defaults(for: .arrow), hasSelection: false)
        let chip = try #require(chips(in: capsule, labeled: "Saved Color").first)
        let menu = try #require(chip.menu)
        #expect(menu.items.map(\.title) == ["Remove Saved Color"])
        menu.performActionForItem(at: 0)
        #expect(capsule.savedColors.colors == [SavedColors.stored(RGBA(red: 0.5, green: 0.25, blue: 0.125))])

        capsule.show(kind: .arrow, settings: ToolSettings.defaults(for: .arrow), hasSelection: false)
        let again = try #require(chips(in: capsule, labeled: "Saved Color").first)
        let action = try #require(again.accessibilityCustomActions()?.first)
        #expect(action.name == "Remove Saved Color")
        #expect(action.handler?() == true)
        #expect(capsule.savedColors.colors.isEmpty)
    }

    @Test func aColorAlmostAnInkIsNotOfferedToKeep() {
        let capsule = makeCapsule()
        var settings = ToolSettings.defaults(for: .arrow)
        // An off-white the eyedropper might take, 5/255 from White.
        settings.color = RGBA(red: 250.0 / 255, green: 251.0 / 255, blue: 251.0 / 255)
        capsule.show(kind: .arrow, settings: settings, hasSelection: false)
        #expect(chips(in: capsule, labeled: "Save Color").isEmpty)
        // 9/255 away is a color of its own.
        settings.color = RGBA(red: 246.0 / 255, green: 1, blue: 1)
        capsule.show(kind: .arrow, settings: settings, hasSelection: false)
        #expect(chips(in: capsule, labeled: "Save Color").count == 1)
    }

    @Test func theKeptColorsStandBehindADivider() throws {
        func order(_ view: NSView) -> [NSView] {
            view is CapsuleChip || view is NSBox ? [view] : view.subviews.flatMap(order)
        }
        let without = makeCapsule()
        without.show(kind: .arrow, settings: ToolSettings.defaults(for: .arrow), hasSelection: false)
        let plain = order(without)
        let wheel = try #require(plain.firstIndex { $0.accessibilityLabel() == "Other Color…" })
        #expect(!(plain[wheel - 1] is NSBox))

        let with = makeCapsule(keeping: [kept])
        with.show(kind: .arrow, settings: ToolSettings.defaults(for: .arrow), hasSelection: false)
        let views = order(with)
        let first = try #require(views.firstIndex { $0.accessibilityLabel() == "Saved Color" })
        #expect(views[first - 1] is NSBox)
    }

    @Test func colorPanelElevatesAboveHighLevelHostWindowAndRestoresOnRelease() throws {
        _ = NSApplication.shared
        let capsule = makeCapsule()
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 400, height: 100), styleMask: [.borderless], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let hostLevel = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue + 1)
        window.level = hostLevel
        window.contentView?.addSubview(capsule)
        defer {
            capsule.releaseColorPanel()
            window.close()
            NSColorPanel.shared.orderOut(nil)
        }

        let originalLevel = NSColorPanel.shared.level
        let originalHides = NSColorPanel.shared.hidesOnDeactivate
        capsule.show(kind: .arrow, settings: ToolSettings.defaults(for: .arrow), hasSelection: false)
        let wheel = try #require(chips(in: capsule, labeled: "Other Color…").first)

        wheel.performClick(nil)
        #expect(NSColorPanel.shared.level == NSWindow.Level(rawValue: hostLevel.rawValue + 1))
        #expect(!NSColorPanel.shared.hidesOnDeactivate)

        // Opening again while elevated must not overwrite the saved original state.
        wheel.performClick(nil)
        #expect(NSColorPanel.shared.level == NSWindow.Level(rawValue: hostLevel.rawValue + 1))
        #expect(!NSColorPanel.shared.hidesOnDeactivate)

        capsule.releaseColorPanel()
        #expect(NSColorPanel.shared.level == originalLevel)
        #expect(NSColorPanel.shared.hidesOnDeactivate == originalHides)
    }

    @Test func colorPanelRestoresWhenTakenOverByANormalLevelWindow() throws {
        _ = NSApplication.shared
        let elevatedCapsule = makeCapsule()
        let elevatedWindow = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 400, height: 100), styleMask: [.borderless], backing: .buffered, defer: true)
        elevatedWindow.isReleasedWhenClosed = false
        let hostLevel = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue + 1)
        elevatedWindow.level = hostLevel
        elevatedWindow.contentView?.addSubview(elevatedCapsule)

        let normalCapsule = makeCapsule()
        let normalWindow = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 400, height: 100), styleMask: [.borderless], backing: .buffered, defer: true)
        normalWindow.isReleasedWhenClosed = false
        normalWindow.level = .normal
        normalWindow.contentView?.addSubview(normalCapsule)

        defer {
            elevatedCapsule.releaseColorPanel()
            normalCapsule.releaseColorPanel()
            elevatedWindow.close()
            normalWindow.close()
            NSColorPanel.shared.orderOut(nil)
        }

        let originalLevel = NSColorPanel.shared.level
        let originalHides = NSColorPanel.shared.hidesOnDeactivate
        elevatedCapsule.show(kind: .arrow, settings: ToolSettings.defaults(for: .arrow), hasSelection: false)
        normalCapsule.show(kind: .arrow, settings: ToolSettings.defaults(for: .arrow), hasSelection: false)

        try #require(chips(in: elevatedCapsule, labeled: "Other Color…").first).performClick(nil)
        #expect(NSColorPanel.shared.level == NSWindow.Level(rawValue: hostLevel.rawValue + 1))
        #expect(!NSColorPanel.shared.hidesOnDeactivate)

        try #require(chips(in: normalCapsule, labeled: "Other Color…").first).performClick(nil)
        #expect(NSColorPanel.shared.level == originalLevel)
        #expect(NSColorPanel.shared.hidesOnDeactivate == originalHides)
    }

    @Test func savedColorContextMenuLowersHighLevelHostWindowWhileTracking() throws {
        _ = NSApplication.shared
        let capsule = makeCapsule(keeping: [kept])
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 400, height: 100), styleMask: [.borderless], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let hostLevel = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue + 1)
        window.level = hostLevel
        window.contentView?.addSubview(capsule)
        defer { window.close() }

        capsule.show(kind: .arrow, settings: ToolSettings.defaults(for: .arrow), hasSelection: false)
        let chip = try #require(chips(in: capsule, labeled: "Saved Color").first)
        var levelDuringMenu: NSWindow.Level?
        var menuTitles: [String] = []
        chip.popUpMenu = { menu, _, _ in
            levelDuringMenu = window.level
            menuTitles = menu.items.map(\.title)
        }

        let rightClick = try #require(NSEvent.mouseEvent(
            with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
        ))
        chip.rightMouseDown(with: rightClick)
        #expect(menuTitles == ["Remove Saved Color"])
        #expect(levelDuringMenu == NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue - 1))
        #expect(window.level == hostLevel)

        levelDuringMenu = nil
        let controlClick = try #require(NSEvent.mouseEvent(
            with: .leftMouseDown, location: .zero, modifierFlags: [.control], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
        ))
        chip.mouseDown(with: controlClick)
        #expect(levelDuringMenu == NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue - 1))
        #expect(window.level == hostLevel)
    }

    @Test func finishingInPlaceAnnotationReleasesElevatedColorPanel() throws {
        _ = NSApplication.shared
        let context = try #require(CGContext(
            data: nil, width: 400, height: 200, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 400, height: 200))
        let image = try #require(context.makeImage())
        var cancelled = false
        let annotator = InPlaceAnnotationView(
            frame: image, scale: 1, size: CGSize(width: 400, height: 200), selection: CGRect(x: 40, y: 40, width: 120, height: 80),
            actions: .init(copy: { _ in }, save: { _ in }, openInEditor: { _ in }, cancel: { cancelled = true })
        )
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 400, height: 200), styleMask: [.borderless], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let hostLevel = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue + 1)
        window.level = hostLevel
        window.contentView = annotator
        defer {
            annotator.capsule.releaseColorPanel()
            window.close()
            NSColorPanel.shared.orderOut(nil)
        }

        let originalLevel = NSColorPanel.shared.level
        let originalHides = NSColorPanel.shared.hidesOnDeactivate
        annotator.session.tool = .arrow
        let wheel = try #require(chips(in: annotator.capsule, labeled: "Other Color…").first)
        wheel.performClick(nil)
        #expect(NSColorPanel.shared.level == NSWindow.Level(rawValue: hostLevel.rawValue + 1))
        #expect(!NSColorPanel.shared.hidesOnDeactivate)

        // First backOut puts down .arrow to .select; second cancels and calls finish -> releaseColorPanel().
        annotator.backOut()
        annotator.backOut()
        #expect(cancelled)
        #expect(NSColorPanel.shared.level == originalLevel)
        #expect(NSColorPanel.shared.hidesOnDeactivate == originalHides)
    }
}
