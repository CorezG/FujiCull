/// A frame's cull state (R7). Every frame starts Undecided.
public enum Decision: String, Codable, Sendable {
    case undecided
    case keep
    case reject
}

/// A decision plus the ♥ flag. `isFavourite` implies `.keep`; `CullSession` keeps that true (R8).
public struct FrameMark: Hashable, Codable, Sendable {
    public var decision: Decision
    public var isFavourite: Bool

    public init(decision: Decision = .undecided, isFavourite: Bool = false) {
        self.decision = decision
        self.isFavourite = isFavourite
    }

    /// The same mark with the favourite invariant enforced.
    var normalised: FrameMark {
        FrameMark(decision: decision, isFavourite: isFavourite && decision == .keep)
    }
}

/// Totals for the overlay (R16), kept up to date incrementally.
public struct CullCounts: Equatable, Sendable {
    public var keep: Int
    public var reject: Int
    public var undecided: Int
    public var favourite: Int

    public init(keep: Int, reject: Int, undecided: Int, favourite: Int) {
        self.keep = keep
        self.reject = reject
        self.undecided = undecided
        self.favourite = favourite
    }
}

/// Everything the keyboard can do to a session (REQUIREMENTS §4.3). View toggles (zoom, grid, EXIF)
/// are UI state and live in the app.
public enum CullCommand: Equatable, Sendable {
    case keep
    case reject
    case toggleFavourite
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
