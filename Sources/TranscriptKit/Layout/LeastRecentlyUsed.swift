/// Values with a cost each, of which it keeps the most recently used, up to
/// a total cost. The newest value always stays, even when it alone costs more.
struct LeastRecentlyUsed<Key: Hashable, Value> {
    private struct Node {
        var value: Value
        var cost: Int
        var older: Key?
        var newer: Key?
    }

    let costLimit: Int
    private var nodes: [Key: Node] = [:]
    private var oldest: Key?
    private var newest: Key?
    private(set) var totalCost = 0

    init(costLimit: Int) {
        self.costLimit = max(costLimit, 0)
    }

    var count: Int { nodes.count }

    /// The value for `key`, which becomes the most recently used.
    mutating func value(for key: Key) -> Value? {
        guard let node = unlink(key) else { return nil }
        link(key, node)
        return node.value
    }

    /// Whether `key` has a value, without using it.
    func contains(_ key: Key) -> Bool { nodes[key] != nil }

    /// Keeps `value` as the most recently used, and removes the least
    /// recently used values while the total cost is over the limit.
    mutating func set(_ value: Value, for key: Key, cost: Int) {
        if let old = unlink(key) { totalCost -= old.cost }
        let cost = max(cost, 0)
        link(key, Node(value: value, cost: cost))
        totalCost += cost
        while totalCost > costLimit, let oldest, oldest != key, let removed = unlink(oldest) {
            totalCost -= removed.cost
        }
    }

    mutating func removeAll() {
        nodes = [:]
        oldest = nil
        newest = nil
        totalCost = 0
    }

    private mutating func unlink(_ key: Key) -> Node? {
        guard let node = nodes.removeValue(forKey: key) else { return nil }
        if let older = node.older { nodes[older]?.newer = node.newer } else { oldest = node.newer }
        if let newer = node.newer { nodes[newer]?.older = node.older } else { newest = node.older }
        return Node(value: node.value, cost: node.cost)
    }

    private mutating func link(_ key: Key, _ node: Node) {
        var node = node
        node.older = newest
        node.newer = nil
        if let newest { nodes[newest]?.newer = key } else { oldest = key }
        newest = key
        nodes[key] = node
    }
}
