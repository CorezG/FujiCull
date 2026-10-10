/// The order of the background T0 pass: from the cursor to the end, then from the start, so thumbnails
/// near what the user is looking at fill in first (DESIGN §5.4).
public enum MetadataPass {
    public static func order(count: Int, startingAt start: Int) -> [Int] {
        guard count > 0 else { return [] }
        let first = (0..<count).contains(start) ? start : 0
        return Array(first..<count) + Array(0..<first)
    }
}
