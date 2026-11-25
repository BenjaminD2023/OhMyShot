import AppKit
import AVKit
import CoreGraphics
import OMSCore
import OMSDesign
import SwiftUI

/// The Studio window's content: the preview and its transport above the timeline, the inspector to the right.
struct StudioView: View {
    @Bindable var document: StudioDocument
    @Bindable var model: StudioWindowModel
    let player: NSView
    let swatches: [StudioWindowController.Swatch]

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                PlayerArea(view: player)
                    // The chosen zoom is aimed over the movie itself.
                    .overlay { StudioZoomAim(document: document) { model.isAimingFocused = $0 } }
                    .padding(20)
                    .overlay { previewState }
                    .background(Color(nsColor: .underPageBackgroundColor))
                Divider()
                TransportBar(document: document, model: model)
                // Saving is told under the window's title; only a save that failed takes a row, for Retry.
                if case .failed = document.saveState { saveFailure }
                StudioTimeline(document: document, model: model)
                    .frame(height: document.canChangeLayoutAlongTheTimeline ? StudioTimeline.heightWithLayouts : StudioTimeline.height)
            }
            Divider()
            StudioInspector(document: document, swatches: swatches) { model.controller?.chooseBackgroundPicture() }
                .frame(width: 290)
        }
        .overlay {
            if let progress = model.progress {
                let percent = Int((min(max(progress, 0), 1) * 100).rounded())
                let label = model.exportLabel ?? (model.makesGIF
                    ? String(localized: "Making the GIF…", bundle: .module)
                    : String(localized: "Exporting…", bundle: .module))
                VStack(spacing: 10) {
                    ProgressView(value: progress)
                        .frame(width: 180)
                    HStack(spacing: 6) {
                        Text(verbatim: label)
                        Text(verbatim: "\(percent)%")
                            .monospacedDigit()
                    }
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    Button(role: .cancel) {
                        if model.makesGIF { model.controller?.cancelGIF() } else { model.controller?.cancelExport() }
                    } label: {
                        Text("Cancel", bundle: .module)
                    }
                    .keyboardShortcut(.cancelAction)
                    .controlSize(.small)
                }
                .padding(.horizontal, 22)
                .padding(.vertical, 16)
                .windowNoticeCard()
                .accessibilityElement(children: .contain)
            }
        }
        .toolbar { toolbar }
        .onDeleteCommand { document.deleteSelection() }
        .onChange(of: document.saveState, initial: true) { _, state in
            model.controller?.window?.subtitle = Self.subtitle(for: state)
        }
    }

    /// Keep an existing frame visible while a new composition is prepared, but identify a stale preview.
    @ViewBuilder private var previewState: some View {
        switch document.previewState {
        case .preparing:
            ProgressView()
                .controlSize(.regular)
                .accessibilityLabel(Text("Preparing the preview", bundle: .module))
        case .updating:
            VStack {
                Spacer()
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Updating preview…", bundle: .module).font(.callout)
                }
                .padding(8)
                .windowNoticeCard()
                .padding(12)
            }
            .allowsHitTesting(false)
            .accessibilityElement(children: .combine)
        case .failed(let reason):
            VStack {
                if document.composition != nil { Spacer() }
                VStack(spacing: 6) {
                    Label {
                        document.composition == nil
                            ? Text("The recording couldn’t be read", bundle: .module)
                            : Text("The preview couldn’t be updated", bundle: .module)
                    } icon: { Image(systemName: "exclamationmark.triangle") }
                    // What it means in the app's words; the system's own reason on the pointer and in the log.
                    Group {
                        document.composition == nil
                            ? Text("It may have been moved or damaged.", bundle: .module)
                            : Text("Your edits are kept.", bundle: .module)
                    }
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .help(reason)
                    .accessibilityHint(reason)
                    Button {
                        Task { await document.makeComposition() }
                    } label: { Text("Retry Preview", bundle: .module) }
                }
                .padding(12)
                .windowNoticeCard()
                .padding(12)
                .accessibilityElement(children: .contain)
            }
        case .ready:
            EmptyView()
        }
    }

    private var saveFailure: some View {
        HStack(spacing: 8) {
            if case .failed(let reason) = document.saveState {
                Label { Text("Project changes haven’t been saved", bundle: .module) } icon: { Image(systemName: "exclamationmark.triangle") }
                    .font(.callout)
                    .lineLimit(1)
                    .help(reason)
                    .accessibilityHint(reason)
                Spacer(minLength: 4)
                Button {
                    Task { try? await document.flushSave() }
                } label: { Text("Retry Saving", bundle: .module) }
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 24)
        .accessibilityElement(children: .contain)
    }

    /// The window's subtitle: where the project's saving stands, as a document window says it under its title.
    static func subtitle(for state: StudioDocument.SaveState) -> String {
        switch state {
        case .saved: String(localized: "Project saved", bundle: .module)
        case .failed: String(localized: "Project changes haven’t been saved", bundle: .module)
        default: String(localized: "Saving project…", bundle: .module)
        }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        if model.controller?.canMakeGIF == true {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    model.controller?.makeGIF()
                } label: {
                    Label { Text("Make GIF", bundle: .module) } icon: { Image(systemName: "photo.stack") }
                }
                .help(Text("Make a GIF of the movie, without sound, as large as it was on screen", bundle: .module))
                .disabled(model.progress != nil)
            }
        }
        ToolbarItem(placement: .primaryAction) {
            Menu {
                Button { model.controller?.saveMovieAs() } label: { Text("Save As…", bundle: .module) }
                Divider()
                Button { model.controller?.exportProjectPackage() } label: { Text("Export Project Package…", bundle: .module) }
            } label: {
                Label {
                    model.saved ? Text("Saved", bundle: .module) : Text("Save", bundle: .module)
                } icon: {
                    Image(nsImage: Theme.symbol(
                        model.saved ? "checkmark" : "square.and.arrow.down",
                        described: model.saved ? String(localized: "Saved", bundle: .module) : String(localized: "Save", bundle: .module)
                    ))
                }
            } primaryAction: {
                model.controller?.saveMovie()
            }
            .help(Text("Save a Copy (⌘S)", bundle: .module))
            // SwiftUI leaves this split button without a VoiceOver name otherwise; the editor's and the recording
            // window's take theirs from the label.
            .accessibilityLabel(model.saved ? Text("Saved", bundle: .module) : Text("Save", bundle: .module))
            .disabled(model.progress != nil)
        }
        ToolbarSpacer(.fixed, placement: .primaryAction)
        ToolbarItem(placement: .primaryAction) {
            Button {
                model.controller?.copyMovie()
            } label: {
                Label {
                    model.copied ? Text("Copied", bundle: .module) : Text("Copy", bundle: .module)
                } icon: {
                    Image(systemName: model.copied ? "checkmark" : "doc.on.doc")
                }
                .labelStyle(.titleAndIcon)
            }
            .buttonStyle(.glassProminent)
            .help(Text("Copy the movie (⌘C)", bundle: .module))
            .disabled(model.progress != nil)
        }
    }
}

