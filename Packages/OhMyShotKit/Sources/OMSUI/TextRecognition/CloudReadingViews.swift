import OMSCore
import SwiftUI

/// The toolbar's Read with, beside Translate and like it a mode: on, the text side shows the cloud model's reading
/// (the picture is sent the first time); off, this Mac's again. Its tooltip names where the picture goes.
struct CloudToggle: View {
    @Bindable var model: TextRecognitionModel
    let cloud: CloudModel

    var body: some View {
        Toggle(isOn: $model.readsInCloud) {
            Label {
                Text("Read with \(cloud.name)", bundle: .module)
            } icon: {
                Image(systemName: "cloud")
            }
            .labelStyle(.iconOnly)
        }
        .toggleStyle(.button)
        .keyboardShortcut("r", modifiers: [.command, .shift])
        .disabled(model.image == nil)
        .help(help)
    }

    /// Where the picture goes, and in how many pieces or at what size when it doesn't go whole.
    private var help: Text {
        if model.readsInCloud { return Text("Show the text read on this Mac (⇧⌘R)", bundle: .module) }
        let host = cloud.host ?? cloud.address
        let sends = Text("Read with \(cloud.name): sends this picture to \(host) (⇧⌘R)", bundle: .module)
        guard let image = model.image else { return sends }
        let plan = CloudPicture.plan(width: image.width, height: image.height, limits: .of(cloud.kind))
        let percent = Int((plan.scale * 100).rounded())
        switch (plan.pieces.count > 1, plan.scale < 1) {
        case (true, true): return sends + Text(verbatim: ". ") + Text("It goes in \(plan.pieces.count) pieces, at \(percent)% of its size.", bundle: .module)
        case (true, false): return sends + Text(verbatim: ". ") + Text("It goes in \(plan.pieces.count) pieces.", bundle: .module)
        case (false, true): return sends + Text(verbatim: ". ") + Text("It goes at \(percent)% of its size.", bundle: .module)
        case (false, false): return sends
        }
    }
}

/// Under the text while Read with is on, in the edited notice's style: the reading's progress, who read the text and
/// what it cost, that the model found nothing (this Mac's text stays), or why it couldn't read, with Try Again.
struct CloudStatus: View {
    @Bindable var model: TextRecognitionModel
    let cloud: CloudModel

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 8) {
                content
            }
            .frame(minHeight: 22)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
    }

    @ViewBuilder private var content: some View {
        switch model.cloud {
        case .idle:
            Spacer(minLength: 0)
        case .reading(let characters):
            CloudProgress(cloud: cloud, characters: characters)
            Spacer(minLength: 8)
            Button { model.readsInCloud = false } label: { Text("Cancel", bundle: .module) }
                .controlSize(.small)
        case .read(let result) where result.reading.text.isEmpty:
            Text("\(cloud.name) found no text", bundle: .module)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 8)
        case .read(let result):
            Text("Read by \(cloud.name)", bundle: .module)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            if !result.reading.isComplete {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .help(Text("\(cloud.name) stopped before the end of the text", bundle: .module))
                    .accessibilityLabel(Text("\(cloud.name) stopped before the end of the text", bundle: .module))
            }
            Spacer(minLength: 8)
            Text(verbatim: Self.summary(result.reading))
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(Self.details(result.reading, host: cloud.host ?? cloud.address))
        case .failed(let message, let canRetry):
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text("Couldn’t read with \(cloud.name)", bundle: .module)
                    .font(.callout)
                    .lineLimit(1)
                Text(verbatim: message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .textSelection(.enabled)
                    .help(message)
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 8)
            if canRetry {
                Button { model.retryCloudReading() } label: { Text("Try Again", bundle: .module) }
                    .controlSize(.small)
            }
        }
    }

    /// "claude-opus-5-5 · 2,712 tokens": the model that answered, and what the reading cost in tokens.
    static func summary(_ reading: CloudReading) -> String {
        guard let input = reading.inputTokens, let output = reading.outputTokens else { return reading.model }
        let tokens = String(localized: "\((input + output).formatted()) tokens", bundle: .module)
        return "\(reading.model) · \(tokens)"
    }

    static func details(_ reading: CloudReading, host: String) -> Text {
        if let input = reading.inputTokens, let output = reading.outputTokens {
            return Text("Read by \(reading.model) at \(host): \(input.formatted()) tokens in, \(output.formatted()) out", bundle: .module)
        }
        return Text("Read by \(reading.model) at \(host)", bundle: .module)
    }
}

/// The text side when Vision found no text and a cloud model is set up: Read with as the way on, then the reading's
/// progress, its failure, or that it found nothing either.
struct CloudEmptyState: View {
    @Bindable var model: TextRecognitionModel
    let cloud: CloudModel

    var body: some View {
        switch model.readsInCloud ? model.cloud : .idle {
        case .idle:
            PanelPlaceholder(
                symbol: "text.magnifyingglass",
                title: Text("No text found", bundle: .module),
                message: Text("Try an image with larger text or more contrast, or read it with \(cloud.name).", bundle: .module)
            ) {
                Button { model.readsInCloud = true } label: {
                    Label { Text("Read with \(cloud.name)", bundle: .module) } icon: { Image(systemName: "cloud") }
                }
                .padding(.top, 6)
                .help(Text("Sends this picture to \(cloud.host ?? cloud.address)", bundle: .module))
            }
        case .reading(let characters):
            VStack(spacing: 10) {
                CloudProgress(cloud: cloud, characters: characters)
                Button { model.readsInCloud = false } label: { Text("Cancel", bundle: .module) }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .read:
            // Only an empty reading leaves the empty state.
            PanelPlaceholder(
                symbol: "text.magnifyingglass",
                title: Text("No text found", bundle: .module),
                message: Text("Neither this Mac nor \(cloud.name) found text in it.", bundle: .module)
            )
        case .failed(let message, let canRetry):
            PanelPlaceholder(
                symbol: "exclamationmark.triangle",
                title: Text("Couldn’t read with \(cloud.name)", bundle: .module),
                message: Text(verbatim: message)
            ) {
                if canRetry {
                    Button { model.retryCloudReading() } label: { Text("Try Again", bundle: .module) }
                        .padding(.top, 6)
                }
            }
        }
    }
}

/// "Reading with Claude… 1,204 characters", with a small spinner; "Sending to api.anthropic.com…" until the first
/// characters come.
private struct CloudProgress: View {
    let cloud: CloudModel
    let characters: Int

    var body: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Group {
                if characters > 0 {
                    Text("Reading with \(cloud.name)… \(characters.formatted()) characters", bundle: .module)
                } else {
                    Text("Sending to \(cloud.host ?? cloud.address)…", bundle: .module)
                }
            }
            .font(.callout)
            .monospacedDigit()
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
    }
}
