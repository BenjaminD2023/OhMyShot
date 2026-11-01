import AppKit
import Foundation
import OMSCore
import SwiftUI

/// Walks the user through the one permission OhMyShot cannot work without, then, while macOS still answers the keys of
/// OhMyShot's shortcuts, through turning its screenshot keys off. A plain window rather than a modal alert: the user has
/// to leave for System Settings and come back.
public final class OnboardingWindowController: NSWindowController, NSWindowDelegate {
    public enum Step {
        case permission, shortcuts
    }

    public var onClose: (() -> Void)?

    private var windowLease: ActiveResources.Lease?

    static let showedShortcutsKey = "onboardingShowedShortcuts"

    /// Whether the shortcuts step has been shown: it opens by itself at launch once, never again.
    public static var hasShownShortcuts: Bool {
        UserDefaults.standard.bool(forKey: showedShortcutsKey)
    }

    /// `readHotKeys` reads macOS's hot keys and `bindings` OhMyShot's shortcuts (scripted checks put others in their place).
    public init(
        permissions: PermissionCenter,
        startingAt step: Step = .permission,
        readHotKeys: @escaping () -> [String: Any]? = SystemScreenshotKeys.readHotKeys,
        bindings: @escaping @MainActor () -> [SystemScreenshotKeys.Binding] = SystemScreenshotKeys.currentBindings,
        relaunch: @escaping () -> Void
    ) {
        let window = OnboardingWindow(
            contentRect: .zero,
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: true
        )
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        // Hidden on screen, read by VoiceOver, which would otherwise say the window has no title.
        window.title = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "OhMyShot"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        let controller = NSHostingController(rootView: OnboardingView(
            permissions: permissions,
            readHotKeys: readHotKeys,
            bindings: bindings,
            relaunch: relaunch,
            close: { [weak self] in self?.close() },
            step: step
        ))
        controller.sizingOptions = [.preferredContentSize]
        window.contentViewController = controller
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    public func show() {
        if windowLease == nil {
            windowLease = ActiveResources.shared.acquire(.window)
        }
        window?.center()
        showWindow(nil)
        AppActivation.bringForward(window)
    }

    public func windowWillClose(_ notification: Notification) {
        windowLease?.end()
        windowLease = nil
        onClose?()
    }
}

/// Closes on Escape at every step. Its buttons take no focus, so the window itself is the first responder, and an Escape
/// no button answers stops in its own `cancelOperation`, before the controller or the view could hear it.
private final class OnboardingWindow: NSWindow {
    override func cancelOperation(_ sender: Any?) {
        close()
    }
}

struct OnboardingView: View {
    let permissions: PermissionCenter
    let readHotKeys: () -> [String: Any]?
    let bindings: @MainActor () -> [SystemScreenshotKeys.Binding]
    let relaunch: () -> Void
    let close: () -> Void

    @State private var step: OnboardingWindowController.Step
    @State private var openedSettings = false
    @State private var clashes: [SystemScreenshotKeys.Clash] = []

    init(
        permissions: PermissionCenter,
        readHotKeys: @escaping () -> [String: Any]?,
        bindings: @escaping @MainActor () -> [SystemScreenshotKeys.Binding],
        relaunch: @escaping () -> Void,
        close: @escaping () -> Void,
        step: OnboardingWindowController.Step
    ) {
        self.permissions = permissions
        self.readHotKeys = readHotKeys
        self.bindings = bindings
        self.relaunch = relaunch
        self.close = close
        _step = State(initialValue: step)
        _clashes = State(initialValue: SystemScreenshotKeys.clashes(hotKeys: readHotKeys(), bindings: bindings()))
    }

    private var isGranted: Bool {
        permissions.status(of: .screenRecording) == .granted
    }

    /// Whether macOS still answers the keys of any of OhMyShot's shortcuts.
    private var keysTaken: Bool {
        clashes.contains(where: \.takenByMacOS)
    }

