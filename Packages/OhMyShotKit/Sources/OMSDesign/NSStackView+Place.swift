import AppKit

public extension NSStackView {
    /// Adds, removes, or shows a bar's arranged views with room to spare, then places the stack in `rect`. A bar's stack
    /// starts at 0 × 0, and a capsule is still at its old width while a new tool adds its chips; AppKit checks each
    /// chip's required size as it is added, and in a stack that small it logs a broken constraint for every one.
    func rearrange(in rect: CGRect, _ change: () -> Void) {
        makeRoom()
        change()
        place(in: rect)
    }

    /// Room to spare for the arranged views a bar adds as it is built, before its first layout places the stack.
    func makeRoom() {
        frame.size = CGSize(width: max(frame.width, Self.room), height: max(frame.height, Self.room))
    }

    /// Places a bar's stack in `rect`, never smaller than its arranged views need (see `rearrange`). Once the bar has
    /// its size (its fitting size, as bars are sized), this is `rect` itself.
    func place(in rect: CGRect) {
        let fitting = fittingSize
        frame = CGRect(origin: rect.origin, size: CGSize(width: max(rect.width, fitting.width), height: max(rect.height, fitting.height)))
    }

    /// More room than any bar takes.
    private static let room: CGFloat = 10_000
}
