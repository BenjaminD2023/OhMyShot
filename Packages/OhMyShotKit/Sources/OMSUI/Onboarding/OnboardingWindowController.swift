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
        NSApp.activate()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
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

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Image(systemName: isGranted ? "checkmark.circle" : "rectangle.dashed")
                .font(.system(size: 34, weight: .regular))
                .foregroundStyle(.tint)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 8) {
                Text(isGranted ? "OhMyShot can see your screen" : "Let OhMyShot see your screen", bundle: .module)
                    .font(.title2.weight(.semibold))
                Text(isGranted
                     ? "Screen Recording is on. If captures still come out blank, relaunch once so macOS applies it."
                     : "macOS lets an app capture the screen only after you allow it. Turn on OhMyShot under Privacy & Security › Screen & System Audio Recording, then relaunch so the change takes effect.",
                     bundle: .module)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text("macOS also asks you to confirm about once a month. That reminder comes from macOS, not from OhMyShot.", bundle: .module)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Button(action: close) {
                    Text(isGranted ? "Done" : "Not Now", bundle: .module)
                }
                .keyboardShortcut(.cancelAction)
                Spacer()
                if openedSettings || isGranted {
                    Button(action: relaunch) {
                        Text("Relaunch OhMyShot", bundle: .module)
                    }
                }
                if !isGranted {
                    Button {
                        Task {
                            await permissions.request(.screenRecording)
                            permissions.openSystemSettings(for: .screenRecording)
                            openedSettings = true
                        }
                    } label: {
                        Text("Open System Settings", bundle: .module)
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(.top, 4)
        }
        .padding(28)
        .frame(width: 460)
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            permissions.refresh([.screenRecording])
        }
    }
}
