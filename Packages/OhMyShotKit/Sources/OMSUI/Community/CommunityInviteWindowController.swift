import AppKit
import Foundation
import OMSCore
import SwiftUI

/// The invitation to star OhMyShot on GitHub or join MMFoundation's Discord, shown once ever (`CommunityInvite` decides
/// when). It looks like the onboarding window: a plain window, never modal, with Not Now, Join Discord, and Star on
/// GitHub. Star on GitHub opens the app's repository and Join Discord the organization's Discord, in the browser; they,
/// Not Now, Escape, and the close button all close the window, and each spends the invitation as much as the others.
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
        window.title = AppIdentity.displayName
        window.isReleasedWhenClosed = false
        // Keep the invitation above ordinary windows, on the Space the person is using when it opens.
        window.level = .floating
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        super.init(window: window)
        let controller = NSHostingController(rootView: CommunityInviteView(
            star: { [weak self] in
                NSWorkspace.shared.open(CommunityInvite.github)
                self?.close()
            },
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
    let star: () -> Void
    let join: () -> Void
    let close: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(nsImage: AppActivation.appIcon).resizable().interpolation(.high)
                .frame(width: 64, height: 64)
                .accessibilityHidden(true)

            VStack(spacing: 6) {
                Text("Enjoying OhMyShot?", bundle: .module)
                    .font(.title2.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                Text("A star on GitHub helps more people find OhMyShot. On Discord, ask questions, share ideas, and hear what’s coming from MMFoundation, the people who make it.", bundle: .module)
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
                .help(Text(verbatim: CommunityInvite.discord.absoluteString))
                Button(action: star) {
                    Text("Star on GitHub", bundle: .module)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)
                .keyboardShortcut(.defaultAction)
                .help(Text(verbatim: CommunityInvite.github.absoluteString))
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
