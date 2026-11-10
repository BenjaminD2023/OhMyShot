import AppKit
import Foundation
import Observation
import OMSCore
import OMSDesign
import SwiftUI

/// A nonmodal first-use guide. Permission repair uses just its permission page; explicit replay and new
/// installations use the four-step tour. The owner keeps progress when this window leaves for a capture or relaunch.
public final class OnboardingWindowController: NSWindowController, NSWindowDelegate {
    public typealias Step = OnboardingProgress.Step

    public enum Mode {
        case tour, permissionRecovery
    }

    /// Scripted previews and tests supply their own permission state, without changing TCC or asking for access.
    public struct Access {
        public var isGranted: () -> Bool
        public var hasAsked: () -> Bool
        public var refresh: () -> Void
        public var request: () async -> Void
        public var openSettings: () -> Void

        public init(
            isGranted: @escaping () -> Bool, hasAsked: @escaping () -> Bool,
            refresh: @escaping () -> Void, request: @escaping () async -> Void, openSettings: @escaping () -> Void
        ) {
            self.isGranted = isGranted
            self.hasAsked = hasAsked
            self.refresh = refresh
            self.request = request
            self.openSettings = openSettings
        }

        static func live(_ permissions: PermissionCenter) -> Self {
            Self(
                isGranted: { permissions.status(of: .screenRecording) == .granted },
                hasAsked: { permissions.hasAsked(.screenRecording) },
                refresh: { permissions.refresh([.screenRecording]) },
                request: { await permissions.request(.screenRecording) },
                openSettings: { permissions.openSystemSettings(for: .screenRecording) }
            )
        }
    }

    public var onClose: (() -> Void)?
    public var onDismiss: (() -> Void)?
    private var continuing = false
    private var windowLease: ActiveResources.Lease?
    let model: OnboardingModel

    public var currentStep: Step { model.step }
    public var isTour: Bool { model.mode == .tour }

    public init(
        permissions: PermissionCenter,
        startingAt step: Step = .permission,
        mode: Mode = .permissionRecovery,
        readHotKeys: @escaping () -> [String: Any]? = SystemScreenshotKeys.readHotKeys,
        bindings: @escaping @MainActor () -> [SystemScreenshotKeys.Binding] = SystemScreenshotKeys.currentBindings,
        access: Access? = nil,
        captureMessage: String? = nil,
        cardCorner: QuickAccessCorner = .bottomLeft,
        stepChanged: @escaping (Step) -> Void = { _ in },
        openShortcuts: @escaping () -> Void = {},
        capture: @escaping () -> Void = {},
        relaunch: @escaping () -> Void
    ) {
        model = OnboardingModel(
            step: step, mode: mode, access: access ?? .live(permissions), readHotKeys: readHotKeys,
            bindings: bindings, stepChanged: stepChanged
        )
        let window = OnboardingWindow(
            contentRect: .zero,
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: true
        )
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.title = String(localized: "Getting Started", bundle: .module)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        let content = NSHostingController(rootView: OnboardingView(
            model: model, captureMessage: captureMessage, cardCorner: cardCorner, openShortcuts: openShortcuts,
            capture: capture, relaunch: relaunch, close: { [weak self] in self?.close() }
        ))
        content.sizingOptions = [.minSize]
        window.contentViewController = content
        window.setContentSize(NSSize(width: 600, height: mode == .tour ? 600 : 560))
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public func show() {
        model.refresh()
        if windowLease == nil { windowLease = ActiveResources.shared.acquire(.window) }
        if window?.isVisible != true {
            if let window, let screen = window.screen ?? NSScreen.main {
                let size = window.frame.size
                window.setFrame(NSRect(origin: window.frame.origin, size: NSSize(
                    width: min(size.width, screen.visibleFrame.width), height: min(size.height, screen.visibleFrame.height)
                )), display: false)
            }
            window?.center()
        }
        showWindow(nil)
        AppActivation.bringForward(window)
    }

    /// A programmatic close for a capture, or quitting for a permission change, must not count as skipping.
    public func preserveProgress() { continuing = true }

    public func closeForCapture() {
        preserveProgress()
        close()
    }

    public func windowDidBecomeKey(_ notification: Notification) { model.refresh() }

    public func windowWillClose(_ notification: Notification) {
        if !continuing { onDismiss?() }
        windowLease?.end()
        windowLease = nil
        onClose?()
    }
}

private final class OnboardingWindow: NSWindow {
    override func cancelOperation(_ sender: Any?) { performClose(sender) }
}

@Observable
final class OnboardingModel {
    typealias Step = OnboardingProgress.Step
    private(set) var step: Step
    let mode: OnboardingWindowController.Mode
    private(set) var isGranted = false
    private(set) var hasAsked = false
    private(set) var isRequesting = false
    private(set) var clashes: [SystemScreenshotKeys.Clash] = []
    private(set) var shortcuts: [SystemScreenshotKeys.Binding] = []
    private let access: OnboardingWindowController.Access
    private let readHotKeys: () -> [String: Any]?
    private let bindings: () -> [SystemScreenshotKeys.Binding]
    private let stepChanged: (Step) -> Void