/// Hosts the player in the SwiftUI window.
struct PlayerArea: NSViewRepresentable {
    let view: NSView

    func makeNSView(context: Context) -> NSView { view }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// Play and pause, where the preview is, and the timeline's two commands.
struct TransportBar: View {
    @Bindable var document: StudioDocument
    @Bindable var model: StudioWindowModel

    var body: some View {
        HStack(spacing: 12) {
            Button {
                model.controller?.togglePlay()
            } label: {
                Image(systemName: document.isPlaying ? "pause.fill" : "play.fill")
                    .frame(width: 18)
            }
            .buttonStyle(.borderless)
            .keyboardShortcut(.space, modifiers: [])
            .help(document.isPlaying ? Text("Pause (Space)", bundle: .module) : Text("Play (Space)", bundle: .module))
            .accessibilityLabel(document.isPlaying ? Text("Pause", bundle: .module) : Text("Play", bundle: .module))
            Text(verbatim: "\(Self.format(document.movieTime(document.time))) / \(Self.format(Self.movieDuration(of: document)))")
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .accessibilityLabel(Self.spokenPosition(of: document))
            if model.shuttleRate != 0, model.shuttleRate != 1 {
                let speed = Self.shuttleLabel(model.shuttleRate)
                Text(verbatim: speed)
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.primary.opacity(0.08), in: Capsule())
                    .accessibilityLabel(Text("Playback speed \(speed)", bundle: .module))
            }
            Spacer()
            Button {
                document.addZoom()
            } label: {
                Label { Text("Add Zoom", bundle: .module) } icon: { Image(systemName: "plus.magnifyingglass") }
            }
            // Dimmed rather than doing nothing where zooms fill the playhead's place to the end.
            .disabled(!document.canAddZoom)
            .help(document.canAddZoom
                ? Text("A zoom at the playhead, following the pointer", bundle: .module)
                : Text("No room for a zoom at the playhead: move it past the zooms there", bundle: .module))
            Button {
                document.addSpeed()
            } label: {
                Label { Text("Add Speed", bundle: .module) } icon: { Image(systemName: "gauge.with.needle") }
            }
            .disabled(!document.canAddSpeed)
            .help(document.canAddSpeed
                ? Text("Play a stretch faster or slower from the playhead", bundle: .module)
                : Text("No room for a speed stretch at the playhead: move it past the speeds there", bundle: .module))
            if document.canChangeLayoutAlongTheTimeline {
                Button {
                    document.addCameraSegment()
                } label: {
                    Label { Text("Add Layout", bundle: .module) } icon: { Image(systemName: "rectangle.on.rectangle") }
                }
                .disabled(!document.canAddCameraSegment)
                .help(document.canAddCameraSegment
                    ? Text("Shows the camera another way from the playhead: filling the movie, or hidden", bundle: .module)
                    : Text("No room for a layout at the playhead: move it past the layouts there", bundle: .module))
            }
            if document.selectedRange == nil, let cut = document.selectedCut {
                Button {
                    document.restoreCut(at: cut)
                } label: {
                    Label { Text("Restore Cut", bundle: .module) } icon: { Image(systemName: "arrow.uturn.backward") }
                }
                .help(Text("Put the chosen cut back in the movie", bundle: .module))
            } else {
                if let range = document.selectedRange {
                    Button {
                        document.keepOnly(range)
                    } label: {
                        Label { Text("Keep Only", bundle: .module) } icon: { Image(systemName: "timeline.selection") }
                    }
                    .help(Text("Trim the movie to only the chosen range", bundle: .module))
                } else {
                    // Nothing chosen yet: how to choose it, while the row has room to say so.
                    ViewThatFits(in: .horizontal) {
                        Text("Drag along the clip to choose what to cut", bundle: .module)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Color.clear.frame(width: 0, height: 0)
                    }
                }
                Button {
                    if document.selectedRange != nil { document.deleteSelection() }
                } label: {
                    Label { Text("Cut", bundle: .module) } icon: { Image(systemName: "scissors") }
                }
                .disabled(document.selectedRange == nil)
                .help(Text("Leave the stretch chosen on the clip out of the movie (drag along the clip, or I and O)", bundle: .module))
            }
            Menu {
                SpeedChoices(document: document)
            } label: {
                Label { Text("Speed", bundle: .module) } icon: { Image(systemName: "gauge.with.dots.needle.67percent") }
            }
            .fixedSize()
            .disabled(!document.canSetSpeed)
            .help(Text("Play the stretch chosen on the clip faster or slower", bundle: .module))
        }
        .controlSize(.regular)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    /// How long the movie is, cuts left out.
    static func movieDuration(of document: StudioDocument) -> Double {
        document.composition?.duration ?? document.movieTime(document.duration)
    }

    /// Where the movie is, for VoiceOver: "1.2 of 3.5 seconds".
    static func spokenPosition(of document: StudioDocument) -> Text {
        let now = oneDecimal(document.movieTime(document.time))
        let length = oneDecimal(movieDuration(of: document))
        return Text("\(now) of \(length) seconds", bundle: .module)
    }

    /// A number with one decimal, as the app's language writes it: "2.5" in English, "2,5" in French.
    static func oneDecimal(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(1)))
    }

    /// A scale with one decimal: "2.0×".
    static func scale(_ value: Double) -> String {
        oneDecimal(value) + "×"
    }

    /// A speed, a decimal only where it has one: "2×", "0.5×".
    static func speed(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...1))) + "×"
    }

    /// A shuttle speed label: "2×", "4×", "−1×", "−2×".
    static func shuttleLabel(_ rate: Float) -> String {
        let magnitude = Int(abs(rate).rounded())
        return rate < 0 ? "−\(magnitude)×" : "\(magnitude)×"
    }

    /// A time as the transport shows it, in the inspector's clock but rounded down: 0:12.34, 1:02:09.40.
    static func format(_ seconds: Double) -> String {
        StudioTimeInput.clock(max(0, seconds), rounding: .down)
    }
}

/// The inspector: the background, the frame, the cursor, the camera, zooms, keys, and the movie's quality.
struct StudioInspector: View {
    @Bindable var document: StudioDocument
    let swatches: [StudioWindowController.Swatch]
    /// Asks for a picture for the background, in a sheet over the window.
    let choosePicture: () -> Void
    @Environment(\.colorSchemeContrast) private var contrast
    /// The Blurred recording tile's picture: a frame of the recording, blurred, once it is read.
    @State private var blurredFrame: CGImage?

