import AppKit
import OMSCore
import SwiftUI
import UniformTypeIdentifiers

/// The editor's working area: the canvas filling it, the tool rail standing at its left edge, and the
/// style capsule beside the selected mark, or at the rail's foot for the next mark.
final class EditorContentView: NSView, NSPopoverDelegate {
    let session: AnnotationSession
    let canvas: AnnotationCanvasView
    /// After the picture moves or zooms.
    var onViewportChange: (() -> Void)?
    private let rail = ToolRail()
    private let capsule = StyleCapsule()
    /// The open suggestions Redact All counted when the capsule was last shown.
    private var shownSuggestions = 0
    /// What the capsule was last placed for, so a new selection fades it in while a zoom just moves it.
    private var capsuleAnchor: [Annotation.ID]?
    /// The background's adjustments, while their popover is open.
    private var adjustments: BackdropAdjustments?
    private weak var adjustPopover: NSPopover?

    /// The picture last chosen for a background, offered again.
    private static let lastPictureKey = "annotation.backdropPicture"

    private static let railInset: CGFloat = 12
    /// The band along the bottom where the capsule rests when nothing is selected.
    private static let foot: CGFloat = 12 + StyleCapsule.height + 12

    init(session: AnnotationSession) {
        self.session = session
        canvas = AnnotationCanvasView(session: session)
        super.init(frame: .zero)
        canvas.contentInsets = NSEdgeInsets(top: 24, left: Self.railInset + ToolRail.width + 18, bottom: Self.foot, right: 28)
        addSubview(canvas)
        addSubview(rail)
        addSubview(capsule)
        capsule.alphaValue = 0

        rail.select(session.tool)
        rail.onSelect = { [weak self] tool in self?.choose(tool) }
        capsule.onChange = { [weak self] name, change in
            guard let self else { return }
            session.changeSettings(name, change)
            canvas.refreshEditingStyle()
        }
        capsule.onDelete = { [weak self] in self?.session.deleteSelection() }
        capsule.onRedactAll = { [weak self] in self?.session.acceptAllRedactionSuggestions() }
        capsule.onCropReset = { [weak self] in self?.canvas.resetCrop() }
        capsule.onCropDone = { [weak self] in
            guard let self else { return }
            canvas.commitCrop()
            session.leavePictureMode()
        }
        capsule.onBackdropFill = { [weak self] fill in self?.setFill(fill) }
        capsule.onBackdropChoosePicture = { [weak self] in self?.choosePicture() }
        capsule.onBackdropAdjust = { [weak self] chip in self?.showAdjustments(from: chip) }
        capsule.onBackdropPresets = { [weak self] chip in self?.showPresets(from: chip) }
        canvas.onViewportChange = { [weak self] in
            self?.placeCapsule()
            self?.onViewportChange?()
        }
        session.observe { [weak self] event in self?.sessionChanged(event) }
        refreshCapsule()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var isFlipped: Bool { true }

    /// The shared color panel must not point at a capsule that is going away, nor a popover outlive it.
    func releaseColorPanel() {
        capsule.releaseColorPanel()
        adjustPopover?.close()
    }

    private func choose(_ tool: AnnotationTool) {
        session.tool = tool
        window?.makeFirstResponder(canvas)
    }

    private func sessionChanged(_ event: AnnotationSession.Event) {
        switch event {
        case .tool:
            rail.select(session.tool)
            if session.tool != .background { adjustPopover?.close() }
            refreshCapsule()
        case .selection, .settings:
            refreshCapsule()
        case .document:
            // The selected mark may have changed kind of settings (undo, a restyle elsewhere), or the
            // background its fill.
            if !session.selection.isEmpty || session.tool == .background || suggestionCountChanged { refreshCapsule() }
            adjustments?.refresh()
        case .history:
            break
        case .suggestions:
            if session.tool == .redact { refreshCapsule() }
        }
    }

    /// Whether Redact All's count is out of date: the capsule is rebuilt for it, not for every drag frame.
    private var suggestionCountChanged: Bool {
        session.tool == .redact && session.openRedactionSuggestions.count != shownSuggestions
    }

    private func refreshCapsule() {
        shownSuggestions = session.tool == .redact ? session.openRedactionSuggestions.count : 0
        if session.tool == .background {
            capsule.showBackground(StyleCapsule.BackgroundState(
                backdrop: session.document.backdrop,
                lastPicture: UserDefaults.standard.string(forKey: Self.lastPictureKey),
                blur: session.blurredCapture
            ))
        } else {
            capsule.show(
                kind: session.currentKind, settings: session.currentSettings, hasSelection: !session.selection.isEmpty,
                suggestions: session.tool == .redact ? session.openRedactionSuggestions.count : 0,
                finding: session.tool == .redact && session.isFindingRedactions
            )
        }
        placeCapsule()
    }

    #if DEBUG
    /// Opens the background's adjustments, as their chip does.
    func debugShowAdjustments() {
        if let chip = capsule.adjustChip { showAdjustments(from: chip) }
    }
    #endif

    // MARK: Background

    private func setFill(_ fill: Backdrop.Fill?) {
        if let fill {
            session.changeBackdrop(String(localized: "Background", bundle: .module)) { $0.fill = fill }
        } else if session.document.backdrop != nil {
            session.setBackdrop(nil, actionName: String(localized: "Remove Background", bundle: .module))
        }
    }

    /// Chooses a picture for the background, starting among the system's desktop pictures the first time.
    private func choosePicture() {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.prompt = String(localized: "Use Picture", bundle: .module)
        panel.message = String(localized: "Choose a picture to set the capture on.", bundle: .module)
        if UserDefaults.standard.string(forKey: Self.lastPictureKey) == nil {
            let pictures = URL(filePath: "/System/Library/Desktop Pictures", directoryHint: .isDirectory)
            if FileManager.default.fileExists(atPath: pictures.path(percentEncoded: false)) { panel.directoryURL = pictures }
        }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            do {
                let name = try PictureStore.shared.add(url)
                UserDefaults.standard.set(name, forKey: Self.lastPictureKey)
                setFill(.picture(name))
                // The chip offers the new picture even when the fill was a picture already.
                refreshCapsule()
            } catch {
                NSSound.beep()
            }
        }
    }

