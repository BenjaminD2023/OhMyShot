import AppKit
import OMSCore

/// The editor's working area: the canvas filling it, the tool rail standing at its left edge, and the
/// style capsule beside the selected mark, or at the rail's foot for the next mark.
final class EditorContentView: NSView {
    let session: AnnotationSession
    let canvas: AnnotationCanvasView
    /// After the picture moves or zooms.
    var onViewportChange: (() -> Void)?
    private let rail = ToolRail()
    private let capsule = StyleCapsule()
    /// What the capsule was last placed for, so a new selection fades it in while a zoom just moves it.
    private var capsuleAnchor: [Annotation.ID]?
    private var toolBeforeCrop: AnnotationTool = .arrow

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
        capsule.onCropReset = { [weak self] in self?.canvas.resetCrop() }
        capsule.onCropDone = { [weak self] in
            guard let self else { return }
            canvas.commitCrop()
            session.tool = toolBeforeCrop
        }
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

    /// The shared color panel must not point at a capsule that is going away.
    func releaseColorPanel() {
        capsule.releaseColorPanel()
    }

    private func choose(_ tool: AnnotationTool) {
        if tool == .crop, session.tool != .crop { toolBeforeCrop = session.tool }
        session.tool = tool
        window?.makeFirstResponder(canvas)
    }

    private func sessionChanged(_ event: AnnotationSession.Event) {
        switch event {
        case .tool:
            if session.tool == .crop, toolBeforeCrop == .crop { toolBeforeCrop = .arrow }
            rail.select(session.tool)
            refreshCapsule()
        case .selection, .settings:
            refreshCapsule()
        case .document:
            // The selected mark may have changed kind of settings (undo, a restyle elsewhere).
            if !session.selection.isEmpty { refreshCapsule() }
        case .history:
            break
        }
    }

    private func refreshCapsule() {
        capsule.show(kind: session.currentKind, settings: session.currentSettings, hasSelection: !session.selection.isEmpty)
        placeCapsule()
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