    var body: some View {
        ScrollViewReader { proxy in
            form
                // A zoom, cut, speed stretch, or layout chosen on the timeline brings its section into view.
                .onChange(of: document.selectedZoom) { _, chosen in
                    guard chosen != nil else { return }
                    proxy.scrollTo(Self.chosenZoomID, anchor: .top)
                }
                .onChange(of: document.selectedCut) { _, chosen in
                    guard chosen != nil else { return }
                    proxy.scrollTo(Self.chosenCutID, anchor: .top)
                }
                .onChange(of: document.selectedSpeed) { _, chosen in
                    guard chosen != nil else { return }
                    proxy.scrollTo(Self.chosenSpeedID, anchor: .top)
                }
                .onChange(of: document.selectedSegment) { _, chosen in
                    guard chosen != nil else { return }
                    proxy.scrollTo(Self.chosenLayoutID, anchor: .top)
                }
        }
    }

    private static let chosenZoomID = "chosen-zoom"
    private static let chosenCutID = "chosen-cut"
    private static let chosenSpeedID = "chosen-speed"
    private static let chosenLayoutID = "chosen-layout"

    private var form: some View {
        Form {
            // The zoom chosen on the timeline, first: it is what was just picked out, at the window's bottom.
            if let id = document.selectedZoom, let zoom = document.project.zooms.first(where: { $0.id == id }) {
                Section {
                    StudioTimeRangeFields(start: zoom.start, end: zoom.end) { value, start in
                        document.setZoomEdge(id, start: start, to: value) ?? zoom.start...zoom.end
                    }
                    .id(id)
                    LabeledSlider(
                        title: Text("Zoom", bundle: .module),
                        value: Binding(get: { zoom.scale }, set: { scale in document.updateZoom(id) { $0.scale = scale } }),
                        range: 1.2...4, reading: { TransportBar.scale($0) }, document: document
                    )
                    Picker(selection: Binding(
                        get: { zoom.target == nil ? ZoomTarget.pointer : .spot },
                        set: { document.setZoomTarget(id, $0 == .pointer ? nil : document.aim(of: id)) }
                    )) {
                        Text("Follow pointer", bundle: .module).tag(ZoomTarget.pointer)
                        Text("Fixed spot", bundle: .module).tag(ZoomTarget.spot)
                    } label: {
                        Text("Target", bundle: .module)
                    }
                    .accessibilityLabel(Text("Zoom target", bundle: .module))
                    if zoom.target != nil {
                        Text("Click or drag on the preview to aim the zoom. With the preview focused, the arrow keys move it.", bundle: .module)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    Button(role: .destructive) {
                        document.removeZoom(id)
                    } label: {
                        Text("Remove Zoom", bundle: .module)
                    }
                } header: {
                    zoom.isAutomatic ? Text("Automatic Zoom", bundle: .module) : Text("Chosen Zoom", bundle: .module)
                }
                .id(Self.chosenZoomID)
            }
            if let cutStart = document.selectedCut,
               let cutIndex = document.project.cuts.firstIndex(where: { $0.lowerBound == cutStart }) {
                let cut = document.project.cuts[cutIndex]
                Section {
                    StudioTimeRangeFields(start: cut.lowerBound, end: cut.upperBound) { value, start in
                        document.setCutEdge(at: cut.lowerBound, start: start, to: value) ?? cut
                    }
                    .id(cutIndex)
                    Button(role: .destructive) {
                        document.restoreCut(at: cut.lowerBound)
                    } label: {
                        Text("Restore Cut", bundle: .module)
                    }
                } header: {
                    Text("Chosen Cut", bundle: .module)
                }
                .id(Self.chosenCutID)
            }
            // A stretch chosen on the clip, or a speed on the timeline: how fast it plays, beside Cut.
            if let rate = document.chosenRate {
                Section {
                    if let start = document.selectedSpeed,
                       let speedIndex = document.project.speeds.firstIndex(where: { $0.start == start }) {
                        let speed = document.project.speeds[speedIndex]
                        StudioTimeRangeFields(start: speed.start, end: speed.end) { value, isStart in
                            document.setSpeedEdge(at: speed.start, start: isStart, to: value) ?? speed.start...speed.end
                        }
                        .id(speedIndex)
                    }
                    Picker(selection: Binding(get: { rate }, set: { document.setSpeed($0) })) {
                        Text("As recorded", bundle: .module).tag(1.0)
                        ForEach(StudioProject.speedRates, id: \.self) { rate in
                            Text(verbatim: TransportBar.speed(rate)).tag(rate)
                        }
                        if rate != 1.0, !StudioProject.speedRates.contains(where: { abs($0 - rate) < 1e-6 }) {
                            Text(verbatim: TransportBar.speed(rate)).tag(rate)
                        }
                    } label: {
                        Text("Speed", bundle: .module)
                    }
                    if let start = document.selectedSpeed {
                        Button(role: .destructive) {
                            document.removeSpeed(at: start)
                        } label: {
                            Text("Remove Speed", bundle: .module)
                        }
                    } else if let range = document.selectedRange {
                        Button {
                            document.deleteSelection()
                        } label: {
                            Text("Cut", bundle: .module)
                        }
                        Button {
                            document.keepOnly(range)
                        } label: {
                            Text("Keep Only", bundle: .module)
                        }
                    }
                } header: {
                    document.selectedSpeed == nil ? Text("Chosen Stretch", bundle: .module) : Text("Chosen Speed", bundle: .module)
                }
                .id(Self.chosenSpeedID)
            }
            Section {
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(44), spacing: 8), count: 5), spacing: 8) {
                    ForEach(swatches) { swatch in
                        let chosen = document.project.background == .gradient(swatch.name)
                        Button {
                            document.project.background = .gradient(swatch.name)
                        } label: {
                            Image(decorative: swatch.picture, scale: 2)
                                .resizable()
                                .frame(width: 44, height: 30)
                                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                                        .strokeBorder(
                                            chosen ? Color.accentColor : contrast == .increased ? Self.swatchEdgeStrong : Self.swatchEdge,
                                            lineWidth: chosen ? 2 : 1
                                        )
                                )
                        }
                        .buttonStyle(.plain)
                        .help(Text(verbatim: swatch.title))
                        .accessibilityLabel(Text(verbatim: swatch.title))
                        .accessibilityAddTraits(chosen ? .isSelected : [])
                    }
                }
                // A tile like the gradients', filled with the color and ringed while it is the background, rather
                // than a color well, whose empty capsule read as a switch turned off.
                LabeledContent {
                    Button(action: choosePlainColor) {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(plainColor)
                            .frame(width: 44, height: 30)
                            .overlay(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .strokeBorder(
                                        isPlainColor ? Color.accentColor : contrast == .increased ? Self.swatchEdgeStrong : Self.swatchEdge,
                                        lineWidth: isPlainColor ? 2 : 1
                                    )
                            )
                    }
                    .buttonStyle(.plain)
                    .help(Text("Choose a plain color", bundle: .module))
                    .accessibilityLabel(Text("Plain color", bundle: .module))
                    .accessibilityAddTraits(isPlainColor ? .isSelected : [])
                } label: {
                    Text("Plain color", bundle: .module)
                }
                // A picture of one's own: the one in use, or the last one chosen while the project is open, beside
                // Choose Image…, which asks for another.
                LabeledContent {
                    HStack(spacing: 8) {
                        Button(action: choosePicture) { Text("Choose Image…", bundle: .module) }
                            .controlSize(.small)
                        if let name = shownPicture, let thumbnail = document.pictureThumbnail(name) {
                            Button {
                                document.project.background = .picture(name)
                            } label: {
                                backgroundTile(chosen: document.project.background == .picture(name)) {
                                    Image(decorative: thumbnail, scale: 2).resizable().scaledToFill()
                                }
                            }
                            .buttonStyle(.plain)
                            .help(Text("Use this picture", bundle: .module))
                            .accessibilityLabel(Text("Picture", bundle: .module))
                            .accessibilityAddTraits(document.project.background == .picture(name) ? .isSelected : [])
                        }
                    }
                } label: {
                    Text("Picture", bundle: .module)
                }
                LabeledContent {
                    Button {
                        document.project.background = .blur
                    } label: {
                        backgroundTile(chosen: document.project.background == .blur) {
                            if let blurredFrame {
                                Image(decorative: blurredFrame, scale: 2).resizable().scaledToFill()
                            } else {
                                Color(nsColor: .quaternaryLabelColor)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .help(Text("The recording itself, blurred until only its colors are left", bundle: .module))
                    .accessibilityLabel(Text("Blurred recording", bundle: .module))
                    .accessibilityAddTraits(document.project.background == .blur ? .isSelected : [])
                } label: {
                    Text("Blurred recording", bundle: .module)
                }
                .task { blurredFrame = await document.blurredRecordingThumbnail() }
            } header: {
                Text("Background", bundle: .module)
            }

            Section {
                Picker(selection: $document.project.aspect) {
                    Text("As recorded", bundle: .module).tag(StudioProject.Aspect.auto)
                    Text("16:9", bundle: .module).tag(StudioProject.Aspect.widescreen)
                    Text("4:3", bundle: .module).tag(StudioProject.Aspect.standard)
                    Text("1:1", bundle: .module).tag(StudioProject.Aspect.square)
                    Text("9:16", bundle: .module).tag(StudioProject.Aspect.vertical)
                } label: {
                    Text("Shape", bundle: .module)
                }
                LabeledSlider(title: Text("Padding", bundle: .module), value: $document.project.padding, range: 0...0.25, reading: Self.percent, document: document)
                LabeledSlider(title: Text("Corners", bundle: .module), value: $document.project.cornerRadius, range: 0...40, reading: { "\(Int($0.rounded())) pt" }, document: document)
                LabeledSlider(title: Text("Shadow", bundle: .module), value: $document.project.shadow, range: 0...1, reading: Self.percent, document: document)
            } header: {
                Text("Frame", bundle: .module)
            }

            Section {
                Picker(selection: cropPresetChoice) {
                    Text("Full", bundle: .module).tag(CropPreset.full)
                    Text("16:9", bundle: .module).tag(CropPreset.widescreen)
                    Text("4:3", bundle: .module).tag(CropPreset.standard)
                    Text("1:1", bundle: .module).tag(CropPreset.square)
                    Text("9:16", bundle: .module).tag(CropPreset.vertical)
                    if cropPresetChoice.wrappedValue == .custom {
                        Text("Custom", bundle: .module).tag(CropPreset.custom)
                    }
                } label: {
                    Text("Preset", bundle: .module)
                }
                .accessibilityLabel(Text("Crop preset", bundle: .module))
                LabeledSlider(title: Text("Left", bundle: .module), value: cropLeftBinding, range: 0...0.9, reading: Self.percent, document: document)
                LabeledSlider(title: Text("Right", bundle: .module), value: cropRightBinding, range: 0...0.9, reading: Self.percent, document: document)
                LabeledSlider(title: Text("Top", bundle: .module), value: cropTopBinding, range: 0...0.9, reading: Self.percent, document: document)
                LabeledSlider(title: Text("Bottom", bundle: .module), value: cropBottomBinding, range: 0...0.9, reading: Self.percent, document: document)
                if document.project.crop != nil {
                    Button {
                        document.resetCrop()
                    } label: {
                        Text("Reset Crop", bundle: .module)
                    }
                }
            } header: {
                Text("Crop", bundle: .module)
            }

            Section {
                Picker(selection: $document.project.cursor.style) {
                    Text("As recorded", bundle: .module).tag(StudioProject.Cursor.Style.recorded)
                    Text("Arrow", bundle: .module).tag(StudioProject.Cursor.Style.arrow)
                    Text("Highlight", bundle: .module).tag(StudioProject.Cursor.Style.highlight)
                } label: {
                    Text("Style", bundle: .module)
                }
                .accessibilityLabel(Text("Cursor style", bundle: .module))
                LabeledSlider(title: Text("Size", bundle: .module), value: $document.project.cursor.size, range: 1...3, reading: { TransportBar.scale($0) }, document: document)
                LabeledSlider(title: Text("Smoothing", bundle: .module), value: $document.project.cursor.smoothing, range: 0...1, reading: Self.percent, document: document)
                Toggle(isOn: $document.project.cursor.hidesWhenIdle) { Text("Hide when still", bundle: .module) }
                // Typing is known only when the keys were written down.
                if document.hasKeyPresses {
                    Toggle(isOn: $document.project.cursor.hidesWhileTyping) { Text("Hide while typing", bundle: .module) }
                }
            } header: {
                Text("Cursor", bundle: .module)
            }

            Section {
                Picker(selection: clickChoice) {
                    Text("None", bundle: .module).tag(ClickChoice.none)
                    Text("Ring", bundle: .module).tag(ClickChoice.ring)
                    Text("Ripple", bundle: .module).tag(ClickChoice.ripple)
                } label: {
                    Text("Effect", bundle: .module)
                }
                .accessibilityLabel(Text("Click effect", bundle: .module))
                LabeledContent {
                    HStack(spacing: 0) {
                        ForEach(StudioProject.ClickColor.allCases, id: \.self) { color in
                            ClickColorSwatch(color: color, isChosen: document.project.cursor.clickColor == color) {
                                document.project.cursor.clickColor = color
                            }
                        }
                    }
                } label: {
                    Text("Color", bundle: .module)
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel(Text("Click color", bundle: .module))
                .disabled(!document.project.cursor.showsClicks)
            } header: {
                Text("Clicks", bundle: .module)
            }

            if document.hasCamera {
                Section {
                    Picker(selection: $document.project.camera.layout) {
                        Text("Picture in picture", bundle: .module).tag(StudioProject.Camera.Layout.pictureInPicture)
                        Text("Side by side", bundle: .module).tag(StudioProject.Camera.Layout.sideBySide)
                        Text("Camera only", bundle: .module).tag(StudioProject.Camera.Layout.cameraOnly)
                        Text("Screen only", bundle: .module).tag(StudioProject.Camera.Layout.screenOnly)
                    } label: {
                        Text("Layout", bundle: .module)
                    }
                    .accessibilityLabel(Text("Camera layout", bundle: .module))
                    // The bubble's own settings, wherever the bubble shows: the movie's layout, or a stretch of the timeline.
                    if document.showsBubble {
                        // Named apart from the frame's Shape and the cursor's Size for VoiceOver.
                        Picker(selection: $document.project.camera.shape) {
                            Text("Circle", bundle: .module).tag(StudioProject.Camera.Shape.circle)
                            Text("Rounded square", bundle: .module).tag(StudioProject.Camera.Shape.roundedSquare)
                        } label: {
                            Text("Shape", bundle: .module)
                        }
                        .accessibilityLabel(Text("Camera shape", bundle: .module))
                        // A cut-out person has no bubble to shape.
                        .disabled(document.project.camera.background == .cutout)
                        // The recording bar's sizes.
                        Picker(selection: $document.project.camera.size) {
                            Text("Small", bundle: .module).tag(120.0)
                            Text("Medium", bundle: .module).tag(180.0)
                            Text("Large", bundle: .module).tag(260.0)
                        } label: {
                            Text("Size", bundle: .module)
                        }
                        .accessibilityLabel(Text("Camera size", bundle: .module))
                        Picker(selection: $document.project.camera.corner) {
                            Text("Bottom left", bundle: .module).tag(StudioProject.Camera.Corner.bottomLeft)
                            Text("Bottom right", bundle: .module).tag(StudioProject.Camera.Corner.bottomRight)
                            Text("Top left", bundle: .module).tag(StudioProject.Camera.Corner.topLeft)
                            Text("Top right", bundle: .module).tag(StudioProject.Camera.Corner.topRight)
                        } label: {
                            Text("Corner", bundle: .module)
                        }
                    }
                    if document.project.camera.layout == .sideBySide {
                        Picker(selection: $document.project.camera.side) {
                            Text("Left", bundle: .module).tag(StudioProject.Camera.Side.left)
                            Text("Right", bundle: .module).tag(StudioProject.Camera.Side.right)
                        } label: {
                            Text("Side", bundle: .module)
                        }
                        .accessibilityLabel(Text("Camera side", bundle: .module))
                    }
                    if document.showsCamera {
                        // Named apart from the movie's Background for VoiceOver.
                        Picker(selection: $document.project.camera.background) {
                            Text("Original", bundle: .module).tag(StudioProject.Camera.Background.original)
                            Text("Blur", bundle: .module).tag(StudioProject.Camera.Background.blur)
                            Text("Cutout", bundle: .module).tag(StudioProject.Camera.Background.cutout)
                        } label: {
                            Text("Background", bundle: .module)
                        }
                        .accessibilityLabel(Text("Camera background", bundle: .module))
                        Toggle(isOn: $document.project.camera.mirrored) { Text("Mirror", bundle: .module) }
                    }
                    // Other layouts for stretches of the movie: not side by side, which widens all of it.
                    if document.canChangeLayoutAlongTheTimeline {
                        if let id = document.selectedSegment, let segment = document.project.cameraSegments.first(where: { $0.id == id }) {
                            StudioTimeRangeFields(start: segment.start, end: segment.end) { value, start in
                                document.setCameraSegmentEdge(id, start: start, to: value) ?? segment.start...segment.end
                            }
                            .id(id)
                            .id(Self.chosenLayoutID)
                            Picker(selection: Binding(get: { segment.layout }, set: { document.setCameraSegmentLayout(id, $0) })) {
                                ForEach(StudioProject.Camera.Layout.stretchLayouts, id: \.self) { layout in
                                    Text(verbatim: layout.name).tag(layout)
                                }
                            } label: {
                                Text("Chosen stretch", bundle: .module)
                            }
                            .accessibilityLabel(Text("Layout of the chosen stretch", bundle: .module))
                            Button(role: .destructive) {
                                document.removeCameraSegment(id)
                            } label: {
                                Text("Remove Layout", bundle: .module)
                            }
                        } else if document.project.cameraSegments.isEmpty {
                            Text("Add Layout shows the camera another way for a stretch of the movie.", bundle: .module)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        } else {
                            Text("Choose a layout on the timeline to change it.", bundle: .module)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("Camera", bundle: .module)
                }
            } else if document.cameraFailed {
                Section {
                    Text("The camera couldn’t be recorded.", bundle: .module)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("Camera", bundle: .module)
                }
            }

            Section {
                Toggle(isOn: Binding(get: { document.project.automaticZooms }, set: { document.setAutomaticZooms($0) })) {
                    document.hasKeyPresses ? Text("Zoom on clicks and typing", bundle: .module) : Text("Zoom on clicks", bundle: .module)
                }
                Toggle(isOn: $document.project.motionBlur) { Text("Motion blur", bundle: .module) }
                    .help(Text("Blurs the picture while the view zooms or pans, as a camera would. Still frames stay sharp.", bundle: .module))
                if document.project.automaticZooms, document.automaticZooms.isEmpty {
                    Group {
                        if !document.hasEventsToFollow {
                            document.hasKeyPresses
                                ? Text("No clicks or typing to follow, so no zooms were placed.", bundle: .module)
                                : Text("No clicks to follow, so no zooms were placed.", bundle: .module)
                        } else {
                            // A lone click places none: a zoom in and straight back out for one click only jolts.
                            document.hasKeyPresses
                                ? Text("The clicks and typing were too few or too spread out to zoom on. Add Zoom places one by hand.", bundle: .module)
                                : Text("The clicks were too few or too spread out to zoom on. Add Zoom places one by hand.", bundle: .module)
                        }
                    }
                    .font(.callout)
                    .foregroundStyle(.secondary)
                }
                if document.selectedZoom == nil, !document.project.zooms.isEmpty {
                    Text("Choose a zoom on the timeline to change it.", bundle: .module)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                if !document.automaticZooms.isEmpty {
                    Button {
                        document.resetToAutomaticZooms()
                    } label: {
                        Text("Reset to Automatic", bundle: .module)
                    }
                    .disabled(document.matchesAutomaticZooms)
                }
                if !document.project.zooms.isEmpty {
                    Button(role: .destructive) {
                        document.clearAllZooms()
                    } label: {
                        Text("Clear All Zooms", bundle: .module)
                    }
                }
            } header: {
                Text("Zoom", bundle: .module)
            }

            if document.hasKeys {
                Section {
                    Toggle(isOn: $document.project.showsKeys) { Text("Show the keys pressed", bundle: .module) }
                    // All keys were written down: the movie can show them all, or shortcuts only.
                    if document.telemetry.keystrokeMode == .all {
                        Picker(selection: $document.project.keystrokeMode) {
                            Text("All keys", bundle: .module).tag(KeystrokeMode.all)
                            Text("Shortcuts only", bundle: .module).tag(KeystrokeMode.shortcuts)
                        } label: {
                            Text("Show", bundle: .module)
                        }
                        .disabled(!document.project.showsKeys)
                        // What was typed is in the project, as typed: Settings can keep shortcuts only, or no keys.
                        Text("What you typed is kept with this recording, on this Mac. Settings › Recording can keep shortcuts only, or no keys.", bundle: .module)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    } else if document.telemetry.keystrokeMode == .shortcuts {
                        Text("Only shortcuts were recorded", bundle: .module)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Keys", bundle: .module)
                }
            } else if document.telemetry.keystrokeMode == .shortcuts, !document.telemetry.keys.isEmpty {
                Section {
                    Text("Only shortcuts were recorded", bundle: .module)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("Keys", bundle: .module)
                }
            } else if document.telemetry.keystrokeMode == nil {
                // Keys are written down while recording, when Input Monitoring is on: this recording has none to show.
                Section {
                    Text("No keys were kept with this recording. Studio keeps them when Input Monitoring is on and Settings allows it (a window recorded on its own, only with Show Keystrokes on).", bundle: .module)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("Keys", bundle: .module)
                }
            }

            // Each of the recording's sounds, set on its own: the system's and the microphone's where they were kept
            // apart, else the recording's sound as one.
            if !document.sounds.isEmpty {
                Section {
                    Toggle(isOn: Binding(get: { document.project.audio.master.isMuted }, set: { document.setMasterMuted($0) })) {
                        Text("Mute Audio", bundle: .module)
                    }
                    LabeledSlider(
                        title: Text("Master volume", bundle: .module),
                        value: $document.project.audio.master.volume,
                        range: 0...1, reading: Self.percent, document: document
                    )
                    .disabled(document.project.audio.master.isMuted)
                    ForEach(document.sounds, id: \.self) { sound in
                        SoundLevelRow(sound: sound, document: document)
                            .disabled(document.project.audio.master.isMuted)
                    }
                    LabeledSlider(
                        title: Text("Fade In", bundle: .module),
                        value: Binding(get: { document.project.audio.fadeIn }, set: { document.setAudioFadeIn($0) }),
                        range: 0...3, reading: Self.seconds, document: document
                    )
                    .disabled(document.project.audio.master.isMuted)
                    LabeledSlider(
                        title: Text("Fade Out", bundle: .module),
                        value: Binding(get: { document.project.audio.fadeOut }, set: { document.setAudioFadeOut($0) }),
                        range: 0...3, reading: Self.seconds, document: document
                    )
                    .disabled(document.project.audio.master.isMuted)
                } header: {
                    Text("Audio", bundle: .module)
                }
            }

            Section {
                Picker(selection: resolutionChoice) {
                    Text("Original", bundle: .module).tag(ResolutionChoice.original)
                    Text("1080p", bundle: .module).tag(ResolutionChoice.p1080)
                    Text("720p", bundle: .module).tag(ResolutionChoice.p720)
                    if case .custom(let pixels) = resolutionChoice.wrappedValue {
                        Text(verbatim: "\(pixels) px").tag(ResolutionChoice.custom(pixels))
                    }
                } label: {
                    Text("Resolution", bundle: .module)
                }
                Picker(selection: Binding(
                    get: { document.project.resolvedFramesPerSecond <= 30 ? 30 : 60 },
                    set: { document.setFramesPerSecond($0 == 60 ? nil : $0) }
                )) {
                    Text("60 fps", bundle: .module).tag(60)
                    Text("30 fps", bundle: .module).tag(30)
                } label: {
                    Text("Frame Rate", bundle: .module)
                }
                Picker(selection: Binding(get: { document.project.quality }, set: { document.setQuality($0) })) {
                    Text("Smaller file", bundle: .module).tag(StudioProject.Quality.smaller)
                    Text("Standard", bundle: .module).tag(StudioProject.Quality.standard)
                    Text("Best quality", bundle: .module).tag(StudioProject.Quality.best)
                } label: {
                    Text("Quality", bundle: .module)
                }
                // Follows the resolution, quality, shape, padding, and cuts; byte estimate is unknown when the recording's size is.
                let canvas = document.movieLayout().canvas
                let dimensions = "\(Int(canvas.width)) × \(Int(canvas.height))"
                if let bytes = document.estimatedMovieByteCount {
                    Text(verbatim: "\(dimensions) · \(StudioExporter.estimateDescription(byteCount: bytes))")
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                } else {
                    Text(verbatim: dimensions)
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Movie", bundle: .module)
            }
        }
        .formStyle(.grouped)
    }

    /// Where the chosen zoom looks, as the picker has it: following the pointer, or held on a spot of its own,
    /// which choosing it puts where the zoom looks now.
    private enum ZoomTarget: Hashable {
        case pointer
        case spot
    }

    /// How clicks show, as the picker has it: none, or an effect. Clicks off are `showsClicks`; the effect is
    /// kept while they are, so choosing None and then Ripple brings back a ripple.
    private enum ClickChoice: Hashable {
        case none
        case ring
        case ripple
    }

    private var clickChoice: Binding<ClickChoice> {
        Binding {
            let cursor = document.project.cursor
            guard cursor.showsClicks else { return .none }
            return cursor.clickEffect == .ring ? .ring : .ripple
        } set: { choice in
            // One change to the project, so Undo takes it back as one.
            var cursor = document.project.cursor
            switch choice {
            case .none:
                cursor.showsClicks = false
            case .ring:
                cursor.showsClicks = true
                cursor.clickEffect = .ring
            case .ripple:
                cursor.showsClicks = true
                cursor.clickEffect = .ripple
            }
            document.project.cursor = cursor
        }
    }

    /// The plain background's color, white until one is chosen.
    private var plainNSColor: NSColor {
        if case .color(let red, let green, let blue) = document.project.background {
            return NSColor(srgbRed: red, green: green, blue: blue, alpha: 1)
        }
        return .white
    }

    private var plainColor: Color { Color(nsColor: plainNSColor) }

    /// Makes the plain color the background and opens the Colors panel on it, whose changes follow as they are
    /// made (the document takes changes within 0.4 s of each other back as one).
    private func choosePlainColor() {
        let color = plainNSColor
        // Weakly: the panel outlives the window, and a project closed takes no more colors.
        let use = { [weak document] (color: NSColor) in
            guard let document, let srgb = color.usingColorSpace(.sRGB) else { return }
            document.project.background = .color(red: srgb.redComponent, green: srgb.greenComponent, blue: srgb.blueComponent)
        }
        use(color)
        let link = PlainColorLink(apply: use)
        // The panel doesn't keep its target, so the link keeps itself until the next one takes its place.
        PlainColorLink.current = link
        let panel = NSColorPanel.shared
        panel.showsAlpha = false
        panel.isContinuous = true
        // Setting the panel's color sends its action: aimed at nothing first, so the color never reaches the
        // editor (or the Studio) that used the panel last.
        panel.setTarget(nil)
        panel.setAction(nil)
        panel.color = color
        panel.setTarget(link)
        panel.setAction(#selector(PlainColorLink.changed(_:)))
        panel.orderFront(nil)
    }

    private var isPlainColor: Bool {
        if case .color = document.project.background { return true }
        return false
    }

    /// The picture the Picture row offers: the background's, or the last one chosen.
    private var shownPicture: String? {
        if case .picture(let name) = document.project.background { return name }
        return document.lastPicture
    }

    /// A background's tile, as the gradients' are: 44 × 30 pt, 6 pt continuous corners, edged with the Capsule
    /// Swatch Edge and ringed by a 2 pt accent line while it is the background.
    private func backgroundTile(chosen: Bool, @ViewBuilder content: () -> some View) -> some View {
        content()
            .frame(width: 44, height: 30)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(
                        chosen ? Color.accentColor : contrast == .increased ? Self.swatchEdgeStrong : Self.swatchEdge,
                        lineWidth: chosen ? 2 : 1
                    )
            )
    }

    private enum ResolutionChoice: Hashable {
        case original
        case p1080
        case p720
        case custom(Int)
    }

    private var resolutionChoice: Binding<ResolutionChoice> {
        Binding {
            switch document.project.outputMaxSide {
            case nil: .original
            case 1920: .p1080
            case 1280: .p720
            case let pixels?: .custom(pixels)
            }
        } set: { choice in
            switch choice {
            case .original: document.setOutputMaxSide(nil)
            case .p1080: document.setOutputMaxSide(1920)
            case .p720: document.setOutputMaxSide(1280)
            case .custom(let pixels): document.setOutputMaxSide(pixels)
            }
        }
    }

    private enum CropPreset: Hashable {
        case full
        case widescreen
        case standard
        case square
        case vertical
        case custom

        var ratio: Double? {
            switch self {
            case .full, .custom: nil
            case .widescreen: 16.0 / 9
            case .standard: 4.0 / 3
            case .square: 1.0
            case .vertical: 9.0 / 16
            }
        }
    }

    private var cropPresetChoice: Binding<CropPreset> {
        Binding {
            guard let crop = document.project.crop else { return .full }
            let size = document.recordingSize
            for preset in [CropPreset.widescreen, .standard, .square, .vertical] {
                guard let ratio = preset.ratio,
                      let expected = StudioProject.centeredCrop(aspectRatio: ratio, recordingSize: size) else { continue }
                if abs(crop.minX - expected.minX) < 0.005
                    && abs(crop.minY - expected.minY) < 0.005
                    && abs(crop.width - expected.width) < 0.005
                    && abs(crop.height - expected.height) < 0.005 {
                    return preset
                }
            }
            return .custom
        } set: { preset in
            switch preset {
            case .full:
                document.resetCrop()
            case .widescreen, .standard, .square, .vertical:
                if let ratio = preset.ratio {
                    document.setCrop(StudioProject.centeredCrop(aspectRatio: ratio, recordingSize: document.recordingSize))
                }
            case .custom:
                break
            }
        }
    }

    private var cropLeftBinding: Binding<Double> {
        Binding {
            Double(document.project.effectiveCrop.minX)
        } set: { newValue in
            let crop = document.project.effectiveCrop
            let rightInset = max(0, 1.0 - Double(crop.maxX))
            let left = min(max(newValue, 0), max(0, 0.9 - rightInset))
            let width = max(0.1, 1.0 - left - rightInset)
            document.setCrop(CGRect(x: left, y: Double(crop.minY), width: width, height: Double(crop.height)))
        }
    }

    private var cropRightBinding: Binding<Double> {
        Binding {
            max(0, 1.0 - Double(document.project.effectiveCrop.maxX))
        } set: { newValue in
            let crop = document.project.effectiveCrop
            let left = Double(crop.minX)
            let right = min(max(newValue, 0), max(0, 0.9 - left))
            let width = max(0.1, 1.0 - left - right)
            document.setCrop(CGRect(x: left, y: Double(crop.minY), width: width, height: Double(crop.height)))
        }
    }

    private var cropTopBinding: Binding<Double> {
        Binding {
            Double(document.project.effectiveCrop.minY)
        } set: { newValue in
            let crop = document.project.effectiveCrop
            let bottomInset = max(0, 1.0 - Double(crop.maxY))
            let top = min(max(newValue, 0), max(0, 0.9 - bottomInset))
            let height = max(0.1, 1.0 - top - bottomInset)
            document.setCrop(CGRect(x: Double(crop.minX), y: top, width: Double(crop.width), height: height))
        }
    }

    private var cropBottomBinding: Binding<Double> {
        Binding {
            max(0, 1.0 - Double(document.project.effectiveCrop.maxY))
        } set: { newValue in
            let crop = document.project.effectiveCrop
            let top = Double(crop.minY)
            let bottom = min(max(newValue, 0), max(0, 0.9 - top))
            let height = max(0.1, 1.0 - top - bottom)
            document.setCrop(CGRect(x: Double(crop.minX), y: top, width: Double(crop.width), height: height))
        }
    }

    static func percent(_ value: Double) -> String {
        "\(Int((value * 100).rounded()))%"
    }

    static func seconds(_ value: Double) -> String {
        "\(TransportBar.oneDecimal(value)) s"
    }

    /// The capsule swatch edge (black 0.18, white 0.38 in Dark; 0.40 and 0.60 under Increase Contrast),
    /// which holds around the palest and the darkest backgrounds alike.
    static let swatchEdge = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.isDark ? NSColor(white: 1, alpha: 0.38) : NSColor(white: 0, alpha: 0.18)
    })
    static let swatchEdgeStrong = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.isDark ? NSColor(white: 1, alpha: 0.6) : NSColor(white: 0, alpha: 0.4)
    })
}

extension StudioProject.Camera.Layout {
    /// The layouts a stretch of the timeline can take: side by side widens the whole movie, so it is not one.
    static let stretchLayouts: [StudioProject.Camera.Layout] = [.pictureInPicture, .cameraOnly, .screenOnly]

    var name: String {
        switch self {
        case .pictureInPicture: String(localized: "Picture in picture", bundle: .module)
        case .sideBySide: String(localized: "Side by side", bundle: .module)
        case .cameraOnly: String(localized: "Camera only", bundle: .module)
        case .screenOnly: String(localized: "Screen only", bundle: .module)
        }
    }

    /// The symbol that stands for the layout on the timeline's chips.
    var symbol: String {
        switch self {
        case .pictureInPicture: "pip"
        case .sideBySide: "rectangle.split.2x1"
        case .cameraOnly: "web.camera"
        case .screenOnly: "display"
        }
    }
}

/// One color for the clicks' effect: a 14 pt disc of the color (the accent as the user has it), edged with the
/// Capsule Swatch Edge, and ringed by a 2 pt line in label ink 2 pt outside it while chosen: never the accent, which
/// is one of the colors it rings (DESIGN.md › Shapes).
struct ClickColorSwatch: View {
    let color: StudioProject.ClickColor
    let isChosen: Bool
    let choose: () -> Void
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        Button(action: choose) {
            Circle()
                .fill(fill)
                .frame(width: 14, height: 14)
                .overlay(Circle().strokeBorder(contrast == .increased ? StudioInspector.swatchEdgeStrong : StudioInspector.swatchEdge, lineWidth: contrast == .increased ? 1 : 0.5))
                .overlay(Circle().strokeBorder(Color(nsColor: .labelColor), lineWidth: 2).padding(-4).opacity(isChosen ? 1 : 0))
                .padding(4)
        }
        .buttonStyle(.plain)
        .help(title)
        .accessibilityLabel(title)
        .accessibilityAddTraits(isChosen ? .isSelected : [])
    }

    private var fill: Color {
        color.rgb.map { Color(red: $0.red, green: $0.green, blue: $0.blue) } ?? Color.accentColor
    }

    private var title: Text {
        switch color {
        case .accent: Text("Accent", bundle: .module)
        case .red: Text("Red", bundle: .module)
        case .orange: Text("Orange", bundle: .module)
        case .yellow: Text("Yellow", bundle: .module)
        case .green: Text("Green", bundle: .module)
        case .blue: Text("Blue", bundle: .module)
        case .purple: Text("Purple", bundle: .module)
        case .white: Text("White", bundle: .module)
        }
    }
}

/// A slider with its title and its reading, the reading in secondary ink with monospaced digits. A drag is
/// taken back by Undo as one change.
struct LabeledSlider: View {
    let title: Text
    @Binding var value: Double
    let range: ClosedRange<Double>
    let reading: (Double) -> String
    let document: StudioDocument

