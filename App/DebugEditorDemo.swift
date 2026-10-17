#if DEBUG
import AppKit
import CoreImage
import Foundation
import OMSAnnotate
import OMSCore
import OSLog

/// The annotation editor on the drawn demo page (never the screen), with a mark of every kind, for
/// scripted screenshots. Its edits go to a file in the debug snapshot folder, never to the history.
@MainActor
enum DebugEditorDemo {
    private static var editor: AnnotationEditorWindowController?

    /// The demo editor's window, while it is open.
    static var window: NSWindow? { editor?.window }

    /// - Parameters:
    ///   - marks: whether to start with the sample marks.
    ///   - spot: adds a spotlight over the QR code.
    ///   - hidden: behind the wallpaper, the app left inactive.
    static func open(marks: Bool, spot: Bool, tool: AnnotationTool?, select: Int?, editText: Int?, actualSize: Bool, hidden: Bool = false, dark: Bool = false) {
        editor?.close()
        guard let page = DebugPanelDemo.image(), let image = dark ? inverted(page) : page else { return }
        let file = DebugHooks.snapshotDirectory.appending(path: "editor-demo.png")
        try? FileManager.default.createDirectory(at: DebugHooks.snapshotDirectory, withIntermediateDirectories: true)
        var document = AnnotationDocument(pixelSize: CGSize(width: image.width, height: image.height), scale: 2)
        if marks { document.items = sampleMarks(spot: spot) }
        let controller = AnnotationEditorWindowController(
            image: image, scale: 2, document: document, title: "Annotate Demo", fileURL: file,
            actions: .init(
                keep: { document, png, _ in
                    try? png.write(to: file, options: .atomic)
                    Log.app.notice("debug.editor-demo kept \(document.items.count, privacy: .public) mark(s), \(png.count, privacy: .public) bytes")
                    return file
                },
                save: { file in
                    Log.app.notice("debug.editor-demo save \(file.lastPathComponent, privacy: .public)")
                    return file
                }
            )
        )
        controller.onClose = {
            Task { @MainActor in
                editor = nil
                MemoryRelief.endEventWait()
            }
        }
        editor = controller
        if hidden { controller.showBehindWallpaper() } else { controller.show() }
        Task {
            // After the window has laid out, so the selection's capsule finds its place.
            try? await Task.sleep(for: .milliseconds(300))
            controller.preview(tool: tool, select: select, editText: editText, actualSize: actualSize)
            Log.app.notice("debug.editor-demo open, \(controller.session.document.items.count, privacy: .public) mark(s)")
        }
    }

