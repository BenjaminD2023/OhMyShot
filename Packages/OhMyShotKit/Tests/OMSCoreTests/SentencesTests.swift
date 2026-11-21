import OMSCore
import Testing

struct SentencesTests {
    @Test func latinSentencesTakeASpace() {
        #expect(Sentences.joined("Saved the last 15 seconds.", "Nothing changed on the display.") == "Saved the last 15 seconds. Nothing changed on the display.")
    }

    @Test func fullWidthEndsTakeNone() {
        #expect(Sentences.joined("已保存最后 15 秒。", "显示器上没有变化。") == "已保存最后 15 秒。显示器上没有变化。")
        #expect(Sentences.joined("履歴がオフです。", "範囲をキャプチャするには⌘⇧4を押してください。") == "履歴がオフです。範囲をキャプチャするには⌘⇧4を押してください。")
    }

    @Test func mixedLanguagesAndMissingParts() {
        #expect(Sentences.joined("服务器不接受凭据。", "Invalid access key") == "服务器不接受凭据。Invalid access key")
        #expect(Sentences.joined("The server didn’t accept the credentials.", nil) == "The server didn’t accept the credentials.")
        #expect(Sentences.joined(["", "  One. ", "Two."]) == "One. Two.")
    }

    /// A help put together sentence by sentence comes apart into those sentences, in every script.
    @Test func splitUndoesJoined() {
        let english = ["Drag to capture an area.", "The arrow keys move the corner a pixel, ten with Shift.", "Press Escape to cancel."]
        #expect(Sentences.split(Sentences.joined(english)) == english)
        let chinese = ["拖移以截取区域。", "方向键将角移动一个像素，按住 Shift 键则移动十个像素。", "按下 Esc 键取消。"]
        #expect(Sentences.split(Sentences.joined(chinese)) == chinese)
        let japanese = ["ドラッグして範囲をキャプチャします。", "キャンセルするにはescキーを押します。"]
        #expect(Sentences.split(Sentences.joined(japanese)) == japanese)
        #expect(Sentences.split("  ") == [])
    }
}