    private func showAdjustments(from chip: NSView) {
        if let adjustPopover, adjustPopover.isShown {
            adjustPopover.close()
            return
        }
        let model = BackdropAdjustments(session: session)
        let hosting = NSHostingController(rootView: BackdropAdjustView(model: model))
        hosting.sizingOptions = .preferredContentSize
        let popover = NSPopover()
        popover.contentViewController = hosting
        popover.behavior = .transient
        popover.delegate = self
        adjustments = model
        adjustPopover = popover
        // Above the chip: the capsule rests at the window's foot. Edges are in the chip's own
        // coordinates, and a button's are flipped.
        popover.show(relativeTo: chip.bounds, of: chip, preferredEdge: chip.isFlipped ? .minY : .maxY)
    }

    private func showPresets(from chip: NSView) {
        let presets = BackdropPresets.shared
        let menu = NSMenu()
        let current = session.document.backdrop
        for preset in presets.all {
            let item = NSMenuItem(title: preset.name, action: #selector(applyPreset(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = preset.id
            item.state = preset.backdrop == current ? .on : .off
            menu.addItem(item)
        }
        if !presets.all.isEmpty { menu.addItem(.separator()) }
        let save = NSMenuItem(title: String(localized: "Save as Preset…", bundle: .module), action: #selector(savePreset(_:)), keyEquivalent: "")
        save.target = self
        save.isEnabled = current != nil
        menu.addItem(save)
        if !presets.all.isEmpty {
            let delete = NSMenuItem(title: String(localized: "Delete Preset", bundle: .module), action: nil, keyEquivalent: "")
            let deleteMenu = NSMenu()
            for preset in presets.all {
                let item = NSMenuItem(title: preset.name, action: #selector(deletePreset(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = preset.id
                deleteMenu.addItem(item)
            }
            delete.submenu = deleteMenu
            menu.addItem(delete)
            menu.addItem(.separator())
            let automatic = NSMenuItem(title: String(localized: "Use for New Screenshots", bundle: .module), action: nil, keyEquivalent: "")
            let automaticMenu = NSMenu()
            let none = NSMenuItem(title: String(localized: "None", bundle: .module), action: #selector(setAutomaticPreset(_:)), keyEquivalent: "")
            none.target = self
            none.state = presets.automatic == nil ? .on : .off
            automaticMenu.addItem(none)
            automaticMenu.addItem(.separator())
            for preset in presets.all {
                let item = NSMenuItem(title: preset.name, action: #selector(setAutomaticPreset(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = preset.id
                item.state = presets.automatic?.id == preset.id ? .on : .off
                automaticMenu.addItem(item)
            }
            automatic.submenu = automaticMenu
            menu.addItem(automatic)
        }
        menu.popUp(positioning: nil, at: CGPoint(x: 0, y: chip.isFlipped ? chip.bounds.maxY + 4 : -4), in: chip)
    }

    @objc private func applyPreset(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID, let preset = BackdropPresets.shared.all.first(where: { $0.id == id }) else { return }
        session.setBackdrop(preset.backdrop, actionName: String(localized: "Background", bundle: .module))
    }

    @objc private func savePreset(_ sender: NSMenuItem) {
        guard let window, let backdrop = session.document.backdrop else { return }
        let alert = NSAlert()
        alert.messageText = String(localized: "Save Background as Preset", bundle: .module)
        alert.informativeText = String(localized: "Set it again from Presets, or on every new screenshot.", bundle: .module)
        let field = NSTextField(string: Self.suggestedName(for: backdrop))
        field.frame = CGRect(x: 0, y: 0, width: 240, height: 22)
        alert.accessoryView = field
        alert.addButton(withTitle: String(localized: "Save", bundle: .module))
        alert.addButton(withTitle: String(localized: "Cancel", bundle: .module))
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else { return }
            let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            BackdropPresets.shared.add(name: name.isEmpty ? Self.suggestedName(for: backdrop) : name, backdrop: backdrop)
        }
    }

    @objc private func deletePreset(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        BackdropPresets.shared.remove(id)
    }

    @objc private func setAutomaticPreset(_ sender: NSMenuItem) {
        BackdropPresets.shared.setAutomatic(sender.representedObject as? UUID)
    }

    /// A preset's first name: its fill's.
    private static func suggestedName(for backdrop: Backdrop) -> String {
        switch backdrop.fill {
        case .clear: String(localized: "Transparent", bundle: .module)
        case .gradient(let gradient): StyleCapsule.name(of: gradient)
        case .color: String(localized: "Color", bundle: .module)
        case .blur: String(localized: "Blurred Capture", bundle: .module)
        case .picture: String(localized: "Picture", bundle: .module)
        }
    }

    override func layout() {
        super.layout()
        canvas.frame = bounds
        let size = rail.fittingSize
        // Centered in the space above the capsule's band, never closer than the inset to the top.
        let free = bounds.height - Self.foot
        let y = max(Self.railInset, (free - size.height) / 2)
        rail.frame = CGRect(x: Self.railInset, y: y.rounded(), width: size.width, height: size.height)
        placeCapsule()
    }

    /// Beside the selection: 10 pt below it, above it without room, inside the view's bottom when it
    /// fills the view; with nothing selected, in the band at the rail's foot. Hidden while a mark is
    /// dragged, so nothing trails the pointer.
    private func placeCapsule() {
        let hasContent = !(session.currentKind == .select && session.selection.isEmpty)
        let size = capsule.fittingSize
        let visible = hasContent && !canvas.isDragging
        var frame: CGRect
        let anchorKey = session.selection
        if let selection = canvas.selectionFrame, !session.selection.isEmpty {
            let minX = rail.frame.maxX + 8
            let x = min(max(selection.midX - size.width / 2, minX), bounds.maxX - 8 - size.width)
            var y = selection.maxY + 10
            if y + size.height > bounds.maxY - 8 {
                y = selection.minY - 10 - size.height
                if y < 8 { y = bounds.maxY - 8 - size.height }
            }
            frame = CGRect(x: max(x, minX), y: y, width: size.width, height: size.height)
        } else {
            frame = CGRect(x: Self.railInset, y: bounds.maxY - 12 - size.height, width: size.width, height: size.height)
        }
        frame = frame.integral
        let anchorChanged = capsuleAnchor != anchorKey
        capsuleAnchor = anchorKey
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if !visible {
            capsule.alphaValue = 0
            capsule.frame = frame
            return
        }
        if anchorChanged || capsule.alphaValue == 0 {
            capsule.frame = frame
            if reduceMotion {
                capsule.alphaValue = 1
            } else {
                capsule.alphaValue = 0
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = Theme.Motion.fade
                    context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    capsule.animator().alphaValue = 1
                }
            }
        } else {
            capsule.frame = frame
        }
    }
}

extension EditorContentView {
    func popoverDidClose(_ notification: Notification) {
        adjustments?.finish()
        adjustments = nil
    }
}
