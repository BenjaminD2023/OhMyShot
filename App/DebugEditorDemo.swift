#if DEBUG
import AppKit
import Foundation
import OMSAnnotate
import OMSCore
import OSLog

/// The annotation editor on the drawn demo page (never the screen), with a mark of every kind, for
/// scripted screenshots. Its edits go to a file in the debug snapshot folder, never to the history.
@MainActor
enum DebugEditorDemo {
    private static var editor: AnnotationEditorWindowController?

    /// - Parameters:
    ///   - marks: whether to start with the sample marks.
    ///   - spot: adds a spotlight over the QR code.
    static func open(marks: Bool, spot: Bool, tool: AnnotationTool?, select: Int?, editText: Int?, actualSize: Bool) {
        editor?.close()
        guard let image = DebugPanelDemo.image() else { return }
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
            Task { @MainActor in editor = nil }
        }
        editor = controller
        controller.show()
        Task {
            // After the window has laid out, so the selection's capsule finds its place.
            try? await Task.sleep(for: .milliseconds(300))
            controller.preview(tool: tool, select: select, editText: editText, actualSize: actualSize)
            Log.app.notice("debug.editor-demo open, \(controller.session.document.items.count, privacy: .public) mark(s)")
        }
    }

    /// Acts on the open demo editor: drag=x1,y1,x2,y2 (capture pixels) with tool=, shift=1, option=1,
    /// clicks=2; key=<characters>&code=<key code>[&cmd=1|&shift=1]; type=<text> into the text being
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
        Log.app.notice("debug.editor-act \(editor.debugSummary, privacy: .public)")
        if value("chain") == "1" {
            Log.app.notice("debug.editor-chain \(editor.debugUndoChain, privacy: .public)")
        }
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
