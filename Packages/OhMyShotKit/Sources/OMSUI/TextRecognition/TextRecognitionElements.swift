import OMSCore
import OMSDesign
import OMSOCR
import SwiftUI

/// A recognized table as a grid, the first row as its header, figures right-aligned.
/// Double-clicking any cell edits its text inline.
struct TablePreview: View {
    private struct CellID: Hashable {
        let row: Int
        let column: Int
    }

    @Bindable var model: TextRecognitionModel
    let table: OCRTable
    @State private var editingCell: CellID?
    @State private var draftText = ""
    @FocusState private var cellFocused: Bool
    @Environment(\.displayScale) private var displayScale
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if model.tables.count > 1 {
                Picker(selection: $model.tableIndex) {
                    ForEach(model.tables.indices, id: \.self) { index in
                        Text("Table \(index + 1)", bundle: .module).tag(index)
                    }
                } label: {
                    Text("Table", bundle: .module)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            ScrollView([.horizontal, .vertical]) {
                let width = table.rows.map(\.count).max() ?? 0
                let figures = (0..<width).map { Self.holdsFigures(table, column: $0) }
                let hairline = 1 / max(displayScale, 1)
                let separator = Color(nsColor: .separatorColor)
                let shape = RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                    ForEach(Array(table.rows.enumerated()), id: \.offset) { row, cells in
                        GridRow {
                            ForEach(0..<width, id: \.self) { column in
                                let cellID = CellID(row: row, column: column)
                                let value = column < cells.count ? cells[column] : ""
                                cellView(
                                    cellID: cellID,
                                    value: value,
                                    isHeader: row == 0,
                                    isFigures: figures[column],
                                    hairline: hairline,
                                    separator: separator,
                                    isLastColumn: column == width - 1,
                                    isLastRow: row == table.rows.count - 1
                                )
                            }
                        }
                    }
                }
                .clipShape(shape)
                .overlay { shape.strokeBorder(separator, lineWidth: hairline) }
                .padding(1)
            }
            HStack(spacing: 8) {
                Button { commitEdit(); model.copyTable(as: .markdown) } label: { Text("Copy as Markdown", bundle: .module) }
                Button { commitEdit(); model.copyTable(as: .tsv) } label: { Text("Copy TSV", bundle: .module) }
                Button { commitEdit(); model.copyTable(as: .csv) } label: { Text("Copy as CSV", bundle: .module) }
                Button { commitEdit(); model.exportTableCSV() } label: { Text("Export CSV…", bundle: .module) }
            }
            .controlSize(.small)
            .layoutPriority(1)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onChange(of: model.tableIndex) { _, _ in
            commitEdit()
        }
        .onChange(of: cellFocused) { _, focused in
            if !focused { commitEdit() }
        }
    }

