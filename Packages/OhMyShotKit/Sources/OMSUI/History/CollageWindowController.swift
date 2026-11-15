import AppKit
import Foundation
import Observation
import OMSCore
import SwiftUI

/// Combine into Collage, from History: the selected screenshots laid out together, previewed as the choices change,
/// and made into one picture that opens in the editor as a new capture (`combine`), where a background, marks, or a
/// crop can follow as on any other.
public final class CollageWindowController: NSWindowController, NSWindowDelegate {
    public var onClose: (() -> Void)?

    private var windowLease: ActiveResources.Lease?
    private let model: CollageModel

    /// `pictures` in the order they are laid out; `scale` is the pixels per point the collage is made at;
    /// `combine` is given the collage and that scale, and the window closes.
    public init(pictures: [CollageRenderer.Picture], scale: CGFloat, combine: @escaping (CGImage, CGFloat) -> Void) {
        model = CollageModel(pictures: pictures, scale: scale)
        let window = CollageWindow(
            contentRect: CGRect(x: 0, y: 0, width: 880, height: 600),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: true
        )
        window.title = String(localized: "Combine into Collage", bundle: .module)
        window.isReleasedWhenClosed = false
        window.minSize = CGSize(width: 720, height: 480)
        window.tabbingMode = .disallowed
        super.init(window: window)
        let model = model
        let controller = NSHostingController(rootView: CollageView(
            model: model,
            combine: { [weak self] in
                guard let self else { return }
                Task {
                    guard let image = await model.render() else { return NSSound.beep() }
                    combine(image, model.scale)
                    self.close()
                }
            },
            cancel: { [weak self] in self?.close() }
        ))
        window.contentViewController = controller
        window.setContentSize(CGSize(width: 880, height: 600))
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

    public func windowWillClose(_ notification: Notification) {
        windowLease?.end()
        windowLease = nil
        onClose?()
    }
}

/// Closes on Escape when no control takes it.
private final class CollageWindow: NSWindow {
    override func cancelOperation(_ sender: Any?) {
        close()
    }
}

/// The colors a collage can be laid on.
enum CollageBackground: String, CaseIterable, Identifiable {
    case white, light, dark, black, clear

    var id: String { rawValue }

    var color: CGColor? {
        switch self {
        case .white: CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
        case .light: CGColor(srgbRed: 0.93, green: 0.94, blue: 0.95, alpha: 1)
        case .dark: CGColor(srgbRed: 0.17, green: 0.18, blue: 0.2, alpha: 1)
        case .black: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)
        case .clear: nil
        }
    }

    var title: String {
        switch self {
        case .white: String(localized: "White", bundle: .module)
        case .light: String(localized: "Light Gray", bundle: .module)
        case .dark: String(localized: "Dark Gray", bundle: .module)
        case .black: String(localized: "Black", bundle: .module)
        case .clear: String(localized: "None", bundle: .module)
        }
    }
}

@MainActor
@Observable
final class CollageModel {
    let pictures: [CollageRenderer.Picture]
    let scale: CGFloat
    /// The pictures made small, for the preview, which is drawn again at every change.
    @ObservationIgnored private let previews: [CollageRenderer.Picture]

    var arrangement: CollageLayout.Arrangement
    var fitting: CollageLayout.Fitting = .fit
    var width: CGFloat
    var spacing: CGFloat = 16
    var margin: CGFloat = 24
    var cornerRadius: CGFloat = 8
    var background: CollageBackground = .white
    private(set) var preview: CGImage?
    private(set) var isRendering = false

    static let widthRange: ClosedRange<CGFloat> = CollageLayout.leastWidth...3200

    init(pictures: [CollageRenderer.Picture], scale: CGFloat) {
        self.pictures = pictures
        self.scale = max(scale, 1)
        let sizes = pictures.map(\.size)
        let arrangement = CollageLayout.suggested(for: sizes)
        self.arrangement = arrangement
        width = min(max(CollageLayout.suggestedWidth(for: sizes, arrangement: arrangement), Self.widthRange.lowerBound), Self.widthRange.upperBound)
        previews = pictures.map { picture in
            CollageRenderer.Picture(image: Self.thumbnail(of: picture.image, longest: 700) ?? picture.image, size: picture.size)
        }
    }

    var options: CollageLayout.Options {
        CollageLayout.Options(arrangement: arrangement, width: width, spacing: spacing, margin: margin, fitting: fitting)
    }

    var layout: CollageLayout { CollageLayout.layout(pictures.map(\.size), options: options) }

    /// Whether the fitting choice changes anything: rows and columns are made of cells of the pictures' shapes.
    var fittingMatters: Bool { arrangement == .grid || arrangement == .featured }

    /// What the collage will be, in pixels.
    var pixelSize: CGSize {
        let size = layout.size
        return CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
    }

    /// The preview again, about 900 pixels wide, from the small pictures.
    func updatePreview() {
        let layout = layout
        let previewScale = min(900 / max(layout.size.width, 1), 2)
        preview = CollageRenderer.render(
            previews, layout: layout, fitting: fitting, cornerRadius: cornerRadius, background: background.color, scale: previewScale
        )
    }

    /// The collage at full size, made off the main actor.
    func render() async -> CGImage? {
        isRendering = true
        defer { isRendering = false }
        let pictures = pictures, layout = layout, fitting = fitting, radius = cornerRadius, color = background.color, scale = scale
        return await Task.detached(priority: .userInitiated) {
            CollageRenderer.render(pictures, layout: layout, fitting: fitting, cornerRadius: radius, background: color, scale: scale)
        }.value
    }

