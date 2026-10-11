/// The culling state of one source: a decision per frame, the cursor, the Undecided-only filter and undo
/// (DESIGN §5.2). A value type with one entry point, `apply(_:)`, so every key is a unit test.
///
/// Rules, in addition to the per-command ones:
/// - A favourite is always a Keep (R8), and so is a photo flagged for editing (R28).
/// - When the filter is on, the cursor sits on an undecided frame if there is one (D4).
/// - Undo covers decisions only, and returns the cursor to the frame it changed (D3).
public struct CullSession: Equatable, Sendable {
    public let frameIDs: [FrameID]
    public private(set) var cursor = 0
    public private(set) var undecidedOnly = false
    /// Advance after ↑/↓ (R11). Always implied while the filter is on.
    public var autoAdvance: Bool
    public private(set) var counts: CullCounts

    /// Only frames that aren't plain Undecided are stored.
    private var marks: [FrameID: FrameMark] = [:]
    private var undoStack: [(frame: Int, previous: FrameMark)] = []

    /// `cursor` and `undecidedOnly` restore a saved position; an unknown cursor starts at the first frame.
    public init(
        frameIDs: [FrameID], marks: [FrameID: FrameMark] = [:], autoAdvance: Bool = true, cursor: FrameID? = nil,
        undecidedOnly: Bool = false
    ) {
        self.frameIDs = frameIDs
        self.autoAdvance = autoAdvance
        self.counts = CullCounts(keep: 0, reject: 0, undecided: frameIDs.count, favourite: 0)
        for id in frameIDs {
            if let mark = marks[id]?.normalised, mark != FrameMark() { setMark(mark, for: id) }
        }
        if let cursor, let index = frameIDs.firstIndex(of: cursor) { self.cursor = index }
        self.undecidedOnly = undecidedOnly
        if !frameIDs.isEmpty { settleCursor(from: self.cursor) }
    }

    public static func == (lhs: CullSession, rhs: CullSession) -> Bool {
        lhs.frameIDs == rhs.frameIDs && lhs.cursor == rhs.cursor && lhs.undecidedOnly == rhs.undecidedOnly
            && lhs.autoAdvance == rhs.autoAdvance && lhs.marks == rhs.marks
            && lhs.undoStack.map(\.frame) == rhs.undoStack.map(\.frame)
            && lhs.undoStack.map(\.previous) == rhs.undoStack.map(\.previous)
    }

    // MARK: Reading

    public func mark(at index: Int) -> FrameMark {
        marks[frameIDs[index]] ?? FrameMark()
    }

    /// Every stored mark that isn't Undecided, for saving.
    public var storedMarks: [FrameID: FrameMark] { marks }

    /// Indices of the frames the user is moving through: all of them, or only Undecided ones.
    public var visibleIndices: [Int] {
        undecidedOnly ? frameIDs.indices.filter(isVisible) : Array(frameIDs.indices)
    }

    /// The frame under the cursor, or nil when there's nothing to show.
    public var currentFrameID: FrameID? {
        guard frameIDs.indices.contains(cursor), isVisible(cursor) else { return nil }
        return frameIDs[cursor]
    }

    public var canUndo: Bool { !undoStack.isEmpty }

    // MARK: Commands

    public mutating func apply(_ command: CullCommand) {
        guard !frameIDs.isEmpty else { return }
        switch command {
        case .keep:
            let mark = self.mark(at: cursor)
            decide(FrameMark(decision: .keep, isFavourite: mark.isFavourite, needsEdit: mark.needsEdit), advance: true)
        case .reject:
            decide(FrameMark(decision: .reject), advance: true)
        case .toggleFavourite:
            let mark = self.mark(at: cursor)
            decide(
                FrameMark(decision: .keep, isFavourite: !mark.isFavourite, needsEdit: mark.needsEdit), advance: false)
        case .toggleNeedsEdit:
            let mark = self.mark(at: cursor)
            decide(
                FrameMark(decision: .keep, isFavourite: mark.isFavourite, needsEdit: !mark.needsEdit), advance: false)
        case .reset:
            decide(FrameMark(), advance: false)
        case .next:
            move(by: 1)
        case .previous:
            move(by: -1)
        case .jump(let delta):
            move(by: delta)
        case .goTo(let index):
            if frameIDs.indices.contains(index), isVisible(index) { cursor = index }
        case .undo:
            undo()
        case .toggleUndecidedFilter:
            undecidedOnly.toggle()
            settleCursor(from: cursor)
        }
    }

