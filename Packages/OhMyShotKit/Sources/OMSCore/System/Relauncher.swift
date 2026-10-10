import AppKit
import Foundation
import OSLog

@MainActor
public enum Relauncher {
    /// Starts a new copy of the app, then quits this one.
    ///
    /// Needed after granting Screen Recording, which macOS applies only to new processes. A helper
    /// process cannot do the relaunch: it belongs to this app's launch job and dies with it. The new
    /// copy waits for this one to exit (`afterOtherInstancesExit`) before it takes the shortcuts.
    public static func relaunch() {
        startNewCopy { started in
            if started { NSApp.terminate(nil) }
        }
    }

    /// Starts a new copy of the app and reports whether it started; quitting this one is up to the caller.
    public static func startNewCopy(_ completion: @escaping @MainActor (Bool) -> Void) {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        configuration.activates = false
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, error in
            Task { @MainActor in
                if let error {
                    Log.app.error("Relaunch failed: \(error.localizedDescription, privacy: .public)")
                }
                completion(error == nil)
            }
        }
    }

    /// Runs `body` once no other copy of this app is running, immediately if there is none.
    /// Gives up waiting after `timeout`, so a copy that hangs while quitting cannot block launch.
    public static func afterOtherInstancesExit(timeout: Duration = .seconds(5), _ body: @escaping () -> Void) {
        let waiter = InstanceWaiter(body: body)
        guard waiter.othersAreRunning else {
            waiter.finish()
            return
        }
        Log.app.notice("Waiting for the previous copy to quit")
        waiter.observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                if !waiter.othersAreRunning { waiter.finish() }
            }
        }
        Task {
            try? await Task.sleep(for: timeout)
            waiter.finish()
        }
    }
}

@MainActor
private final class InstanceWaiter {
    var observer: (any NSObjectProtocol)?
    private var body: (() -> Void)?

    init(body: @escaping () -> Void) {
        self.body = body
    }

    var othersAreRunning: Bool {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        return NSRunningApplication
            .runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            .contains { $0.processIdentifier != ownPID && !$0.isTerminated }
    }

    /// Runs the body once; later calls do nothing.
    func finish() {
        guard let body else { return }
        self.body = nil
        if let observer {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            self.observer = nil
        }
        body()
    }
}
