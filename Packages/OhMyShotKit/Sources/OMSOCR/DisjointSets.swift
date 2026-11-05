/// Sets of indices that have been joined, by union-find: the boxes of a row, the lines of a block or a paragraph,
/// a column's lines, the sizes harmonized together, a formula and the lines on its row.
struct DisjointSets {
    private var parent: [Int]

    init(count: Int) {
        parent = Array(0..<count)
    }

    /// The index that stands for `index`'s set, the same for each of its indices until the set is joined to another.
    /// Shortens the way to it as it goes.
    mutating func root(_ index: Int) -> Int {
        var index = index
        while parent[index] != index {
            parent[index] = parent[parent[index]]
            index = parent[index]
        }
        return index
    }

    /// Joins the sets of `a` and `b`: the one that stood for `a`'s stands for both.
    mutating func join(_ a: Int, _ b: Int) {
        parent[root(b)] = root(a)
    }

    /// The sets, each its indices in order, the sets in the order of their first index.
    var groups: [[Int]] {
        var sets = self
        var members: [Int: [Int]] = [:]
        for index in parent.indices { members[sets.root(index), default: []].append(index) }
        return members.values.sorted { $0[0] < $1[0] }
    }
}