    // MARK: Internals

    private func isVisible(_ index: Int) -> Bool {
        !undecidedOnly || mark(at: index).decision == .undecided
    }

    private mutating func decide(_ newMark: FrameMark, advance: Bool) {
        guard isVisible(cursor) else { return }
        let index = cursor
        let previous = mark(at: index)
        guard newMark != previous else { return }
        undoStack.append((index, previous))
        setMark(newMark, for: frameIDs[index])
        if advance && (autoAdvance || undecidedOnly) {
            if let next = (index + 1..<frameIDs.count).first(where: isVisible) { cursor = next }
        }
        settleCursor(from: cursor)
    }

    private mutating func move(by delta: Int) {
        let visible = visibleIndices
        guard !visible.isEmpty else { return }
        // Position in the visible list; a cursor between visible frames counts from the next one.
        let position = visible.firstIndex { $0 >= cursor } ?? visible.count - 1
        let base = visible[position] == cursor || delta > 0 ? position : position - 1
        cursor = visible[min(max(base + delta, 0), visible.count - 1)]
    }

    /// Clears a restored decision that turned out not to belong to this frame (SR2). It isn't a user action,
    /// so nothing is added to undo, and undo steps already recorded for the frame are dropped.
    public mutating func discardMark(of id: FrameID) {
        guard marks[id] != nil, let index = frameIDs.firstIndex(of: id) else { return }
        setMark(FrameMark(), for: id)
        undoStack.removeAll { $0.frame == index }
        settleCursor(from: cursor)
    }

    /// The session once Apply has deleted `deleted` from the card (SR21). Every other frame keeps its
    /// decision and its undo history; undo steps for the deleted frames go with them, because there is
    /// nothing left to undo. The cursor stays on the same photo, or moves to the next one left.
    public func removing(_ deleted: Set<FrameID>) -> CullSession {
        guard !deleted.isEmpty else { return self }
        var newIndex: [Int: Int] = [:]
        var kept: [FrameID] = []
        for (index, id) in frameIDs.enumerated() where !deleted.contains(id) {
            newIndex[index] = kept.count
            kept.append(id)
        }
        let landing =
            (cursor..<frameIDs.count).first { newIndex[$0] != nil }
            ?? (0..<min(cursor, frameIDs.count)).last { newIndex[$0] != nil }
        var next = CullSession(
            frameIDs: kept, marks: marks, autoAdvance: autoAdvance, cursor: landing.map { frameIDs[$0] },
            undecidedOnly: undecidedOnly)
        next.undoStack = undoStack.compactMap { step in newIndex[step.frame].map { ($0, step.previous) } }
        return next
    }

    private mutating func undo() {
        guard let last = undoStack.popLast() else { return }
        setMark(last.previous, for: frameIDs[last.frame])
        cursor = last.frame
        settleCursor(from: cursor)
    }

    /// Keeps the cursor on a visible frame: itself, else the next one, else the previous one.
    private mutating func settleCursor(from index: Int) {
        guard !isVisible(index) else { return }
        if let next = (index + 1..<frameIDs.count).first(where: isVisible) {
            cursor = next
        } else if let previous = (0..<index).last(where: isVisible) {
            cursor = previous
        }
    }

    private mutating func setMark(_ mark: FrameMark, for id: FrameID) {
        let old = marks[id] ?? FrameMark()
        adjustCounts(for: old, by: -1)
        adjustCounts(for: mark, by: 1)
        marks[id] = mark == FrameMark() ? nil : mark
    }

    private mutating func adjustCounts(for mark: FrameMark, by amount: Int) {
        switch mark.decision {
        case .keep: counts.keep += amount
        case .reject: counts.reject += amount
        case .undecided: counts.undecided += amount
        }
        if mark.isFavourite { counts.favourite += amount }
        if mark.needsEdit { counts.needsEdit += amount }
    }
}
