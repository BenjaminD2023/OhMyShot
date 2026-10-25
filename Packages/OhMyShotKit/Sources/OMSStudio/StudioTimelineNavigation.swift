import Foundation

nonisolated enum StudioTimelineNavigation {
    struct Item: Equatable, Sendable {
        let selection: StudioSelection
        let start: Double
        let order: Int
        let key: String
    }

    static func items(
        zooms: [StudioProject.Zoom], cuts: [ClosedRange<Double>], layouts: [StudioProject.CameraSegment]
    ) -> [Item] {
        let zoomItems = zooms.map { Item(selection: .zoom($0.id), start: $0.start, order: 0, key: $0.id.uuidString) }
        let cutItems = cuts.map { Item(selection: .cut($0.lowerBound), start: $0.lowerBound, order: 1, key: String($0.lowerBound)) }
        let layoutItems = layouts.map { Item(selection: .cameraSegment($0.id), start: $0.start, order: 2, key: $0.id.uuidString) }
        return (zoomItems + cutItems + layoutItems).sorted {
            if $0.start != $1.start { return $0.start < $1.start }
            if $0.order != $1.order { return $0.order < $1.order }
            return $0.key < $1.key
        }
    }

    static func adjacent(in items: [Item], selection: StudioSelection, time: Double, forward: Bool) -> Item? {
        guard !items.isEmpty else { return nil }
        if let index = items.firstIndex(where: { $0.selection == selection }) {
            return items[min(max(index + (forward ? 1 : -1), 0), items.count - 1)]
        }
        return forward
            ? (items.first { $0.start >= time } ?? items.last)
            : (items.last { $0.start <= time } ?? items.first)
    }
}
