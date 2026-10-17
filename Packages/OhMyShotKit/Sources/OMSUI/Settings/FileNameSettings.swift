import OMSCore
import SwiftUI

/// The controls of Settings › General › File name: the pattern, a button for each token, the name the next file
/// would take, and whether saving asks for a name.
struct FileNameSettings: View {
    @Bindable var settings: SettingsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                TextField(text: $settings.fileNamePattern, prompt: Text(verbatim: FilenameTemplate.standard.pattern)) {
                    Text("File name", bundle: .module)
                }
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .frame(width: 250)
                InfoButton(Text("A name is made from this pattern for each capture and each file saved. {date} and {time} are when it was taken; {app} is the app in front; {window} is the window’s title, or the front window’s for an area; {counter} is a number that goes up by one with each file saved.", bundle: .module))
            }
            // The token's name without its braces, so the five fit the column whole; the braces go in with it.
            HStack(spacing: 4) {
                ForEach(FilenameTemplate.Token.allCases, id: \.self) { token in
                    Button {
                        insert(token)
                    } label: {
                        Text(verbatim: String(token.placeholder.dropFirst().dropLast()))
                            .font(.caption.monospaced())
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .fixedSize()
                    .help(Text("Insert \(token.placeholder)", bundle: .module))
                    .accessibilityLabel(Text("Insert \(token.placeholder)", bundle: .module))
                }
            }
            // The time moves on, so the preview is read again every second while the pane is open.
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text("Next: \(preview(at: context.date))", bundle: .module)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 300, alignment: .leading)
                    .help(preview(at: context.date))
            }
            HStack(spacing: 6) {
                Toggle(isOn: $settings.asksForFileName) {
                    Text("Ask for a name when saving", bundle: .module)
                }
                InfoButton(Text("Save, and saving after a capture, ask for the file’s name first, offering the one above. Return saves; Escape doesn’t save. A save started by a URL command or a shortcut never asks, nor does Save All or a card that saves itself as it closes.", bundle: .module))
            }
        }
    }

    /// The pattern with the token added to its end.
    private func insert(_ token: FilenameTemplate.Token) {
        settings.fileNamePattern += token.placeholder
    }

    /// The next file as it would be named, for an app and a window made up, since no capture has them yet.
    private func preview(at date: Date) -> String {
        let name = settings.nextFileName(date: date, appName: "Safari", windowTitle: "Welcome")
        return name + "." + settings.screenshotFormat.fileExtension
    }
}
