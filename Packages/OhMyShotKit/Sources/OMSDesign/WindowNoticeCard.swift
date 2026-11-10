import AppKit
import SwiftUI

/// A notice over a window's content: Studio's export and preview notices, the recording window's busy card, Capture
/// History's loading note. The window's own ground behind its words, 12 pt continuous corners, the separator's
/// hairline, and the shadow of a bar floating over a picture.
public struct WindowNoticeCard: ViewModifier {
    public init() {}

    public func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
        content
            .background(Color(nsColor: .windowBackgroundColor), in: shape)
            .overlay(shape.strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.16), radius: 10, y: 3)
    }
}

public extension View {
    /// Dresses a notice over a window's content as every window's notices are (`WindowNoticeCard`).
    func windowNoticeCard() -> some View {
        modifier(WindowNoticeCard())
    }
}
