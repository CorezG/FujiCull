/// Which frames to load around the cursor and how urgently: the current frame, three ahead, one behind
/// (DESIGN §5.4). Pure, so the viewer's prefetching is testable without a window.
public enum PrefetchWindow {
    public struct Request: Equatable, Sendable {
        public let index: Int
        public let priority: ReadPriority
    }

    public static func requests(cursor: Int, count: Int) -> [Request] {
        guard (0..<count).contains(cursor) else { return [] }
        let wanted: [(Int, ReadPriority)] = [
            (cursor, .current), (cursor + 1, .ahead1), (cursor + 2, .ahead2), (cursor + 3, .ahead3),
            (cursor - 1, .behind1),
        ]
        return wanted.filter { (0..<count).contains($0.0) }.map { Request(index: $0.0, priority: $0.1) }
    }
}
