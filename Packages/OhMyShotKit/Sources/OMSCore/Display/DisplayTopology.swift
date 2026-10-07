import AppKit
import CoreGraphics
import Observation
import OSLog

/// The live display arrangement, rebuilt whenever a display is attached, removed, or changes mode.
@MainActor
@Observable
public final class DisplayTopology {
    public private(set) var layout: DisplayLayout

    /// Runs after each change, for example to dismiss an overlay sized for the old arrangement.
    @ObservationIgnored public var onChange: ((DisplayLayout) -> Void)?

    @ObservationIgnored private var observer: (any NSObjectProtocol)?

    public init() {
        layout = Self.currentLayout()
        observer = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.rebuild() }
        }
    }

    public func rebuild() {
        let next = Self.currentLayout()
        guard next != layout else { return }
        layout = next
        Log.display.notice("Display arrangement changed: \(next.displays.count, privacy: .public) display(s)")
        onChange?(next)
    }

    public static func currentLayout() -> DisplayLayout {
        DisplayLayout(displays: NSScreen.screens.compactMap(DisplayInfo.init(screen:)))
    }
}

extension DisplayInfo {
    @MainActor
    init?(screen: NSScreen) {
        guard let id = screen.cgDirectDisplayID else { return nil }
        let pixelSize: CGSize
        if let mode = CGDisplayCopyDisplayMode(id) {
            pixelSize = CGSize(width: mode.pixelWidth, height: mode.pixelHeight)
        } else {
            pixelSize = CGSize(
                width: screen.frame.width * screen.backingScaleFactor,
                height: screen.frame.height * screen.backingScaleFactor
            )
        }
        self.init(
            id: id,
            name: screen.localizedName,
            frame: screen.frame,
            pixelSize: pixelSize,
            backingScale: screen.backingScaleFactor,
            maximumPotentialEDR: screen.maximumPotentialExtendedDynamicRangeColorComponentValue
        )
    }
}