    var keysTaken: Bool { clashes.contains(where: \.takenByMacOS) }
    var shownShortcuts: [CaptureShortcut] {
        let main: [CaptureShortcut] = [.captureArea, .captureFullscreen, .allInOne]
        return main + clashes.filter { $0.takenByMacOS && !main.contains($0.shortcut) }.map(\.shortcut)
    }
    var index: Int { Step.allCases.firstIndex(of: step) ?? 0 }
    /// The top of the status menu as it is, with the current keys: what the welcome page shows under the icon.
    var menuEntries: [MenuBarPreview.Entry] {
        [CaptureShortcut.captureArea, .captureWindow, .captureFullscreen].map { shortcut in
            MenuBarPreview.Entry(title: shortcut.title, keys: shortcuts.first { $0.shortcut == shortcut }?.keys)
        }
    }

    init(
        step: Step, mode: OnboardingWindowController.Mode, access: OnboardingWindowController.Access,
        readHotKeys: @escaping () -> [String: Any]?, bindings: @escaping () -> [SystemScreenshotKeys.Binding],
        stepChanged: @escaping (Step) -> Void
    ) {
        self.step = step
        self.mode = mode
        self.access = access
        self.readHotKeys = readHotKeys
        self.bindings = bindings
        self.stepChanged = stepChanged
        refresh()
    }

    func refresh() {
        access.refresh()
        isGranted = access.isGranted()
        hasAsked = access.hasAsked()
        shortcuts = bindings()
        clashes = SystemScreenshotKeys.clashes(hotKeys: readHotKeys(), bindings: shortcuts)
    }

    func move(to step: Step) {
        self.step = step
        stepChanged(step)
        refresh()
    }

    func back() {
        guard index > 0 else { return }
        move(to: Step.allCases[index - 1])
    }

    func next() {
        guard index < Step.allCases.count - 1, step != .permission || isGranted else { return }
        move(to: Step.allCases[index + 1])
    }

    func requestAccess() async {
        guard !isRequesting else { return }
        isRequesting = true
        defer { isRequesting = false }
        if access.hasAsked() { access.openSettings() } else { await access.request() }
        refresh()
    }
}

private extension OnboardingProgress.Step {
    var title: String {
        switch self {
        case .welcome: String(localized: "Welcome", bundle: .module)
        case .permission: String(localized: "Screen Recording", bundle: .module)
        case .shortcuts: String(localized: "Shortcuts", bundle: .module)
        case .capture: String(localized: "Your First Capture", bundle: .module)
        }
    }
}

private struct OnboardingView: View {
    @Bindable var model: OnboardingModel
    let captureMessage: String?
    let cardCorner: QuickAccessCorner
    let openShortcuts: () -> Void
    let capture: () -> Void
    let relaunch: () -> Void
    let close: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        VStack(spacing: 0) {
            if model.mode == .tour { progress.padding(.horizontal, 32).padding(.top, 38).padding(.bottom, 4) }
            // A new step starts at its top and fades in over the last one, in place; at once under Reduce Motion.
            ZStack {
                ScrollView {
                    VStack(spacing: 0) {
                        switch model.step {
                        case .welcome: welcome
                        case .permission: permission
                        case .shortcuts: shortcuts
                        case .capture: practice
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 40)
                    .padding(.top, model.mode == .tour ? 24 : 44)
                    .padding(.bottom, 24)
                }
                .scrollBounceBehavior(.basedOnSize)
                .id(model.step)
                .transition(.opacity)
            }
            .frame(maxHeight: .infinity)
            // The fade is the step's alone: the progress line and the buttons change at once.
            .animation(reduceMotion ? nil : .easeOut(duration: Theme.Motion.slide), value: model.step)
            Divider()
            footer.padding(.horizontal, 24).padding(.vertical, 20)
        }
        .frame(minWidth: 520, minHeight: 440)
        .background(Color(nsColor: .windowBackgroundColor))
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in model.refresh() }
    }

    // MARK: Progress

