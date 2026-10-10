import AppKit
import Foundation
import OMSCore
import SwiftUI

/// Walks the user through the one permission OhMyShot cannot work without. A plain window rather
/// than a modal alert: the user has to leave for System Settings and come back.
public final class OnboardingWindowController: NSWindowController, NSWindowDelegate {
    public var onClose: (() -> Void)?

    private var windowLease: ActiveResources.Lease?

    public init(permissions: PermissionCenter, relaunch: @escaping () -> Void) {
        let window = NSWindow(
            contentRect: .zero,
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: true
        )
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        super.init(window: window)
        let controller = NSHostingController(rootView: OnboardingView(
            permissions: permissions,
            relaunch: relaunch,
            close: { [weak self] in self?.close() }
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

struct OnboardingView: View {
    let permissions: PermissionCenter
    let relaunch: () -> Void
    let close: () -> Void

    @State private var openedSettings = false

    private var isGranted: Bool {
        permissions.status(of: .screenRecording) == .granted
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

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: isGranted ? "checkmark.circle" : "rectangle.dashed")
                .font(.system(size: 40, weight: .regular))
                .foregroundStyle(.tint)
                .accessibilityHidden(true)

            VStack(spacing: 6) {
                Text(title, bundle: .module)
                    .font(.title2.weight(.semibold))
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

            HStack(spacing: 10) {
                Button(action: close) {
                    Text(isGranted ? "Done" : "Not Now", bundle: .module)
                        .frame(maxWidth: .infinity)
                }
                .keyboardShortcut(.cancelAction)
                if !isGranted && !openedSettings {
                    Button(action: openSettings) {
                        Text(primaryAction, bundle: .module)
                            .frame(maxWidth: .infinity)
                    }
                    .keyboardShortcut(.defaultAction)
                }
                if openedSettings || isGranted {
                    Button(action: relaunch) {
                        Text("Relaunch", bundle: .module)
                            .frame(maxWidth: .infinity)
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
            .controlSize(.large)
            .padding(.top, 8)
        }
        .padding(.horizontal, 28)
        .padding(.top, 36)
        .padding(.bottom, 24)
        .frame(width: 380)
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            permissions.refresh([.screenRecording])
        }
    }
}
