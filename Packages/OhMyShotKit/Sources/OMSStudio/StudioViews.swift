import AppKit
import AVKit
import OMSCore
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
                    .padding(20)
                    .overlay { previewState }
                    .background(Color(nsColor: .underPageBackgroundColor))
                Divider()
                TransportBar(document: document, model: model)
                StudioTimeline(document: document, model: model)
                    .frame(height: document.canChangeLayoutAlongTheTimeline ? StudioTimeline.heightWithLayouts : StudioTimeline.height)
            }
            Divider()
            StudioInspector(document: document, swatches: swatches)
                .frame(width: 290)
        }
        .overlay {
            if let progress = model.progress {
                VStack(spacing: 10) {
                    ProgressView(value: progress)
                        .frame(width: 180)
                    Text("Exporting…", bundle: .module)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Button(role: .cancel) {
                        model.controller?.cancelExport()
                    } label: {
                        Text("Cancel", bundle: .module)
                    }
                    .keyboardShortcut(.cancelAction)
                    .controlSize(.small)
                }
                .padding(.horizontal, 22)
                .padding(.vertical, 16)
                .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.18), radius: 10, y: 3)
                .accessibilityElement(children: .combine)
            }
        }
        .toolbar { toolbar }
        .onDeleteCommand { document.deleteSelection() }
    }

    /// Over the preview until its first movie is made, or when the recording can't be read.
    @ViewBuilder private var previewState: some View {
        if document.composition == nil {
            if document.compositionFailed {
                VStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 28, weight: .light))
                        .foregroundStyle(.tertiary)
                    Text("The recording couldn’t be read", bundle: .module)
                        .font(.title3)
                    Text("It may have been moved or damaged.", bundle: .module)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
            } else {
                ProgressView()
                    .controlSize(.regular)
                    .accessibilityLabel(Text("Preparing the preview", bundle: .module))
            }
        }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Menu {
                Button { model.controller?.saveMovieAs() } label: { Text("Save As…", bundle: .module) }
            } label: {
                Label {
                    model.saved ? Text("Saved", bundle: .module) : Text("Save", bundle: .module)
                } icon: {
                    Image(systemName: model.saved ? "checkmark" : "square.and.arrow.down")
                }
            } primaryAction: {
                model.controller?.saveMovie()
            }
            .help(Text("Save a Copy (⌘S)", bundle: .module))
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
            Spacer()
            Button {
                document.addZoom()
            } label: {
                Label { Text("Add Zoom", bundle: .module) } icon: { Image(systemName: "plus.magnifyingglass") }
            }
            .help(Text("A zoom at the playhead, following the pointer", bundle: .module))
            if document.canChangeLayoutAlongTheTimeline {
                Button {
                    document.addCameraSegment()
                } label: {
                    Label { Text("Add Layout", bundle: .module) } icon: { Image(systemName: "rectangle.on.rectangle") }
                }
                .help(Text("Shows the camera another way from the playhead: filling the movie, or hidden", bundle: .module))
            }
            if model.selectedRange == nil, let cut = document.selectedCut {
                Button {
                    document.restoreCut(at: cut)
                } label: {
                    Label { Text("Restore Cut", bundle: .module) } icon: { Image(systemName: "arrow.uturn.backward") }
                }
                .help(Text("Put the chosen cut back in the movie", bundle: .module))
            } else {
                Button {
                    if let range = model.selectedRange {
                        document.cut(range)
                        model.selectedRange = nil
                    }
                } label: {
                    Label { Text("Cut", bundle: .module) } icon: { Image(systemName: "scissors") }
                }
                .disabled(model.selectedRange == nil)
                .help(Text("Leave the stretch chosen on the clip out of the movie (drag along the clip, or I and O)", bundle: .module))
            }
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
        let now = String(format: "%.1f", document.movieTime(document.time))
        let length = String(format: "%.1f", movieDuration(of: document))
        return Text("\(now) of \(length) seconds", bundle: .module)
    }

    /// A time as the transport shows it: 0:12.3, 1:02:09.4.
    static func format(_ seconds: Double) -> String {
        let total = max(0, seconds)
        let tenths = Int((total * 10).rounded(.down))
        let hours = tenths / 36_000, minutes = tenths / 600 % 60, secs = tenths / 10 % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d.%d", hours, minutes, secs, tenths % 10)
            : String(format: "%d:%02d.%d", minutes, secs, tenths % 10)
    }
}