    @ViewBuilder
    private func cellView(
        cellID: CellID,
        value: String,
        isHeader: Bool,
        isFigures: Bool,
        hairline: CGFloat,
        separator: Color,
        isLastColumn: Bool,
        isLastRow: Bool
    ) -> some View {
        let isEditing = editingCell == cellID
        Group {
            if isEditing {
                TextField(text: $draftText) { EmptyView() }
                    .textFieldStyle(.plain)
                    .font(isHeader ? .body.weight(.semibold) : .body)
                    .monospacedDigit()
                    .multilineTextAlignment(isFigures ? .trailing : .leading)
                    .focused($cellFocused)
                    .onSubmit { commitEdit() }
                    .onExitCommand { cancelEdit() }
                    .frame(maxWidth: 260, alignment: isFigures ? .trailing : .leading)
                    .accessibilityLabel(Text("Edit cell", bundle: .module))
            } else {
                Text(verbatim: value)
                    .font(isHeader ? .body.weight(.semibold) : .body)
                    .monospacedDigit()
                    .textSelection(.enabled)
                    .multilineTextAlignment(isFigures ? .trailing : .leading)
                    .frame(maxWidth: 260, alignment: isFigures ? .trailing : .leading)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        // Every cell fills its column, so the rules line up from row to row.
        .frame(minWidth: 56, maxWidth: .infinity, maxHeight: .infinity, alignment: isFigures ? .topTrailing : .topLeading)
        .background(isHeader ? (colorScheme == .dark ? Color.white : Color.black).opacity(Theme.ChipFill.hover(dark: colorScheme == .dark)) : Color.clear)
        .overlay {
            if isEditing {
                Rectangle().strokeBorder(Color.accentColor, lineWidth: 1.5)
            }
        }
        .overlay(alignment: .trailing) {
            if !isLastColumn { separator.frame(width: hairline) }
        }
        .overlay(alignment: .bottom) {
            if !isLastRow { separator.frame(height: hairline) }
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            beginEdit(cellID, currentValue: value)
        }
        .help(isEditing ? Text(verbatim: "") : Text("Double-click to edit", bundle: .module))
    }

    private func beginEdit(_ cellID: CellID, currentValue: String) {
        if editingCell != nil, editingCell != cellID {
            commitEdit()
        }
        editingCell = cellID
        draftText = currentValue
        cellFocused = true
    }

    private func commitEdit() {
        guard let editingCell else { return }
        let updated = draftText
        self.editingCell = nil
        model.updateTableCell(row: editingCell.row, column: editingCell.column, value: updated)
    }

    private func cancelEdit() {
        editingCell = nil
        draftText = ""
    }

    /// A column of figures (`TableTabStops.holdsFigures`).
    static func holdsFigures(_ table: OCRTable, column: Int) -> Bool {
        TableTabStops.holdsFigures(table.rows, column: column)
    }
}

/// Links, contacts, dates, formulas, and codes found in the image, each one click from being used.
struct FoundList: View {
    let model: TextRecognitionModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("Found in Image", bundle: .module)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.bottom, 4)
                    .accessibilityAddTraits(.isHeader)
                ForEach(Array(model.codes.enumerated()), id: \.offset) { index, code in
                    let found = FoundCode(payload: code.payload, isMatrix: code.kind.isMatrix, box: code.box)
                    FoundRow(
                        symbol: Self.symbol(for: code, structured: found.structured),
                        kind: Self.name(of: code.kind),
                        value: found.displaySummary,
                        copyValue: found.primaryCopyValue,
                        action: model.action(for: code),
                        model: model,
                        onHover: { inside in
                            if inside { model.hoveredCode = index } else if model.hoveredCode == index { model.hoveredCode = nil }
                        }
                    )
                }
                ForEach(Array(model.formulas.enumerated()), id: \.offset) { _, formula in
                    let formatted = model.formulaDelimiter().wrap(formula.latex)
                    FoundRow(
                        symbol: "function",
                        kind: Text("Formula", bundle: .module),
                        value: formatted,
                        copyValue: formatted,
                        action: nil,
                        model: model
                    )
                }
                ForEach(Array(model.items.enumerated()), id: \.offset) { _, item in
                    FoundRow(symbol: Self.symbol(for: item.kind), kind: Self.kind(item.kind), value: item.text, action: model.action(for: item), model: model)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 10)
        }
        .frame(maxHeight: 176)
        .fixedSize(horizontal: false, vertical: true)
    }

    static func symbol(for code: OCRCode, structured: FoundCode.StructuredPayload?) -> String {
        switch structured {
        case .wifi: "wifi"
        case .mailto: "envelope"
        case .phone: "phone"
        case .contact: "person.crop.rectangle"
        case .web, nil: code.kind.isMatrix ? "qrcode" : "barcode"
        }
    }

    static func name(of kind: OCRCode.Kind) -> Text {
        switch kind {
        case .qr: Text("QR Code", bundle: .module)
        case .aztec: Text(verbatim: "Aztec")
        case .dataMatrix: Text(verbatim: "Data Matrix")
        case .pdf417: Text(verbatim: "PDF417")
        case .ean13: Text(verbatim: "EAN-13")
        case .ean8: Text(verbatim: "EAN-8")
        case .upce: Text(verbatim: "UPC-E")
        case .code128: Text(verbatim: "Code 128")
        case .code39: Text(verbatim: "Code 39")
        case .other: Text("Barcode", bundle: .module)
        }
    }

    static func symbol(for kind: DetectedItem.Kind) -> String {
        switch kind {
        case .link: "link"
        case .email: "envelope"
        case .phone: "phone"
        case .date: "calendar"
        case .address: "mappin.and.ellipse"
        }
    }

    static func kind(_ kind: DetectedItem.Kind) -> Text {
        switch kind {
        case .link: Text("Link", bundle: .module)
        case .email: Text("Email", bundle: .module)
        case .phone: Text("Phone", bundle: .module)
        case .date: Text("Date", bundle: .module)
        case .address: Text("Address", bundle: .module)
        }
    }
}

/// One found item: what it is shown by its symbol, the value, and quiet buttons for its verb and Copy.
/// VoiceOver hears one element, kind and value, with both verbs as actions.
struct FoundRow: View {
    let symbol: String
    let kind: Text
    let value: String
    var copyValue: String? = nil
    let action: TextRecognitionModel.Action?
    let model: TextRecognitionModel
    var onHover: (Bool) -> Void = { _ in }
    @State private var hovering = false
    @State private var copied = false
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .foregroundStyle(.secondary)
                .frame(width: 18)
                .help(kind)
            Text(verbatim: value)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
            Spacer(minLength: 8)
            if let action {
                Button(action: action.perform) {
                    Image(systemName: action.symbol)
                }
                .help(action.title)
            }
            Button(action: copy) {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
            }
            .help(Text("Copy", bundle: .module))
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.primary)
        .padding(.horizontal, 8)
        .frame(minHeight: 28)
        .background {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(hovering ? (colorScheme == .dark ? Color.white : Color.black).opacity(Theme.ChipFill.hover(dark: colorScheme == .dark)) : Color.clear)
        }
        .onHover { inside in
            hovering = inside
            onHover(inside)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(kind)
        .accessibilityValue(Text(verbatim: value))
        .accessibilityAction { action?.perform() ?? copy() }
        .accessibilityActions {
            if let action {
                Button(action: action.perform) { action.title }
            }
            Button(action: copy) { Text("Copy", bundle: .module) }
        }
    }

    private func copy() {
        model.copy(copyValue ?? value)
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(1.2))
            copied = false
        }
    }
}