    /// Acts on the open demo editor: drag=x1,y1,x2,y2 (capture pixels) with tool=, shift=1, option=1,
    /// cmd=1, clicks=2; key=<characters>&code=<key code>[&cmd=1|&shift=1]; type=<text> into the text being
    /// edited. Logs a summary afterwards.
    static func act(on other: AnnotationEditorWindowController?, _ value: (String) -> String?) {
        guard let editor = editor ?? other else {
            Log.app.error("debug.editor-act: no editor open")
            return
        }
        if let tool = value("tool").flatMap(AnnotationTool.init(rawValue:)) { editor.session.tool = tool }
        if let drag = value("drag")?.split(separator: ",").compactMap({ Double($0) }), drag.count == 4 {
            var modifiers: NSEvent.ModifierFlags = []
            if value("shift") == "1" { modifiers.insert(.shift) }
            if value("option") == "1" { modifiers.insert(.option) }
            // cmd=1 with a drag holds ⌘ through it (a highlighter drawing freely).
            if value("cmd") == "1" { modifiers.insert(.command) }
            editor.simulateDrag(
                from: CGPoint(x: drag[0], y: drag[1]), to: CGPoint(x: drag[2], y: drag[3]),
                modifiers: modifiers, clickCount: value("clicks").flatMap(Int.init) ?? 1
            )
        }
        if let key = value("key") {
            var modifiers: NSEvent.ModifierFlags = []
            if value("cmd") == "1" { modifiers.insert(.command) }
            if value("shift") == "1", value("drag") == nil { modifiers.insert(.shift) }
            editor.simulateKey(key, keyCode: value("code").flatMap(UInt16.init) ?? 0, modifiers: modifiers)
        }
        if let numbering = value("numbering").flatMap(Counter.Numbering.init(rawValue:)) {
            // As the capsule's numbering chips do.
            editor.session.changeSettings("Numbering") { $0.numbering = numbering }
        }
        // The background: backdrop=none|clear|blur|<gradient>|color:RRGGBB|picture:<path>, then
        // padding=, inset=, corners=, shadow= (numbers), balanced=0|1, ratio=auto|W:H, align=<alignment>.
        if let fill = value("backdrop") {
            if fill == "none" {
                editor.session.setBackdrop(nil, actionName: "Remove Background")
            } else if let parsed = backdropFill(fill) {
                editor.session.changeBackdrop("Background") { $0.fill = parsed }
            }
        }
        func number(_ name: String) -> CGFloat? { value(name).flatMap(Double.init).map { CGFloat($0) } }
        if let padding = number("padding") { editor.session.changeBackdrop("Padding") { $0.padding = padding } }
        if let inset = number("inset") { editor.session.changeBackdrop("Inset") { $0.inset = inset } }
        if let corners = number("corners") { editor.session.changeBackdrop("Corners") { $0.cornerRadius = corners } }
        if let shadow = number("shadow") { editor.session.changeBackdrop("Shadow") { $0.shadow = shadow } }
        if let balanced = value("balanced") { editor.session.changeBackdrop("Auto Balance") { $0.balanced = balanced == "1" } }
        if let ratio = value("ratio") {
            let parts = ratio.split(separator: ":").compactMap { Int($0) }
            editor.session.changeBackdrop("Picture Shape") { $0.ratio = parts.count == 2 ? Backdrop.Ratio(parts[0], parts[1]) : nil }
        }
        if let align = value("align").flatMap(Backdrop.Alignment.init(rawValue:)) {
            editor.session.changeBackdrop("Position") { $0.alignment = align }
        }
        if value("adjust") == "1" {
            editor.showBackdropAdjustments()
        }
        // preset=<name> saves the background as a preset; automatic=<name>|none sets the one every new
        // screenshot gets (put it back to none afterwards).
        if let name = value("preset"), let backdrop = editor.session.document.backdrop {
            BackdropPresets.shared.add(name: name, backdrop: backdrop)
        }
        if let automatic = value("automatic") {
            BackdropPresets.shared.setAutomatic(BackdropPresets.shared.all.last { $0.name == automatic }?.id)
            Log.app.notice("debug.editor-act automatic=\(BackdropPresets.shared.automatic?.name ?? "none", privacy: .public) presets=\(BackdropPresets.shared.all.count, privacy: .public)")
        }
        if let name = value("deletepreset") {
            BackdropPresets.shared.all.filter { $0.name == name }.forEach { BackdropPresets.shared.remove($0.id) }
        }
        // addimage=<path>[&at=x,y] combines a picture file as a drop does; pasteimage=<path> pastes it as
        // PNG data from a private pasteboard, never the clipboard.
        if let path = value("addimage") {
            let at = value("at")?.split(separator: ",").compactMap { Double($0) } ?? []
            let point = at.count == 2 ? CGPoint(x: at[0], y: at[1]) : CGPoint(x: editor.session.document.canvas.maxX, y: editor.session.document.canvas.midY)
            editor.simulateDrop([URL(filePath: path)], at: point)
        }
        if let target = value("droptarget") {
            editor.simulateDropTarget(target == "1")
        }
        if let path = value("pasteimage"), let data = try? Data(contentsOf: URL(filePath: path)) {
            let pasteboard = NSPasteboard(name: NSPasteboard.Name("io.github.fzlzjerry.ohmyshot.debug.\(UUID().uuidString)"))
            pasteboard.clearContents()
            pasteboard.setData(data, forType: .png)
            editor.simulatePaste(from: pasteboard)
            pasteboard.releaseGlobally()
        }
        // saveproject=<path> writes the capture and its marks as a project, as Save as Project… does.
        if let path = value("saveproject") {
            do {
                try AnnotationProject(capture: editor.session.base, document: editor.session.document).write(to: URL(filePath: path))
                Log.app.notice("debug.editor-act saved project \(path, privacy: .public)")
            } catch {
                Log.app.error("debug.editor-act project failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        if let steps = value("zoomin").flatMap(Int.init) {
            editor.simulateZoomIn(steps)
        }
        if let undo = value("undo") {
            editor.simulateUndo(redo: undo == "redo")
        }
        if value("crop") == "apply" {
            editor.simulateKey("\r", keyCode: 36)
        }
        if let text = value("type") {
            (editor.window?.firstResponder as? NSTextView)?.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
        }
        // redactall=1 covers every redaction suggestion, as the capsule's Redact All does.
        if value("redactall") == "1" {
            editor.session.acceptAllRedactionSuggestions()
        }
        Log.app.notice("debug.editor-act \(editor.debugSummary, privacy: .public)")
        if value("chain") == "1" {
            Log.app.notice("debug.editor-chain \(editor.debugUndoChain, privacy: .public)")
        }
    }

    /// The page with its shades turned over: white text on black, for how marks read on dark content.
    private static func inverted(_ image: CGImage) -> CGImage? {
        let filter = CIFilter(name: "CIColorInvert")
        filter?.setValue(CIImage(cgImage: image), forKey: kCIInputImageKey)
        guard let output = filter?.outputImage else { return nil }
        return CIContext().createCGImage(output, from: output.extent, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
    }

    private static func backdropFill(_ text: String) -> Backdrop.Fill? {
        if text == "clear" { return .clear }
        if text == "blur" { return .blur }
        if let gradient = BackdropGradient(rawValue: text) { return .gradient(gradient) }
        if text.hasPrefix("color:"), let value = UInt32(text.dropFirst(6), radix: 16) {
            return .color(RGBA(red: Double((value >> 16) & 0xFF) / 255, green: Double((value >> 8) & 0xFF) / 255, blue: Double(value & 0xFF) / 255))
        }
        if text.hasPrefix("picture:"), let name = try? PictureStore.shared.add(URL(filePath: String(text.dropFirst(8)))) {
            return .picture(name)
        }
        return nil
    }

    /// A mark of every kind, placed on the demo page's parts (in its pixels, at 2×).
    private static func sampleMarks(spot: Bool) -> [Annotation] {
        var marks: [Annotation] = [
            Annotation(shape: .highlighter(Stroke(points: [CGPoint(x: 84, y: 318), CGPoint(x: 880, y: 318)])), style: Style(color: .marker, lineWidth: 18, shadow: false)),
            Annotation(shape: .rectangle(Box(rect: CGRect(x: 1064, y: 144, width: 372, height: 372), cornerRadius: 4)), style: Style(color: .red, lineWidth: 4)),
            Annotation(shape: .arrow(Arrow(start: CGPoint(x: 1240, y: 760), end: CGPoint(x: 1250, y: 560), bend: -60, head: .tapered)), style: Style(color: .red, lineWidth: 6)),
            Annotation(shape: .arrow(Arrow(start: CGPoint(x: 760, y: 1010), end: CGPoint(x: 620, y: 900))), style: Style(color: .blue, lineWidth: 4)),
            Annotation(shape: .ellipse(Box(rect: CGRect(x: 430, y: 832, width: 160, height: 72))), style: Style(color: .green, lineWidth: 4)),
            Annotation(shape: .redaction(Redaction(rect: CGRect(x: 118, y: 480, width: 236, height: 40), method: .pixelate)), style: Style(color: .black, shadow: false)),
            Annotation(shape: .text(TextBlock(origin: CGPoint(x: 1010, y: 800), string: "可以直接拖出 ✨", fontSize: 18, look: .label)), style: Style(color: .red)),
            Annotation(shape: .text(TextBlock(origin: CGPoint(x: 1010, y: 900), string: "Outlined text", fontSize: 18, look: .outlined)), style: Style(color: .orange)),
            Annotation(shape: .counter(Counter(center: CGPoint(x: 1050, y: 1040), value: 1)), style: Style(color: .red, lineWidth: 4)),
            Annotation(shape: .counter(Counter(center: CGPoint(x: 1130, y: 1040), value: 2)), style: Style(color: .red, lineWidth: 4)),
            Annotation(shape: .counter(Counter(center: CGPoint(x: 1210, y: 1040), value: 3, numbering: .letters)), style: Style(color: .purple, lineWidth: 4)),
            Annotation(shape: .pen(Stroke(points: [
                CGPoint(x: 900, y: 940), CGPoint(x: 915, y: 958), CGPoint(x: 930, y: 972), CGPoint(x: 950, y: 948),
                CGPoint(x: 975, y: 915), CGPoint(x: 1000, y: 884),
            ])), style: Style(color: .green, lineWidth: 3)),
            Annotation(shape: .line(Line(start: CGPoint(x: 80, y: 660), end: CGPoint(x: 900, y: 660), dashed: true)), style: Style(color: .purple, lineWidth: 2)),
        ]
        if spot {
            marks.append(Annotation(shape: .spotlight(Spot(rect: CGRect(x: 1060, y: 140, width: 380, height: 380), oval: false)), style: Style(shadow: false)))
        }
        return marks
    }
}
#endif
