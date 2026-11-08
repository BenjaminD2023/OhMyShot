import Foundation
import Observation

/// First-use progress, independent of windows and permissions. Construct before installing default shortcuts:
/// their existing markers distinguish an upgrade from a new installation without reading capture history.
@MainActor
@Observable
public final class OnboardingProgress {
    public enum Step: String, Codable, CaseIterable, Sendable {
        case welcome, permission, shortcuts, capture
    }

    public enum Status: String, Codable, Sendable {
        case active, completed, skipped, existingUser
    }

    private struct Record: Codable {
        var status: Status
        var step: Step
    }

    public private(set) var status: Status
    public private(set) var step: Step
    @ObservationIgnored private let defaults: UserDefaults
    static let key = "onboardingProgress.v1"

    public var shouldPresentAutomatically: Bool { status == .active }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.key), let record = try? JSONDecoder().decode(Record.self, from: data) {
            status = record.status
            step = record.step
        } else {
            let wasInstalled = defaults.object(forKey: "installedDefaultShortcuts") != nil
                || defaults.bool(forKey: "didInstallDefaultShortcuts")
                || defaults.bool(forKey: "onboardingShowedShortcuts")
                || defaults.integer(forKey: "communityInviteLaunches") > 0
            status = wasInstalled ? .existingUser : .active
            step = .welcome
            persist()
        }
    }

    public func replay() {
        status = .active
        step = .welcome
        persist()
    }

    public func move(to step: Step) {
        guard status == .active else { return }
        self.step = step
        persist()
    }

    public func skip() {
        guard status == .active else { return }
        status = .skipped
        persist()
    }

    /// Called only after the practice capture has been kept. A cancelled or failed attempt stays on Capture.
    public func complete() {
        guard status == .active else { return }
        status = .completed
        persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(Record(status: status, step: step)) else { return }
        defaults.set(data, forKey: Self.key)
    }
}
