import OMSCore
import SwiftUI

/// Under the text while a cloud model is set up: whose reading it is, and Read with…, which sends the picture to the
/// model's service and names the service before it does. While the model reads, its progress and Cancel; once it
/// has, a switch between this Mac's reading and the model's; after a failure, why, and Try Again.
struct CloudFooter: View {
    let model: TextRecognitionModel

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
            Text("Read on this Mac", bundle: .module)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 8)
            ReadWithButton(model: model)
        case .reading(let cloud, let characters):
            CloudProgress(cloud: cloud, characters: characters)
            Spacer(minLength: 8)
            Button { model.cancelCloudReading() } label: { Text("Cancel", bundle: .module) }
                .controlSize(.small)
                .help(Text("Stop reading with \(cloud.name)", bundle: .module))
        case .read(let result) where result.reading.text.isEmpty:
            Text("\(result.model.name) found no text", bundle: .module)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 8)
            ReadWithButton(model: model)
        case .read(let result):
            Picker(selection: Binding(get: { model.source }, set: { model.show($0) })) {
                Text("This Mac", bundle: .module).tag(TextRecognitionModel.TextSource.device)
                Text(verbatim: result.model.name).tag(TextRecognitionModel.TextSource.cloud)
            } label: {
                Text("Show the text read by", bundle: .module)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            .fixedSize()
            .help(Text("Show the text read on this Mac, or the text \(result.model.name) read", bundle: .module))
            if !result.reading.isComplete {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .help(Text("\(result.model.name) stopped before the end of the text", bundle: .module))
                    .accessibilityLabel(Text("\(result.model.name) stopped before the end of the text", bundle: .module))
            }
            Spacer(minLength: 8)
            if model.source == .cloud {
                Text(verbatim: Self.summary(result))
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(Self.details(result))
            }
        case .failed(let cloud, let message, let canRetry):
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
                Button { model.readInCloud(with: cloud) } label: { Text("Try Again", bundle: .module) }
                    .controlSize(.small)
            } else {
                ReadWithButton(model: model)
            }
        }
    }

    /// "claude-opus-5-5 · 2,712 tokens": the model that answered, and what the reading cost in tokens.
    static func summary(_ result: TextRecognitionModel.CloudResult) -> String {
        let reading = result.reading
        guard let input = reading.inputTokens, let output = reading.outputTokens else { return reading.model }
        let tokens = String(localized: "\((input + output).formatted()) tokens", bundle: .module)
        return "\(reading.model) · \(tokens)"
    }

    static func details(_ result: TextRecognitionModel.CloudResult) -> Text {
        let reading = result.reading
        let host = result.model.host ?? result.model.address
        if let input = reading.inputTokens, let output = reading.outputTokens {
            return Text("Read by \(reading.model) at \(host): \(input.formatted()) tokens in, \(output.formatted()) out", bundle: .module)
        }
        return Text("Read by \(reading.model) at \(host)", bundle: .module)
    }
}

/// The empty state's actions while Vision found no text: Read with…, then the same progress, failure, and outcome the
/// footer shows.
struct CloudEmptyActions: View {
    let model: TextRecognitionModel

    var body: some View {
        switch model.cloud {
        case .idle:
            ReadWithButton(model: model, size: .regular)
        case .reading(let cloud, let characters):
            VStack(spacing: 8) {
                CloudProgress(cloud: cloud, characters: characters)
                Button { model.cancelCloudReading() } label: { Text("Cancel", bundle: .module) }
            }
        case .read(let result):
            // Only an empty reading leaves the empty state.
            VStack(spacing: 8) {
                Text("\(result.model.name) found no text either", bundle: .module)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if model.cloudModels.count > 1 { ReadWithButton(model: model, size: .regular) }
            }
        case .failed(let cloud, let message, let canRetry):
            VStack(spacing: 8) {
                Label {
                    Text("Couldn’t read with \(cloud.name)", bundle: .module)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
                .font(.callout)
                Text(verbatim: message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .textSelection(.enabled)
                    .frame(maxWidth: 360)
                if canRetry {
                    Button { model.readInCloud(with: cloud) } label: { Text("Try Again", bundle: .module) }
                } else {
                    ReadWithButton(model: model, size: .regular)
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

/// Read with the model used last, its tooltip naming where the picture goes and how; with more than one model set up,
/// a menu of the others beside it.
struct ReadWithButton: View {
    let model: TextRecognitionModel
    var size: ControlSize = .small

    var body: some View {
        let models = model.cloudModels
        if let first = models.first {
            if models.count == 1 {
                Button { model.readInCloud(with: first) } label: { label(first) }
                    .controlSize(size)
                    .help(help(first))
            } else {
                Menu {
                    ForEach(models) { cloud in
                        Button { model.readInCloud(with: cloud) } label: {
                            Text("Read with \(cloud.name)", bundle: .module)
                        }
                        .help(help(cloud))
                    }
                } label: {
                    label(first)
                } primaryAction: {
                    model.readInCloud(with: first)
                }
                .controlSize(size)
                .fixedSize()
                .help(help(first))
            }
        }
    }

    private func label(_ cloud: CloudModel) -> some View {
        Label {
            Text("Read with \(cloud.name)", bundle: .module)
        } icon: {
            Image(systemName: "cloud")
        }
    }

    /// Where the picture goes, with which model, and in how many pieces or at what size when it isn't whole.
    private func help(_ cloud: CloudModel) -> Text {
        let host = cloud.host ?? cloud.address
        guard let image = model.image else { return Text("Send this picture to \(host) and read it with \(cloud.model)", bundle: .module) }
        let plan = CloudPicture.plan(width: image.width, height: image.height, limits: .of(cloud.kind))
        let percent = Int((plan.scale * 100).rounded())
        switch (plan.pieces.count > 1, plan.scale < 1) {
        case (true, true):
            return Text("Send this picture to \(host) and read it with \(cloud.model). It goes in \(plan.pieces.count) pieces, at \(percent)% of its size.", bundle: .module)
        case (true, false):
            return Text("Send this picture to \(host) and read it with \(cloud.model). It goes in \(plan.pieces.count) pieces.", bundle: .module)
        case (false, true):
            return Text("Send this picture to \(host) and read it with \(cloud.model). It goes at \(percent)% of its size.", bundle: .module)
        case (false, false):
            return Text("Send this picture to \(host) and read it with \(cloud.model)", bundle: .module)
        }
    }
}
