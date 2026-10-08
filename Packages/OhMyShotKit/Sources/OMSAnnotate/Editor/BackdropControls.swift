import AppKit
import OMSCore
import SwiftUI

/// A background saved under a name, to set again in one click or on every new screenshot.
nonisolated public struct BackdropPreset: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var name: String
    public var backdrop: Backdrop

    public init(id: UUID = UUID(), name: String, backdrop: Backdrop) {
        self.id = id
        self.name = name
        self.backdrop = backdrop
    }
}

/// The saved backgrounds, and the one set on every new screenshot, if any. Kept in the user defaults;
/// a preset's picture stays in the backgrounds folder.
@MainActor
public final class BackdropPresets {
    public static let shared = BackdropPresets()

    public private(set) var all: [BackdropPreset]
    /// Called after any change.
    public var onChange: (() -> Void)?

    private let defaults: UserDefaults
    private static let presetsKey = "annotation.backdropPresets"
    private static let automaticKey = "annotation.backdropAutomatic"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        all = defaults.data(forKey: Self.presetsKey).flatMap { try? JSONDecoder().decode([BackdropPreset].self, from: $0) } ?? []
    }

    /// The preset set on every new screenshot.
    public var automatic: BackdropPreset? {
        guard let id = defaults.string(forKey: Self.automaticKey).flatMap(UUID.init(uuidString:)) else { return nil }
        return all.first { $0.id == id }
    }

    public func setAutomatic(_ id: UUID?) {
        defaults.set(id?.uuidString, forKey: Self.automaticKey)
        onChange?()
    }

    @discardableResult
    public func add(name: String, backdrop: Backdrop) -> BackdropPreset {
        let preset = BackdropPreset(name: name, backdrop: backdrop)
        all.append(preset)
        save()
        return preset
    }

    public func remove(_ id: UUID) {
        all.removeAll { $0.id == id }
        if automatic == nil { defaults.removeObject(forKey: Self.automaticKey) }
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(all) {
            defaults.set(data, forKey: Self.presetsKey)
        }
        onChange?()
    }
}

/// What the background's adjustments show and change: the background in the session, or the last
/// one set while there is none.
@MainActor
@Observable
final class BackdropAdjustments {
    private(set) var backdrop: Backdrop
    /// Whether the capture's edge is one color, which inset and balance need.
    private(set) var hasEvenEdge: Bool
    @ObservationIgnored private let session: AnnotationSession
    /// The slider being dragged: its changes make one undo step.
    @ObservationIgnored private var dragging: String?

    init(session: AnnotationSession) {
        self.session = session
        backdrop = session.document.backdrop ?? session.lastBackdrop
        hasEvenEdge = session.edges.opaque && session.edges.edgeColor != nil
    }

    /// After the session changed some other way, such as Undo.
    func refresh() {
        let current = session.document.backdrop ?? session.lastBackdrop
        if current != backdrop { backdrop = current }
        let even = session.edges.opaque && session.edges.edgeColor != nil
        if even != hasEvenEdge { hasEvenEdge = even }
    }

    func set(_ name: String, _ change: (inout Backdrop) -> Void) {
        session.changeBackdrop(name, change)
        backdrop = session.document.backdrop ?? session.lastBackdrop
    }

    func dragChanged(_ name: String, editing: Bool) {
        if editing {
            guard dragging == nil else { return }
            dragging = name
            session.beginLiveChange()
        } else {
            guard let name = dragging else { return }
            dragging = nil
            session.endLiveChange(actionName: name)
        }
    }

    /// Ends a drag the popover closed in the middle of.
    func finish() {
        dragChanged(dragging ?? "", editing: false)
    }
}

/// The background's adjustments: room, corners, shadow, and the picture's shape.
struct BackdropAdjustView: View {
    @Bindable var model: BackdropAdjustments

