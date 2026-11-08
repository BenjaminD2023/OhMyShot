import SwiftUI

/// Buttons of one width side by side, or one above the other, full width, when a language's labels are too long for
/// each to fit its share of the row. The community invitation lays its buttons out the same way.
struct ButtonRow: Layout {
    var horizontalSpacing: CGFloat = 10
    var verticalSpacing: CGFloat = 8

    private func fitsInRow(_ subviews: Subviews, width: CGFloat?) -> Bool {
        guard let width, !subviews.isEmpty else { return true }
        let widest = subviews.map { $0.sizeThatFits(.unspecified).width }.max() ?? 0
        let count = CGFloat(subviews.count)
        return widest * count + horizontalSpacing * (count - 1) <= width
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let width = proposal.width ?? sizes.map(\.width).reduce(0, +)
        let height = sizes.map(\.height).max() ?? 0
        if fitsInRow(subviews, width: proposal.width) {
            return CGSize(width: width, height: height)
        }
        let count = CGFloat(subviews.count)
        return CGSize(width: width, height: sizes.map(\.height).reduce(0, +) + verticalSpacing * (count - 1))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let count = CGFloat(subviews.count)
        if fitsInRow(subviews, width: bounds.width) {
            let width = (bounds.width - horizontalSpacing * (count - 1)) / count
            for (index, subview) in subviews.enumerated() {
                let x = bounds.minX + CGFloat(index) * (width + horizontalSpacing)
                subview.place(at: CGPoint(x: x, y: bounds.minY), proposal: ProposedViewSize(width: width, height: bounds.height))
            }
        } else {
            // The default button, last and rightmost in a row, on top, as in a stacked alert.
            var y = bounds.minY
            for subview in subviews.reversed() {
                let height = subview.sizeThatFits(.unspecified).height
                subview.place(at: CGPoint(x: bounds.minX, y: y), proposal: ProposedViewSize(width: bounds.width, height: height))
                y += height + verticalSpacing
            }
        }
    }
}
