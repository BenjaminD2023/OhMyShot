import AppKit
import OMSCore
import Testing
@testable import OMSCapture

@MainActor
struct WindowPickerTests {
    private let main = DisplayInfo(
        id: 1, name: "Main", frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
        pixelSize: CGSize(width: 2880, height: 1800), backingScale: 2, maximumPotentialEDR: 1
    )
    private let other = DisplayInfo(
        id: 2, name: "Other", frame: CGRect(x: -1920, y: -180, width: 1920, height: 1080),
        pixelSize: CGSize(width: 1920, height: 1080), backingScale: 1, maximumPotentialEDR: 1
    )
    private var layout: DisplayLayout { DisplayLayout(displays: [main, other]) }
    private var game: WindowCatalog.Choice {
        WindowCatalog.Choice(target: WindowTarget(id: 99, frame: other.frame, ownerName: "Game", title: "全屏游戏"), processID: 999, isOnScreen: false)
    }
    private var browser: WindowCatalog.Choice {
        WindowCatalog.Choice(target: WindowTarget(id: 100, frame: main.frame, ownerName: "Safari", title: "Documentation"), processID: 998, isOnScreen: true)
    }

    private func descendants(of view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + descendants(of: $0) } }
    private func frame(width: Int = 960) throws -> CGImage {
        let context = try #require(CGContext(data: nil, width: width, height: 540, bitsPerComponent: 8, bytesPerRow: 0,
                                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.07, green: 0.13, blue: 0.18, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: 540))
        context.setFillColor(CGColor(red: 0.14, green: 0.25, blue: 0.30, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: 160))
        let graphics = NSGraphicsContext(cgContext: context, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        ("FULL-SCREEN GAME" as NSString).draw(at: CGPoint(x: 64, y: 300), withAttributes: [.font: NSFont.systemFont(ofSize: 40, weight: .semibold), .foregroundColor: NSColor.white])
        ("Window preview fixture" as NSString).draw(at: CGPoint(x: 66, y: 260), withAttributes: [.font: NSFont.systemFont(ofSize: 20), .foregroundColor: NSColor.lightGray])
        NSGraphicsContext.restoreGraphicsState()
        return try #require(context.makeImage())
    }

    @Test func aWindowUsesItsOwnDisplayIncludingNegativeCoordinatesAndMixedScales() {
        #expect(game.target.display(in: layout) == other)
        let crossing = WindowTarget(id: 1, frame: CGRect(x: -900, y: 50, width: 1000, height: 500), ownerName: "App", title: nil)
        #expect(crossing.display(in: layout) == other)
        let detached = WindowTarget(id: 2, frame: CGRect(x: 8000, y: 0, width: 800, height: 600), ownerName: "App", title: nil)
        #expect(detached.display(in: layout) == main)
        #expect(detached.display(in: DisplayLayout(displays: [])) == nil)
    }

    @Test func applicationsReplaceTheFlatWindowListAndPreferTheUsersCurrentApp() {
        let second = WindowCatalog.Choice(target: WindowTarget(id: 101, frame: main.frame, ownerName: "Safari", title: "Swift reference"), processID: 998, isOnScreen: true)
        var model = WindowPickerModel()
        model.replace([browser, second, game, game], preferredProcessID: game.processID)
        #expect(model.applications.count == 2)
        #expect(model.selected == game)
        #expect(model.application?.windows.count == 1)
        model.selectApplication(browser.processID)
        #expect(model.application?.windows.count == 2)
        model.selectWindow(second.target.id)
        model.selectApplication(game.processID)
        model.selectApplication(browser.processID)
        #expect(model.selected == second)
        model.filter("SWIFT reference")
        #expect(model.applications.count == 1 && model.application?.windows.count == 1 && model.selected == second)
        model.filter("游戏")
        #expect(model.selected == game)
        model.filter("missing app")
        #expect(model.selected == nil && model.applications.isEmpty)
        model.filter("")
        model.replace([game], preferredProcessID: nil)
        #expect(model.applications.count == 1 && model.selected == game)
    }

    @Test func theInitialPreviewIsTheOnlyWindowCapturedUntilTheUserChoosesAnotherApp() async throws {
        let image = try frame(), game = game, browser = browser
        var previews: [UInt32] = []
        let picker = WindowPickerController(layout: layout, recording: nil, preferredProcessID: game.processID,
                                            load: { [browser, game] }, preview: { previews.append($0.id); return image })
        defer { picker.close() }
        let panel = try #require(picker.window)
        let root = try #require(panel.contentView)
        #expect(panel.styleMask.contains(.nonactivatingPanel) && panel.collectionBehavior.contains(.fullScreenAuxiliary))
        let capture = try #require(descendants(of: root).compactMap { $0 as? NSButton }.first { $0.title == "Capture" })
        var captured: WindowTarget?
        picker.onChoose = { target, choices in captured = target; #expect(choices == nil) }
        #expect(!capture.isEnabled)
        await picker.reload().value
        #expect(previews == [game.target.id])
        #expect(capture.isEnabled)
        #expect(descendants(of: root).compactMap { $0 as? NSTableView }.isEmpty)
        #expect(descendants(of: root).compactMap { $0 as? NSPopUpButton }.first?.isHidden == true)
        #expect(descendants(of: root).compactMap { $0 as? NSSearchField }.first?.isHidden == true)
        capture.performClick(nil)
        #expect(captured == game.target && !panel.isVisible)
    }

    @Test func aLatePreviewCannotReplaceTheNewlyChosenApp() async throws {
        let game = game, browser = browser, firstImage = try frame(width: 960), secondImage = try frame(width: 800)
        let started = AsyncStream<Void>.makeStream()
        let secondReady = AsyncStream<Void>.makeStream()
        var pending: CheckedContinuation<CGImage, any Error>?
        let picker = WindowPickerController(layout: layout, recording: nil, preferredProcessID: game.processID, load: { [game, browser] }) { target in
            if target.id == game.target.id {
                return try await withCheckedThrowingContinuation { pending = $0; started.continuation.yield(()) }
            }
            secondReady.continuation.yield(())
            return secondImage
        }
        defer { picker.close() }
        let load = picker.reload()
        for await _ in started.stream { break }
        let root = try #require(picker.window?.contentView)
        let appButton = try #require(descendants(of: root).compactMap { $0 as? NSButton }.first { $0.tag == Int(browser.processID) })
        appButton.performClick(nil)
        for await _ in secondReady.stream { break }
        pending?.resume(returning: firstImage)
        await load.value
        #expect(picker.model.selected?.target.id == browser.target.id)
        let image = try #require(descendants(of: root).compactMap { $0 as? NSImageView }.first?.image)
        #expect(image.cgImage(forProposedRect: nil, context: nil, hints: nil)?.width == 800)
    }

    @Test func unavailablePreviewsAndFailedRefreshCannotStartRecording() async throws {
        let game = game, image = try frame()
        var failLoad = false, failPreview = true
        let picker = WindowPickerController(layout: layout, recording: RecordingChoices(systemAudio: true), load: {
            if failLoad { throw CocoaError(.fileReadUnknown) }
            return [game]
        }, preview: { _ in
            if failPreview { throw CaptureError.windowNotFound(game.target.id) }
            return image
        })
        defer { picker.close() }
        let root = try #require(picker.window?.contentView)
        let bar = try #require(descendants(of: root).compactMap { $0 as? RecordingBar }.first)
        var targets: [WindowTarget] = []
        picker.onChoose = { target, _ in targets.append(target) }
        await picker.reload().value
        #expect(!bar.canRecord)
        bar.onRecord?()
        #expect(targets.isEmpty)
        failPreview = false
        await picker.reload().value
        #expect(bar.canRecord)
        bar.onRecord?()
        #expect(targets == [game.target])
        failLoad = true
        await picker.reload().value
        #expect(!bar.canRecord && picker.model.selected == nil)
        bar.onRecord?()
        #expect(targets.count == 1)
    }

    @Test(arguments: [false, true], [false, true])
    func aSinglePreviewAndCompactControlsFitInLightAndDark(recording: Bool, dark: Bool) async throws {
        let image = try frame(), game = game, browser = browser
        let extra = ["Preview", "Terminal", "Notes", "Music", "Calendar", "Messages", "Long Application Name"].enumerated().map { index, name in
            WindowCatalog.Choice(target: WindowTarget(id: UInt32(200 + index), frame: main.frame, ownerName: name, title: "Document"), processID: pid_t(2000 + index), isOnScreen: false)
        }
        let picker = WindowPickerController(layout: layout, recording: recording ? RecordingChoices() : nil,
                                            preferredProcessID: game.processID, offersBack: true, load: { [game, browser] + extra }, preview: { _ in image })
        defer { picker.close() }
        let panel = try #require(picker.window)
        panel.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let root = try #require(panel.contentView)
        await picker.reload().value
        root.layoutSubtreeIfNeeded()
        let views = descendants(of: root)
        #expect(!root.hasAmbiguousLayout)
        #expect(root.bounds.width == 620 && root.bounds.height == 452)
        let preview = try #require(views.compactMap { $0 as? NSImageView }.first)
        #expect(preview.frame.width > 500 && preview.frame.height > 180)
        for control in views.compactMap({ $0 as? NSControl }) where !control.isHiddenOrHasHiddenAncestor {
            if control.enclosingScrollView != nil { continue }
            let rect = control.convert(control.bounds, to: root)
            #expect(root.bounds.insetBy(dx: -1, dy: -1).contains(rect), "\(type(of: control)): \(rect)")
        }
        if recording {
            let bar = try #require(views.compactMap { $0 as? RecordingBar }.first)
            let buttons = descendants(of: bar).compactMap { $0 as? NSButton }
            #expect(buttons.count == 5)
            #expect(!buttons.contains { $0.accessibilityLabel() == "Camera" || $0.accessibilityLabel() == "Show Keystrokes" })
        }
        if let directory = ProcessInfo.processInfo.environment["OMS_WINDOW_PICKER_SNAPSHOTS"] {
            let bitmap = try #require(root.bitmapImageRepForCachingDisplay(in: root.bounds))
            root.cacheDisplay(in: root.bounds, to: bitmap)
            let data = try #require(bitmap.representation(using: .png, properties: [:]))
            let folder = URL(fileURLWithPath: directory, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try data.write(to: folder.appending(path: "window-picker-\(recording ? "record" : "capture")-\(dark ? "dark" : "light").png"))
        }
    }
}