    var body: some View {
        LabeledContent {
            HStack(spacing: 8) {
                Slider(value: $value, in: range) { editing in
                    if editing { document.beginContinuousChange() } else { document.endContinuousChange() }
                }
                .labelsHidden()
                Text(verbatim: reading(value))
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 44, alignment: .trailing)
            }
        } label: {
            title
        }
        .accessibilityValue(Text(verbatim: reading(value)))
    }
}

/// The speeds a chosen stretch can play at, each checked while it does, and Remove Speed for one played so already:
/// the transport's Speed menu.
struct SpeedChoices: View {
    let document: StudioDocument

    var body: some View {
        ForEach(StudioProject.speedRates, id: \.self) { rate in
            Toggle(isOn: Binding(get: { document.chosenRate == rate }, set: { _ in document.setSpeed(rate) })) {
                Text(verbatim: TransportBar.speed(rate))
            }
        }
        if document.selectedSpeed != nil {
            Divider()
            Button {
                document.setSpeed(1)
            } label: {
                Text("Remove Speed", bundle: .module)
            }
        }
    }
}

/// One of the recording's sounds: Mute, a toggle, and how loud it plays, with the reading in secondary ink with
/// monospaced digits. A drag is taken back by Undo as one change.
struct SoundLevelRow: View {
    let sound: StudioSound
    @Bindable var document: StudioDocument