    private static func thumbnail(of image: CGImage, longest: Int) -> CGImage? {
        let longestSide = max(image.width, image.height)
        guard longestSide > longest else { return image }
        let factor = CGFloat(longest) / CGFloat(longestSide)
        let width = max(1, Int(CGFloat(image.width) * factor)), height = max(1, Int(CGFloat(image.height) * factor))
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }
}

struct CollageView: View {
    @Bindable var model: CollageModel
    let combine: () -> Void
    let cancel: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            previewArea
            Divider()
            controls
                .frame(width: 320)
        }
        .task(id: PreviewKey(model)) { model.updatePreview() }
    }

    private var previewArea: some View {
        ZStack {
            Color(nsColor: .underPageBackgroundColor)
            if let preview = model.preview {
                Image(decorative: preview, scale: 1)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .background(Checkerboard().opacity(model.background == .clear ? 1 : 0))
                    .shadow(color: .black.opacity(0.18), radius: 10, y: 3)
                    .padding(28)
                    .accessibilityLabel(Text("Collage preview", bundle: .module))
            }
        }
    }

    private var controls: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    Picker(selection: $model.arrangement) {
                        ForEach(CollageLayout.Arrangement.allCases) { arrangement in
                            Text(title(of: arrangement)).tag(arrangement)
                        }
                    } label: {
                        Text("Arrangement", bundle: .module)
                    }
                    Picker(selection: $model.fitting) {
                        Text("Whole Pictures", bundle: .module).tag(CollageLayout.Fitting.fit)
                        Text("Fill the Cells", bundle: .module).tag(CollageLayout.Fitting.fill)
                    } label: {
                        Text("Pictures", bundle: .module)
                    }
                    .disabled(!model.fittingMatters)
                } footer: {
                    Text("In the order History shows them.", bundle: .module)
                        .foregroundStyle(.secondary)
                }
                Section {
                    slider(Text("Width", bundle: .module), value: $model.width, in: CollageModel.widthRange, step: 50)
                    slider(Text("Spacing", bundle: .module), value: $model.spacing, in: 0...64, step: 2)
                    slider(Text("Margin", bundle: .module), value: $model.margin, in: 0...96, step: 2)
                    slider(Text("Corners", bundle: .module), value: $model.cornerRadius, in: 0...32, step: 1)
                }
                Section {
                    LabeledContent {
                        HStack(spacing: 8) {
                            ForEach(CollageBackground.allCases) { background in
                                swatch(background)
                            }
                        }
                    } label: {
                        Text("Background", bundle: .module)
                    }
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                Text(sizeDescription)
                    .font(.callout)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize()
                Spacer()
                Button(role: .cancel, action: cancel) { Text("Cancel", bundle: .module) }
                    .keyboardShortcut(.cancelAction)
                Button(action: combine) { Text("Combine", bundle: .module) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.isRendering)
            }
            .padding(14)
        }
    }

    private var sizeDescription: String {
        let size = model.pixelSize
        return String(localized: "\(Int(size.width)) × \(Int(size.height)) pixels", bundle: .module)
    }

    /// A slider in steps of `step`, rounded as it moves: a stepped slider would draw a tick at every step.
    private func slider(_ label: Text, value: Binding<CGFloat>, in range: ClosedRange<CGFloat>, step: CGFloat) -> some View {
        let stepped = Binding<CGFloat>(
            get: { value.wrappedValue },
            set: { value.wrappedValue = min(max(($0 / step).rounded() * step, range.lowerBound), range.upperBound) }
        )
        return LabeledContent {
            HStack(spacing: 8) {
                Slider(value: stepped, in: range) { label }
                    .labelsHidden()
                Text(String(localized: "\(Int(value.wrappedValue)) pt", bundle: .module))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 58, alignment: .trailing)
            }
        } label: {
            label
        }
    }

    private func swatch(_ background: CollageBackground) -> some View {
        let selected = model.background == background
        return Button {
            model.background = background
        } label: {
            ZStack {
                if let color = background.color {
                    Circle().fill(Color(cgColor: color))
                } else {
                    Checkerboard().clipShape(Circle())
                }
                Circle().strokeBorder(.primary.opacity(0.18), lineWidth: 1)
            }
            .frame(width: 22, height: 22)
            .padding(3)
            .overlay { Circle().strokeBorder(Color.accentColor, lineWidth: selected ? 2 : 0) }
        }
        .buttonStyle(.plain)
        .help(background.title)
        .accessibilityLabel(background.title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func title(of arrangement: CollageLayout.Arrangement) -> String {
        switch arrangement {
        case .row: String(localized: "Side by Side", bundle: .module)
        case .column: String(localized: "One Under Another", bundle: .module)
        case .grid: String(localized: "Grid", bundle: .module)
        case .featured: String(localized: "One Beside the Rest", bundle: .module)
        }
    }

}

/// What the preview is drawn from: it is drawn again when any of it changes.
private struct PreviewKey: Equatable {
    var options: CollageLayout.Options
    var cornerRadius: CGFloat
    var background: CollageBackground

    @MainActor init(_ model: CollageModel) {
        options = model.options
        cornerRadius = model.cornerRadius
        background = model.background
    }
}

/// Gray and white squares, where a clear background shows through.
private struct Checkerboard: View {
    var body: some View {
        Canvas { context, size in
            let side: CGFloat = 8
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.white))
            for row in 0..<Int((size.height / side).rounded(.up)) {
                for column in 0..<Int((size.width / side).rounded(.up)) where (row + column).isMultiple(of: 2) {
                    context.fill(Path(CGRect(x: CGFloat(column) * side, y: CGFloat(row) * side, width: side, height: side)), with: .color(Color(white: 0.88)))
                }
            }
        }
        .accessibilityHidden(true)
    }
}