    /// Every step by name, so what is left is plain from the first page: done and current segments in the accent.
    private var progress: some View {
        HStack(alignment: .top, spacing: 8) {
            ForEach(Array(OnboardingProgress.Step.allCases.enumerated()), id: \.offset) { index, step in
                VStack(alignment: .leading, spacing: 7) {
                    Capsule()
                        .fill(index <= model.index ? Color.accentColor : Color.primary.opacity(contrast == .increased ? 0.25 : 0.1))
                        .frame(height: 3)
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        if index < model.index {
                            Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.tint)
                        }
                        Text(verbatim: step.title)
                            .font(.system(size: 11, weight: index == model.index ? .semibold : .regular))
                            .foregroundStyle(index == model.index ? .primary : .secondary)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Step \(model.index + 1) of 4", bundle: .module))
        .accessibilityValue(Text(verbatim: model.step.title))
    }

    // MARK: Pieces

    private func heading(_ title: LocalizedStringKey, message: LocalizedStringKey) -> some View {
        VStack(spacing: 8) {
            Text(title, bundle: .module)
                .font(.system(size: 26, weight: .semibold))
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            Text(message, bundle: .module)
                .font(.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: OnboardingColumn.width)
    }

    /// Instructions in the order they are done, numbered because the order matters.
    private func steps(_ items: [LocalizedStringKey]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(verbatim: "\(index + 1)")
                        .font(.system(size: 11, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: 20, height: 20)
                        .background(Color.primary.opacity(contrast == .increased ? 0.14 : 0.07), in: Circle())
                        .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
                        .accessibilityHidden(true)
                    Text(item, bundle: .module).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(width: OnboardingColumn.width, alignment: .leading)
        .accessibilityElement(children: .contain)
    }

    private func footnote(_ text: LocalizedStringKey) -> some View {
        Text(text, bundle: .module)
            .font(.callout).foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: OnboardingColumn.width)
    }

    /// A sentence with its one action beside it, for what only some people need: a relaunch, other keys.
    private func aside(_ text: LocalizedStringKey, action title: LocalizedStringKey, perform: @escaping () -> Void) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) {
                Text(text, bundle: .module).foregroundStyle(.secondary)
                Button(action: perform) { Text(title, bundle: .module) }.buttonStyle(.link)
            }
            VStack(spacing: 4) {
                Text(text, bundle: .module).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Button(action: perform) { Text(title, bundle: .module) }.buttonStyle(.link)
            }
        }
        .font(.callout)
        .frame(maxWidth: OnboardingColumn.width)
    }

    // MARK: Steps

    private var welcome: some View {
        VStack(spacing: 0) {
            Image(nsImage: AppActivation.appIcon).resizable().interpolation(.high)
                .frame(width: 72, height: 72).accessibilityHidden(true)
                .padding(.bottom, 14)
            heading("Welcome to OhMyShot", message: "Allow Screen Recording, check your shortcuts, and take your first screenshot. It takes about a minute.")
                .padding(.bottom, 24)
            MenuBarPreview(entries: model.menuEntries)
                .padding(.bottom, 12)
            footnote("OhMyShot lives in the menu bar, not the Dock. Click its icon to capture, or open the app from Finder or Spotlight for Settings.")
        }
    }

    private var permission: some View {
        VStack(spacing: 0) {
            ScreenRecordingSettingsPreview(isOn: model.isGranted)
                .animation(reduceMotion ? nil : .snappy(duration: Theme.Motion.slide), value: model.isGranted)
                .padding(.bottom, 20)
            if model.isGranted {
                heading("Screen Recording Is On", message: "You’re ready to capture your screen.")
                    .padding(.bottom, 20)
                if model.hasAsked {
                    aside("If captures come out blank, relaunch once.", action: "Relaunch", perform: relaunch)
                        .padding(.bottom, 20)
                }
            } else {
                heading("Allow Screen Recording", message: "macOS requires it before any app can capture the screen, screenshots included.")
                    .padding(.bottom, 16)
                steps([
                    model.hasAsked ? "Click Open System Settings." : "Click Allow Screen Recording, then choose Open System Settings in the prompt.",
                    "Turn on OhMyShot under Screen & System Audio Recording.",
                    "If macOS asks, choose Quit & Reopen. The guide continues where you left off.",
                ])
                .padding(.bottom, 16)
                if model.hasAsked {
                    aside("Already turned it on?", action: "Relaunch OhMyShot", perform: relaunch)
                        .padding(.bottom, 12)
                }
            }
            footnote("Microphone, camera, and other permissions are only requested when a feature needs them.")
        }
    }

    private var shortcuts: some View {
        VStack(spacing: 0) {
            Group {
                if model.keysTaken {
                    heading("Free up your screenshot keys", message: "macOS’s own screenshot shortcuts use these keys first, so OhMyShot never receives them.")
                } else if !model.clashes.isEmpty {
                    heading("Your shortcuts are ready", message: "macOS’s screenshot keys are off, so these keys capture with OhMyShot.")
                } else {
                    heading("Capture from any app", message: "Use these shortcuts from any app, or choose a capture from the menu bar.")
                }
            }
            .padding(.bottom, 22)
            shortcutList
                .padding(.bottom, 16)
            if model.keysTaken {
                steps(["In Keyboard Settings, open Keyboard Shortcuts, then Screenshots.", "Turn off the ones that use the keys above."])
                    .padding(.bottom, 16)
            }
            Button(action: openShortcuts) { Text("Choose Different Shortcuts…", bundle: .module) }
                .buttonStyle(.link)
                .font(.callout)
        }
    }

