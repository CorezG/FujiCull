/// A frame's cull state (R7). Every frame starts Undecided.
public enum Decision: String, Codable, Sendable {
    case undecided
    case keep
    case reject
}

/// A decision plus two flags: ♥ favourite (R8), and "needs editing" for a photo whose RAW file wants more
/// than basic adjustments (R28). Both imply `.keep`; `CullSession` keeps that true.
public struct FrameMark: Hashable, Codable, Sendable {
    public var decision: Decision
    public var isFavourite: Bool
    public var needsEdit: Bool

    public init(decision: Decision = .undecided, isFavourite: Bool = false, needsEdit: Bool = false) {
        self.decision = decision
        self.isFavourite = isFavourite
        self.needsEdit = needsEdit
    }

    // Sessions saved before the edit flag existed have no `needsEdit`.
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        decision = try values.decode(Decision.self, forKey: .decision)
        isFavourite = try values.decode(Bool.self, forKey: .isFavourite)
        needsEdit = try values.decodeIfPresent(Bool.self, forKey: .needsEdit) ?? false
    }

    /// The same mark with the "flags imply Keep" invariant enforced.
    var normalised: FrameMark {
        let isKeep = decision == .keep
        return FrameMark(decision: decision, isFavourite: isFavourite && isKeep, needsEdit: needsEdit && isKeep)
    }
}

/// Totals for the overlay (R16), kept up to date incrementally.
public struct CullCounts: Equatable, Sendable {
    public var keep: Int
    public var reject: Int
    public var undecided: Int
    public var favourite: Int
    public var needsEdit: Int

    public init(keep: Int, reject: Int, undecided: Int, favourite: Int, needsEdit: Int = 0) {
        self.keep = keep
        self.reject = reject
        self.undecided = undecided
        self.favourite = favourite
        self.needsEdit = needsEdit
    }
}

/// Everything the keyboard can do to a session (REQUIREMENTS §4.3). View toggles (zoom, grid, EXIF)
/// are UI state and live in the app.
public enum CullCommand: Equatable, Sendable {
    case keep
    case reject
    case toggleFavourite
    /// `,`: flag the photo as needing a RAW edit (R28).
    case toggleNeedsEdit
    case reset
    case next
    case previous
    /// Move by this many frames in the visible list (⇧← / ⇧→ use ±10).
    case jump(Int)
    /// Go straight to a frame, e.g. a click in the filmstrip (R14); ignored if it isn't in the visible list.
    case goTo(Int)
    case undo
    case toggleUndecidedFilter
}