    private var title: LocalizedStringKey {
        isGranted ? "Screen Recording Is On" : "Allow Screen Recording"
    }

    private var message: LocalizedStringKey {
        if isGranted { return "If captures come out blank, relaunch once." }
        if openedSettings { return "Turn on OhMyShot, then relaunch." }
        return "OhMyShot needs it to capture your screen."
    }

    /// Before macOS's own prompt has appeared, the button only leads to it.
    private var primaryAction: LocalizedStringKey {
        permissions.hasAsked(.screenRecording) ? "Open System Settings" : "Continue"
    }

    /// The first time, macOS's own prompt offers System Settings, so opening it too would ask twice.
    /// macOS prompts only once; after that this opens System Settings itself.
    private func openSettings() {
        openedSettings = true
        if permissions.hasAsked(.screenRecording) {
            permissions.openSystemSettings(for: .screenRecording)
        } else {
            Task { await permissions.request(.screenRecording) }
        }
    }

    @ViewBuilder private var buttons: some View {
        if isGranted && keysTaken {
            // On to the keys; relaunching first comes back to them too, as the next launch opens on them.
            Button(action: relaunch) {
                Text("Relaunch", bundle: .module)
                    .frame(maxWidth: .infinity)
            }
            Button { step = .shortcuts } label: {
                Text("Continue", bundle: .module)
                    .frame(maxWidth: .infinity)
            }
            .keyboardShortcut(.defaultAction)
        } else {
            Button(action: close) {
                Text(isGranted ? "Done" : "Not Now", bundle: .module)
                    .frame(maxWidth: .infinity)
            }
            .keyboardShortcut(.cancelAction)
        }
        if !isGranted && !openedSettings {
            Button(action: openSettings) {
                Text(primaryAction, bundle: .module)
                    .frame(maxWidth: .infinity)
            }
            .keyboardShortcut(.defaultAction)
        }
        if openedSettings && !isGranted || isGranted && !keysTaken {
            Button(action: relaunch) {
                Text("Relaunch", bundle: .module)
                    .frame(maxWidth: .infinity)
            }
            .keyboardShortcut(.defaultAction)
        }
    }

    var body: some View {
        Group {
            switch step {
            case .permission: permissionStep
            case .shortcuts: shortcutsStep
            }
        }
        .padding(.horizontal, 28)
        .padding(.top, 36)
        .padding(.bottom, 24)
        .frame(width: 380)
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            permissions.refresh([.screenRecording])
            clashes = SystemScreenshotKeys.clashes(hotKeys: readHotKeys(), bindings: bindings())
        }
    }

