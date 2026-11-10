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
}
