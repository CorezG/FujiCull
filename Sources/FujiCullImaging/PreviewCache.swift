/// A least-recently-used cache bounded by total cost in bytes (DESIGN §5.4 memory budget).
/// Memory only, by design: nothing is ever written to the Mac's disk (ADR-002).
/// Holds a few dozen entries at most, so a simple recency list is enough.
public struct PreviewCache<Key: Hashable, Value> {
    public let byteBudget: Int
    public private(set) var totalCost = 0

    private var entries: [Key: (value: Value, cost: Int)] = [:]
    /// Least recent first.
    private var recency: [Key] = []

    public init(byteBudget: Int) {
        self.byteBudget = byteBudget
    }

    /// Returns the value and marks it most recently used.
    public mutating func value(for key: Key) -> Value? {
        guard let entry = entries[key] else { return nil }
        touch(key)
        return entry.value
    }

    /// Stores `value`, evicting the least recently used entries until the budget fits.
    /// A value costing more than the whole budget isn't stored.
    public mutating func insert(_ value: Value, for key: Key, cost: Int) {
        remove(key)
        guard cost <= byteBudget else { return }
        entries[key] = (value, cost)
        recency.append(key)
        totalCost += cost
        while totalCost > byteBudget, let oldest = recency.first {
            remove(oldest)
        }
    }

    public mutating func remove(_ key: Key) {
        guard let entry = entries.removeValue(forKey: key) else { return }
        totalCost -= entry.cost
        recency.removeAll { $0 == key }
    }

    public mutating func removeAll() {
        entries.removeAll()
        recency.removeAll()
        totalCost = 0
    }

    private mutating func touch(_ key: Key) {
        recency.removeAll { $0 == key }
        recency.append(key)
    }
}