    private var permissionStep: some View {
        VStack(spacing: 16) {
            Image(systemName: isGranted ? "checkmark.circle" : "rectangle.dashed")
                .font(.system(size: 40, weight: .regular))
                .foregroundStyle(.tint)
                .accessibilityHidden(true)

            VStack(spacing: 6) {
                Text(title, bundle: .module)
                    .font(.title2.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                Text(message, bundle: .module)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if openedSettings && !isGranted {
                    Button(action: openSettings) {
                        Text("Open System Settings", bundle: .module)
                    }
                    .buttonStyle(.link)
                }
            }
            .multilineTextAlignment(.center)

            ButtonRow { buttons }
            .controlSize(.large)
            .padding(.top, 8)
        }
    }

    private var shortcutsStep: some View {
        VStack(spacing: 16) {
            Image(systemName: keysTaken ? "keyboard" : "checkmark.circle")
                .font(.system(size: 40, weight: .regular))
                .foregroundStyle(.tint)
                .accessibilityHidden(true)

            VStack(spacing: 6) {
                Text(keysTaken ? "Turn Off macOS’s Screenshot Keys" : "OhMyShot Has Its Keys", bundle: .module)
                    .font(.title2.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                Text(
                    keysTaken
                        ? "macOS answers these keys before OhMyShot can. Turn them off in Keyboard Settings › Keyboard Shortcuts › Screenshots."
                        : "macOS’s screenshot keys are off, so these keys capture with OhMyShot.",
                    bundle: .module
                )
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            .multilineTextAlignment(.center)

            if !clashes.isEmpty {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                    ForEach(clashes) { clash in
                        GridRow {
                            Text(verbatim: clash.keys)
                                .monospacedDigit()
                            Text(clash.shortcut.title)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Group {
                                if clash.takenByMacOS {
                                    Text(verbatim: "macOS")
                                        .foregroundStyle(.secondary)
                                } else {
                                    Label { Text(verbatim: "OhMyShot") } icon: { Image(systemName: "checkmark") }
                                        .foregroundStyle(.tint)
                                }
                            }
                            .gridColumnAlignment(.trailing)
                        }
                    }
                }
                .padding(.horizontal, 8)
                // A row's modifiers go to each of its cells: VoiceOver gets one element a row from here instead.
                .accessibilityChildren {
                    ForEach(clashes) { clash in
                        Text(verbatim: "\(clash.shortcut.title), \(clash.keys)")
                            .accessibilityValue(Text(verbatim: clash.takenByMacOS ? "macOS" : "OhMyShot"))
                    }
                }
            }

            ButtonRow {
                if keysTaken {
                    Button(action: close) {
                        Text("Not Now", bundle: .module)
                            .frame(maxWidth: .infinity)
                    }
                    .keyboardShortcut(.cancelAction)
                    Button {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")!)
                    } label: {
                        Text("Open Keyboard Settings", bundle: .module)
                            .frame(maxWidth: .infinity)
                    }
                    .keyboardShortcut(.defaultAction)
                } else {
                    Button(action: close) {
                        Text("Done", bundle: .module)
                            .frame(maxWidth: .infinity)
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
            .controlSize(.large)
            .padding(.top, 8)
        }
        // Shown once is enough: it never opens by itself again.
        .onAppear { UserDefaults.standard.set(true, forKey: OnboardingWindowController.showedShortcutsKey) }
    }
}

/// Buttons of one width side by side, or one above the other, full width, when a language's labels are too long for
/// each to fit its share of the row. The community invitation lays its buttons out the same way.
struct ButtonRow: Layout {
    var horizontalSpacing: CGFloat = 10
    var verticalSpacing: CGFloat = 8

    private func fitsInRow(_ subviews: Subviews, width: CGFloat?) -> Bool {
        guard let width, !subviews.isEmpty else { return true }
        let widest = subviews.map { $0.sizeThatFits(.unspecified).width }.max() ?? 0
        let count = CGFloat(subviews.count)
        return widest * count + horizontalSpacing * (count - 1) <= width
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let width = proposal.width ?? sizes.map(\.width).reduce(0, +)
        let height = sizes.map(\.height).max() ?? 0
        if fitsInRow(subviews, width: proposal.width) {
            return CGSize(width: width, height: height)
        }
        let count = CGFloat(subviews.count)
        return CGSize(width: width, height: sizes.map(\.height).reduce(0, +) + verticalSpacing * (count - 1))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let count = CGFloat(subviews.count)
        if fitsInRow(subviews, width: bounds.width) {
            let width = (bounds.width - horizontalSpacing * (count - 1)) / count
            for (index, subview) in subviews.enumerated() {
                let x = bounds.minX + CGFloat(index) * (width + horizontalSpacing)
                subview.place(at: CGPoint(x: x, y: bounds.minY), proposal: ProposedViewSize(width: width, height: bounds.height))
            }
        } else {
            // The default button, last and rightmost in a row, on top, as in a stacked alert.
            var y = bounds.minY
            for subview in subviews.reversed() {
                let height = subview.sizeThatFits(.unspecified).height
                subview.place(at: CGPoint(x: bounds.minX, y: y), proposal: ProposedViewSize(width: bounds.width, height: height))
                y += height + verticalSpacing
            }
        }
    }
}
