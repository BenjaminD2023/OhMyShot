import Foundation
import Testing
@testable import OMSCore

/// Which captures are pictures, movies, and GIFs.
struct CaptureMediaTests {
    @Test func aRecordingKeptAsAGIFIsAGIF() {
        #expect(CaptureMedia(kind: .recording, fileExtension: "gif") == .gif)
        #expect(CaptureMedia(kind: .recording, fileExtension: "GIF") == .gif)
        #expect(CaptureMedia(kind: .recording, fileExtension: "mov") == .movie)
        #expect(CaptureMedia(kind: .recording, fileExtension: "mp4") == .movie)
        #expect(CaptureMedia(recordingAt: URL(filePath: "/tmp/Recording.gif")) == .gif)
        #expect(CaptureMedia(recordingAt: URL(filePath: "/tmp/Recording.mp4")) == .movie)
    }

    /// The kind decides first: a picture is a picture, whatever its file is called.
    @Test func aScreenshotIsAScreenshot() {
        #expect(CaptureMedia(kind: .screenshot, fileExtension: "gif") == .screenshot)
        #expect(CaptureMedia(kind: .screenshot, fileExtension: "png") == .screenshot)
    }
}