    var body: some View {
        Form {
            Section {
                slider(String(localized: "Padding", bundle: .module), \.padding, in: Backdrop.paddingRange, reading: percent)
                slider(String(localized: "Inset", bundle: .module), \.inset, in: Backdrop.insetRange, reading: percent)
                    .disabled(!model.hasEvenEdge)
                Toggle(isOn: Binding(
                    get: { model.backdrop.balanced },
                    set: { value in model.set(String(localized: "Auto Balance", bundle: .module)) { $0.balanced = value } }
                )) {
                    Text("Auto Balance", bundle: .module)
                    Text("Evens out the room around what the capture shows.", bundle: .module)
                }
                .disabled(!model.hasEvenEdge)
            } footer: {
                if !model.hasEvenEdge {
                    Text("Inset and Auto Balance need a capture whose edge is one color.", bundle: .module)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            Section {
                slider(String(localized: "Corners", bundle: .module), \.cornerRadius, in: Backdrop.cornerRadiusRange) { "\(Int($0.rounded())) pt" }
                slider(String(localized: "Shadow", bundle: .module), \.shadow, in: Backdrop.shadowRange, reading: percent)
            }
            Section {
                Picker(selection: Binding(
                    get: { model.backdrop.ratio },
                    set: { value in model.set(String(localized: "Picture Shape", bundle: .module)) { $0.ratio = value } }
                )) {
                    Text("Automatic", bundle: .module).tag(Backdrop.Ratio?.none)
                    Divider()
                    ForEach(Backdrop.Ratio.presets, id: \.self) { ratio in
                        Text(verbatim: "\(ratio.width):\(ratio.height)").monospacedDigit().tag(Optional(ratio))
                    }
                } label: {
                    Text("Shape", bundle: .module)
                }
                LabeledContent {
                    AlignmentGrid(selection: Binding(
                        get: { model.backdrop.alignment },
                        set: { value in model.set(String(localized: "Position", bundle: .module)) { $0.alignment = value } }
                    ))
                } label: {
                    // Dimmed with its grid while the shape is automatic and leaves no room to place.
                    Group {
                        Text("Position", bundle: .module)
                        Text("Where the capture sits when the shape leaves room.", bundle: .module)
                    }
                    .foregroundStyle(model.backdrop.ratio == nil ? .tertiary : .primary)
                }
                .disabled(model.backdrop.ratio == nil)
            }
        }
        .formStyle(.grouped)
        // Opaque under the text: the popover's glass is its rim, never what the capture shows through.
        .scrollContentBackground(.hidden)
        .background(Color(nsColor: .windowBackgroundColor))
        .frame(width: 320)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func percent(_ value: CGFloat) -> String {
        "\(Int((value * 100).rounded()))%"
    }

    private func slider(_ name: String, _ path: WritableKeyPath<Backdrop, CGFloat>, in range: ClosedRange<CGFloat>, reading: @escaping (CGFloat) -> String) -> some View {
        LabeledContent {
            HStack(spacing: 8) {
                Slider(
                    value: Binding(get: { model.backdrop[keyPath: path] }, set: { value in model.set(name) { $0[keyPath: path] = value } }),
                    in: range
                ) { editing in
                    model.dragChanged(name, editing: editing)
                }
                .labelsHidden()
                // VoiceOver hears the slider by name with its reading, and can still step it.
                .accessibilityLabel(Text(name))
                .accessibilityValue(Text(verbatim: reading(model.backdrop[keyPath: path])))
                Text(verbatim: reading(model.backdrop[keyPath: path]))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 40, alignment: .trailing)
                    .accessibilityHidden(true)
            }
        } label: {
            Text(name)
        }
    }
}

/// Nine places to put the capture: a 3 × 3 grid of small squares, the chosen one in the accent.
struct AlignmentGrid: View {
    @Binding var selection: Backdrop.Alignment
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Grid(horizontalSpacing: 3, verticalSpacing: 3) {
            ForEach(0..<3, id: \.self) { row in
                GridRow {
                    ForEach(0..<3, id: \.self) { column in
                        let place = Backdrop.Alignment.allCases[row * 3 + column]
                        Button {
                            selection = place
                        } label: {
                            RoundedRectangle(cornerRadius: 3, style: .continuous)
                                .fill(place == selection && isEnabled ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary))
                                .frame(width: 16, height: 12)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(Self.name(of: place))
                        .accessibilityAddTraits(place == selection ? .isSelected : [])
                    }
                }
            }
        }
    }

    static func name(of place: Backdrop.Alignment) -> Text {
        switch place {
        case .topLeft: Text("Top Left", bundle: .module)
        case .top: Text("Top", bundle: .module)
        case .topRight: Text("Top Right", bundle: .module)
        case .left: Text("Left", bundle: .module)
        case .center: Text("Center", bundle: .module)
        case .right: Text("Right", bundle: .module)
        case .bottomLeft: Text("Bottom Left", bundle: .module)
        case .bottom: Text("Bottom", bundle: .module)
        case .bottomRight: Text("Bottom Right", bundle: .module)
        }
    }
}