    var body: some View {
        let level = document.project.audio[sound]
        LabeledContent {
            HStack(spacing: 8) {
                Toggle(isOn: Binding(get: { level.isMuted }, set: { document.setMuted($0, sound) })) {
                    Image(systemName: level.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .frame(width: 18)
                }
                .toggleStyle(.button)
                .buttonStyle(.borderless)
                .help(muteLabel)
                .accessibilityLabel(muteLabel)
                Slider(value: $document.project.audio[sound].volume, in: 0...1) { editing in
                    if editing { document.beginContinuousChange() } else { document.endContinuousChange() }
                }
                .labelsHidden()
                .disabled(level.isMuted)
                .accessibilityLabel(volumeLabel)
                .accessibilityValue(Text(verbatim: StudioInspector.percent(level.volume)))
                Text(verbatim: StudioInspector.percent(level.volume))
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 44, alignment: .trailing)
                    .accessibilityHidden(true)
            }
        } label: {
            title
        }
    }

    private var title: Text {
        switch sound {
        case .system: Text("System sound", bundle: .module)
        case .microphone: Text("Microphone", bundle: .module)
        case .recorded: Text("Sound", bundle: .module)
        }
    }

    private var muteLabel: Text {
        switch sound {
        case .system: Text("Mute system sound", bundle: .module)
        case .microphone: Text("Mute microphone", bundle: .module)
        case .recorded: Text("Mute sound", bundle: .module)
        }
    }

    private var volumeLabel: Text {
        switch sound {
        case .system: Text("System sound volume", bundle: .module)
        case .microphone: Text("Microphone volume", bundle: .module)
        case .recorded: Text("Sound volume", bundle: .module)
        }
    }
}

/// The Colors panel's target while it edits Studio's plain background: an object, since the panel keeps a
/// target and an action rather than a closure.
@MainActor
final class PlainColorLink: NSObject {
    /// The link the panel was last pointed at.
    static var current: PlainColorLink?
    private let apply: (NSColor) -> Void

    init(apply: @escaping (NSColor) -> Void) {
        self.apply = apply
    }

    @objc func changed(_ sender: NSColorPanel) {
        apply(sender.color)
    }
}