/// The inspector: the background, the frame, the cursor, the camera, zooms, keys, and the movie's quality.
struct StudioInspector: View {
    @Bindable var document: StudioDocument
    let swatches: [StudioWindowController.Swatch]
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        Form {
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
                                            lineWidth: chosen ? 2 : contrast == .increased ? 1 : 0.5
                                        )
                                )
                        }
                        .buttonStyle(.plain)
                        .help(Text(verbatim: swatch.title))
                        .accessibilityLabel(Text(verbatim: swatch.title))
                        .accessibilityAddTraits(chosen ? .isSelected : [])
                    }
                }
                ColorPicker(selection: plainColor, supportsOpacity: false) {
                    HStack(spacing: 6) {
                        Text("Plain color", bundle: .module)
                        if isPlainColor {
                            Image(systemName: "checkmark")
                                .font(.callout.weight(.semibold))
                                .foregroundStyle(.tint)
                                .accessibilityLabel(Text("Chosen", bundle: .module))
                        }
                    }
                }
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
                Picker(selection: $document.project.cursor.style) {
                    Text("As recorded", bundle: .module).tag(StudioProject.Cursor.Style.recorded)
                    Text("Arrow", bundle: .module).tag(StudioProject.Cursor.Style.arrow)
                    Text("Highlight", bundle: .module).tag(StudioProject.Cursor.Style.highlight)
                } label: {
                    Text("Style", bundle: .module)
                }
                .accessibilityLabel(Text("Cursor style", bundle: .module))
                LabeledSlider(title: Text("Size", bundle: .module), value: $document.project.cursor.size, range: 1...3, reading: { String(format: "%.1f×", $0) }, document: document)
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
                        Toggle(isOn: $document.project.camera.mirrored) { Text("Mirror", bundle: .module) }
                    }
                    // Other layouts for stretches of the movie: not side by side, which widens all of it.
                    if document.canChangeLayoutAlongTheTimeline {
                        if let id = document.selectedSegment, let segment = document.project.cameraSegments.first(where: { $0.id == id }) {
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
                if let id = document.selectedZoom, let zoom = document.project.zooms.first(where: { $0.id == id }) {
                    LabeledSlider(
                        title: Text("Zoom", bundle: .module),
                        value: Binding(get: { zoom.scale }, set: { scale in document.updateZoom(id) { $0.scale = scale } }),
                        range: 1.2...4, reading: { String(format: "%.1f×", $0) }, document: document
                    )
                    Button(role: .destructive) {
                        document.removeZoom(id)
                    } label: {
                        Text("Remove Zoom", bundle: .module)
                    }
                } else if !document.project.zooms.isEmpty {
                    Text("Choose a zoom on the timeline to change it.", bundle: .module)
                        .font(.callout)
                        .foregroundStyle(.secondary)
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
                    }
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

            Section {
                Picker(selection: Binding(get: { document.project.quality }, set: { document.setQuality($0) })) {
                    Text("Smaller file", bundle: .module).tag(StudioProject.Quality.smaller)
                    Text("Standard", bundle: .module).tag(StudioProject.Quality.standard)
                    Text("Best quality", bundle: .module).tag(StudioProject.Quality.best)
                } label: {
                    Text("Quality", bundle: .module)
                }
                // Follows the quality, the shape and padding, and the cuts; unknown when the recording's size is.
                if let bytes = document.estimatedMovieByteCount {
                    Text(verbatim: StudioExporter.estimateDescription(byteCount: bytes))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Movie", bundle: .module)
            }
        }
        .formStyle(.grouped)
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

    private var plainColor: Binding<Color> {
        Binding {
            if case .color(let red, let green, let blue) = document.project.background {
                return Color(red: red, green: green, blue: blue)
            }
            return .white
        } set: { color in
            guard let srgb = NSColor(color).usingColorSpace(.sRGB) else { return }
            document.project.background = .color(red: srgb.redComponent, green: srgb.greenComponent, blue: srgb.blueComponent)
        }
    }

    private var isPlainColor: Bool {
        if case .color = document.project.background { return true }
        return false
    }

    static func percent(_ value: Double) -> String {
        "\(Int((value * 100).rounded()))%"
    }

    /// The capsule swatch edge (black 0.18, white 0.38 in Dark; 0.40 and 0.60 under Increase Contrast),
    /// which holds around the palest and the darkest backgrounds alike.
    static let swatchEdge = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(white: 1, alpha: 0.38) : NSColor(white: 0, alpha: 0.18)
    })
    static let swatchEdgeStrong = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(white: 1, alpha: 0.6) : NSColor(white: 0, alpha: 0.4)
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
/// Capsule Swatch Edge, and ringed by a 2 pt accent line 2 pt outside it while chosen.
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
                .overlay(Circle().strokeBorder(Color.accentColor, lineWidth: 2).padding(-4).opacity(isChosen ? 1 : 0))
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
