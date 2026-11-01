import AppKit
import Foundation
import OMSCore
import SwiftUI

/// The invitation to MMFoundation's Discord, shown once ever (`CommunityInvite` decides when). It looks like the
/// onboarding window: a plain window, never modal, with Not Now and Join Discord. Join Discord opens the organization's
/// Discord in the browser; it, Not Now, Escape, and the close button all close the window, and each spends the
/// invitation as much as the others.
public final class CommunityInviteWindowController: NSWindowController, NSWindowDelegate {
    public var onClose: (() -> Void)?

    private var windowLease: ActiveResources.Lease?

    public init() {
        let window = CommunityInviteWindow(
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
        let controller = NSHostingController(rootView: CommunityInviteView(
            join: { [weak self] in
                NSWorkspace.shared.open(CommunityInvite.discord)
                self?.close()
            },
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

    #if DEBUG
    /// For scripted captures: the window as it is shown, but behind the desktop picture, never in front of anyone.
    public func showBehindWallpaper() {
        guard let window else { return }
        if windowLease == nil {
            windowLease = ActiveResources.shared.acquire(.window)
        }
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) - 1)
        window.center()
        window.orderFront(nil)
    }
    #endif

    public func windowWillClose(_ notification: Notification) {
        windowLease?.end()
        windowLease = nil
        onClose?()
    }
}

/// Closes on Escape: its buttons take no focus, so the window itself is the first responder, and an Escape no button
/// answers stops in its own `cancelOperation`.
private final class CommunityInviteWindow: NSWindow {
    override func cancelOperation(_ sender: Any?) {
        close()
    }
}

struct CommunityInviteView: View {
    let join: () -> Void
    let close: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 40, weight: .regular))
                .foregroundStyle(.tint)
                .accessibilityHidden(true)

            VStack(spacing: 6) {
                Text("Join Us on Discord", bundle: .module)
                    .font(.title2.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                Text("Ask questions, share ideas, and hear what’s coming from MMFoundation, the people who make OhMyShot.", bundle: .module)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .multilineTextAlignment(.center)

            ButtonRow {
                Button(action: close) {
                    Text("Not Now", bundle: .module)
                        .frame(maxWidth: .infinity)
                }
                .keyboardShortcut(.cancelAction)
                Button(action: join) {
                    Text("Join Discord", bundle: .module)
                        .frame(maxWidth: .infinity)
                }
                .keyboardShortcut(.defaultAction)
                .help(Text(verbatim: CommunityInvite.discord.absoluteString))
            }
            .controlSize(.large)
            .padding(.top, 8)
        }
        .padding(.horizontal, 28)
        .padding(.top, 36)
        .padding(.bottom, 24)
        .frame(width: 380)
    }
}
