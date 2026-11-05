import Foundation
import OMSCore
import SwiftUI

/// What happens after a screenshot or a recording is kept, the same four switches in Screenshots and Recording:
/// Copy, Quick Access, Save, and Upload for a person who has somewhere to upload to; under them, a line when none of
/// them keeps the capture outside History (`AfterCapture.keepsNothing`). The panes name the row and explain it, as
/// those differ.
struct AfterCaptureChoices: View {
    @Bindable var settings: SettingsStore
    /// Whose choices these are: screenshots' or recordings'.
    let kind: HistoryItem.Kind
    let hasDestination: Bool
    /// The line when nothing keeps a capture and History doesn't either.
    let keptNowhere: Text
    /// The line when nothing keeps a capture but History.
    let keptInHistoryOnly: Text

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 14) {
                Toggle(isOn: $settings[dynamicMember: choices.copy]) {
                    Text("Copy", bundle: .module)
                }
                Toggle(isOn: $settings[dynamicMember: choices.quickAccess]) {
                    Text("Quick Access", bundle: .module)
                }
                Toggle(isOn: $settings[dynamicMember: choices.save]) {
                    Text("Save", bundle: .module)
                }
                // Uploading is offered only to a person who has somewhere to upload to.
                if hasDestination {
                    Toggle(isOn: $settings[dynamicMember: choices.upload]) {
                        Text("Upload", bundle: .module)
                    }
                }
            }
            if settings.afterCapture(for: kind).keepsNothing(hasDestination: hasDestination) {
                SettingsWarning(settings.historyRetention == .never ? keptNowhere : keptInHistoryOnly)
            }
        }
    }

    /// The settings the switches change, as `SettingsStore.afterCapture(for:)` reads them.
    private var choices: (
        copy: ReferenceWritableKeyPath<SettingsStore, Bool>, quickAccess: ReferenceWritableKeyPath<SettingsStore, Bool>,
        save: ReferenceWritableKeyPath<SettingsStore, Bool>, upload: ReferenceWritableKeyPath<SettingsStore, Bool>
    ) {
        switch kind {
        case .screenshot: (\.copyAfterCapture, \.showQuickAccess, \.saveAfterCapture, \.uploadAfterCapture)
        case .recording: (\.copyAfterRecording, \.showRecordingQuickAccess, \.saveAfterRecording, \.uploadAfterRecording)
        }
    }
}
