import Foundation
import Testing
@testable import OMSCore

@MainActor
struct OnboardingProgressTests {
    private func withDefaults(_ body: (UserDefaults) throws -> Void) throws {
        let suite = "OnboardingProgressTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        try body(defaults)
    }

    @Test func aNewInstallStartsAtWelcomeAndSurvivesInstallingShortcuts() throws {
        try withDefaults { defaults in
            let progress = OnboardingProgress(defaults: defaults)
            #expect(progress.shouldPresentAutomatically && progress.step == .welcome)
            defaults.set(["captureArea"], forKey: "installedDefaultShortcuts")
            progress.move(to: .permission)
            let relaunched = OnboardingProgress(defaults: defaults)
            #expect(relaunched.shouldPresentAutomatically && relaunched.step == .permission)
        }
    }

    @Test(arguments: ["installedDefaultShortcuts", "didInstallDefaultShortcuts", "onboardingShowedShortcuts", "communityInviteLaunches"])
    func upgradesDoNotShowTheNewGuide(marker: String) throws {
        try withDefaults { defaults in
            if marker == "installedDefaultShortcuts" { defaults.set([String](), forKey: marker) }
            else { defaults.set(1, forKey: marker) }
            let progress = OnboardingProgress(defaults: defaults)
            #expect(progress.status == .existingUser)
            #expect(!progress.shouldPresentAutomatically)
            #expect(!OnboardingProgress(defaults: defaults).shouldPresentAutomatically)
        }
    }

    @Test func closingOrSkippingNeverAutomaticallyRepeatsButCanBeReplayed() throws {
        try withDefaults { defaults in
            let progress = OnboardingProgress(defaults: defaults)
            progress.move(to: .shortcuts)
            progress.skip()
            let reopened = OnboardingProgress(defaults: defaults)
            #expect(reopened.status == .skipped && !reopened.shouldPresentAutomatically)
            reopened.move(to: .capture)
            #expect(reopened.step == .shortcuts)
            reopened.replay()
            #expect(reopened.shouldPresentAutomatically && reopened.step == .welcome)
        }
    }

    @Test func onlyACompletedPracticeEndsTheGuide() throws {
        try withDefaults { defaults in
            let progress = OnboardingProgress(defaults: defaults)
            progress.move(to: .capture)
            // An interrupted or unsuccessful capture changes no progress, and retries at the capture page.
            let retry = OnboardingProgress(defaults: defaults)
            #expect(retry.shouldPresentAutomatically && retry.step == .capture)
            retry.complete()
            retry.skip() // Programmatic window cleanup cannot replace a successful result with a dismissal.
            let finished = OnboardingProgress(defaults: defaults)
            #expect(finished.status == .completed && !finished.shouldPresentAutomatically)
            finished.replay()
            #expect(finished.shouldPresentAutomatically && finished.step == .welcome)
        }
    }

    @Test func resettingPreferencesDoesNotResetOnboarding() throws {
        try withDefaults { defaults in
            let progress = OnboardingProgress(defaults: defaults)
            progress.skip()
            SettingsStore(defaults: defaults).resetToDefaults()
            #expect(OnboardingProgress(defaults: defaults).status == .skipped)
        }
    }
}