    private var shortcutList: some View {
        VStack(spacing: 0) {
            ForEach(Array(model.shownShortcuts.enumerated()), id: \.element) { index, shortcut in
                let taken = model.clashes.contains { $0.shortcut == shortcut && $0.takenByMacOS }
                if index > 0 { Divider().padding(.leading, 14) }
                HStack(spacing: 10) {
                    Text(shortcut.title).lineLimit(1)
                    Spacer(minLength: 8)
                    if taken {
                        Label { Text("Used by macOS", bundle: .module) } icon: { Image(systemName: "exclamationmark.triangle.fill") }
                            .font(.callout)
                            .foregroundStyle(.orange)
                            .lineLimit(1)
                    }
                    if let binding = model.shortcuts.first(where: { $0.shortcut == shortcut }) {
                        KeyCaps(keys: binding.keys).opacity(taken ? 0.55 : 1)
                    } else {
                        Text("Not set", bundle: .module).foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 14)
                .frame(minHeight: 40)
                .accessibilityElement(children: .combine)
            }
        }
        .frame(width: OnboardingColumn.width)
        .guideWell()
    }

    private var practice: some View {
        VStack(spacing: 0) {
            FirstCapturePreview(cardsOnLeft: cardCorner.slidesFromLeft)
                .padding(.bottom, 24)
            heading("Take your first screenshot", message: "Drag over any part of the screen, then let go. Press Esc to cancel.")
                .padding(.bottom, 20)
            footnote(cardCorner.slidesFromLeft
                ? "When you let go, a card with your screenshot appears in the bottom-left corner, ready to copy, save, or mark up."
                : "When you let go, a card with your screenshot appears in the bottom-right corner, ready to copy, save, or mark up.")
                .padding(.bottom, 16)
            if let keys = model.shortcuts.first(where: { $0.shortcut == .captureArea })?.keys,
               !model.clashes.contains(where: { $0.shortcut == .captureArea && $0.takenByMacOS }) {
                HStack(spacing: 8) {
                    Text("Or from any app:", bundle: .module).font(.callout).foregroundStyle(.secondary)
                    KeyCaps(keys: keys)
                }
                .accessibilityElement(children: .combine)
                .padding(.bottom, 16)
            }
            if let captureMessage {
                VStack(spacing: 6) {
                    Label { Text(captureMessage).fixedSize(horizontal: false, vertical: true) } icon: {
                        Image(systemName: "exclamationmark.circle").foregroundStyle(.orange)
                    }
                    Button(action: relaunch) { Text("Relaunch", bundle: .module) }.buttonStyle(.link)
                }
                .font(.callout)
                .padding(12)
                .frame(width: OnboardingColumn.width)
                // The guide's own well: the warning is the symbol's orange, never a tint behind the words.
                .guideWell()
            }
        }
    }

    // MARK: Footer

    private var footer: some View {
        GuideFooterLayout {
            Button(action: close) { Text(model.mode == .tour ? "Skip Guide" : "Not Now", bundle: .module) }
                .buttonStyle(.link)
                .keyboardShortcut(.cancelAction)
            if model.mode == .tour, model.index > 0 {
                Button { model.back() } label: { Text("Back", bundle: .module) }.controlSize(.large)
            }
            if model.step == .shortcuts, model.keysTaken {
                Button { model.next() } label: { Text("Set Up Later", bundle: .module) }.controlSize(.large)
            }
            Button(action: primaryAction) {
                Text(primaryTitle, bundle: .module).padding(.horizontal, 8)
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            .disabled(model.isRequesting)
        }
    }

    private var primaryTitle: LocalizedStringKey {
        switch model.step {
        case .welcome: "Get Started"
        case .permission:
            if model.isGranted { model.mode == .tour ? "Continue" : "Done" }
            else { model.hasAsked ? "Open System Settings" : "Allow Screen Recording" }
        case .shortcuts: model.keysTaken ? "Open Keyboard Settings" : "Continue"
        case .capture: captureMessage == nil ? "Start Capture" : "Try Again"
        }
    }

    private func primaryAction() {
        switch model.step {
        case .permission:
            if !model.isGranted { Task { await model.requestAccess() }; return }
            if model.mode == .permissionRecovery { return close() }
            model.next()
        case .shortcuts where model.keysTaken:
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")!)
        case .capture: capture()
        default: model.next()
        }
    }
}
